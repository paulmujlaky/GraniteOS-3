//! A film in an MPEG system stream: its pictures decoded as they fall due, and its MPEG audio as the speakers need it.

const std = @import("std");

const mp3 = @import("mp3.zig");
const system = @import("system.zig");
const video = @import("video.zig");

const Source = @import("source.zig").Source;
const Tags = @import("tags.zig").Tags;

pub const Error = @import("source.zig").Error;

/// Bytes of sound held waiting for the decoder at most; a stream interleaved worse than this loses some.
const backlog = 1024 * 1024;

/// Seconds before a seek's target that reading starts from, so the sound for the target is surely after it.
const preload = 1;

/// The most samples one MPEG audio frame decodes to, in two channels.
const longest = 1152 * 2;

pub const Size = struct {

    width: u32,
    height: u32,

};

pub const Movie = struct {

    /// The sound's format; a silent film has no channels.
    rate: u32 = 0,
    channels: u8 = 0,
    tags: Tags = .{},

    allocator: std.mem.Allocator,
    demuxer: system.Demuxer,
    pictures: video.Decoder,
    sound: *mp3.Frames,

    /// Sound bytes from the stream not yet decoded, and the time of the first frame among them.
    feed: mp3.Feed,
    heard: ?f64 = null,

    /// Samples of the last frame decoded, and how many of its frames were read.
    decoded: [longest]f32 = undefined,
    held: usize = 0,
    used: usize = 0,

    /// Where the first sound plays from, and pictures earlier than this are passed over after a seek.
    beginning: f64 = 0,
    after: f64 = 0,

    /// A picture decoded while learning the pictures' size, given out first.
    waiting: ?*const video.Picture = null,

    /// The stream ran out.
    finished: bool = false,

    pub fn open(allocator: std.mem.Allocator, source: *Source) Error!Movie {

        const demuxer = try system.Demuxer.open(source);
        const audio = try allocator.alloc(u8, backlog);

        errdefer allocator.free(audio);

        const sound = try allocator.create(mp3.Frames);

        errdefer allocator.destroy(sound);

        sound.* = mp3.Frames.init();

        var movie = Movie{

            .allocator = allocator,
            .demuxer = demuxer,
            .pictures = video.Decoder.init(allocator),
            .sound = sound,
            .feed = .init(audio),

        };

        errdefer movie.pictures.deinit(allocator);

        // Reads ahead until the sound's format and the pictures' size are known.
        while (movie.demuxer.audio and movie.rate == 0 or movie.demuxer.video and movie.pictures.sequence() == null) {

            if (movie.feed.tail == backlog or !try movie.pull()) break;
            if (movie.rate == 0) movie.probe();

            // The decoder reads the sequence header only as it decodes.
            if (movie.demuxer.video and movie.pictures.sequence() == null) movie.waiting = try movie.pictures.next(false);

        }

        if (movie.demuxer.video and movie.pictures.sequence() == null) return error.Invalid;

        movie.beginning = movie.heard orelse 0;

        return movie;

    }

    pub fn deinit(self: *Movie, allocator: std.mem.Allocator) void {

        self.pictures.deinit(allocator);
        allocator.destroy(self.sound);
        allocator.free(self.feed.bytes);

    }

    /// Seconds from the first timestamp to the last, when the stream gives them.
    pub fn duration(self: *const Movie) ?f64 {

        return self.demuxer.duration();

    }

    /// The pictures' size, or null for a film of sound alone.
    pub fn size(self: *const Movie) ?Size {

        const sequence = self.pictures.sequence() orelse return null;

        return .{

            .width = sequence.width,
            .height = sequence.height,

        };

    }

    /// Pictures shown each second.
    pub fn frameRate(self: *const Movie) f64 {

        const sequence = self.pictures.sequence() orelse return 25;

        return sequence.rate;

    }

    /// Up to `out.len / channels` frames of interleaved samples; zero at the end.
    pub fn read(self: *Movie, out: []f32) Error!usize {

        if (self.channels == 0) return 0;

        const wanted = out.len / self.channels;
        var done: usize = 0;

        while (done < wanted) {

            if (self.used == self.held) {

                if (!try self.hear()) break;
                continue;

            }

            const count = @min(self.held - self.used, wanted - done);

            @memcpy(out[done * self.channels ..][0 .. count * self.channels], self.decoded[self.used * self.channels ..][0 .. count * self.channels]);
            self.used += count;
            done += count;

        }

        return done;

    }

    /// The next picture in display order, or null at the end; it stays valid until the next call.
    pub fn picture(self: *Movie) Error!?*const video.Picture {

        if (self.waiting) |first| {

            self.waiting = null;
            return first;

        }

        while (true) {

            const next = try self.pictures.next(self.finished) orelse {

                if (self.finished) return null;

                _ = try self.pull();
                continue;

            };

            if (next.time + 0.5 / self.frameRate() >= self.after) return next;

        }

    }

    /// Moves to `seconds` in, as near as its sound allows, and returns where the sound starts again.
    pub fn seek(self: *Movie, seconds: f64) Error!f64 {

        // Packs are found by their pictures' times, and the sound beside them may run up to a muxer's preload ahead.
        _ = try self.demuxer.seek(@max(seconds - preload, 0));

        self.pictures.reset();
        self.sound.reset();
        self.feed.clear();
        self.heard = null;
        self.held = 0;
        self.used = 0;
        self.finished = false;
        self.after = seconds;
        self.waiting = null;

        if (self.channels == 0) return seconds;

        // Decodes sound up to the frame holding `seconds`, then steps into it to start exactly there.
        while (try self.hear()) {

            const rate: f64 = @floatFromInt(self.rate);
            const start = self.heard.? - @as(f64, @floatFromInt(self.held)) / rate;

            if (start + @as(f64, @floatFromInt(self.held)) / rate > seconds) {

                self.used = @intFromFloat(std.math.clamp((seconds - start) * rate, 0, @as(f64, @floatFromInt(self.held))));

                return start + @as(f64, @floatFromInt(self.used)) / rate;

            }

        }

        return seconds;

    }

    /// Decodes the next whole frame of sound, reading on through the stream until one is in; false at the end.
    fn hear(self: *Movie) Error!bool {

        while (true) {

            if (self.feed.frame()) |bytes| {

                const header = mp3.Header.parse(std.mem.readInt(u32, bytes[0..4], .big)).?;
                var samples: [longest]f32 = undefined;

                // A frame that fails still takes its time, so what follows stays in step with the pictures.
                self.heard = (self.heard orelse 0) + @as(f64, @floatFromInt(header.samples())) / @as(f64, @floatFromInt(header.rate));

                const frames = self.sound.decode(bytes, &samples) catch |err| switch (err) {

                    error.Invalid, error.Unsupported => continue,
                    else => return err,

                };

                self.held = frames;
                self.used = 0;
                mp3.remix(&samples, header.channels, &self.decoded, self.channels, frames);

                return true;

            }

            if (!try self.pull()) return false;

        }

    }

    /// Takes the stream's next packet: sound into the bytes waiting, pictures into their decoder; false at the end.
    fn pull(self: *Movie) Error!bool {

        const packet = try self.demuxer.next() orelse {

            self.finished = true;
            return false;

        };

        switch (packet.kind) {

            .video => try self.pictures.feed(self.allocator, packet.bytes, packet.time),
            .audio => self.keep(packet.bytes, packet.time),

        }

        return true;

    }

    /// Adds sound bytes; the first carrying a time, after a seek or at the start, says when the frames from it begin.
    fn keep(self: *Movie, bytes: []const u8, time: ?f64) void {

        if (self.heard == null) {

            const stamp = time orelse return;

            self.heard = stamp;
            self.feed.clear();

        }

        // Pictures read far ahead of the sound; what will not fit is lost rather than held without end.
        self.feed.keep(bytes);

    }

    /// Learns the sound's format from the bytes held.
    fn probe(self: *Movie) void {

        self.feed.probe();
        self.rate = self.feed.rate;
        self.channels = self.feed.channels;

    }

};

/// What playing a whole film gave: sound frames, pictures, and whether the pictures' times only rose.
const Played = struct {

    heard: usize = 0,
    seen: usize = 0,
    rising: bool = true,

};

/// Plays a whole film the way a player would, a little sound then a picture, keeping as much sound as `sound` holds.
fn play(movie: *Movie, sound: []f32) Error!Played {

    var result = Played{};
    var piece: [2000]f32 = undefined;
    var last: f64 = -1;
    var silent = false;

    while (true) {

        const got = if (silent) 0 else try movie.read(&piece);
        const kept = @min(got * movie.channels, sound.len -| result.heard * movie.channels);

        @memcpy(sound[@min(result.heard * movie.channels, sound.len)..][0..kept], piece[0..kept]);
        result.heard += got;
        silent = got == 0;

        const next = try movie.picture() orelse if (silent) break else continue;

        result.rising = result.rising and next.time > last;
        last = next.time;
        result.seen += 1;

    }

    return result;

}

test "films give their sound and pictures in step, starting where the sound does" {

    const allocator = std.testing.allocator;
    var source = Source.fixed(@embedFile("fixtures/video-gop.mpg"));
    var movie = try Movie.open(allocator, &source);

    defer movie.deinit(allocator);

    try std.testing.expectEqual(32000, movie.rate);
    try std.testing.expectEqual(1, movie.channels);
    try std.testing.expectEqual(Size{ .width = 160, .height = 120 }, movie.size().?);
    try std.testing.expectEqual(25, movie.frameRate());
    try std.testing.expectApproxEqAbs(0.525, movie.beginning, 0.001);

    const sound = try allocator.alloc(f32, 64 * 1152);

    defer allocator.free(sound);

    const played = try play(&movie, sound);

    try std.testing.expectEqual(28 * 1152, played.heard);
    try std.testing.expectEqual(25, played.seen);
    try std.testing.expect(played.rising);

    var peak: f32 = 0;

    for (sound[0..played.heard]) |sample| peak = @max(peak, @abs(sample));

    try std.testing.expect(peak > 0.1 and peak < 1.01);

}

test "films seek to the sound frame holding the target and read the same through a small window" {

    const allocator = std.testing.allocator;
    const bytes = @embedFile("fixtures/system-long.mpg");
    var whole = Source.fixed(bytes);
    var movie = try Movie.open(allocator, &whole);

    defer movie.deinit(allocator);

    try std.testing.expectApproxEqAbs(6.36, movie.duration().?, 0.05);

    for ([_]f64{ 3.0, 1.234, 5.5, 0.6 }) |target| {

        const landed = try movie.seek(target);

        try std.testing.expectApproxEqAbs(target, landed, 1.0 / 32000.0);

        var sound: [512]f32 = undefined;

        try std.testing.expectEqual(512, try movie.read(&sound));

        const next = (try movie.picture()).?;

        try std.testing.expect(next.time >= target - 0.5 / 25.0 and next.time < target + 0.6);

    }

    var file = @import("source.zig").Chunked{

        .bytes = bytes,
        .piece = 333,

    };

    var buffer: [4096]u8 = undefined;
    var chunked = file.source(&buffer);
    var first = try Movie.open(allocator, &whole);
    var second = try Movie.open(allocator, &chunked);

    defer first.deinit(allocator);
    defer second.deinit(allocator);

    const expected = try allocator.alloc(f32, 7 * 32000);
    const actual = try allocator.alloc(f32, 7 * 32000);

    defer allocator.free(expected);
    defer allocator.free(actual);

    const played = try play(&first, expected);

    try std.testing.expect(played.rising and played.seen == 150 and played.heard == 167 * 1152);
    try std.testing.expectEqual(played, try play(&second, actual));
    try std.testing.expectEqualSlices(f32, expected[0..played.heard], actual[0..played.heard]);

}

test "damaged films never fail harder than an error" {

    const allocator = std.testing.allocator;
    const original = @embedFile("fixtures/video-gop.mpg");
    const damaged = try allocator.dupe(u8, original);
    const sound = try allocator.alloc(f32, 64 * 1152);

    defer allocator.free(damaged);
    defer allocator.free(sound);

    var prng = std.Random.DefaultPrng.init(5);

    for (0..150) |round| {

        @memcpy(damaged, original);

        for (0..1 + round % 16) |_| damaged[prng.random().uintLessThan(usize, damaged.len)] = prng.random().int(u8);

        var source = Source.fixed(damaged[0 .. damaged.len - prng.random().uintLessThan(usize, damaged.len / 3)]);
        var movie = Movie.open(allocator, &source) catch continue;

        defer movie.deinit(allocator);

        _ = play(&movie, sound) catch continue;

        _ = movie.seek(prng.random().float(f64) * 2) catch {

        };

    }

}
