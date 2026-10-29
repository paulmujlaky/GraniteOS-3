//! Radio stations: a few to start with, the ones a directory search finds, and the favourites a person keeps.

const std = @import("std");

pub const Station = struct {

    name: []const u8,

    /// What plays and where, such as `Ambient · SomaFM`.
    detail: []const u8 = "",

    url: []const u8,

    /// Kbit/s, when known.
    bitrate: u32 = 0,

    /// The station as a favourites line: its name, address, and detail, between tabs.
    pub fn line(self: Station, out: []u8) ?[]const u8 {

        return std.fmt.bufPrint(out, "{s}\t{s}\t{s}", .{ self.name, self.url, self.detail }) catch null;

    }

    /// Reads a favourites line; the station's words point into `text`.
    pub fn parse(text: []const u8) ?Station {

        var fields = std.mem.splitScalar(u8, text, '\t');
        const name = fields.next() orelse return null;
        const url = fields.next() orelse return null;

        if (name.len == 0 or !playable(url)) return null;

        return .{

            .name = name,
            .url = url,
            .detail = fields.rest(),

        };

    }

    /// The station with its words copied into `allocator`'s memory, tabs and line breaks turned to spaces.
    pub fn copy(self: Station, allocator: std.mem.Allocator) std.mem.Allocator.Error!Station {

        return .{

            .name = try clean(allocator, self.name),
            .detail = try clean(allocator, self.detail),
            .url = try clean(allocator, self.url),
            .bitrate = self.bitrate,

        };

    }

};

/// Stations that play MP3 over plain HTTP, to listen to before searching.
pub const featured = [_]Station{

    .{ .name = "Groove Salad", .detail = "Ambient chill · SomaFM", .url = "http://ice1.somafm.com/groovesalad-128-mp3", .bitrate = 128 },
    .{ .name = "Drone Zone", .detail = "Atmospheric space · SomaFM", .url = "http://ice1.somafm.com/dronezone-128-mp3", .bitrate = 128 },
    .{ .name = "Secret Agent", .detail = "Downtempo lounge · SomaFM", .url = "http://ice1.somafm.com/secretagent-128-mp3", .bitrate = 128 },
    .{ .name = "Lush", .detail = "Vocal electronica · SomaFM", .url = "http://ice1.somafm.com/lush-128-mp3", .bitrate = 128 },
    .{ .name = "Indie Pop Rocks", .detail = "Indie · SomaFM", .url = "http://ice1.somafm.com/indiepop-128-mp3", .bitrate = 128 },
    .{ .name = "Radio Paradise", .detail = "Eclectic rock · DJ mixed", .url = "http://stream.radioparadise.com/mp3-128", .bitrate = 128 },
    .{ .name = "KEXP 90.3", .detail = "Where the music matters · Seattle", .url = "http://live-mp3-128.kexp.org/kexp128.mp3", .bitrate = 128 },
    .{ .name = "WFMU", .detail = "Freeform · New Jersey", .url = "http://stream0.wfmu.org/freeform-128k", .bitrate = 128 },
    .{ .name = "franceinfo", .detail = "News · France", .url = "http://icecast.radiofrance.fr/franceinfo-midfi.mp3", .bitrate = 128 },

};

/// The Radio Browser directory's search for MP3 stations by name, the most listened to first; the name goes at the end.
pub const directory = "http://all.api.radio-browser.info/json/stations/search?limit=40&hidebroken=true&codec=MP3&order=clickcount&reverse=true&name=";

/// Reads a directory reply into `out`, its words in `allocator`'s memory, leaving out stations with no address, ones sent
/// in HLS pieces, and repeats; returns how many it kept.
pub fn read(allocator: std.mem.Allocator, reply: []const u8, out: []Station) !usize {

    const found = try std.json.parseFromSliceLeaky([]const struct {

        name: []const u8 = "",
        url: []const u8 = "",
        url_resolved: []const u8 = "",
        tags: []const u8 = "",
        country: []const u8 = "",
        bitrate: u32 = 0,
        hls: u8 = 0,

    }, allocator, reply, .{

        .ignore_unknown_fields = true,

    });

    var count: usize = 0;

    for (found) |entry| {

        if (count == out.len) break;

        const url = if (entry.url_resolved.len != 0) entry.url_resolved else entry.url;
        const name = std.mem.trim(u8, entry.name, " \t\r\n");

        if (name.len == 0 or entry.hls != 0 or !playable(url) or listed(out[0..count], url)) continue;

        const tag = std.mem.trim(u8, entry.tags[0 .. std.mem.indexOfScalar(u8, entry.tags, ',') orelse entry.tags.len], " ");
        const country = std.mem.trim(u8, entry.country, " ");

        out[count] = try (Station{

            .name = name,
            .url = url,
            .bitrate = entry.bitrate,

            .detail = try describe(allocator, tag, country),

        }).copy(allocator);

        count += 1;

    }

    return count;

}

/// Whether `url` is an address Radio can open.
fn playable(url: []const u8) bool {

    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");

}

fn listed(stations: []const Station, url: []const u8) bool {

    for (stations) |station| {

        if (std.mem.eql(u8, station.url, url)) return true;

    }

    return false;

}

/// `Tag · Country`, or whichever of the two there is.
fn describe(allocator: std.mem.Allocator, tag: []const u8, country: []const u8) std.mem.Allocator.Error![]const u8 {

    if (tag.len == 0) return country;

    const result = if (country.len == 0) try allocator.dupe(u8, tag) else try std.fmt.allocPrint(allocator, "{s} \u{00b7} {s}", .{ tag, country });

    // Directory tags are all lower case.
    result[0] = std.ascii.toUpper(result[0]);

    return result;

}

fn clean(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {

    const result = try allocator.dupe(u8, text);

    for (result) |*byte| {

        if (byte.* == '\t' or byte.* == '\r' or byte.* == '\n') byte.* = ' ';

    }

    return result;

}

test "a directory reply gives playable stations once each, described by their first tag and country" {

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();

    const reply =
        \\[{"name":" Jazz \u00e9 Radio\t","url":"http://a/","url_resolved":"http://a/x.mp3","codec":"MP3","bitrate":128,"tags":"jazz,blues","country":"France","hls":0},
        \\{"name":"Second","url":"http://b/y.mp3","url_resolved":"","bitrate":64,"tags":"","country":"Spain"},
        \\{"name":"Again","url_resolved":"http://a/x.mp3"},
        \\{"name":"Pieces","url_resolved":"http://c/z.m3u8","hls":1},
        \\{"name":"Nowhere","url_resolved":"ftp://d/"},
        \\{"name":"","url_resolved":"http://e/"}]
    ;

    var out: [8]Station = undefined;
    const count = try read(arena.allocator(), reply, &out);

    try std.testing.expectEqual(2, count);
    try std.testing.expectEqualStrings("Jazz \u{e9} Radio", out[0].name);
    try std.testing.expectEqualStrings("http://a/x.mp3", out[0].url);
    try std.testing.expectEqualStrings("Jazz \u{00b7} France", out[0].detail);
    try std.testing.expectEqual(128, out[0].bitrate);
    try std.testing.expectEqualStrings("Spain", out[1].detail);
    try std.testing.expectEqualStrings("http://b/y.mp3", out[1].url);

    var few: [1]Station = undefined;

    try std.testing.expectEqual(1, try read(arena.allocator(), reply, &few));
    try std.testing.expectError(error.SyntaxError, read(arena.allocator(), "<html>", &few));

}

test "favourites lines keep a station's name, address, and detail" {

    var bytes: [256]u8 = undefined;
    const kept = featured[0].line(&bytes).?;
    const station = Station.parse(kept).?;

    try std.testing.expectEqualStrings(featured[0].name, station.name);
    try std.testing.expectEqualStrings(featured[0].url, station.url);
    try std.testing.expectEqualStrings(featured[0].detail, station.detail);
    try std.testing.expectEqual(null, Station.parse("Name only"));
    try std.testing.expectEqual(null, Station.parse("Name\tfile:///etc"));
    try std.testing.expectEqual(null, featured[0].line(bytes[0..8]));

    for (featured) |entry| try std.testing.expect(playable(entry.url));

}
