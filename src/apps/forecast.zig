//! Weather from Open-Meteo, shared by Weather and the quick settings' card: forecasts and place searches over HTTPS, what each
//! weather code looks like, readings in the unit each person chose, and the brief the card shows.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const metrics = api.metrics;
const HttpError = api.http.HttpError;

/// Weather's config: `unit=` `fahrenheit` or `celsius`, `shown=` the place on show, 0 for the current location and 1 on for
/// each `place=LATITUDE|LONGITUDE|NAME|DETAIL` in turn.
pub const config = "weather";

/// The config the card reads, which Weather writes after each forecast of the place shown.
pub const brief = "forecast";

/// Weather started with this before a home forecasts the place shown for the card, with no window, then quits.
pub const quiet = "quiet:";

pub const Unit = enum {

    fahrenheit,
    celsius,

    pub fn read(settings: *const api.Config) Unit {

        return if (std.mem.eql(u8, settings.get("unit") orelse "", "celsius")) .celsius else .fahrenheit;

    }

    /// Whole degrees in this unit.
    pub fn degrees(self: Unit, celsius: f32) i32 {

        return @intFromFloat(@round(if (self == .fahrenheit) celsius * 9 / 5 + 32 else celsius));

    }

    /// A temperature as shown, such as `72°`.
    pub fn temperature(self: Unit, out: []u8, celsius: f32) []const u8 {

        return std.fmt.bufPrint(out, "{d}\u{00b0}", .{self.degrees(celsius)}) catch "";

    }

    /// A wind speed as shown, such as `8 mph`.
    pub fn speed(self: Unit, out: []u8, kilometres: f32) []const u8 {

        if (self == .celsius) return std.fmt.bufPrint(out, "{d:.0} km/h", .{kilometres}) catch "";

        return std.fmt.bufPrint(out, "{d:.0} mph", .{kilometres / 1.609344}) catch "";

    }

    /// Rain or snow fallen, such as `0.12 in`.
    pub fn depth(self: Unit, out: []u8, millimetres: f32) []const u8 {

        if (self == .celsius) return std.fmt.bufPrint(out, "{d:.1} mm", .{millimetres}) catch "";

        return std.fmt.bufPrint(out, "{d:.2} in", .{millimetres / 25.4}) catch "";

    }

};

/// How a weather code reads and looks.
pub const Sky = struct {

    title: []const u8,
    icon: gui.Icon,

};

/// The WMO weather code `code` as people read it, by day or by night.
pub fn sky(code: u8, day: bool) Sky {

    const clear: gui.Icon = if (day) .sun else .moon;
    const broken: gui.Icon = if (day) .cloud_sun else .cloud_moon;

    return switch (code) {

        0 => .{ .title = "Clear", .icon = clear },
        1 => .{ .title = "Mostly clear", .icon = broken },
        2 => .{ .title = "Partly cloudy", .icon = broken },
        3 => .{ .title = "Overcast", .icon = .cloud },
        45, 48 => .{ .title = "Fog", .icon = .fog },
        51, 53, 55 => .{ .title = "Drizzle", .icon = .drizzle },
        56, 57 => .{ .title = "Freezing drizzle", .icon = .drizzle },
        61 => .{ .title = "Light rain", .icon = .rain },
        63 => .{ .title = "Rain", .icon = .rain },
        65 => .{ .title = "Heavy rain", .icon = .rain },
        66, 67 => .{ .title = "Freezing rain", .icon = .rain },
        71 => .{ .title = "Light snow", .icon = .snow },
        73 => .{ .title = "Snow", .icon = .snow },
        75 => .{ .title = "Heavy snow", .icon = .snow },
        77 => .{ .title = "Snow grains", .icon = .snow },
        80, 81, 82 => .{ .title = "Showers", .icon = .rain },
        85, 86 => .{ .title = "Snow showers", .icon = .snow },
        95 => .{ .title = "Thunderstorm", .icon = .storm },
        96, 99 => .{ .title = "Thunderstorm with hail", .icon = .storm },
        else => .{ .title = "Unsettled", .icon = .cloud },

    };

}

/// The compass point wind from `degrees` blows from.
pub fn compass(degrees: f32) []const u8 {

    const points = [_][]const u8{ "N", "NE", "E", "SE", "S", "SW", "W", "NW" };
    const turn = @mod(degrees + 22.5, 360);

    return points[@min(@as(usize, @intFromFloat(turn / 45)), points.len - 1)];

}

pub const Now = struct {

    temperature: f32 = 0,
    feels: f32 = 0,
    humidity: f32 = 0,
    wind: f32 = 0,
    direction: f32 = 0,
    pressure: f32 = 0,
    code: u8 = 0,
    day: bool = true,

};

pub const Hour = struct {

    /// UTC seconds.
    time: i64 = 0,
    temperature: f32 = 0,

    /// Percent chance of rain or snow.
    chance: f32 = 0,
    code: u8 = 0,
    day: bool = true,

};

pub const Day = struct {

    /// UTC seconds at the place's midnight.
    time: i64 = 0,
    high: f32 = 0,
    low: f32 = 0,
    code: u8 = 0,

    /// Rain or snow in millimetres, and its percent chance.
    rain: f32 = 0,
    chance: f32 = 0,
    wind: f32 = 0,
    uv: f32 = 0,
    sunrise: i64 = 0,
    sunset: i64 = 0,

};

/// Celsius, km/h, and hPa; the hours run from the place's midnight today, a week of them.
pub const Forecast = struct {

    /// Seconds the place's clocks run ahead of UTC.
    offset: i64 = 0,
    now: Now = .{},

    hours: [7 * 24]Hour = undefined,
    hour_count: usize = 0,

    days: [7]Day = undefined,
    day_count: usize = 0,

    /// The place's own time at UTC `time`, for `api.Date`.
    pub fn local(self: *const Forecast, time: i64) u64 {

        return @intCast(@max(time + self.offset, 0));

    }

};

const Reply = struct {

    utc_offset_seconds: i64 = 0,

    current: struct {

        temperature_2m: ?f32 = null,
        apparent_temperature: ?f32 = null,
        relative_humidity_2m: ?f32 = null,
        is_day: ?f32 = null,
        weather_code: ?f32 = null,
        wind_speed_10m: ?f32 = null,
        wind_direction_10m: ?f32 = null,
        surface_pressure: ?f32 = null,

    },
    hourly: struct {

        time: []const i64,
        temperature_2m: []const ?f32,
        precipitation_probability: []const ?f32,
        weather_code: []const ?f32,
        is_day: []const ?f32,

    },
    daily: struct {

        time: []const i64,
        weather_code: []const ?f32,
        temperature_2m_max: []const ?f32,
        temperature_2m_min: []const ?f32,
        sunrise: []const i64,
        sunset: []const i64,
        precipitation_sum: []const ?f32,
        precipitation_probability_max: []const ?f32,
        wind_speed_10m_max: []const ?f32,
        uv_index_max: []const ?f32,

    },

};

/// The week's forecast at a place.
pub fn fetch(latitude: f64, longitude: f64) HttpError!Forecast {

    var arena = std.heap.ArenaAllocator.init(api.pages);

    defer arena.deinit();

    var url: [640]u8 = undefined;

    const address = std.fmt.bufPrint(&url, "https://api.open-meteo.com/v1/forecast?latitude={d:.4}&longitude={d:.4}" ++
        "&current=temperature_2m,apparent_temperature,relative_humidity_2m,is_day,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure" ++
        "&hourly=temperature_2m,precipitation_probability,weather_code,is_day" ++
        "&daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,uv_index_max" ++
        "&timezone=auto&timeformat=unixtime&forecast_days=7", .{ latitude, longitude }) catch return error.Malformed;

    const reply = std.json.parseFromSliceLeaky(Reply, arena.allocator(), try download(arena.allocator(), address), .{

        .ignore_unknown_fields = true,

    }) catch return error.Malformed;

    const current = reply.current;
    const hourly = reply.hourly;
    const daily = reply.daily;

    var result = Forecast{

        .offset = reply.utc_offset_seconds,
        .now = .{

            .temperature = current.temperature_2m orelse 0,
            .feels = current.apparent_temperature orelse 0,
            .humidity = current.relative_humidity_2m orelse 0,
            .wind = current.wind_speed_10m orelse 0,
            .direction = current.wind_direction_10m orelse 0,
            .pressure = current.surface_pressure orelse 0,
            .code = kind(current.weather_code orelse 0),
            .day = (current.is_day orelse 1) != 0,

        },

    };

    result.hour_count = @min(hourly.time.len, result.hours.len);

    for (result.hours[0..result.hour_count], 0..) |*hour, index| hour.* = .{

        .time = hourly.time[index],
        .temperature = at(hourly.temperature_2m, index),
        .chance = at(hourly.precipitation_probability, index),
        .code = kind(at(hourly.weather_code, index)),
        .day = at(hourly.is_day, index) != 0,

    };

    result.day_count = @min(daily.time.len, result.days.len);

    for (result.days[0..result.day_count], 0..) |*day, index| day.* = .{

        .time = daily.time[index],
        .high = at(daily.temperature_2m_max, index),
        .low = at(daily.temperature_2m_min, index),
        .code = kind(at(daily.weather_code, index)),
        .rain = at(daily.precipitation_sum, index),
        .chance = at(daily.precipitation_probability_max, index),
        .wind = at(daily.wind_speed_10m_max, index),
        .uv = at(daily.uv_index_max, index),
        .sunrise = if (index < daily.sunrise.len) daily.sunrise[index] else 0,
        .sunset = if (index < daily.sunset.len) daily.sunset[index] else 0,

    };

    return result;

}

/// A place a search found, its names padded as a `metrics.Place`'s are.
pub const Found = struct {

    latitude: f64 = 0,
    longitude: f64 = 0,
    name: [48]u8 = @splat(0),

    /// Its region and country, such as `Illinois, United States`.
    detail: [96]u8 = @splat(0),

};

/// Fills `out` with places named like `query`, best first; returns how many.
pub fn search(query: []const u8, out: []Found) HttpError!usize {

    var arena = std.heap.ArenaAllocator.init(api.pages);

    defer arena.deinit();

    var url: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&url);

    writer.writeAll("https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&format=json&name=") catch return error.Malformed;
    api.http.escape(&writer, query) catch return error.Malformed;

    const reply = std.json.parseFromSliceLeaky(struct {

        results: []const struct {

            name: []const u8,
            latitude: f64,
            longitude: f64,
            admin1: []const u8 = "",
            country: []const u8 = "",

        } = &.{},

    }, arena.allocator(), try download(arena.allocator(), writer.buffered()), .{

        .ignore_unknown_fields = true,

    }) catch return error.Malformed;

    const count = @min(reply.results.len, out.len);

    for (reply.results[0..count], out[0..count]) |result, *found| {

        var detail: [96]u8 = undefined;
        const joined = if (result.admin1.len == 0) result.country else std.fmt.bufPrint(&detail, "{s}, {s}", .{ result.admin1, result.country }) catch result.country;

        found.* = .{

            .latitude = result.latitude,
            .longitude = result.longitude,

        };

        metrics.fill(&found.name, result.name);
        metrics.fill(&found.detail, joined);

    }

    return count;

}

fn download(allocator: std.mem.Allocator, url: []const u8) HttpError![]const u8 {

    var body = std.Io.Writer.Allocating.init(allocator);

    if (try api.http.get(api.pages, url, &body.writer) != 200) return error.Malformed;

    return body.written();

}

fn at(values: []const ?f32, index: usize) f32 {

    return if (index < values.len) values[index] orelse 0 else 0;

}

fn kind(value: f32) u8 {

    return @intFromFloat(std.math.clamp(value, 0, 255));

}

/// What the card shows, from Weather's last forecast of the place it showed.
pub const Brief = struct {

    place: [48]u8 = @splat(0),
    temperature: f32 = 0,
    code: u8 = 0,
    day: bool = true,

    /// When it was fetched, in `api.clock` seconds.
    updated: u64 = 0,

    pub fn of(name: []const u8, forecast: *const Forecast) Brief {

        var result = Brief{

            .temperature = forecast.now.temperature,
            .code = forecast.now.code,
            .day = forecast.now.day,
            .updated = api.clock(),

        };

        metrics.fill(&result.place, name);

        return result;

    }

    /// The brief kept for user `owner`, if Weather has written one.
    pub fn load(owner: []const u8) ?Brief {

        store.open(owner, brief);

        var result = Brief{

            .temperature = tenths(store.number(i32, "temperature") orelse return null),
            .code = store.number(u8, "code") orelse 0,
            .day = (store.number(u8, "day") orelse 1) != 0,
            .updated = store.number(u64, "updated") orelse 0,

        };

        metrics.fill(&result.place, store.get("place") orelse "");

        return result;

    }

    pub fn save(self: *const Brief, owner: []const u8) void {

        store.open(owner, brief);
        _ = store.set("place", metrics.text(&self.place));
        _ = store.set("temperature", @as(i32, @intFromFloat(@round(self.temperature * 10))));
        _ = store.set("code", self.code);
        _ = store.set("day", @intFromBool(self.day));
        _ = store.set("updated", self.updated);

        store.save() catch {

        };

    }

};

var store = api.Config{};

fn tenths(value: i32) f32 {

    return @as(f32, @floatFromInt(value)) / 10;

}
