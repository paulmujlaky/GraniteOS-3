//! Metrics: roughly where this computer is, worked out from its public address once the network is up, for apps granted
//! `network` such as Weather; kept in `/cfgs/system/metrics.config` across restarts and looked up again every few hours.

const std = @import("std");

const api = @import("api");

const metrics = api.metrics;
const protocol = api.protocol;
const Place = metrics.Place;
pub const panic = api.panic;

/// Where the public address is looked up, asked in turn until one answers.
const sources = [_]Source{

    .{ .url = "https://ipinfo.io/json", .read = readInfo },
    .{ .url = "https://ipapi.co/json/", .read = readApi },

};

const Source = struct {

    url: []const u8,
    read: *const fn (std.mem.Allocator, []const u8, *Place) anyerror!void,

};

/// Ticks between lookups once one worked, between tries while none has, and the longest one lookup may take.
const fresh = 6 * 60 * 60 * 100;
const retry = 60 * 100;
const longest = 20 * 100;

var place = Place{};
var known = false;

/// Every source has been tried at least once since the network came up, so an unknown place stays unknown for now.
var tried = false;
var finding = false;
var due: u64 = 0;
var deadline: u64 = 0;

var configuration = api.Config{};

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.network) or api.permits(.ports)) api.exit(2);

    load();
    api.net.idle = &idle;

    while (true) {

        const request = api.within(100) catch {

            maintain();
            continue;

        };

        answer(request);

    }

}

fn answer(request: api.Request) void {

    const result: u64 = switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .locate => locate(request),
        else => protocol.invalid,

    };

    api.answer(request, result);

}

fn locate(request: api.Request) u64 {

    if (!known) return if (finding or !tried) protocol.busy else protocol.missing;
    if (request.fourth < @sizeOf(Place)) return protocol.invalid;

    api.store(request, 0, std.mem.asBytes(&place)) catch return protocol.invalid;

    return 0;

}

/// Looks the place up once it is due and the network is up.
fn maintain() void {

    if (api.ticks() < due) return;

    due = api.ticks() + retry;

    const state = api.net.status() catch return;
    if (!state.online()) return;

    finding = true;
    defer finding = false;

    for (sources) |source| {

        if (!lookup(source)) continue;

        known = true;
        due = api.ticks() + fresh;
        save();

        return;

    }

    tried = true;

}

fn lookup(source: Source) bool {

    var arena = std.heap.ArenaAllocator.init(api.pages);

    defer arena.deinit();

    var body = std.Io.Writer.Allocating.init(arena.allocator());

    deadline = api.ticks() + longest;

    const code = api.http.get(api.pages, source.url, &body.writer) catch return false;
    if (code != 200) return false;

    var found = Place{};

    source.read(arena.allocator(), body.written(), &found) catch return false;
    place = found;

    return true;

}

/// Answers whoever asks while a lookup waits on the network, and gives up on one taking too long.
fn idle() api.net.NetError!void {

    while (api.receive(false)) |request| answer(request) else |_| {

    }

    if (api.ticks() >= deadline) return error.Timeout;

}

/// ipinfo.io: `loc` holds the coordinates as `LATITUDE,LONGITUDE`, and `country` a two-letter code.
fn readInfo(allocator: std.mem.Allocator, bytes: []const u8, out: *Place) anyerror!void {

    const found = try std.json.parseFromSliceLeaky(struct {

        city: []const u8 = "",
        region: []const u8 = "",
        country: []const u8 = "",
        loc: []const u8,
        timezone: []const u8 = "",

    }, allocator, bytes, .{ .ignore_unknown_fields = true });

    const comma = std.mem.indexOfScalar(u8, found.loc, ',') orelse return error.Malformed;

    out.latitude = try std.fmt.parseFloat(f64, found.loc[0..comma]);
    out.longitude = try std.fmt.parseFloat(f64, found.loc[comma + 1 ..]);
    name(out, found.city, found.region, found.country, found.timezone);

}

/// ipapi.co: the coordinates as numbers and the country by name.
fn readApi(allocator: std.mem.Allocator, bytes: []const u8, out: *Place) anyerror!void {

    const found = try std.json.parseFromSliceLeaky(struct {

        city: []const u8 = "",
        region: []const u8 = "",
        country_name: []const u8 = "",
        latitude: f64,
        longitude: f64,
        timezone: []const u8 = "",

    }, allocator, bytes, .{ .ignore_unknown_fields = true });

    out.latitude = found.latitude;
    out.longitude = found.longitude;
    name(out, found.city, found.region, found.country_name, found.timezone);

}

fn name(out: *Place, city: []const u8, region: []const u8, country: []const u8, zone: []const u8) void {

    metrics.fill(&out.city, city);
    metrics.fill(&out.region, region);
    metrics.fill(&out.country, country);
    metrics.fill(&out.zone, zone);

}

fn load() void {

    configuration.open(api.config.system, "metrics");

    place = .{

        .latitude = std.fmt.parseFloat(f64, configuration.get("latitude") orelse return) catch return,
        .longitude = std.fmt.parseFloat(f64, configuration.get("longitude") orelse return) catch return,

    };

    name(&place, configuration.get("city") orelse "", configuration.get("region") orelse "", configuration.get("country") orelse "", configuration.get("zone") orelse "");
    known = true;

}

fn save() void {

    var bytes: [2][32]u8 = undefined;

    configuration.open(api.config.system, "metrics");
    _ = configuration.set("latitude", std.fmt.bufPrint(&bytes[0], "{d:.4}", .{place.latitude}) catch return);
    _ = configuration.set("longitude", std.fmt.bufPrint(&bytes[1], "{d:.4}", .{place.longitude}) catch return);
    _ = configuration.set("city", metrics.text(&place.city));
    _ = configuration.set("region", metrics.text(&place.region));
    _ = configuration.set("country", metrics.text(&place.country));
    _ = configuration.set("zone", metrics.text(&place.zone));

    configuration.save() catch {

        api.log("metrics: the place was not saved\n");

    };

}
