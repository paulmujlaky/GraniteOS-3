//! Intel High Definition Audio controllers, such as VMware's and the Coffee Lake PCH's: the command rings that carry verbs
//! to codecs, and one output stream the device plays round and round from a ring of half-page buffers.

const std = @import("std");

const codec = @import("codec.zig");

const api = @import("api");

// Registers, by offset into BAR 0.
const capabilities = 0x00;
const control = 0x08;
const states = 0x0e;
const interrupts = 0x20;
const corb_base = 0x40;
const corb_write = 0x48;
const corb_read = 0x4a;
const corb_control = 0x4c;
const corb_size = 0x4e;
const rirb_base = 0x50;
const rirb_write = 0x58;
const rirb_count = 0x5a;
const rirb_control = 0x5c;
const rirb_status = 0x5d;
const rirb_size = 0x5e;
const immediate_out = 0x60;
const immediate_in = 0x64;
const immediate_status = 0x68;
const descriptors = 0x80;

// Stream descriptor registers, by offset from the descriptor.
const stream_control = 0x00;
const stream_tag = 0x02;
const stream_status = 0x03;
const link_position = 0x04;
const cyclic_length = 0x08;
const last_index = 0x0c;
const stream_format = 0x12;
const list_low = 0x18;
const list_high = 0x1c;

// Stream control bits: reset, run, and interrupt on completion; and the command rings' DMA run bit.
const stream_reset = 1 << 0;
const stream_run = 1 << 1;
const completion = 1 << 2;
const ring_run = 1 << 1;
const response_flag = 1 << 0;

/// Frames in each buffer the device plays, half a page of 16-bit stereo, and buffers in the ring.
pub const period = 512;
pub const periods = 16;
pub const ring_bytes = periods * period_bytes;

const period_bytes = period * 4;

/// One buffer descriptor list entry; bit 0 of `flags` interrupts once the device has played the buffer.
const Entry = extern struct {

    address: u64,
    length: u32,
    flags: u32,

};

pub const Controller = struct {

    registers: usize,

    /// Codecs that answered the reset, one bit per address.
    codecs: u15 = 0,

    /// The command ring, the response ring, their entries, and the last of each used; or the immediate interface when the
    /// rings do not answer.
    corb: api.Page = undefined,
    rirb: api.Page = undefined,
    entries: u16 = 0,
    sent: u16 = 0,
    seen: u16 = 0,
    immediate: bool = false,

    /// The first output stream's descriptor, and its bit among the interrupt enables.
    output: usize = 0,
    order: u5 = 0,

    list: api.Page = undefined,
    buffers: [periods / 2]api.Page = undefined,

    /// Resets the controller at `base` and starts its command rings; fails when no codec answers.
    pub fn init(self: *Controller, base: u64, size: u64) !void {

        self.* = .{

            .registers = @intFromPtr(try api.map(base, size)),

        };

        self.write(u8, corb_control, 0);
        self.write(u8, rirb_control, 0);
        self.until(u8, corb_control, ring_run, 0) catch {

        };

        self.write(u32, control, self.read(u32, control) & ~@as(u32, 1));
        try self.until(u32, control, 1, 0);
        api.sleep(1);
        self.write(u32, control, self.read(u32, control) | 1);
        try self.until(u32, control, 1, 1);

        // Codecs ask for an address within 521 µs of the reset ending.
        api.sleep(2);
        self.codecs = @truncate(self.read(u16, states));
        self.write(u16, states, 0x7fff);
        if (self.codecs == 0) return error.NoCodec;

        const global = self.read(u16, capabilities);
        const inputs: u5 = @truncate(global >> 8 & 0xf);

        if (global >> 12 & 0xf == 0) return error.NoOutput;

        self.order = inputs;
        self.output = descriptors + @as(usize, inputs) * 0x20;

        self.corb = try api.dma();
        self.rirb = try api.dma();

        self.entries = @min(largest(self.read(u8, corb_size)), largest(self.read(u8, rirb_size)));

        self.write(u32, corb_base, @truncate(self.corb.physical));
        self.write(u32, corb_base + 4, @intCast(self.corb.physical >> 32));
        self.write(u8, corb_size, encode(self.entries));
        self.write(u16, corb_read, 0x8000);
        self.until(u16, corb_read, 0x8000, 0x8000) catch {

        };

        // Some controllers never show the reset bit set, so clearing it is all that is waited for.
        self.write(u16, corb_read, 0);
        self.until(u16, corb_read, 0x8000, 0) catch {

        };

        self.write(u16, corb_write, 0);

        self.write(u32, rirb_base, @truncate(self.rirb.physical));
        self.write(u32, rirb_base + 4, @intCast(self.rirb.physical >> 32));
        self.write(u8, rirb_size, encode(self.entries));
        self.write(u16, rirb_write, 0x8000);
        self.write(u16, rirb_count, 1);

        self.write(u8, corb_control, ring_run);
        // The response flag must be on for clearing it to restart the count, or controllers that pause at the count, as QEMU's does, stop answering.
        self.write(u8, rirb_control, ring_run | response_flag);

        // A controller whose rings stay silent may still answer one verb at a time.
        if (self.command(@as(u32, @ctz(self.codecs)) << 28 | 0xf0000) == null) {

            self.write(u8, corb_control, 0);
            self.write(u8, rirb_control, 0);
            self.immediate = true;

        }

    }

    /// Sends one verb and waits for its response; null when none comes.
    pub fn command(self: *Controller, verb: u32) ?u32 {

        if (self.immediate) return self.single(verb);

        const corb: [*]volatile u32 = @ptrCast(self.corb.bytes);
        const rirb: [*]volatile u64 = @ptrCast(@alignCast(self.rirb.bytes));

        self.sent = (self.sent + 1) % self.entries;
        corb[self.sent] = verb;
        self.write(u16, corb_write, self.sent);

        const deadline = api.ticks() + 5;
        var spins: u32 = 0;

        while (true) {

            if (self.read(u16, rirb_write) & 0xff != self.seen) {

                self.seen = (self.seen + 1) % self.entries;
                self.write(u8, rirb_status, 0x5);

                const response = rirb[self.seen];

                // Unsolicited responses, such as a jack's, are not answers.
                if (response >> 36 & 1 == 0) return @truncate(response);
                continue;

            }

            if (api.ticks() >= deadline) return null;

            // Codecs usually answer within microseconds, so a short spin comes before sleeping.
            spins += 1;
            if (spins < 4096) std.atomic.spinLoopHint() else api.sleep(1);

        }

    }

    /// Carries verbs to the codec at `address`.
    pub fn link(self: *Controller, address: u4) codec.Link {

        return .{

            .context = self,
            .send = send,
            .address = address,

        };

    }

    /// Readies the first output stream to play its ring as stream `tag` in `format`, stopped and silent.
    pub fn open(self: *Controller, tag: u4, format: u16) !void {

        const at = self.output;

        self.write(u8, at + stream_control, stream_reset);
        self.until(u8, at + stream_control, stream_reset, stream_reset) catch {

        };

        self.write(u8, at + stream_control, 0);
        try self.until(u8, at + stream_control, stream_reset, 0);

        self.list = try api.dma();

        for (&self.buffers) |*page| page.* = try api.dma();

        const entries: *[periods]Entry = @ptrCast(@alignCast(self.list.bytes));

        for (entries, 0..) |*entry, index| entry.* = .{

            .address = self.buffers[index / 2].physical + index % 2 * period_bytes,
            .length = period_bytes,
            .flags = 1,

        };

        self.write(u32, at + cyclic_length, ring_bytes);
        self.write(u16, at + last_index, periods - 1);
        self.write(u16, at + stream_format, format);
        self.write(u32, at + list_low, @truncate(self.list.physical));
        self.write(u32, at + list_high, @intCast(self.list.physical >> 32));
        self.write(u8, at + stream_tag, @as(u8, tag) << 4);
        self.write(u8, at + stream_status, 0x1c);
        self.write(u32, interrupts, self.read(u32, interrupts) | 1 << 31 | @as(u32, 1) << self.order);
        self.write(u8, at + stream_control, completion);

    }

    /// Starts or stops the stream where it is.
    pub fn run(self: *const Controller, on: bool) void {

        const at = self.output + stream_control;

        self.write(u8, at, if (on) self.read(u8, at) | stream_run else self.read(u8, at) & ~@as(u8, stream_run));

    }

    /// Clears the stream's interrupt.
    pub fn acknowledge(self: *const Controller) void {

        self.write(u8, self.output + stream_status, self.read(u8, self.output + stream_status));

    }

    /// Where the device is in the ring, in bytes from its start.
    pub fn position(self: *const Controller) u32 {

        return self.read(u32, self.output + link_position);

    }

    /// The samples of buffer `index`, left then right.
    pub fn buffer(self: *const Controller, index: usize) *[period * 2]i16 {

        return @ptrCast(@alignCast(self.buffers[index / 2].bytes[index % 2 * period_bytes ..][0..period_bytes]));

    }

    fn single(self: *const Controller, verb: u32) ?u32 {

        self.until(u16, immediate_status, 1, 0) catch return null;
        self.write(u32, immediate_out, verb);

        // Clears any stale response, then starts the command.
        self.write(u16, immediate_status, 0x3);
        self.until(u16, immediate_status, 0x2, 0x2) catch return null;

        return self.read(u32, immediate_in);

    }

    fn until(self: *const Controller, comptime T: type, offset: usize, mask: T, value: T) !void {

        const deadline = api.ticks() + 10;
        var spins: u32 = 0;

        while (self.read(T, offset) & mask != value) {

            if (api.ticks() >= deadline) return error.Timeout;

            spins += 1;
            if (spins < 4096) std.atomic.spinLoopHint() else api.sleep(1);

        }

    }

    fn read(self: *const Controller, comptime T: type, offset: usize) T {

        return @as(*volatile T, @ptrFromInt(self.registers + offset)).*;

    }

    fn write(self: *const Controller, comptime T: type, offset: usize, value: T) void {

        @as(*volatile T, @ptrFromInt(self.registers + offset)).* = value;

    }

};

fn send(context: *anyopaque, verb: u32) ?u32 {

    const self: *Controller = @ptrCast(@alignCast(context));

    return self.command(verb);

}

/// The most entries a ring's size register allows: 256, 16, or 2.
fn largest(register: u8) u16 {

    if (register & 0x40 != 0) return 256;
    if (register & 0x20 != 0) return 16;

    return 2;

}

/// The size register's value for a ring of `entries`.
fn encode(entries: u16) u8 {

    return switch (entries) {

        2 => 0,
        16 => 1,
        else => 2,

    };

}
