//! Shoutcast and Icecast radio: the titles a station sends between runs of its sound, taken out and read.

const std = @import("std");

/// The most of a title kept; longer ones are cut at a whole character.
pub const longest = 256;

/// Takes the metadata out of a station's stream, keeping the latest title.
pub const Demuxer = struct {

    /// Sound bytes between metadata blocks, from the station's `icy-metaint` header; zero when it sends none.
    interval: usize,

    /// Sound bytes left before the next block's length byte.
    until: usize,
    state: enum { sound, length, block } = .sound,

    /// The block being read: how long it is, and what of it has come.
    block: [255 * 16]u8 = undefined,
    want: usize = 0,
    got: usize = 0,

    /// The latest title, and a count that rises each time it changes.
    bytes: [longest]u8 = undefined,
    length: usize = 0,
    changes: u32 = 0,

    pub fn init(interval: usize) Demuxer {

        return .{

            .interval = interval,
            .until = interval,

        };

    }

    /// Takes the metadata out of `bytes` in place, returning the sound left at their start.
    pub fn strip(self: *Demuxer, bytes: []u8) []u8 {

        if (self.interval == 0) return bytes;

        var read: usize = 0;
        var kept: usize = 0;

        while (read < bytes.len) {

            switch (self.state) {

                .sound => {

                    const count = @min(self.until, bytes.len - read);

                    std.mem.copyForwards(u8, bytes[kept..][0..count], bytes[read..][0..count]);
                    read += count;
                    kept += count;
                    self.until -= count;

                    if (self.until == 0) self.state = .length;

                },
                .length => {

                    self.want = @as(usize, bytes[read]) * 16;
                    self.got = 0;
                    read += 1;
                    self.state = if (self.want == 0) .sound else .block;
                    self.until = self.interval;

                },
                .block => {

                    const count = @min(self.want - self.got, bytes.len - read);

                    @memcpy(self.block[self.got..][0..count], bytes[read..][0..count]);
                    read += count;
                    self.got += count;

                    if (self.got == self.want) {

                        self.note(self.block[0..self.got]);
                        self.state = .sound;

                    }

                },

            }

        }

        return bytes[0..kept];

    }

    pub fn title(self: *const Demuxer) []const u8 {

        return self.bytes[0..self.length];

    }

    /// Keeps the `StreamTitle` a block gives, as UTF-8 even when the station sent Latin-1.
    fn note(self: *Demuxer, block: []const u8) void {

        const key = "StreamTitle='";
        const start = (std.mem.indexOf(u8, block, key) orelse return) + key.len;

        // Titles may hold apostrophes, so only a quote before a semicolon ends one.
        const stop = std.mem.indexOfPos(u8, block, start, "';") orelse std.mem.lastIndexOfScalar(u8, block, '\'') orelse block.len;
        const text = std.mem.trim(u8, block[start..@max(stop, start)], " \x00");

        var fresh: [longest]u8 = undefined;
        const length = if (std.unicode.utf8ValidateSlice(text)) whole(&fresh, text) else latin(&fresh, text);

        if (std.mem.eql(u8, fresh[0..length], self.title())) return;

        @memcpy(self.bytes[0..length], fresh[0..length]);
        self.length = length;
        self.changes +%= 1;

    }

};

/// Copies as much of UTF-8 `text` as fits without splitting a character; returns how much.
fn whole(out: []u8, text: []const u8) usize {

    var length = @min(text.len, out.len);

    while (length < text.len and length > 0 and text[length] & 0xc0 == 0x80) length -= 1;

    @memcpy(out[0..length], text[0..length]);

    return length;

}

/// Writes Latin-1 `text` as UTF-8, as much as fits; returns how much.
fn latin(out: []u8, text: []const u8) usize {

    var length: usize = 0;

    for (text) |byte| {

        const size: usize = if (byte < 0x80) 1 else 2;

        if (length + size > out.len) break;

        _ = std.unicode.utf8Encode(byte, out[length..][0..size]) catch unreachable;
        length += size;

    }

    return length;

}

/// A title as stations write it, `Artist - Song`, in its parts; a title without the dash is all song.
pub const Song = struct {

    artist: []const u8,
    name: []const u8,

    pub fn of(title: []const u8) Song {

        const trimmed = std.mem.trim(u8, title, " ");
        const dash = std.mem.indexOf(u8, trimmed, " - ") orelse return .{

            .artist = "",
            .name = trimmed,

        };

        return .{

            .artist = std.mem.trim(u8, trimmed[0..dash], " "),
            .name = std.mem.trim(u8, trimmed[dash + 3 ..], " "),

        };

    }

};

/// What a station's `Content-Type` says it sends.
pub const Format = enum {

    mpeg,
    aac,
    ogg,
    other,

    pub fn of(content: []const u8) Format {

        const pairs = [_]struct { []const u8, Format }{

            .{ "mpeg", .mpeg },
            .{ "mp3", .mpeg },
            .{ "aac", .aac },
            .{ "mp4", .aac },
            .{ "ogg", .ogg },
            .{ "opus", .ogg },

        };

        for (pairs) |pair| {

            if (std.ascii.indexOfIgnoreCase(content, pair[0]) != null) return pair[1];

        }

        return .other;

    }

};

/// A stream of `sound` with `title` blocks after every `interval` bytes, as a station would send it.
fn interleave(out: []u8, sound: []const u8, interval: usize, titles: []const []const u8) []u8 {

    var length: usize = 0;
    var read: usize = 0;
    var index: usize = 0;

    while (read < sound.len) {

        const count = @min(interval, sound.len - read);

        @memcpy(out[length..][0..count], sound[read..][0..count]);
        length += count;
        read += count;

        if (count < interval) break;

        const text = if (index < titles.len) titles[index] else "";
        const blocks = std.math.divCeil(usize, text.len, 16) catch unreachable;

        index += 1;
        out[length] = @intCast(blocks);
        @memset(out[length + 1 ..][0 .. blocks * 16], 0);
        @memcpy(out[length + 1 ..][0..text.len], text);
        length += 1 + blocks * 16;

    }

    return out[0..length];

}

test "metadata comes out of the sound however the stream is split, and titles change only when they differ" {

    var sound: [1000]u8 = undefined;

    for (&sound, 0..) |*byte, index| byte.* = @truncate(index * 31);

    const titles = [_][]const u8{ "StreamTitle='Artist - First';", "StreamTitle='Artist - First';", "", "StreamTitle='Guns N' Roses - Patience';StreamUrl='';" };
    var stream: [2000]u8 = undefined;
    const sent = interleave(&stream, &sound, 100, &titles);

    for ([_]usize{ 1, 7, 64, 101, 2000 }) |piece| {

        var demuxer = Demuxer.init(100);
        var copy: [2000]u8 = undefined;
        var heard: [1000]u8 = undefined;
        var count: usize = 0;
        var at: usize = 0;
        var seen: u32 = 0;

        @memcpy(copy[0..sent.len], sent);

        while (at < sent.len) {

            const part = copy[at..@min(at + piece, sent.len)];
            const kept = demuxer.strip(part);

            @memcpy(heard[count..][0..kept.len], kept);
            count += kept.len;
            at += part.len;

            if (demuxer.changes != seen) {

                seen = demuxer.changes;
                if (seen == 1) try std.testing.expectEqualStrings("Artist - First", demuxer.title());

            }

        }

        try std.testing.expectEqualSlices(u8, &sound, heard[0..count]);
        try std.testing.expectEqualStrings("Guns N' Roses - Patience", demuxer.title());
        try std.testing.expectEqual(2, demuxer.changes);

    }

}

test "a stream without metadata passes through, and Latin-1 titles become UTF-8" {

    var demuxer = Demuxer.init(0);
    var bytes = "\xff\xfb\x90\x64".*;

    try std.testing.expectEqualSlices(u8, "\xff\xfb\x90\x64", demuxer.strip(&bytes));

    var latin_block = Demuxer.init(4);
    var stream: [64]u8 = undefined;
    const sent = interleave(&stream, "abcdefgh", 4, &.{"StreamTitle='Caf\xe9';"});

    _ = latin_block.strip(sent);
    try std.testing.expectEqualStrings("Caf\u{e9}", latin_block.title());

}

test "titles split into artist and song, and content types name the format" {

    const both = Song.of(" Daft Punk - One More Time ");

    try std.testing.expectEqualStrings("Daft Punk", both.artist);
    try std.testing.expectEqualStrings("One More Time", both.name);
    try std.testing.expectEqualStrings("News at noon", Song.of("News at noon").name);
    try std.testing.expectEqualStrings("", Song.of("News at noon").artist);

    try std.testing.expectEqual(.mpeg, Format.of("audio/mpeg"));
    try std.testing.expectEqual(.aac, Format.of("audio/aacp"));
    try std.testing.expectEqual(.ogg, Format.of("application/ogg"));
    try std.testing.expectEqual(.other, Format.of(""));

}
