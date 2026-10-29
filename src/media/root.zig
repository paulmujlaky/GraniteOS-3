//! Recordings and films decoded in Zig, read through a `Source`: WAV, FLAC, MPEG audio (MP3 and MP2), and MPEG-1 video.

const std = @import("std");

pub const source = @import("source.zig");
pub const Source = source.Source;
pub const Error = source.Error;
pub const Tags = @import("tags.zig").Tags;

pub const wav = @import("wav.zig");
pub const flac = @import("flac.zig");
pub const mp3 = @import("mp3.zig");
pub const icy = @import("icy.zig");
pub const video = @import("video.zig");
pub const system = @import("system.zig");
pub const Movie = @import("movie.zig").Movie;
pub const Picture = video.Picture;

pub const Kind = enum {

    wav,
    flac,
    mp3,
    mpeg,

    /// The kind a file's name says it holds, for listing files without reading them.
    pub fn named(name: []const u8) ?Kind {

        const extensions = [_]struct { []const u8, Kind }{

            .{ ".wav", .wav },
            .{ ".wave", .wav },
            .{ ".flac", .flac },
            .{ ".mp3", .mp3 },
            .{ ".mp2", .mp3 },
            .{ ".mp1", .mp3 },
            .{ ".mpa", .mp3 },
            .{ ".mpg", .mpeg },
            .{ ".mpeg", .mpeg },
            .{ ".m1v", .mpeg },

        };

        for (extensions) |entry| {

            if (std.ascii.endsWithIgnoreCase(name, entry[0])) return entry[1];

        }

        return null;

    }

    /// The kind a file's first bytes say it holds, trusting its name where they could be either, as an ID3 tag could start
    /// MP3 or FLAC.
    pub fn detect(head: []const u8, name: []const u8) ?Kind {

        if (head.len >= 12 and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "WAVE")) return .wav;
        if (std.mem.startsWith(u8, head, "fLaC")) return .flac;
        if (std.mem.startsWith(u8, head, "\x00\x00\x01\xba") or std.mem.startsWith(u8, head, "\x00\x00\x01\xb3")) return .mpeg;
        if (std.mem.startsWith(u8, head, "ID3")) return if (named(name) == .flac) .flac else .mp3;
        if (head.len >= 4 and mp3.Header.parse(std.mem.readInt(u32, head[0..4], .big)) != null) return .mp3;

        return named(name);

    }

    /// Whether files of the kind show pictures.
    pub fn moving(self: Kind) bool {

        return self == .mpeg;

    }

    /// What people call the format.
    pub fn title(self: Kind) []const u8 {

        return switch (self) {

            .wav => "WAV",
            .flac => "FLAC",
            .mp3 => "MPEG audio",
            .mpeg => "MPEG-1 video",

        };

    }

};

/// A file being decoded, whatever its kind.
pub const Track = union(Kind) {

    wav: wav.Decoder,
    flac: flac.Decoder,
    mp3: mp3.Decoder,
    mpeg: Movie,

    pub fn open(allocator: std.mem.Allocator, from: *Source, kind: Kind) Error!Track {

        return switch (kind) {

            inline else => |tag| @unionInit(Track, @tagName(tag), try @FieldType(Track, @tagName(tag)).open(allocator, from)),

        };

    }

    pub fn deinit(self: *Track, allocator: std.mem.Allocator) void {

        switch (self.*) {

            inline else => |*decoder| decoder.deinit(allocator),

        }

    }

    /// Frames of sound per second, and channels in each; a film without sound has none.
    pub fn rate(self: *const Track) u32 {

        return switch (self.*) {

            inline else => |*decoder| decoder.rate,

        };

    }

    pub fn channels(self: *const Track) u8 {

        return switch (self.*) {

            inline else => |*decoder| decoder.channels,

        };

    }

    pub fn tags(self: *const Track) *const Tags {

        return switch (self.*) {

            inline else => |*decoder| &decoder.tags,

        };

    }

    /// How many seconds it lasts, when the file says.
    pub fn duration(self: *const Track) ?f64 {

        return switch (self.*) {

            .mpeg => |*film| film.duration(),
            inline else => |*decoder| if (decoder.frames) |frames| @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(decoder.rate)) else null,

        };

    }

    /// Up to `out.len / channels` frames of interleaved samples at full scale ±1; zero at the end.
    pub fn read(self: *Track, out: []f32) Error!usize {

        return switch (self.*) {

            inline else => |*decoder| decoder.read(out),

        };

    }

    /// Moves as near `seconds` in as the format allows and returns where it landed.
    pub fn seek(self: *Track, seconds: f64) Error!f64 {

        const target = @max(seconds, 0);

        return switch (self.*) {

            .mpeg => |*film| film.seek(target),
            inline else => |*decoder| {

                const scale: f64 = @floatFromInt(decoder.rate);
                const landed = try decoder.seek(@intFromFloat(@min(target * scale, 1e15)));

                return @as(f64, @floatFromInt(landed)) / scale;

            },

        };

    }

    /// The film, for a track with pictures.
    pub fn movie(self: *Track) ?*Movie {

        return if (self.* == .mpeg) &self.mpeg else null;

    }

};

test "kinds come from names and first bytes" {

    try std.testing.expectEqual(.flac, Kind.named("/home/a/Song.FLAC"));
    try std.testing.expectEqual(.mpeg, Kind.named("clip.mpeg"));
    try std.testing.expectEqual(null, Kind.named("notes.txt"));
    try std.testing.expectEqual(.wav, Kind.detect("RIFF\x00\x00\x00\x00WAVEfmt ", "x.mp3"));
    try std.testing.expectEqual(.flac, Kind.detect("ID3\x04\x00\x00\x00\x00\x00\x10", "a.flac"));
    try std.testing.expectEqual(.mp3, Kind.detect("ID3\x04\x00\x00\x00\x00\x00\x10", "a.bin"));
    try std.testing.expectEqual(.mp3, Kind.detect("\xff\xfb\x90\x64", "a.bin"));
    try std.testing.expectEqual(.mpeg, Kind.detect("\x00\x00\x01\xba\x44", "a.bin"));
    try std.testing.expectEqual(.wav, Kind.detect("", "a.wav"));
    try std.testing.expect(Kind.mpeg.moving() and !Kind.mp3.moving());

}
