//! MPEG audio Layers I, II and III (.mp1, .mp2, .mp3) at every MPEG-1, MPEG-2 and MPEG-2.5 rate, decoded to float samples.

const std = @import("std");

const Bits = @import("bits.zig").Bits;
const Field = @import("tags.zig").Field;
const huffman = @import("huffman.zig");
const Source = @import("source.zig").Source;
const Tags = @import("tags.zig").Tags;

/// What goes wrong decoding: bytes that break the format, a valid feature not handled, no memory, or a failed read.
pub const Error = @import("source.zig").Error;

/// How a frame's channels relate; joint stereo codes them together, as Layer III's mid/side and intensity stereo or Layers I and II's shared upper subbands.
pub const Mode = enum(u2) {

    stereo,
    joint,
    dual,
    mono,

};

/// A frame header (4 bytes).
pub const Header = struct {

    /// 1, 2 or 3.
    layer: u2,

    /// Whether the frame is MPEG-2 or MPEG-2.5, whose lower rates give Layer III one granule a frame.
    lsf: bool,

    /// Sample rate in Hz, and its place 0 to 8 across MPEG-1, MPEG-2 and MPEG-2.5, which picks the band tables.
    rate: u32,
    table: u4,

    /// 1 or 2, how they relate, and the mode extension: Layer III's mid/side (2) and intensity (1) bits, or Layers I and II's shared subbands.
    channels: u8,
    mode: Mode,
    extension: u2,

    /// Kbit/s; 0 is free format.
    bitrate: u32,

    /// Whether the frame carries one more slot (a byte, or four in Layer I) to keep the bitrate exact.
    padded: bool,

    /// Whether a 16-bit CRC follows the header.
    protected: bool,

    /// Null if `word` is not a valid header.
    pub fn parse(word: u32) ?Header {

        if (word >> 21 != 0x7ff) return null;

        const version: u2 = @truncate(word >> 19);
        const code: u2 = @truncate(word >> 17);
        const index: u4 = @truncate(word >> 12);
        const frequency: u2 = @truncate(word >> 10);

        // Version 1, layer 0, bitrate 15 and rate 3 are all reserved.
        if (version == 1 or code == 0 or index == 15 or frequency == 3) return null;

        const lsf = version != 3;
        const layer: u2 = @intCast(4 - @as(u3, code));
        const mode: Mode = @enumFromInt(@as(u2, @truncate(word >> 6)));
        const table = @as(u4, switch (version) {

            3 => 0,
            2 => 3,
            else => 6,

        }) + frequency;

        return .{

            .layer = layer,
            .lsf = lsf,

            .rate = rates[table],
            .table = table,

            .channels = if (mode == .mono) 1 else 2,
            .mode = mode,
            .extension = @truncate(word >> 4),

            .bitrate = bitrates[@intFromBool(lsf)][layer - 1][index],
            .padded = (word >> 9) & 1 != 0,

            .protected = (word >> 16) & 1 == 0,

        };

    }

    /// Bytes in the whole frame including header and padding; 0 for free format, whose frames do not say.
    pub fn size(self: Header) usize {

        if (self.bitrate == 0) return 0;

        const bits: usize = self.bitrate * 1000;
        const padding: usize = @intFromBool(self.padded);

        return switch (self.layer) {

            1 => (12 * bits / self.rate + padding) * 4,
            2 => 144 * bits / self.rate + padding,
            else => (if (self.lsf) @as(usize, 72) else 144) * bits / self.rate + padding,

        };

    }

    /// Sample frames per channel this frame decodes to.
    pub fn samples(self: Header) usize {

        return switch (self.layer) {

            1 => 384,
            2 => 1152,
            else => if (self.lsf) 576 else 1152,

        };

    }

    /// Bytes of Layer III side information after the header and CRC.
    fn side(self: Header) usize {

        if (self.lsf) return if (self.channels == 1) 9 else 17;

        return if (self.channels == 1) 17 else 32;

    }

    /// Whether `other` can continue a stream this header began.
    fn matches(self: Header, other: Header) bool {

        return self.layer == other.layer and self.rate == other.rate;

    }

};

/// Decodes frames one after another, keeping what spans them: Layer III's bit reservoir, IMDCT overlap, and the synthesis filterbank's history.
pub const Frames = struct {

    /// Layer III main data of earlier frames, which a frame's granules may begin in.
    reservoir: [2048]u8 = undefined,
    reserved: usize = 0,

    /// Each channel's subbands' second IMDCT halves from the last granule, added to the next granule's first halves.
    overlap: [2][32][18]f32 = @splat(@splat(@splat(0))),

    synthesis: [2]Synthesis = .{ .{}, .{} },

    /// Frames decoded in a row with all their main data; after two, what follows owes nothing to a reset.
    whole: usize = 0,

    /// Nothing carried yet; works out the shared tables on first use.
    pub fn init() Frames {

        prepare();

        return .{};

    }

    /// Decodes one whole frame starting at its header; writes interleaved samples (header's channel count) to `out` (at least samples()*channels long); returns sample frames written.
    pub fn decode(self: *Frames, frame: []const u8, out: []f32) Error!usize {

        prepare();

        if (frame.len < 4) return error.Invalid;

        const header = Header.parse(std.mem.readInt(u32, frame[0..4], .big)) orelse return error.Invalid;

        if (header.bitrate == 0) return error.Unsupported;

        const length = header.size();
        const count = header.samples();

        if (frame.len < length or out.len < count * header.channels) return error.Invalid;

        const head: usize = if (header.protected) 6 else 4;
        const body = frame[head..length];

        self.whole += 1;
        errdefer self.whole = 0;

        switch (header.layer) {

            1 => try self.layer1(header, body, out),
            2 => try self.layer2(header, body, out),
            else => try self.layer3(header, body, out),

        }

        return count;

    }

    /// Forgets everything carried between frames, as after a seek.
    pub fn reset(self: *Frames) void {

        self.reserved = 0;
        self.overlap = @splat(@splat(@splat(0)));
        self.synthesis = .{ .{}, .{} };
        self.whole = 0;

    }

    fn layer1(self: *Frames, header: Header, body: []const u8, out: []f32) Error!void {

        var bits = Bits.init(body);
        const channels = header.channels;
        const shared = bound(header, 32);
        const steps = &tables.scales;
        var fields: [2][32]u5 = @splat(@splat(0));
        var scales: [2][32]f32 = @splat(@splat(0));

        for (0..32) |band| {

            for (0..channels) |channel| {

                fields[channel][band] = if (channel > 0 and band >= shared) fields[0][band] else @intCast(bits.read(4));

                if (fields[channel][band] == 15) return error.Invalid;

            }

        }

        for (0..32) |band| {

            for (0..channels) |channel| {

                if (fields[channel][band] != 0) scales[channel][band] = steps[bits.read(6)];

            }

        }

        for (0..12) |slot| {

            var samples: [2][32]f32 = @splat(@splat(0));

            for (0..32) |band| {

                var fraction: f32 = 0;

                for (0..channels) |channel| {

                    const width: u6 = fields[channel][band];

                    if (width == 0) continue;
                    if (channel == 0 or band < shared) fraction = level(bits.read(width + 1), (@as(u32, 2) << @intCast(width)) - 1);

                    samples[channel][band] = fraction * scales[channel][band];

                }

            }

            for (0..channels) |channel| self.synthesis[channel].run(&samples[channel], out[slot * 32 * channels + channel ..], channels);

        }

        if (bits.overrun()) return error.Invalid;

    }

    fn layer2(self: *Frames, header: Header, body: []const u8, out: []f32) Error!void {

        var bits = Bits.init(body);
        const channels = header.channels;
        const layout = allocation(header);
        const limit = layout.limit;
        const shared = bound(header, limit);
        const steps = &tables.scales;
        var classes: [2][32]u8 = @splat(@splat(0));
        var choices: [2][32]u2 = @splat(@splat(0));
        var scales: [2][32][3]f32 = @splat(@splat(@splat(0)));

        for (0..limit) |band| {

            const entry = layout.bands[band];

            for (0..channels) |channel| {

                classes[channel][band] = if (channel > 0 and band >= shared) classes[0][band] else rows[entry.row][bits.read(entry.bits)];

            }

        }

        for (0..limit) |band| {

            for (0..channels) |channel| {

                if (classes[channel][band] != 0) choices[channel][band] = @intCast(bits.read(2));

            }

        }

        for (0..limit) |band| {

            for (0..channels) |channel| {

                if (classes[channel][band] == 0) continue;

                const factors = &scales[channel][band];

                factors[0] = steps[bits.read(6)];

                // Which of the three parts share a scalefactor.
                switch (choices[channel][band]) {

                    0 => {

                        factors[1] = steps[bits.read(6)];
                        factors[2] = steps[bits.read(6)];

                    },
                    1 => {

                        factors[1] = factors[0];
                        factors[2] = steps[bits.read(6)];

                    },
                    2 => {

                        factors[1] = factors[0];
                        factors[2] = factors[0];

                    },
                    3 => {

                        factors[1] = steps[bits.read(6)];
                        factors[2] = factors[1];

                    },

                }

            }

        }

        for (0..12) |group| {

            const part = group / 4;
            var samples: [3][2][32]f32 = @splat(@splat(@splat(0)));

            for (0..limit) |band| {

                var fractions = [3]f32{ 0, 0, 0 };

                for (0..channels) |channel| {

                    const class = classes[channel][band];

                    if (class == 0) continue;
                    if (channel == 0 or band < shared) fractions = triple(&bits, quantizers[class - 1]);

                    for (0..3) |slot| samples[slot][channel][band] = fractions[slot] * scales[channel][band][part];

                }

            }

            for (0..3) |slot| {

                for (0..channels) |channel| self.synthesis[channel].run(&samples[slot][channel], out[(group * 3 + slot) * 32 * channels + channel ..], channels);

            }

        }

        if (bits.overrun()) return error.Invalid;

    }

    fn layer3(self: *Frames, header: Header, body: []const u8, out: []f32) Error!void {

        const length = header.side();

        if (body.len < length) return error.Invalid;

        const side = try Side.parse(header, body[0..length]);
        const main = body[length..];

        if (main.len > self.reservoir.len - self.reserved) return error.Invalid;

        // Main data beginning in bytes not held, as just after a seek, decodes as silence.
        const missing = side.begin > self.reserved;

        if (missing) self.whole = 0;

        const begin = if (missing) self.reserved else self.reserved - side.begin;

        @memcpy(self.reservoir[self.reserved..][0..main.len], main);
        self.reserved += main.len;

        defer self.keep();

        const data = self.reservoir[begin..self.reserved];
        const channels = header.channels;
        var bits = Bits.init(data);
        var position: usize = 0;
        var factors = [2]Factors{ .{}, .{} };

        for (0..@as(usize, if (header.lsf) 1 else 2)) |round| {

            var spectra: [2][576]f32 = undefined;

            for (0..channels) |channel| {

                var granule = side.granules[round][channel];

                if (missing) {

                    @memset(&spectra[channel], 0);
                    continue;

                }

                bits.position = position;
                position += granule.part;

                if (header.lsf) {

                    readFactorsTwo(&bits, &granule, header, channel, &factors[channel]);

                } else {

                    readFactorsOne(&bits, granule, side.scfsi[channel], round == 1, &factors[channel]);

                }

                var values: [576]i32 = undefined;
                const count = try spectrum(&bits, granule, position, &values);

                if (bits.overrun()) return error.Invalid;

                requantize(&values, count, granule, &factors[channel], header, &spectra[channel]);

            }

            if (channels == 2 and header.mode == .joint and !missing) stereo(&spectra, header, side.granules[round][1], &factors[1]);

            for (0..channels) |channel| {

                var slots: [18][32]f32 = undefined;

                self.hybrid(&spectra[channel], side.granules[round][channel], header, channel, &slots);

                for (&slots, 0..) |*slot, time| self.synthesis[channel].run(slot, out[(round * 576 + time * 32) * channels + channel ..], channels);

            }

        }

    }

    /// Keeps the most main data a later frame may reach back into.
    fn keep(self: *Frames) void {

        const kept = @min(self.reserved, 511);

        std.mem.copyForwards(u8, self.reservoir[0..kept], self.reservoir[self.reserved - kept .. self.reserved]);
        self.reserved = kept;

    }

    /// Reorders, alias-reduces and inverse-transforms one channel's granule into 18 time slots of 32 subband samples.
    fn hybrid(self: *Frames, lines: *[576]f32, granule: Granule, header: Header, channel: usize, slots: *[18][32]f32) void {

        const layout = Shape.of(header, granule);
        const longs: usize = if (granule.block != 2) 32 else if (granule.mixed) long_bands[header.table][layout.long] / 18 else 0;

        if (granule.block == 2) reorder(lines, header.table, layout.short);

        var last: usize = 576;

        while (last > 0 and lines[last - 1] == 0) last -= 1;

        // Alias reduction spreads a subband's top lines into the next one up.
        const active = @min(32, (last + 17) / 18 + 1);
        var band: usize = 1;

        while (band < @min(active, longs)) : (band += 1) {

            for (&tables.alias, 0..) |butterfly, offset| {

                const lower = lines[18 * band - 1 - offset];
                const upper = lines[18 * band + offset];

                lines[18 * band - 1 - offset] = lower * butterfly[0] - upper * butterfly[1];
                lines[18 * band + offset] = upper * butterfly[0] + lower * butterfly[1];

            }

        }

        const overlap = &self.overlap[channel];

        for (0..32) |subband| {

            var output: [36]f32 = undefined;
            const input = lines[18 * subband ..][0..18];

            if (subband >= active) {

                @memset(&output, 0);

            } else if (subband >= longs) {

                shortBlocks(input, &output);

            } else {

                longBlock(input, &tables.windows[if (granule.block == 2) 0 else granule.block], &output);

            }

            for (0..18) |time| {

                const sample = output[time] + overlap[subband][time];

                // Odd subbands come out of the filterbank spectrally inverted.
                slots[time][subband] = if (subband & time & 1 != 0) -sample else sample;
                overlap[subband][time] = output[18 + time];

            }

        }

    }

};

/// MPEG audio arriving a piece at a time, as a film's packets or a radio station send it, held until whole frames are in.
pub const Feed = struct {

    /// The format of the first frame header the one after it confirms; zero until `probe` finds one.
    rate: u32 = 0,
    channels: u8 = 0,

    /// Bytes not yet framed, between `head` and `tail`.
    bytes: []u8,
    head: usize = 0,
    tail: usize = 0,

    pub fn init(bytes: []u8) Feed {

        return .{

            .bytes = bytes,

        };

    }

    /// Bytes `keep` takes without dropping any held.
    pub fn room(self: *const Feed) usize {

        return self.bytes.len - (self.tail - self.head);

    }

    /// Drops every byte held, keeping the format.
    pub fn clear(self: *Feed) void {

        self.head = 0;
        self.tail = 0;

    }

    /// Adds `data`; when it will not fit, what is held goes first, so a source running far ahead loses sound rather than stalls.
    pub fn keep(self: *Feed, data: []const u8) void {

        if (self.tail + data.len > self.bytes.len) {

            std.mem.copyForwards(u8, self.bytes[0 .. self.tail - self.head], self.bytes[self.head..self.tail]);
            self.tail -= self.head;
            self.head = 0;

        }

        if (self.tail + data.len > self.bytes.len) self.clear();

        const count = @min(data.len, self.bytes.len);

        @memcpy(self.bytes[self.tail..][0..count], data[0..count]);
        self.tail += count;

    }

    /// Learns the format from the first frame header the bytes held confirm with the one after it, stepping to that frame.
    pub fn probe(self: *Feed) void {

        const held = self.bytes[self.head..self.tail];
        var index: usize = 0;

        while (index + 4 <= held.len) : (index += 1) {

            const header = Header.parse(std.mem.readInt(u32, held[index..][0..4], .big)) orelse continue;
            const next = index + header.size();

            if (next + 4 > held.len) return;

            const following = Header.parse(std.mem.readInt(u32, held[next..][0..4], .big)) orelse continue;

            if (following.rate != header.rate) continue;

            self.rate = header.rate;
            self.channels = header.channels;
            self.head += index;

            return;

        }

    }

    /// The next whole frame held, stepping over what does not start one at the format's rate; null until more arrive.
    pub fn frame(self: *Feed) ?[]const u8 {

        while (self.tail - self.head >= 4) {

            const held = self.bytes[self.head..self.tail];
            const header = Header.parse(std.mem.readInt(u32, held[0..4], .big)) orelse {

                self.head += 1;
                continue;

            };

            const length = header.size();

            if (length < 4 or header.rate != self.rate and self.rate != 0) {

                self.head += 1;
                continue;

            }

            if (held.len < length) return null;

            self.head += length;

            return held[0..length];

        }

        return null;

    }

};

/// Copies `frames` frames of interleaved `samples` in `from` channels to `out` in `to`, averaging two into one or doubling one.
pub fn remix(samples: []const f32, from: u8, out: []f32, to: u8, frames: usize) void {

    if (from == to) return @memcpy(out[0 .. frames * to], samples[0 .. frames * from]);

    for (0..frames) |index| {

        if (from == 1) {

            out[index * 2] = samples[index];
            out[index * 2 + 1] = samples[index];

        } else {

            out[index] = (samples[index * 2] + samples[index * 2 + 1]) / 2;

        }

    }

}

/// The polyphase filterbank turning one sample of each of 32 subbands into 32 output samples.
const Synthesis = struct {

    /// The last 16 matrixed vectors, the newest at `newest` and older ones after it.
    blocks: [16][64]f32 = @splat(@splat(0)),
    newest: u4 = 0,

    /// Writes 32 samples `stride` apart from the start of `out`.
    fn run(self: *Synthesis, subbands: *const [32]f32, out: []f32, stride: usize) void {

        const Vector = @Vector(32, f32);
        var sum: Vector = @splat(0);

        for (subbands, &tables.cosines) |value, column| sum += column * @as(Vector, @splat(value));

        const dct: [32]f32 = sum;

        self.newest -%= 1;

        // The 64-point matrixing is a 32-point DCT read out with these symmetries.
        const block = &self.blocks[self.newest];

        for (0..16) |index| block[index] = dct[16 + index];
        block[16] = 0;
        for (17..48) |index| block[index] = -dct[48 - index];
        for (48..64) |index| block[index] = -dct[index - 48];

        var result: Vector = @splat(0);

        for (0..8) |pair| {

            const even = &self.blocks[self.newest +% @as(u4, @intCast(2 * pair))];
            const odd = &self.blocks[self.newest +% @as(u4, @intCast(2 * pair + 1))];
            const low: Vector = tables.window[64 * pair ..][0..32].*;
            const high: Vector = tables.window[64 * pair + 32 ..][0..32].*;

            result += @as(Vector, even[0..32].*) * low + @as(Vector, odd[32..64].*) * high;

        }

        const samples: [32]f32 = result;

        for (samples, 0..) |sample, index| out[index * stride] = sample;

    }

};

/// The first subband whose samples both channels share in joint stereo Layers I and II.
fn bound(header: Header, limit: usize) usize {

    if (header.mode != .joint) return limit;

    return @min(limit, (@as(usize, header.extension) + 1) * 4);

}

/// What a Layer I or II sample stands for, of `levels` steps spread evenly over -1 to 1.
fn level(value: u32, levels: u32) f32 {

    const count: f32 = @floatFromInt(levels);

    return (@as(f32, @floatFromInt(value)) * 2 + 1 - count) / count;

}

/// Three consecutive Layer II samples of one subband, as one grouped code or three fields.
fn triple(bits: *Bits, quantizer: Quantizer) [3]f32 {

    var result: [3]f32 = undefined;

    if (quantizer.grouped) {

        var code = bits.read(quantizer.bits);

        for (&result) |*value| {

            value.* = level(code % quantizer.levels, quantizer.levels);
            code /= quantizer.levels;

        }

        return result;

    }

    for (&result) |*value| value.* = level(bits.read(quantizer.bits), quantizer.levels);

    return result;

}

const Quantizer = struct {

    levels: u32,
    bits: u6,
    grouped: bool,

};

/// Layer II's quantizer classes 1 to 17, from 3 levels to 65535; 3, 5 and 9 levels pack three samples in one code.
const quantizers = [17]Quantizer{

    .{ .levels = 3, .bits = 5, .grouped = true },
    .{ .levels = 5, .bits = 7, .grouped = true },
    .{ .levels = 7, .bits = 3, .grouped = false },
    .{ .levels = 9, .bits = 10, .grouped = true },
    .{ .levels = 15, .bits = 4, .grouped = false },
    .{ .levels = 31, .bits = 5, .grouped = false },
    .{ .levels = 63, .bits = 6, .grouped = false },
    .{ .levels = 127, .bits = 7, .grouped = false },
    .{ .levels = 255, .bits = 8, .grouped = false },
    .{ .levels = 511, .bits = 9, .grouped = false },
    .{ .levels = 1023, .bits = 10, .grouped = false },
    .{ .levels = 2047, .bits = 11, .grouped = false },
    .{ .levels = 4095, .bits = 12, .grouped = false },
    .{ .levels = 8191, .bits = 13, .grouped = false },
    .{ .levels = 16383, .bits = 14, .grouped = false },
    .{ .levels = 32767, .bits = 15, .grouped = false },
    .{ .levels = 65535, .bits = 16, .grouped = false },

};

/// The quantizer class each allocation value means (0 for none), by row of the allocation tables.
const rows = [6][16]u8{

    .{ 0, 1, 2, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 17, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 17 },
    .{ 0, 1, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 },
    .{ 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },

};

/// A Layer II allocation table: how many subbands carry samples, and each one's allocation field width and row.
const Allocation = struct {

    limit: usize,
    bands: [32]struct { bits: u6, row: u3 },

    /// Builds a table from runs of subbands sharing a field width and row, each as count, width, row.
    fn of(comptime runs: []const [3]u8) Allocation {

        var result = Allocation{

            .limit = 0,
            .bands = undefined,

        };

        for (runs) |run| {

            for (0..run[0]) |_| {

                result.bands[result.limit] = .{ .bits = run[1], .row = run[2] };
                result.limit += 1;

            }

        }

        return result;

    }

};

/// ISO/IEC 11172-3 tables B.2a to B.2d, and ISO/IEC 13818-3 table B.1 for the lower rates.
const allocations = [5]Allocation{

    Allocation.of(&.{ .{ 3, 4, 3 }, .{ 8, 4, 2 }, .{ 12, 3, 1 }, .{ 4, 2, 0 } }),
    Allocation.of(&.{ .{ 3, 4, 3 }, .{ 8, 4, 2 }, .{ 12, 3, 1 }, .{ 7, 2, 0 } }),
    Allocation.of(&.{ .{ 2, 4, 4 }, .{ 6, 3, 4 } }),
    Allocation.of(&.{ .{ 2, 4, 4 }, .{ 10, 3, 4 } }),
    Allocation.of(&.{ .{ 4, 4, 5 }, .{ 7, 3, 4 }, .{ 19, 2, 4 } }),

};

/// The allocation table a Layer II frame uses, chosen by its rate and bitrate per channel.
fn allocation(header: Header) *const Allocation {

    if (header.lsf) return &allocations[4];

    const share = header.bitrate / header.channels;

    if (share <= 48) return &allocations[if (header.rate == 32000) 3 else 2];
    if (share <= 80 or header.rate == 48000) return &allocations[0];

    return &allocations[1];

}

/// One channel's Layer III side information for one granule.
const Granule = struct {

    /// Bits of scalefactors and Huffman codes.
    part: u32 = 0,

    /// Pairs of values coded before the count1 region, the global gain, and how the scalefactors' fields are sized.
    big: u32 = 0,
    gain: u32 = 0,
    compress: u32 = 0,

    /// 0 long, 1 start, 2 short and 3 stop; mixed short blocks keep their lowest bands long.
    block: u2 = 0,
    mixed: bool = false,

    select: [3]u5 = .{ 0, 0, 0 },
    subgain: [3]u3 = .{ 0, 0, 0 },

    /// Lines where the second and third big-value regions begin.
    regions: [2]usize = .{ 0, 0 },

    preflag: bool = false,
    scale: u1 = 0,
    quads: u1 = 0,

};

const Side = struct {

    /// How many bytes before this frame's main data its granules begin.
    begin: usize,
    scfsi: [2]u4,
    granules: [2][2]Granule,

    fn parse(header: Header, bytes: []const u8) Error!Side {

        var bits = Bits.init(bytes);
        const channels = header.channels;
        var side = Side{

            .begin = bits.read(if (header.lsf) 8 else 9),
            .scfsi = .{ 0, 0 },
            .granules = @splat(@splat(.{})),

        };

        bits.skip(if (header.lsf) channels else if (channels == 1) 5 else 3);

        if (!header.lsf) for (0..channels) |channel| {

            side.scfsi[channel] = @intCast(bits.read(4));

        };

        const long = &long_bands[header.table];

        for (0..@as(usize, if (header.lsf) 1 else 2)) |round| {

            for (0..channels) |channel| {

                const granule = &side.granules[round][channel];

                granule.part = bits.read(12);
                granule.big = bits.read(9);
                granule.gain = bits.read(8);
                granule.compress = bits.read(if (header.lsf) 9 else 4);

                if (granule.big > 288) return error.Invalid;

                if (bits.bit()) {

                    granule.block = @intCast(bits.read(2));
                    granule.mixed = bits.bit();
                    granule.select = .{ @intCast(bits.read(5)), @intCast(bits.read(5)), 0 };
                    granule.subgain = .{ @intCast(bits.read(3)), @intCast(bits.read(3)), @intCast(bits.read(3)) };

                    // Switching to normal blocks is reserved.
                    if (granule.block == 0) return error.Invalid;

                    granule.regions = .{ if (granule.block == 2) 3 * short_bands[header.table][3] else long[8], 576 };

                } else {

                    granule.select = .{ @intCast(bits.read(5)), @intCast(bits.read(5)), @intCast(bits.read(5)) };

                    const first = bits.read(4);
                    const second = bits.read(3);

                    granule.regions = .{ long[first + 1], long[@min(first + second + 2, 22)] };

                }

                granule.preflag = !header.lsf and bits.bit();
                granule.scale = @intCast(bits.read(1));
                granule.quads = @intCast(bits.read(1));

            }

        }

        return side;

    }

};

/// One channel's scalefactors for a granule.
const Factors = struct {

    long: [22]u8 = @splat(0),
    short: [13][3]u8 = @splat(@splat(0)),

    /// Per band, the intensity position meaning none: 7 in MPEG-1, the largest its field holds in MPEG-2.
    long_limits: [22]u8 = @splat(7),
    short_limits: [13]u8 = @splat(7),

};

/// How a granule's lines divide: `long` long bands, then short bands from `short` to the last.
const Shape = struct {

    long: usize,
    short: usize,

    fn of(header: Header, granule: Granule) Shape {

        if (granule.block != 2) return .{ .long = 22, .short = 13 };
        if (!granule.mixed) return .{ .long = 0, .short = 0 };

        return .{ .long = if (header.lsf) 6 else 8, .short = 3 };

    }

};

fn readFactorsOne(bits: *Bits, granule: Granule, scfsi: u4, second: bool, factors: *Factors) void {

    const one: u6 = lengths_one[granule.compress];
    const two: u6 = lengths_two[granule.compress];

    if (granule.block == 2) {

        var band: usize = 0;

        if (granule.mixed) {

            for (factors.long[0..8]) |*factor| factor.* = @intCast(bits.read(one));
            band = 3;

        }

        while (band < 12) : (band += 1) {

            for (&factors.short[band]) |*factor| factor.* = @intCast(bits.read(if (band < 6) one else two));

        }

        factors.short[12] = .{ 0, 0, 0 };
        return;

    }

    const groups = [5]usize{ 0, 6, 11, 16, 21 };

    for (0..4) |group| {

        // The second granule may reuse the first's factors, a group at a time.
        if (second and (scfsi >> @intCast(3 - group)) & 1 != 0) continue;

        for (factors.long[groups[group]..groups[group + 1]]) |*factor| factor.* = @intCast(bits.read(if (group < 2) one else two));

    }

    factors.long[21] = 0;

}

fn readFactorsTwo(bits: *Bits, granule: *Granule, header: Header, channel: usize, factors: *Factors) void {

    var widths: [4]u32 = undefined;
    var table: usize = undefined;
    var compress = granule.compress;

    if (header.mode == .joint and header.extension & 1 != 0 and channel == 1) {

        compress >>= 1;

        if (compress < 180) {

            widths = .{ compress / 36, compress % 36 / 6, compress % 6, 0 };
            table = 3;

        } else if (compress < 244) {

            compress -= 180;
            widths = .{ compress % 64 >> 4, compress % 16 >> 2, compress % 4, 0 };
            table = 4;

        } else {

            compress -= 244;
            widths = .{ compress / 3, compress % 3, 0, 0 };
            table = 5;

        }

    } else if (compress < 400) {

        widths = .{ (compress >> 4) / 5, (compress >> 4) % 5, compress % 16 >> 2, compress % 4 };
        table = 0;

    } else if (compress < 500) {

        compress -= 400;
        widths = .{ (compress >> 2) / 5, (compress >> 2) % 5, compress % 4, 0 };
        table = 1;

    } else {

        compress -= 500;
        widths = .{ compress / 3, compress % 3, 0, 0 };
        table = 2;
        granule.preflag = true;

    }

    const kind: usize = if (granule.block != 2) 0 else if (granule.mixed) 2 else 1;
    var values: [39]u8 = @splat(0);
    var limits: [39]u8 = @splat(0);
    var count: usize = 0;

    for (band_counts[table][kind], widths) |bands, width| {

        for (0..bands) |_| {

            values[count] = @intCast(bits.read(@intCast(width)));

            // A field of no bits holds only 0, which is then a real position.
            limits[count] = if (width == 0) 255 else @intCast((@as(u32, 1) << @intCast(width)) - 1);
            count += 1;

        }

    }

    if (granule.block != 2) {

        @memcpy(factors.long[0..21], values[0..21]);
        @memcpy(factors.long_limits[0..21], limits[0..21]);
        factors.long[21] = 0;
        return;

    }

    var index: usize = 0;
    var first: usize = 0;

    if (granule.mixed) {

        @memcpy(factors.long[0..6], values[0..6]);
        @memcpy(factors.long_limits[0..6], limits[0..6]);
        index = 6;
        first = 3;

    }

    for (first..12) |band| {

        @memcpy(&factors.short[band], values[index..][0..3]);
        factors.short_limits[band] = limits[index];
        index += 3;

    }

    factors.short[12] = .{ 0, 0, 0 };

}

/// Reads a granule's Huffman-coded values up to bit `end`, giving how many lead the rest, which are zero.
fn spectrum(bits: *Bits, granule: Granule, end: usize, values: *[576]i32) Error!usize {

    const big = granule.big * 2;
    const stops = [3]usize{ @min(granule.regions[0], big), @min(granule.regions[1], big), big };
    var index: usize = 0;

    for (stops, granule.select) |stop, select| {

        if (index >= stop) continue;

        if (select == 0) {

            @memset(values[index..stop], 0);
            index = stop;
            continue;

        }

        if (select == 4 or select == 14) return error.Invalid;

        const lookup: usize = if (select < 16) select else if (select < 24) 16 else 17;
        const extra = huffman.linbits[select];

        while (index < stop) : (index += 2) {

            const pair = symbol(bits, lookup);

            values[index] = magnitude(bits, pair >> 4, extra);
            values[index + 1] = magnitude(bits, pair & 15, extra);

        }

    }

    while (index + 4 <= 576 and bits.position < end) {

        const quad = if (granule.quads == 1) 15 - bits.read(4) else symbol(bits, 18);
        var four: [4]i32 = undefined;

        for (&four, 0..) |*value, place| {

            value.* = if ((quad >> @intCast(3 - place)) & 1 == 0) 0 else if (bits.bit()) -1 else 1;

        }

        // Encoders may let a last quad run past the granule's bits; decoders agree to drop it.
        if (bits.position > end) break;

        values[index..][0..4].* = four;
        index += 4;

    }

    @memset(values[index..], 0);

    return index;

}

fn magnitude(bits: *Bits, value: u32, extra: u4) i32 {

    var result: i32 = @intCast(value);

    if (extra > 0 and value == 15) result += @intCast(bits.read(extra));
    if (result != 0 and bits.bit()) result = -result;

    return result;

}

/// Reads one Huffman code through lookup `index`, giving its value.
fn symbol(bits: *Bits, index: usize) u32 {

    // Indexing a global's array field by value copies the whole array; through a pointer it does not.
    const entries = &tables.entries;
    var start: usize = (&tables.starts)[index];
    var width: u6 = (&tables.widths)[index];

    while (true) {

        const entry = entries[start + bits.peek(width)];

        if (entry & 0x8000_0000 == 0) {

            bits.skip(entry >> 16);
            return entry & 0xff;

        }

        bits.skip(width);
        width = @intCast((entry >> 16) & 0x3f);
        start = entry & 0xffff;

    }

}

/// Turns quantized values into spectral lines, scaled by the global gain, scalefactors and subblock gains.
fn requantize(values: *const [576]i32, count: usize, granule: Granule, factors: *const Factors, header: Header, out: *[576]f32) void {

    @memset(out, 0);

    const base = @as(i32, @intCast(granule.gain)) - 210;
    const step = @as(i32, 2) << granule.scale;
    const long = &long_bands[header.table];
    const short = &short_bands[header.table];
    const layout = Shape.of(header, granule);

    for (0..layout.long) |band| {

        if (long[band] >= count) break;

        const boost: i32 = if (granule.preflag) pretab[band] else 0;

        scaleLines(values, out, long[band], @min(long[band + 1], count), base - (@as(i32, factors.long[band]) + boost) * step);

    }

    for (layout.short..13) |band| {

        const width = short[band + 1] - short[band];

        for (0..3) |window| {

            const start = 3 * short[band] + window * width;

            if (start >= count) break;

            scaleLines(values, out, start, @min(start + width, count), base - 8 * @as(i32, granule.subgain[window]) - @as(i32, factors.short[band][window]) * step);

        }

    }

}

/// Scales lines `start` to `stop` by 2^(quarters / 4).
fn scaleLines(values: *const [576]i32, out: *[576]f32, start: usize, stop: usize, quarters: i32) void {

    const factor = @exp2(@as(f32, @floatFromInt(quarters)) * 0.25);
    const powers = &tables.powers;

    for (values[start..stop], out[start..stop]) |value, *line| {

        const power = powers[@abs(value)] * factor;

        line.* = if (value < 0) -power else power;

    }

}

/// Joint stereo: mid/side, and intensity stereo above the right channel's last coded band.
fn stereo(lines: *[2][576]f32, header: Header, granule: Granule, right: *const Factors) void {

    const middle = header.extension & 2 != 0;

    if (header.extension & 1 == 0) {

        if (middle) midside(lines, 0, 576);
        return;

    }

    const layout = Shape.of(header, granule);
    const long = &long_bands[header.table];
    const short = &short_bands[header.table];
    var found = false;

    if (layout.short < 13) for (0..3) |window| {

        var edge = layout.short;
        var band: usize = 13;

        while (band > layout.short) {

            band -= 1;

            const width = short[band + 1] - short[band];

            if (!silent(lines[1][3 * short[band] + window * width ..][0..width])) {

                edge = band + 1;
                found = true;
                break;

            }

        }

        for (layout.short..13) |index| {

            const width = short[index + 1] - short[index];
            const start = 3 * short[index] + window * width;

            // The top band has no factor of its own and takes the one below it.
            const from = @min(index, 11);

            if (from < edge) {

                if (middle) midside(lines, start, width);
                continue;

            }

            pan(lines, start, width, right.short[from][window], right.short_limits[from], header, granule.compress, middle);

        }

    };

    if (layout.long == 0) return;

    var limit: usize = layout.long;

    if (!found) {

        limit = 0;

        var band = layout.long;

        while (band > 0) {

            band -= 1;

            if (!silent(lines[1][long[band]..long[band + 1]])) {

                limit = band + 1;
                break;

            }

        }

    }

    for (0..layout.long) |index| {

        const from = @min(index, 20);

        if (from < limit) {

            if (middle) midside(lines, long[index], long[index + 1] - long[index]);
            continue;

        }

        pan(lines, long[index], long[index + 1] - long[index], right.long[from], right.long_limits[from], header, granule.compress, middle);

    }

}

/// Spreads the left channel's lines over both by intensity `position`, unless it is the band's `limit`, meaning none.
fn pan(lines: *[2][576]f32, start: usize, width: usize, position: u8, limit: u8, header: Header, compress: u32, middle: bool) void {

    if (position >= limit) {

        if (middle) midside(lines, start, width);
        return;

    }

    var gains: [2]f32 = undefined;

    if (header.lsf) {

        const step: f32 = if (compress & 1 != 0) 0.5 else 0.25;
        const gain = @exp2(-step * @as(f32, @floatFromInt((position + 1) / 2)));

        gains = if (position & 1 != 0) .{ gain, 1 } else .{ 1, gain };

    } else {

        gains = (&tables.pans)[position];

    }

    for (lines[0][start..][0..width], lines[1][start..][0..width]) |*left, *other| {

        const value = left.*;

        left.* = value * gains[0];
        other.* = value * gains[1];

    }

}

fn midside(lines: *[2][576]f32, start: usize, width: usize) void {

    for (lines[0][start..][0..width], lines[1][start..][0..width]) |*left, *right| {

        const middle = left.*;
        const side = right.*;

        left.* = (middle + side) * std.math.sqrt1_2;
        right.* = (middle - side) * std.math.sqrt1_2;

    }

}

fn silent(lines: []const f32) bool {

    for (lines) |line| if (line != 0) return false;

    return true;

}

/// Puts short bands' lines in time order within each subband, from window by window.
fn reorder(lines: *[576]f32, table: u4, first: usize) void {

    const short = &short_bands[table];
    const start = 3 * short[first];
    var copy: [576]f32 = undefined;

    @memcpy(copy[start..], lines[start..]);

    for (first..13) |band| {

        const width = short[band + 1] - short[band];
        const base = 3 * short[band];

        for (0..3) |window| {

            for (0..width) |line| lines[base + 3 * line + window] = copy[base + window * width + line];

        }

    }

}

/// The 36-point IMDCT of a long block, windowed.
fn longBlock(input: *const [18]f32, window: *const [36]f32, output: *[36]f32) void {

    const Vector = @Vector(18, f32);
    var sum: Vector = @splat(0);

    for (input, &tables.imdct) |value, column| sum += column * @as(Vector, @splat(value));

    // Of the 36 outputs only 18 differ: the first half is odd about its middle, the second even.
    const unique: [18]f32 = sum;

    for (0..9) |index| {

        output[index] = unique[index] * window[index];
        output[17 - index] = -unique[index] * window[17 - index];
        output[18 + index] = unique[9 + index] * window[18 + index];
        output[35 - index] = unique[9 + index] * window[35 - index];

    }

}

/// Three windowed 12-point IMDCTs of a short block, overlapped where a long block's output would lie.
fn shortBlocks(input: *const [18]f32, output: *[36]f32) void {

    const transform = &tables.short;

    @memset(output, 0);

    for (0..3) |window| {

        for (0..12) |index| {

            var sum: f32 = 0;

            for (0..6) |line| sum += transform[index][line] * input[3 * line + window];

            output[6 + 6 * window + index] += sum;

        }

    }

}

/// Tables worked out once, on first use.
const Tables = struct {

    /// |x|^(4/3) for every magnitude Layer III can code.
    powers: [8207]f32,

    /// The Huffman code tables as lookups indexed by the next few bits, as `symbol` walks them.
    entries: [6144]u32,
    used: usize,
    starts: [19]u32,
    widths: [19]u6,

    /// Columns of the 32-point DCT the synthesis matrixing reduces to, and the synthesis window.
    cosines: [32]@Vector(32, f32),
    window: [512]f32,

    /// The 36-point IMDCT's 18 distinct outputs by input, and the windows of block types 0 to 3.
    imdct: [18]@Vector(18, f32),
    windows: [4][36]f32,

    /// The 12-point IMDCT of short blocks, windowed.
    short: [12][6]f32,

    /// Alias reduction's butterflies, as cs and ca.
    alias: [8][2]f32,

    /// Layer I and II scalefactors.
    scales: [64]f32,

    /// MPEG-1 intensity stereo's left and right gains by position.
    pans: [7][2]f32,

};

var tables: Tables = undefined;
var ready = false;

fn prepare() void {

    if (ready) return;

    const pi: f64 = std.math.pi;

    for (&tables.powers, 0..) |*power, index| power.* = @floatCast(std.math.pow(f64, @floatFromInt(index), 4.0 / 3.0));

    tables.used = 0;

    for (huffman.pairs, 0..) |entry, index| {

        if (entry) |table| spread(table, index, false);

    }

    spread(huffman.quads[0], 18, true);

    for (&tables.cosines, 0..) |*column, line| {

        var values: [32]f32 = undefined;

        for (&values, 0..) |*value, row| value.* = @floatCast(@cos(@as(f64, @floatFromInt((2 * line + 1) * row)) * pi / 64));

        column.* = values;

    }

    for (&tables.window, synthesis_window) |*value, step| value.* = @as(f32, @floatFromInt(step)) / 65536;

    for (&tables.imdct, 0..) |*column, line| {

        var values: [18]f32 = undefined;

        for (&values, 0..) |*value, row| {

            const time = if (row < 9) row else row + 9;

            value.* = @floatCast(@cos(pi / 72 * @as(f64, @floatFromInt((2 * time + 19) * (2 * line + 1)))));

        }

        column.* = values;

    }

    for (0..36) |index| {

        const place: f64 = @floatFromInt(index);
        const long: f32 = @floatCast(@sin(pi / 36 * (place + 0.5)));
        const rise: f32 = if (index >= 6 and index < 12) @floatCast(@sin(pi / 12 * (place - 6 + 0.5))) else 0;
        const fall: f32 = if (index >= 24 and index < 30) @floatCast(@sin(pi / 12 * (place - 18 + 0.5))) else 0;

        tables.windows[0][index] = long;
        tables.windows[1][index] = if (index < 18) long else if (index < 24) 1 else fall;
        tables.windows[2][index] = 0;
        tables.windows[3][index] = if (index < 12) rise else if (index < 18) 1 else long;

    }

    for (&tables.short, 0..) |*row, time| {

        for (row, 0..) |*value, line| {

            const place: f64 = @floatFromInt(time);

            value.* = @floatCast(@cos(pi / 24 * @as(f64, @floatFromInt((2 * time + 7) * (2 * line + 1)))) * @sin(pi / 12 * (place + 0.5)));

        }

    }

    const coefficients = [8]f64{ -0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037 };

    for (&tables.alias, coefficients) |*butterfly, coefficient| {

        const norm = @sqrt(1 + coefficient * coefficient);

        butterfly.* = .{ @floatCast(1 / norm), @floatCast(coefficient / norm) };

    }

    for (&tables.scales, 0..) |*scale, index| scale.* = @floatCast(@exp2(1 - @as(f64, @floatFromInt(index)) / 3));

    for (&tables.pans, 0..) |*gains, position| {

        const ratio = @tan(@as(f64, @floatFromInt(position)) * pi / 12);

        gains.* = if (position == 6) .{ 1, 0 } else .{ @floatCast(ratio / (1 + ratio)), @floatCast(1 / (1 + ratio)) };

    }

    ready = true;

}

/// Lays out Huffman `table` as lookup `index`.
fn spread(table: huffman.Table, index: usize, quad: bool) void {

    var longest: u8 = 0;

    for (table.lengths) |length| longest = @max(longest, length);

    const width: u6 = @intCast(@min(longest, 8));

    tables.starts[index] = @intCast(tables.used);
    tables.widths[index] = width;
    fill(table, quad, 0, 0, width);

}

/// Fills a lookup for the codes beginning with the `depth` bits of `prefix`, indexed by the `width` bits after them.
fn fill(table: huffman.Table, quad: bool, prefix: u32, depth: u8, width: u6) void {

    const base = tables.used;
    const span = @as(usize, 1) << @intCast(width);
    var deeper: [256]u8 = @splat(0);

    tables.used += span;
    @memset(tables.entries[base..][0..span], @as(u32, width) << 16);

    for (table.codes, table.lengths, 0..) |code, length, index| {

        if (length <= depth or code >> @intCast(length - depth) != prefix) continue;

        const rest = length - depth;
        const value: u32 = if (quad) @intCast(index) else @intCast(index / table.size << 4 | index % table.size);

        if (rest <= width) {

            const first = (code & ((@as(u32, 1) << @intCast(rest)) - 1)) << @intCast(width - rest);

            @memset(tables.entries[base + first ..][0 .. @as(usize, 1) << @intCast(width - rest)], @as(u32, rest) << 16 | value);

        } else {

            const entry = (code >> @intCast(rest - width)) & ((@as(u32, 1) << @intCast(width)) - 1);

            deeper[entry] = @max(deeper[entry], rest - width);

        }

    }

    for (deeper[0..span], 0..) |extra, entry| {

        if (extra == 0) continue;

        const next: u6 = @intCast(@min(extra, 8));

        tables.entries[base + entry] = 0x8000_0000 | @as(u32, next) << 16 | @as(u32, @intCast(tables.used));
        fill(table, quad, prefix << @intCast(width) | @as(u32, @intCast(entry)), depth + width, next);

    }

}

const rates = [9]u32{ 44100, 48000, 32000, 22050, 24000, 16000, 11025, 12000, 8000 };

/// Kbit/s by MPEG-1 or the lower rates, layer and bitrate index.
const bitrates = [2][3][15]u32{

    .{

        .{ 0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 },
        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 },
        .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 },

    },
    .{

        .{ 0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 },
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },
        .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 },

    },

};

/// Where each long scalefactor band begins, by rate, ending at 576.
const long_bands = [9][23]usize{

    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576 },
    .{ 0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 114, 136, 162, 194, 232, 278, 332, 394, 464, 540, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576 },
    .{ 0, 12, 24, 36, 48, 60, 72, 88, 108, 132, 160, 192, 232, 280, 336, 400, 476, 566, 568, 570, 572, 574, 576 },

};

/// Where each short scalefactor band begins within a window, by rate, ending at 192.
const short_bands = [9][14]usize{

    .{ 0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192 },
    .{ 0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192 },
    .{ 0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192 },
    .{ 0, 4, 8, 12, 18, 24, 32, 42, 56, 74, 100, 132, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192 },
    .{ 0, 8, 16, 24, 36, 52, 72, 96, 124, 160, 162, 164, 166, 192 },

};

/// What the preflag adds to each long band's scalefactor.
const pretab = [22]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0 };

/// MPEG-1 scalefactor field widths for bands 0 to 10 and 11 to 20, by scalefac_compress.
const lengths_one = [16]u6{ 0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4 };
const lengths_two = [16]u6{ 0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3 };

/// MPEG-2 scalefactors per field width, by table, then long, short or mixed blocks.
const band_counts = [6][3][4]usize{

    .{ .{ 6, 5, 5, 5 }, .{ 9, 9, 9, 9 }, .{ 6, 9, 9, 9 } },
    .{ .{ 6, 5, 7, 3 }, .{ 9, 9, 12, 6 }, .{ 6, 9, 12, 6 } },
    .{ .{ 11, 10, 0, 0 }, .{ 18, 18, 0, 0 }, .{ 15, 18, 0, 0 } },
    .{ .{ 7, 7, 7, 0 }, .{ 12, 12, 12, 0 }, .{ 6, 15, 12, 0 } },
    .{ .{ 6, 6, 6, 3 }, .{ 12, 9, 9, 6 }, .{ 6, 12, 9, 6 } },
    .{ .{ 8, 8, 5, 0 }, .{ 15, 12, 9, 0 }, .{ 6, 18, 9, 0 } },

};

/// The synthesis window D of ISO/IEC 11172-3 table 3-B.3, times 65536.
const synthesis_window = [512]i32{

    0, -1, -1, -1, -1, -1, -1, -2, -2, -2, -2, -3, -3, -4, -4, -5,
    -5, -6, -7, -7, -8, -9, -10, -11, -13, -14, -16, -17, -19, -21, -24, -26,
    -29, -31, -35, -38, -41, -45, -49, -53, -58, -63, -68, -73, -79, -85, -91, -97,
    -104, -111, -117, -125, -132, -139, -147, -154, -161, -169, -176, -183, -190, -196, -202, -208,
    213, 218, 222, 225, 227, 228, 228, 227, 224, 221, 215, 208, 200, 189, 177, 163,
    146, 127, 106, 83, 57, 29, -2, -36, -72, -111, -153, -197, -244, -294, -347, -401,
    -459, -519, -581, -645, -711, -779, -848, -919, -991, -1064, -1137, -1210, -1283, -1356, -1428, -1498,
    -1567, -1634, -1698, -1759, -1817, -1870, -1919, -1962, -2001, -2032, -2057, -2075, -2085, -2087, -2080, -2063,
    2037, 2000, 1952, 1893, 1822, 1739, 1644, 1535, 1414, 1280, 1131, 970, 794, 605, 402, 185,
    -45, -288, -545, -814, -1095, -1388, -1692, -2006, -2330, -2663, -3004, -3351, -3705, -4063, -4425, -4788,
    -5153, -5517, -5879, -6237, -6589, -6935, -7271, -7597, -7910, -8209, -8491, -8755, -8998, -9219, -9416, -9585,
    -9727, -9838, -9916, -9959, -9966, -9935, -9863, -9750, -9592, -9389, -9139, -8840, -8492, -8092, -7640, -7134,
    6574, 5959, 5288, 4561, 3776, 2935, 2037, 1082, 70, -998, -2122, -3300, -4533, -5818, -7154, -8540,
    -9975, -11455, -12980, -14548, -16155, -17799, -19478, -21189, -22929, -24694, -26482, -28289, -30112, -31947, -33791, -35640,
    -37489, -39336, -41176, -43006, -44821, -46617, -48390, -50137, -51853, -53534, -55178, -56778, -58333, -59838, -61289, -62684,
    -64019, -65290, -66494, -67629, -68692, -69679, -70590, -71420, -72169, -72835, -73415, -73908, -74313, -74630, -74856, -74992,
    75038, 74992, 74856, 74630, 74313, 73908, 73415, 72835, 72169, 71420, 70590, 69679, 68692, 67629, 66494, 65290,
    64019, 62684, 61289, 59838, 58333, 56778, 55178, 53534, 51853, 50137, 48390, 46617, 44821, 43006, 41176, 39336,
    37489, 35640, 33791, 31947, 30112, 28289, 26482, 24694, 22929, 21189, 19478, 17799, 16155, 14548, 12980, 11455,
    9975, 8540, 7154, 5818, 4533, 3300, 2122, 998, -70, -1082, -2037, -2935, -3776, -4561, -5288, -5959,
    6574, 7134, 7640, 8092, 8492, 8840, 9139, 9389, 9592, 9750, 9863, 9935, 9966, 9959, 9916, 9838,
    9727, 9585, 9416, 9219, 8998, 8755, 8491, 8209, 7910, 7597, 7271, 6935, 6589, 6237, 5879, 5517,
    5153, 4788, 4425, 4063, 3705, 3351, 3004, 2663, 2330, 2006, 1692, 1388, 1095, 814, 545, 288,
    45, -185, -402, -605, -794, -970, -1131, -1280, -1414, -1535, -1644, -1739, -1822, -1893, -1952, -2000,
    2037, 2063, 2080, 2087, 2085, 2075, 2057, 2032, 2001, 1962, 1919, 1870, 1817, 1759, 1698, 1634,
    1567, 1498, 1428, 1356, 1283, 1210, 1137, 1064, 991, 919, 848, 779, 711, 645, 581, 519,
    459, 401, 347, 294, 244, 197, 153, 111, 72, 36, 2, -29, -57, -83, -106, -127,
    -146, -163, -177, -189, -200, -208, -215, -221, -224, -227, -228, -228, -227, -225, -222, -218,
    213, 208, 202, 196, 190, 183, 176, 169, 161, 154, 147, 139, 132, 125, 117, 111,
    104, 97, 91, 85, 79, 73, 68, 63, 58, 53, 49, 45, 41, 38, 35, 31,
    29, 26, 24, 21, 19, 17, 16, 14, 13, 11, 10, 9, 8, 7, 7, 6,
    5, 5, 4, 4, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,

};

/// An MPEG audio file (.mp3 / .mp2 / .mp1).
pub const Decoder = struct {

    rate: u32,
    channels: u8,

    /// Total sample frames, from a Xing, Info or VBRI header less the LAME encoder delay and padding, or estimated from the bitrate.
    frames: ?u64,

    /// ID3v2 TIT2 and TPE1 (TT2 and TP1 in ID3v2.2), falling back to ID3v1 at the file end.
    tags: Tags,

    source: *Source,
    state: *State,

    /// Skips tags, finds the first frame (confirmed by the header after it), and reads any Xing, Info or VBRI header.
    pub fn open(allocator: std.mem.Allocator, source: *Source) Error!Decoder {

        prepare();

        var tags = Tags{};

        try source.seek(0);

        while (true) {

            const head = try source.peek(10);

            if (head.len < 10 or !std.mem.eql(u8, head[0..3], "ID3")) break;

            try readId3v2(source, &tags);

        }

        const start = source.offset();
        const end = try readTrailing(source, &tags, start);

        try source.seek(start);

        const header = try find(source, end, null, 1 << 20) orelse return error.Invalid;
        const first = source.offset();
        const length = header.size();
        const frame = try source.peek(length);
        const info = Info.parse(frame[0..@min(frame.len, length)], header);
        const audio = if (info != null) first + length else first;
        const samples: u64 = header.samples();
        var count: ?u64 = null;
        var total: ?u64 = null;
        var delay: u64 = 0;

        if (info) |found| if (found.count) |frames| {

            count = frames;
            total = frames * samples;

            // The decoder's own delay of 529 samples comes on top of the encoder's.
            if (found.lame) {

                delay = found.delay + 529;
                total = @min(frames * samples -| (found.delay + found.padding), frames * samples -| delay);

            }

        };

        const rate: u64 = header.rate;
        const bytes = end -| audio;
        const nominal = @as(f64, @floatFromInt(samples * header.bitrate * 125)) / @as(f64, @floatFromInt(rate));
        const constant = if (info) |found| found.cbr else true;
        const average = if (!constant and count != null and count.? > 0) @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(count.?)) else nominal;
        const state = try allocator.create(State);

        errdefer allocator.destroy(state);

        state.* = .{

            .frames = .{},
            .pcm = undefined,

            .first = header,
            .start = first,
            .audio = audio,
            .end = end,

            .delay = delay,
            .floor = delay,
            .total = total,
            .count = count,

            .average = @max(average, 1),
            .preroll = preroll(header, @max(average, 1)),

        };

        if (info) |found| if (found.toc) |toc| if (!constant and count != null) {

            state.toc = toc;
            state.toc_bytes = found.bytes orelse end - first;

            // A table that ever steps back is corrupt, and would mislead every seek.
            if (state.toc_bytes == 0 or !std.sort.isSorted(u8, &toc, {}, std.sort.asc(u8))) state.toc = null;

        };

        try source.seek(audio);

        return .{

            .rate = header.rate,
            .channels = header.channels,

            .frames = total orelse @intCast(@min(@as(u128, bytes) * 8 * rate / (@as(u128, header.bitrate) * 1000), std.math.maxInt(u64))),
            .tags = tags,

            .source = source,
            .state = state,

        };

    }

    /// Frees the one allocation `open` made.
    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {

        allocator.destroy(self.state);

    }

    /// Up to out.len / channels sample frames of interleaved f32 (nominal full scale ±1); 0 at the end of the file.
    pub fn read(self: *Decoder, out: []f32) Error!usize {

        const state = self.state;
        const channels: usize = self.channels;
        const wanted = out.len / channels;
        var written: usize = 0;

        while (written < wanted) {

            if (state.used == state.held) {

                if (!try self.next()) break;
                continue;

            }

            if (state.decoded < state.floor) {

                const dropped: usize = @intCast(@min(state.held - state.used, state.floor - state.decoded));

                state.used += dropped;
                state.decoded +|= dropped;
                continue;

            }

            var count = @min(state.held - state.used, wanted - written);

            if (state.total) |total| {

                const left = (state.delay + total) -| state.decoded;

                if (left == 0) break;
                count = @intCast(@min(count, left));

            }

            @memcpy(out[written * channels ..][0 .. count * channels], state.pcm[state.used * channels ..][0 .. count * channels]);
            state.used += count;
            state.decoded +|= count;
            written += count;

        }

        return written;

    }

    /// Moves as near `frame` (a sample frame index) as it can and returns where it landed, decoding a few frames first so what follows is clean.
    pub fn seek(self: *Decoder, frame: u64) Error!u64 {

        const state = self.state;
        const samples: u64 = state.first.samples();
        const target = state.delay +| frame;

        state.frames.reset();
        state.held = 0;
        state.used = 0;
        state.floor = @max(state.delay, target);

        if (state.total) |total| if (frame >= total) {

            try self.source.seek(state.end);
            state.decoded = state.delay + total;
            state.floor = state.decoded;
            return total;

        };

        const wanted = target / samples;
        const aim = wanted -| state.preroll;
        var landed: u64 = 0;

        if (aim == 0) {

            try self.source.seek(state.audio);

        } else {

            try self.source.seek(@min(state.offsetOf(aim), state.end));

            if (try find(self.source, state.end, state.first, std.math.maxInt(u64)) == null) {

                state.decoded = if (state.total) |total| state.delay + total else state.frameAt(state.end) *| samples;
                state.floor = state.decoded;
                return state.decoded -| state.delay;

            }

            landed = state.frameAt(self.source.offset());

        }

        state.decoded = landed *| samples;
        state.synced = true;

        // At the start nothing came before, so nothing is missing; elsewhere frames are dropped until two decode whole.
        var spare: usize = if (landed == 0) 0 else 32;

        while (state.decoded +| samples <= target or (spare > 0 and state.frames.whole < 2)) {

            if (!try self.next()) break;

            state.decoded +|= state.held;
            state.used = state.held;

            if (state.decoded > target) spare -|= 1;

        }

        const reached = @max(state.decoded, state.floor) - state.delay;

        return if (state.total) |total| @min(reached, total) else reached;

    }

    /// Decodes the next frame into `pcm`, resynchronising past whatever is not one; false at the end.
    fn next(self: *Decoder) Error!bool {

        const state = self.state;
        const source = self.source;

        while (source.offset() + 4 <= state.end) {

            const head = try source.peek(4);

            if (head.len < 4) return false;

            if (Header.parse(std.mem.readInt(u32, head[0..4], .big))) |header| {

                const size = header.size();

                if (header.bitrate != 0 and header.matches(state.first) and source.offset() + size <= state.end) {

                    if (state.synced or try confirmed(source, header, state.end)) {

                        const frame = try source.peek(size);

                        if (frame.len >= size) {

                            self.unpack(header, frame[0..size]);
                            try source.skip(size);
                            state.synced = true;
                            return true;

                        }

                    }

                }

            }

            try source.skip(1);
            state.synced = false;

        }

        return false;

    }

    /// Decodes one frame into `pcm`, as silence if it is corrupt, in the decoder's channel count.
    fn unpack(self: *Decoder, header: Header, frame: []const u8) void {

        const state = self.state;
        const count = header.samples();
        const pcm = &state.pcm;

        _ = state.frames.decode(frame, pcm) catch blank: {

            @memset(pcm[0 .. count * header.channels], 0);
            break :blank count;

        };

        if (header.channels == 1 and self.channels == 2) {

            var index = count;

            while (index > 0) {

                index -= 1;
                pcm[2 * index] = pcm[index];
                pcm[2 * index + 1] = pcm[index];

            }

        } else if (header.channels == 2 and self.channels == 1) {

            for (0..count) |index| pcm[index] = (pcm[2 * index] + pcm[2 * index + 1]) * 0.5;

        }

        state.held = count;
        state.used = 0;

    }

};

/// What a `Decoder` keeps between calls, in one allocation.
const State = struct {

    frames: Frames,

    /// One decoded frame, interleaved by the decoder's channel count, and how many of its sample frames are used.
    pcm: [1152 * 2]f32,
    held: usize = 0,
    used: usize = 0,

    /// The first frame's header, whose layer and rate later frames must share.
    first: Header,

    /// Where the frames begin (at any Xing frame), where the audio frames begin, and where they end before trailing tags.
    start: u64,
    audio: u64,
    end: u64,

    /// Whether reading is where the last frame ended, so the next header needs no confirming.
    synced: bool = true,

    /// Which decoded sample frame `pcm[used]` is, counting from the first audio frame; those before `floor` are dropped.
    decoded: u64 = 0,
    floor: u64 = 0,

    /// Sample frames dropped at the start for encoder and decoder delay, and the exact count after them when known.
    delay: u64 = 0,
    total: ?u64 = null,

    /// Audio frames, when a Xing or VBRI header gives them.
    count: ?u64 = null,

    /// The Xing seek table, as 256ths of `toc_bytes` from `start` at each percent of the frames.
    toc: ?[100]u8 = null,
    toc_bytes: u64 = 0,

    /// Bytes per frame on average, and how many frames a seek decodes first to refill the reservoir and overlap.
    average: f64,
    preroll: u64,

    /// Where audio frame `index` should begin.
    fn offsetOf(self: *const State, frame: u64) u64 {

        const at: f64 = @floatFromInt(frame);

        if (self.toc) |toc| {

            const percent = @min(at / @as(f64, @floatFromInt(self.count.?)) * 100, 99.999);
            const whole: usize = @intFromFloat(@max(percent, 0));
            const low: f64 = @floatFromInt(toc[whole]);
            const high: f64 = if (whole < 99) @floatFromInt(toc[whole + 1]) else 256;
            const fraction = (low + (high - low) * (percent - @as(f64, @floatFromInt(whole)))) / 256;

            return self.start + truncate(fraction * @as(f64, @floatFromInt(self.toc_bytes)));

        }

        // Half a frame early, so padding's drift cannot put the guess past the frame's start.
        return self.audio + truncate((at - 0.5) * self.average);

    }

    /// Which audio frame most likely begins at byte `offset`.
    fn frameAt(self: *const State, offset: u64) u64 {

        if (offset <= self.audio) return 0;

        if (self.toc) |toc| {

            const fraction = @as(f64, @floatFromInt(offset - self.start)) / @as(f64, @floatFromInt(self.toc_bytes)) * 256;
            var whole: usize = 0;

            while (whole < 99 and @as(f64, @floatFromInt(toc[whole + 1])) <= fraction) whole += 1;

            const low: f64 = @floatFromInt(toc[whole]);
            const high: f64 = if (whole < 99) @floatFromInt(toc[whole + 1]) else 256;
            const part = if (high > low) std.math.clamp((fraction - low) / (high - low), 0, 1) else 0;
            const percent = @as(f64, @floatFromInt(whole)) + part;

            return truncate(percent / 100 * @as(f64, @floatFromInt(self.count.?)));

        }

        return truncate(@round(@as(f64, @floatFromInt(offset - self.audio)) / self.average));

    }

};

/// What a Xing, Info or VBRI header in a stream's first frame says.
const Info = struct {

    count: ?u64 = null,
    bytes: ?u64 = null,
    toc: ?[100]u8 = null,

    /// Info rather than Xing marks a constant bitrate.
    cbr: bool = false,

    /// Encoder delay and padding from a LAME tag.
    lame: bool = false,
    delay: u64 = 0,
    padding: u64 = 0,

    fn parse(frame: []const u8, header: Header) ?Info {

        if (header.layer != 3) return null;

        // Encoders disagree on whether a CRC moves the header.
        for ([2]usize{ 4 + header.side(), 6 + header.side() }) |at| {

            if (at + 8 > frame.len) continue;

            const tag = frame[at..][0..4];

            if (!std.mem.eql(u8, tag, "Xing") and !std.mem.eql(u8, tag, "Info")) continue;

            const flags = std.mem.readInt(u32, frame[at + 4 ..][0..4], .big);
            var info = Info{ .cbr = std.mem.eql(u8, tag, "Info") };
            var place = at + 8;

            if (flags & 1 != 0) {

                if (place + 4 > frame.len) return info;
                info.count = std.mem.readInt(u32, frame[place..][0..4], .big);
                place += 4;

            }

            if (flags & 2 != 0) {

                if (place + 4 > frame.len) return info;
                info.bytes = std.mem.readInt(u32, frame[place..][0..4], .big);
                place += 4;

            }

            if (flags & 4 != 0) {

                if (place + 100 > frame.len) return info;
                info.toc = frame[place..][0..100].*;
                place += 100;

            }

            if (flags & 8 != 0) place += 4;

            if (info.count == 0) info.count = null;

            if (place + 24 <= frame.len) {

                const lame = frame[place..][0..24];

                if (std.mem.eql(u8, lame[0..4], "LAME") or std.mem.eql(u8, lame[0..4], "Lavf") or std.mem.eql(u8, lame[0..4], "Lavc")) {

                    info.lame = true;
                    info.delay = @as(u64, lame[21]) << 4 | lame[22] >> 4;
                    info.padding = @as(u64, lame[22] & 15) << 8 | lame[23];

                }

            }

            return info;

        }

        if (frame.len >= 54 and std.mem.eql(u8, frame[36..40], "VBRI")) {

            const count = std.mem.readInt(u32, frame[50..54], .big);

            return .{

                .count = if (count == 0) null else count,
                .bytes = std.mem.readInt(u32, frame[46..50], .big),

            };

        }

        return null;

    }

};

/// How many frames a seek decodes and drops so the reservoir a frame may reach back into is full again.
fn preroll(header: Header, average: f64) u64 {

    // Layers I and II carry nothing but the filterbank's history, which two frames refill.
    if (header.layer != 3) return 2;

    const main = @max(average - 4 - @as(f64, @floatFromInt(header.side())), 16);
    const reach: f64 = if (header.lsf) 255 else 511;

    return @min(@as(u64, @intFromFloat(@ceil(reach / main))), 16) + 2;

}

fn truncate(value: f64) u64 {

    if (!(value > 0)) return 0;
    if (value >= 1.8e19) return std.math.maxInt(u64);

    return @intFromFloat(value);

}

/// Moves `source` to the next frame before `end` that the header after it confirms, matching `like` if given; null if none within `limit` bytes.
fn find(source: *Source, end: u64, like: ?Header, limit: u64) Error!?Header {

    var free = false;
    var scanned: u64 = 0;

    while (source.offset() + 4 <= end and scanned < limit) : (scanned += 1) {

        const head = try source.peek(4);

        if (head.len < 4) break;

        if (Header.parse(std.mem.readInt(u32, head[0..4], .big))) |header| {

            if (header.bitrate == 0) {

                free = true;

            } else if (like == null or header.matches(like.?)) {

                if (try confirmed(source, header, end)) return header;

            }

        }

        try source.skip(1);

    }

    return if (free and like == null) error.Unsupported else null;

}

/// Whether the frame at `source` fits before `end` and is followed by a header like it, or by `end` itself.
fn confirmed(source: *Source, header: Header, end: u64) Error!bool {

    const size = header.size();
    const offset = source.offset();

    if (offset + size > end) return false;
    if (offset + size + 4 > end) return true;

    const bytes = try source.peek(size + 4);

    if (bytes.len < size + 4) return false;

    const next = Header.parse(std.mem.readInt(u32, bytes[size..][0..4], .big)) orelse return false;

    return next.matches(header);

}

/// Reads an ID3v2 tag's title and artist into `tags` where still empty, leaving `source` after the tag.
fn readId3v2(source: *Source, tags: *Tags) Error!void {

    const head = try source.take(10);
    const major = head[3];
    const flags = head[5];
    const size = syncsafe(head[6..10]);
    const body = source.offset();
    const footer: u64 = if (major == 4 and flags & 0x10 != 0) 10 else 0;

    if (major >= 2 and major <= 4) {

        readFrames(source, tags, major, flags, body + size) catch |err| switch (err) {

            error.Invalid, error.Unsupported => {},
            else => return err,

        };

    }

    try source.seek(body + size + footer);

}

fn readFrames(source: *Source, tags: *Tags, major: u8, flags: u8, end: u64) Error!void {

    var reader = Reader{

        .source = source,
        .end = end,
        .unsync = major < 4 and flags & 0x80 != 0,

    };

    if (flags & 0x40 != 0 and major >= 3) {

        var length: [4]u8 = undefined;

        if (try reader.bytes(&length) < 4) return;

        try reader.skip(if (major == 3) std.mem.readInt(u32, &length, .big) else syncsafe(&length) -| 4);

    }

    const short = major == 2;
    const length: usize = if (short) 6 else 10;

    while (true) {

        var head: [10]u8 = undefined;

        if (try reader.bytes(head[0..length]) < length or head[0] == 0) return;

        const id = head[0..if (short) 3 else 4];
        const size: u64 = if (short) std.mem.readInt(u24, head[3..6], .big) else if (major == 3) std.mem.readInt(u32, head[4..8], .big) else syncsafe(head[4..8]);
        const format = if (short) 0 else head[9];
        const field: ?*Field = if (std.mem.eql(u8, id, "TT2") or std.mem.eql(u8, id, "TIT2")) &tags.title else if (std.mem.eql(u8, id, "TP1") or std.mem.eql(u8, id, "TPE1")) &tags.artist else null;

        // Compressed or encrypted frames are not worth decoding for a title.
        const hidden = (major == 3 and format & 0xc0 != 0) or (major == 4 and format & 0x0c != 0);

        if (field == null or field.?.length != 0 or hidden) {

            try reader.skip(size);
            continue;

        }

        var extra: usize = 0;

        if (major == 3 and format & 0x20 != 0) extra += 1;
        if (major == 4 and format & 0x40 != 0) extra += 1;
        if (major == 4 and format & 0x01 != 0) extra += 4;

        var text: [260]u8 = undefined;
        const wanted: usize = @intCast(@min(size, text.len));
        const got = try reader.bytes(text[0..wanted]);

        try reader.skip(size - wanted);

        var content: []u8 = text[@min(extra, got)..got];

        if (major == 4 and format & 0x02 != 0) content = resynchronise(content);

        decodeText(field.?, content);

    }

}

/// Reads a tag's bytes up to `end`, undoing whole-tag unsynchronisation if set.
const Reader = struct {

    source: *Source,
    end: u64,
    unsync: bool,
    last: u8 = 0,

    /// Fills as much of `buffer` as the tag holds, giving how much.
    fn bytes(self: *Reader, buffer: []u8) Error!usize {

        var count: usize = 0;

        while (count < buffer.len and self.source.offset() < self.end) {

            if (!self.unsync) {

                const chunk = try self.source.take(@intCast(@min(buffer.len - count, self.end - self.source.offset())));

                @memcpy(buffer[count..][0..chunk.len], chunk);
                count += chunk.len;
                continue;

            }

            const value = try self.source.byte();

            // Unsynchronisation put a zero after every 0xff.
            if (self.last == 0xff and value == 0) {

                self.last = 0;
                continue;

            }

            self.last = value;
            buffer[count] = value;
            count += 1;

        }

        return count;

    }

    fn skip(self: *Reader, count: u64) Error!void {

        if (!self.unsync) return self.source.seek(@min(self.source.offset() +| count, self.end));

        var left = count;
        var scratch: [64]u8 = undefined;

        while (left > 0) {

            const got = try self.bytes(scratch[0..@intCast(@min(left, scratch.len))]);

            if (got == 0) return;
            left -= got;

        }

    }

};

/// Undoes unsynchronisation of one ID3v2.4 frame in place.
fn resynchronise(content: []u8) []u8 {

    var length: usize = 0;
    var previous: u8 = 0;

    for (content) |value| {

        const skipped = previous == 0xff and value == 0;

        previous = if (skipped) 0 else value;

        if (skipped) continue;

        content[length] = value;
        length += 1;

    }

    return content[0..length];

}

/// Keeps an ID3v2 text frame's first string, in whichever of its four encodings it uses.
fn decodeText(field: *Field, content: []const u8) void {

    if (content.len == 0) return;

    const text = content[1..];

    switch (content[0]) {

        0 => field.latin(untilZero(text)),
        1 => {

            if (text.len >= 2 and text[0] == 0xfe and text[1] == 0xff) {

                field.wide(text[2..], .big);

            } else if (text.len >= 2 and text[0] == 0xff and text[1] == 0xfe) {

                field.wide(text[2..], .little);

            } else {

                field.wide(text, .little);

            }

        },
        2 => field.wide(text, .big),
        3 => {

            const string = untilZero(text);

            if (std.unicode.utf8ValidateSlice(string)) field.set(string) else field.latin(string);

        },
        else => {},

    }

}

fn untilZero(text: []const u8) []const u8 {

    return text[0 .. std.mem.indexOfScalar(u8, text, 0) orelse text.len];

}

fn syncsafe(bytes: *const [4]u8) u64 {

    var value: u64 = 0;

    for (bytes) |byte| value = value << 7 | (byte & 0x7f);

    return value;

}

/// Reads an ID3v1 tag at the file's end into whichever `tags` are still empty, and steps back over it and any APEv2 tag, giving where the frames end.
fn readTrailing(source: *Source, tags: *Tags, start: u64) Error!u64 {

    var end = source.size;

    if (end >= start + 128) {

        try source.seek(end - 128);

        const tag = try source.take(128);

        if (std.mem.eql(u8, tag[0..3], "TAG")) {

            if (tags.title.length == 0) tags.title.latin(untilZero(tag[3..33]));
            if (tags.artist.length == 0) tags.artist.latin(untilZero(tag[33..63]));
            end -= 128;

        }

    }

    if (end >= start + 32) {

        try source.seek(end - 32);

        const footer = try source.take(32);

        if (std.mem.eql(u8, footer[0..8], "APETAGEX")) {

            const size: u64 = std.mem.readInt(u32, footer[12..16], .little);
            const header: u64 = if (std.mem.readInt(u32, footer[20..24], .little) & 0x8000_0000 != 0) 32 else 0;

            if (size + header <= end - start) end -= size + header;

        }

    }

    return end;

}

test "headers parse every version and layer, and reserved fields are rejected" {

    const joint = Header.parse(0xfffb9064).?;

    try std.testing.expectEqual(3, joint.layer);
    try std.testing.expect(!joint.lsf);
    try std.testing.expectEqual(44100, joint.rate);
    try std.testing.expectEqual(128, joint.bitrate);
    try std.testing.expectEqual(2, joint.channels);
    try std.testing.expectEqual(Mode.joint, joint.mode);
    try std.testing.expectEqual(2, joint.extension);
    try std.testing.expectEqual(417, joint.size());
    try std.testing.expectEqual(1152, joint.samples());
    try std.testing.expect(!joint.protected);
    try std.testing.expectEqual(418, Header.parse(0xfffb9264).?.size());
    try std.testing.expect(Header.parse(0xfffa9064).?.protected);

    const lower = Header.parse(0xfff36064).?;

    try std.testing.expect(lower.lsf);
    try std.testing.expectEqual(22050, lower.rate);
    try std.testing.expectEqual(48, lower.bitrate);
    try std.testing.expectEqual(156, lower.size());
    try std.testing.expectEqual(576, lower.samples());

    const lowest = Header.parse(0xffe318c4).?;

    try std.testing.expectEqual(8000, lowest.rate);
    try std.testing.expectEqual(8, lowest.table);
    try std.testing.expectEqual(1, lowest.channels);
    try std.testing.expectEqual(72, lowest.size());

    const one = Header.parse(0xffff6050).?;

    try std.testing.expectEqual(1, one.layer);
    try std.testing.expectEqual(192, one.bitrate);
    try std.testing.expectEqual(208, one.size());
    try std.testing.expectEqual(384, one.samples());

    const two = Header.parse(0xfffdb004).?;

    try std.testing.expectEqual(2, two.layer);
    try std.testing.expectEqual(Mode.stereo, two.mode);
    try std.testing.expectEqual(224, two.bitrate);
    try std.testing.expectEqual(731, two.size());

    // No sync, then reserved version, layer, bitrate and rate.
    for ([_]u32{ 0x7ffb9064, 0xffdb9064, 0xffeb9064, 0xfff99064, 0xfffbf064, 0xfffb9c64 }) |word| try std.testing.expectEqual(null, Header.parse(word));

    const free = Header.parse(0xfffb0064).?;

    try std.testing.expectEqual(0, free.bitrate);
    try std.testing.expectEqual(0, free.size());

    var frames = Frames.init();
    var out: [2304]f32 = undefined;
    const silent_frame = [_]u8{ 0xff, 0xfb, 0x90, 0x64 } ++ [_]u8{0} ** 413;

    try std.testing.expectError(error.Unsupported, frames.decode(&([_]u8{ 0xff, 0xfb, 0x00, 0x64 } ++ [_]u8{0} ** 400), &out));
    try std.testing.expectError(error.Invalid, frames.decode(silent_frame[0..3], &out));
    try std.testing.expectError(error.Invalid, frames.decode(silent_frame[0..416], &out));
    try std.testing.expectError(error.Invalid, frames.decode(&silent_frame, out[0..2303]));
    try std.testing.expectEqual(1152, try frames.decode(&silent_frame, &out));

    for (out) |sample| try std.testing.expectEqual(0, sample);

}

const Fixture = struct {

    name: []const u8,
    audio: []const u8,

    /// The first 2048 sample frames (4096 for mono) ffmpeg decodes, as 16-bit PCM.
    reference: []const u8,

    /// Total sample frames ffmpeg decodes.
    frames: u64,

    /// Whether a LAME tag gives the exact count, which an estimate from the bitrate otherwise stands in for.
    tagged: bool,

};

fn fixture(comptime name: []const u8, comptime extension: []const u8, frames: u64, tagged: bool) Fixture {

    return .{

        .name = name,
        .audio = @embedFile("fixtures/" ++ name ++ extension),
        .reference = @embedFile("fixtures/" ++ name ++ ".pcm"),
        .frames = frames,
        .tagged = tagged,

    };

}

const fixtures = [_]Fixture{

    fixture("mp3-44k-joint", ".mp3", 22050, true),
    fixture("mp3-44k-320", ".mp3", 11025, true),
    fixture("mp3-48k-vbr", ".mp3", 24000, true),
    fixture("mp3-32k-mono", ".mp3", 17280, false),
    fixture("mp3-22k-joint", ".mp3", 12672, false),
    fixture("mp3-24k-stereo", ".mp3", 12000, true),
    fixture("mp3-16k-mono", ".mp3", 9216, false),
    fixture("mp3-11k-joint", ".mp3", 5512, true),
    fixture("mp3-12k-mono", ".mp3", 7488, false),
    fixture("mp3-8k-mono", ".mp3", 5184, false),
    fixture("mp2-44k-stereo", ".mp2", 13824, false),
    fixture("mp2-48k-mono", ".mp2", 14976, false),
    fixture("mp2-44k-mono", ".mp2", 23040, false),
    fixture("mp2-32k-stereo", ".mp2", 16128, false),
    fixture("mp2-22k-stereo", ".mp2", 11520, false),
    fixture("mp1-44k-joint", ".mp1", 13824, false),
    fixture("mp1-32k-mono", ".mp1", 9984, false),

};

/// Every sample frame `source` decodes to.
fn decodeAll(allocator: std.mem.Allocator, source: *Source, piece: usize) ![]f32 {

    var decoder = try Decoder.open(allocator, source);
    var samples: std.ArrayList(f32) = .empty;
    var buffer: [4096]f32 = undefined;

    defer decoder.deinit(allocator);
    errdefer samples.deinit(allocator);

    while (true) {

        const count = try decoder.read(buffer[0 .. piece * decoder.channels]);

        if (count == 0) break;
        try samples.appendSlice(allocator, buffer[0 .. count * decoder.channels]);

    }

    return samples.toOwnedSlice(allocator);

}

/// The largest difference from 16-bit `reference`, in steps of 1/32768.
fn difference(samples: []const f32, reference: []const u8) f32 {

    var largest: f32 = 0;

    for (0..reference.len / 2) |index| {

        const expected: f32 = @floatFromInt(std.mem.readInt(i16, reference[index * 2 ..][0..2], .little));
        const actual = if (index < samples.len) std.math.clamp(samples[index] * 32768, -32768, 32767) else std.math.inf(f32);

        largest = @max(largest, @abs(actual - expected));

    }

    return largest;

}

test "every fixture decodes as ffmpeg decodes it, gapless where a LAME tag says how" {

    const allocator = std.testing.allocator;

    for (fixtures) |entry| {

        var source = Source.fixed(entry.audio);
        var decoder = try Decoder.open(allocator, &source);
        const reported = decoder.frames.?;
        const length = Header.parse(std.mem.readInt(u32, entry.audio[0..4], .big)).?.samples();

        decoder.deinit(allocator);

        const samples = try decodeAll(allocator, &source, 1000);

        defer allocator.free(samples);

        const channels: usize = if (std.mem.indexOf(u8, entry.name, "mono") != null) 1 else 2;
        const largest = difference(samples, entry.reference);

        if (largest > 2 or samples.len != entry.frames * channels) std.debug.print("{s}: {d} sample frames, {d} expected, off by {d}\n", .{ entry.name, samples.len / channels, entry.frames, largest });

        try std.testing.expect(largest <= 2);
        try std.testing.expectEqual(entry.frames * channels, samples.len);

        if (entry.tagged) {

            try std.testing.expectEqual(entry.frames, reported);

        } else {

            try std.testing.expect(@max(reported, entry.frames) - @min(reported, entry.frames) <= length);

        }

    }

}

test "Xing and Info headers give the frame count, delay, and seek table" {

    const allocator = std.testing.allocator;
    var source = Source.fixed(fixtures[2].audio);
    var decoder = try Decoder.open(allocator, &source);

    defer decoder.deinit(allocator);

    try std.testing.expectEqual(48000, decoder.rate);
    try std.testing.expectEqual(24000, decoder.frames);
    try std.testing.expect(decoder.state.toc != null);
    try std.testing.expect(decoder.state.delay > 529);

    var constant = Source.fixed(fixtures[0].audio);
    var info = try Decoder.open(allocator, &constant);

    defer info.deinit(allocator);

    // An Info header marks constant bitrate, which seeks in proportion rather than by the coarser table.
    try std.testing.expectEqual(22050, info.frames);
    try std.testing.expectEqual(null, info.state.toc);
    try std.testing.expectEqual(info.state.start + Header.parse(0xfffb9064).?.size(), info.state.audio);

}

test "Layer II and III frames decode one by one as a system stream would feed them" {

    for ([_]usize{ 10, 3, 4 }) |which| {

        const entry = fixtures[which];
        const channels: usize = if (std.mem.indexOf(u8, entry.name, "mono") != null) 1 else 2;
        var frames = Frames.init();
        var samples: [4096 * 2]f32 = undefined;
        var count: usize = 0;
        var offset: usize = 0;

        while (offset + 4 <= entry.audio.len and count < entry.reference.len / 2 / channels) {

            const header = Header.parse(std.mem.readInt(u32, entry.audio[offset..][0..4], .big)).?;
            var out: [2304]f32 = undefined;
            const decoded = try frames.decode(entry.audio[offset..], &out);
            const kept = @min(decoded, samples.len / channels - count);

            @memcpy(samples[count * channels ..][0 .. kept * channels], out[0 .. kept * channels]);
            count += kept;
            offset += header.size();

        }

        try std.testing.expect(difference(samples[0 .. count * channels], entry.reference) <= 2);

    }

}

test "a feed frames sound arriving in pieces of any size, past what comes before the first frame" {

    for ([_]usize{ 10, 3, 4 }) |which| {

        for ([_]usize{ 1, 97, 4096 }) |piece| {

            const entry = fixtures[which];
            const channels: usize = if (std.mem.indexOf(u8, entry.name, "mono") != null) 1 else 2;
            const wanted = entry.reference.len / 2 / channels;
            var buffer: [8192]u8 = undefined;
            var feed = Feed.init(&buffer);
            var frames = Frames.init();
            var samples: [4096 * 2]f32 = undefined;
            var count: usize = 0;
            var offset: usize = 0;

            feed.keep("ICY 200 OK\r\n\r\n");

            while (count < wanted and offset < entry.audio.len) {

                const part = entry.audio[offset..@min(offset + piece, entry.audio.len)];

                feed.keep(part);
                offset += part.len;

                if (feed.rate == 0) feed.probe();
                if (feed.rate == 0) continue;

                while (feed.frame()) |bytes| {

                    var out: [2304]f32 = undefined;
                    const decoded = try frames.decode(bytes, &out);
                    const kept = @min(decoded, wanted - count);

                    @memcpy(samples[count * channels ..][0 .. kept * channels], out[0 .. kept * channels]);
                    count += kept;

                }

            }

            try std.testing.expectEqual(wanted, count);
            try std.testing.expectEqual(channels, feed.channels);
            try std.testing.expect(difference(samples[0 .. count * channels], entry.reference) <= 2);

        }

    }

}

test "remixing folds stereo to mono and doubles mono to stereo" {

    var out: [4]f32 = undefined;

    remix(&.{ 0.5, -0.5 }, 1, &out, 2, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.5, -0.5, -0.5 }, &out);

    remix(&.{ 1, 0, 0.5, 0.25 }, 2, &out, 1, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, 0.375 }, out[0..2]);

}

test "a chunked source and reads of any size give the samples a whole file does" {

    const allocator = std.testing.allocator;

    for ([_]usize{ 0, 2, 7, 10, 15 }) |which| {

        var whole = Source.fixed(fixtures[which].audio);
        const expected = try decodeAll(allocator, &whole, 1000);

        defer allocator.free(expected);

        for ([_]usize{ 1, 7, 1152, 2000 }) |piece| {

            var file = @import("source.zig").Chunked{

                .bytes = fixtures[which].audio,
                .piece = 37,

            };
            var buffer: [4096]u8 = undefined;
            var source = file.source(&buffer);
            const samples = try decodeAll(allocator, &source, piece);

            defer allocator.free(samples);

            try std.testing.expectEqualSlices(f32, expected, samples);

        }

    }

}

/// Reads up to `count` sample frames.
fn readSome(allocator: std.mem.Allocator, decoder: *Decoder, count: usize) ![]f32 {

    const samples = try allocator.alloc(f32, count * decoder.channels);
    var filled: usize = 0;

    while (filled < count) {

        const got = try decoder.read(samples[filled * decoder.channels ..]);

        if (got == 0) break;
        filled += got;

    }

    return allocator.realloc(samples, filled * decoder.channels);

}

test "seeking lands near the target and decodes on cleanly" {

    const allocator = std.testing.allocator;

    // Constant bitrate files land exactly, so what follows must match reading straight through.
    for ([_]usize{ 0, 4, 9, 10, 15, 16 }) |which| {

        var whole = Source.fixed(fixtures[which].audio);
        const expected = try decodeAll(allocator, &whole, 1000);

        defer allocator.free(expected);

        var source = Source.fixed(fixtures[which].audio);
        var decoder = try Decoder.open(allocator, &source);
        const channels: usize = decoder.channels;
        const total = expected.len / channels;

        defer decoder.deinit(allocator);

        for ([_]u64{ total / 2, 1, total - 700, 3000, 0, total / 3 + 77 }) |target| {

            try std.testing.expectEqual(target, try decoder.seek(target));

            const samples = try readSome(allocator, &decoder, 600);

            defer allocator.free(samples);

            const reference = expected[@intCast(target * channels)..][0..samples.len];

            try std.testing.expectEqual(@min(600, total - target) * channels, samples.len);

            for (samples, reference) |sample, wanted| try std.testing.expectApproxEqAbs(wanted, sample, 1e-6);

        }

        try std.testing.expect(try decoder.seek(total + 5000) >= total);
        var rest: [4]f32 = undefined;

        try std.testing.expectEqual(0, try decoder.read(&rest));

    }

    // A variable bitrate file seeks through its Xing table, so it lands near the target; what follows must match some point near there.
    var whole = Source.fixed(fixtures[2].audio);
    const expected = try decodeAll(allocator, &whole, 1000);

    defer allocator.free(expected);

    var source = Source.fixed(fixtures[2].audio);
    var decoder = try Decoder.open(allocator, &source);

    defer decoder.deinit(allocator);

    for ([_]u64{ 12000, 5000, 20000, 9999 }) |target| {

        const landed = try decoder.seek(target);
        const samples = try readSome(allocator, &decoder, 512);

        defer allocator.free(samples);

        try std.testing.expect(@max(landed, target) - @min(landed, target) <= 1152);

        var best: f32 = std.math.inf(f32);
        var start = landed -| 2304;

        while (start <= landed + 2304 and (start + 512) * 2 <= expected.len) : (start += 1) {

            var largest: f32 = 0;

            for (samples, expected[start * 2 ..][0..samples.len]) |sample, wanted| largest = @max(largest, @abs(sample - wanted));

            best = @min(best, largest);

        }

        try std.testing.expect(best < 1e-5);

    }

}

/// An ID3v2 tag of version `major` around `body`, with a footer if `flags` asks for one.
fn id3(allocator: std.mem.Allocator, major: u8, flags: u8, body: []const u8) ![]u8 {

    var tag: std.ArrayList(u8) = .empty;
    const size = [4]u8{ @intCast(body.len >> 21 & 0x7f), @intCast(body.len >> 14 & 0x7f), @intCast(body.len >> 7 & 0x7f), @intCast(body.len & 0x7f) };

    try tag.appendSlice(allocator, &.{ 'I', 'D', '3', major, 0, flags });
    try tag.appendSlice(allocator, &size);
    try tag.appendSlice(allocator, body);

    if (flags & 0x10 != 0) {

        try tag.appendSlice(allocator, &.{ '3', 'D', 'I', major, 0, flags });
        try tag.appendSlice(allocator, &size);

    }

    return tag.toOwnedSlice(allocator);

}

/// Appends an ID3v2 frame, sized as version `major` writes it.
fn id3Frame(allocator: std.mem.Allocator, list: *std.ArrayList(u8), major: u8, id: []const u8, format: u8, content: []const u8) !void {

    const length: u32 = @intCast(content.len);

    try list.appendSlice(allocator, id);

    switch (major) {

        2 => try list.appendSlice(allocator, &.{ @intCast(length >> 16), @intCast(length >> 8 & 0xff), @intCast(length & 0xff) }),
        3 => try list.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, length))),
        else => try list.appendSlice(allocator, &.{ @intCast(length >> 21 & 0x7f), @intCast(length >> 14 & 0x7f), @intCast(length >> 7 & 0x7f), @intCast(length & 0x7f) }),

    }

    if (major > 2) try list.appendSlice(allocator, &.{ 0, format });

    try list.appendSlice(allocator, content);

}

test "ID3v2 tags are skipped and their title and artist read, with ID3v1 to fall back on" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const allocator = arena.allocator();
    const audio = fixtures[3].audio;
    var plain = Source.fixed(audio);
    const expected = try decodeAll(allocator, &plain, 1000);

    var three: std.ArrayList(u8) = .empty;

    try id3Frame(allocator, &three, 3, "APIC", 0, &([_]u8{0xff} ** 5000));
    try id3Frame(allocator, &three, 3, "TIT2", 0, "\x01\xff\xfeT\x00\xef\x00t\x00l\x00e\x00\x00\x00");
    try id3Frame(allocator, &three, 3, "TPE1", 0, "\x00Art\xefst\x00");
    try three.appendNTimes(allocator, 0, 200);

    var four: std.ArrayList(u8) = .empty;

    try four.appendSlice(allocator, &.{ 0, 0, 0, 6, 1, 0 });
    try id3Frame(allocator, &four, 4, "TIT2", 0, "\x03Caf\xc3\xa9\x00Other");
    try id3Frame(allocator, &four, 4, "TPE1", 0x03, "\x00\x00\x00\x0a\x00Mot\xff\x00rhead");

    var two: std.ArrayList(u8) = .empty;

    try id3Frame(allocator, &two, 2, "TT2", 0, "\x00Two");
    try id3Frame(allocator, &two, 2, "TP1", 0, "\x01\xfe\xff\x00P\x00a\x00i\x00r");

    var hidden: std.ArrayList(u8) = .empty;

    try id3Frame(allocator, &hidden, 3, "TIT2", 0, "\x01\xff\x00\xfeS\x00y\x00n\x00c\x00");

    var older: [128]u8 = @splat(0);

    @memcpy(older[0..3], "TAG");
    @memcpy(older[3..12], "Old Title");
    @memcpy(older[33..43], "Old Artist");

    var ape: std.ArrayList(u8) = .empty;
    const item = "\x03\x00\x00\x00\x00\x00\x00\x00Title\x00Ape";

    for ([_]u32{ 0xa000_0000, 0x8000_0000 }) |flags| {

        try ape.appendSlice(allocator, "APETAGEX");

        for ([_]u32{ 2000, item.len + 32, 1, flags, 0, 0 }) |value| try ape.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, value)));

        if (flags == 0xa000_0000) try ape.appendSlice(allocator, item);

    }

    const Case = struct {

        parts: []const []const u8,
        title: []const u8,
        artist: []const u8,

    };

    const cases = [_]Case{

        .{ .parts = &.{ try id3(allocator, 3, 0, three.items), audio }, .title = "Tïtle", .artist = "Artïst" },
        .{ .parts = &.{ try id3(allocator, 4, 0x50, four.items), audio }, .title = "Café", .artist = "Motÿrhead" },
        .{ .parts = &.{ try id3(allocator, 2, 0, two.items), audio, ape.items }, .title = "Two", .artist = "Pair" },
        .{ .parts = &.{ try id3(allocator, 3, 0x80, hidden.items), audio, &older }, .title = "Sync", .artist = "Old Artist" },
        .{ .parts = &.{ try id3(allocator, 4, 0, four.items[6..]), try id3(allocator, 3, 0, three.items), audio, ape.items, &older }, .title = "Café", .artist = "Motÿrhead" },
        .{ .parts = &.{ audio, &older }, .title = "Old Title", .artist = "Old Artist" },
        .{ .parts = &.{audio}, .title = "", .artist = "" },

    };

    for (cases) |case| {

        const bytes = try std.mem.concat(allocator, u8, case.parts);
        var source = Source.fixed(bytes);
        var decoder = try Decoder.open(allocator, &source);

        try std.testing.expectEqualStrings(case.title, decoder.tags.title.get());
        try std.testing.expectEqualStrings(case.artist, decoder.tags.artist.get());
        try std.testing.expectEqual(17280, decoder.frames);

        decoder.deinit(allocator);

        var again = Source.fixed(bytes);

        try std.testing.expectEqualSlices(f32, expected, try decodeAll(allocator, &again, 1000));

    }

}

test "intensity stereo pans the left channel above the right channel's last coded band" {

    prepare();

    var lines: [2][576]f32 = @splat(@splat(0));
    var right = Factors{};

    @memset(&lines[0], 1);
    lines[1][2] = 0.5;
    right.long[1] = 0;
    right.long[2] = 3;
    right.long[3] = 6;
    right.long[4] = 7;
    right.long[20] = 2;

    stereo(&lines, Header.parse(0xfffb9054).?, .{}, &right);

    const ratio: f32 = @tan(std.math.pi / 6.0);
    const expected = [_][3]f32{

        .{ 2, 1, 0.5 },
        .{ 4, 0, 1 },
        .{ 8, 0.5, 0.5 },
        .{ 12, 1, 0 },
        .{ 16, 1, 0 },
        .{ 500, ratio / (1 + ratio), 1 / (1 + ratio) },

    };

    for (expected) |line| {

        const index: usize = @intFromFloat(line[0]);

        try std.testing.expectApproxEqAbs(line[1], lines[0][index], 1e-6);
        try std.testing.expectApproxEqAbs(line[2], lines[1][index], 1e-6);

    }

    // MPEG-2 positions step by 2^-1/4 (or 2^-1/2) towards one side, and a field's largest value means none.
    lines = @splat(@splat(0));
    right = .{};
    @memset(&lines[0], 1);
    right.long[0] = 1;
    right.long[1] = 2;
    right.long[2] = 3;
    right.long_limits[2] = 3;

    stereo(&lines, Header.parse(0xfff36054).?, .{}, &right);

    try std.testing.expectApproxEqAbs(@exp2(@as(f32, -0.25)), lines[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(1, lines[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(1, lines[0][6], 1e-6);
    try std.testing.expectApproxEqAbs(@exp2(@as(f32, -0.25)), lines[1][6], 1e-6);
    try std.testing.expectApproxEqAbs(1, lines[0][12], 1e-6);
    try std.testing.expectApproxEqAbs(0, lines[1][12], 1e-6);

    // With mid/side on too, bands below the intensity ones are mid and side.
    lines = @splat(@splat(0));
    right = .{};
    @memset(&lines[0], 1);
    lines[1][0] = 1;

    stereo(&lines, Header.parse(0xfffb9074).?, .{}, &right);

    try std.testing.expectApproxEqAbs(std.math.sqrt2, lines[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(0, lines[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(std.math.sqrt1_2, lines[0][2], 1e-6);
    try std.testing.expectApproxEqAbs(std.math.sqrt1_2, lines[1][2], 1e-6);
    try std.testing.expectApproxEqAbs(0, lines[0][4], 1e-6);
    try std.testing.expectApproxEqAbs(1, lines[1][4], 1e-6);

}

test "corrupt and truncated input never crashes" {

    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6d70_3362);
    const random = prng.random();
    var buffer: [4096]f32 = undefined;

    for ([_]usize{ 0, 2, 4, 5, 7, 9, 10, 14, 15, 16 }) |which| {

        const original = fixtures[which].audio;
        const copy = try allocator.dupe(u8, original);

        defer allocator.free(copy);

        for (0..30) |_| {

            @memcpy(copy, original);

            var length = copy.len;
            const kind = random.uintLessThan(u8, 4);

            if (kind == 0 or kind == 3) for (0..random.uintAtMost(usize, 40) + 1) |_| {

                const bit = random.uintLessThan(usize, copy.len * 8);

                copy[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);

            };

            if (kind == 1 or kind == 3) length = random.uintLessThan(usize, copy.len);

            if (kind == 2) {

                const start = random.uintLessThan(usize, copy.len);

                random.bytes(copy[start..][0..@min(copy.len - start, random.uintAtMost(usize, 300) + 1)]);

            }

            var source = Source.fixed(copy[0..length]);
            var decoder = Decoder.open(allocator, &source) catch continue;

            defer decoder.deinit(allocator);

            const piece = random.uintAtMost(usize, 1500) + 1;

            while (true) {

                const count = try decoder.read(buffer[0 .. piece * decoder.channels]);

                if (count == 0) break;

                for (buffer[0 .. count * decoder.channels]) |sample| try std.testing.expect(std.math.isFinite(sample));

            }

            for (0..3) |_| {

                _ = try decoder.seek(random.uintLessThan(u64, 40000));
                _ = try decoder.read(&buffer);

            }

        }

    }

    // Random bodies behind every kind of valid header exercise mixed blocks, intensity stereo, and bad tables.
    var frames = Frames.init();
    var frame: [1800]u8 = undefined;
    var out: [2304]f32 = undefined;
    var decoded: usize = 0;

    while (decoded < 3000) {

        const word = random.int(u32) | 0xffe0_0000;
        const header = Header.parse(word) orelse continue;

        if (header.bitrate == 0) continue;

        random.bytes(&frame);

        // Keep some side information plausible so decoding gets past it.
        if (random.boolean()) frame[4] = 0;

        std.mem.writeInt(u32, frame[0..4], word, .big);
        decoded += 1;

        _ = frames.decode(&frame, &out) catch continue;

        for (out[0 .. header.samples() * header.channels]) |sample| try std.testing.expect(std.math.isFinite(sample));

    }

}

test "files with no frames are rejected, and free format is not supported" {

    const allocator = std.testing.allocator;
    var noise: [5000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);

    prng.random().bytes(&noise);

    for ([_][]const u8{ "", "ID3", &noise, "\xff\xfb\x90" }) |bytes| {

        var source = Source.fixed(bytes);

        try std.testing.expectError(error.Invalid, Decoder.open(allocator, &source));

    }

    const free = [_]u8{ 0xff, 0xfb, 0x00, 0x64 } ++ [_]u8{0} ** 300;
    var source = Source.fixed(&(free ++ free ++ free));

    try std.testing.expectError(error.Unsupported, Decoder.open(allocator, &source));

}
