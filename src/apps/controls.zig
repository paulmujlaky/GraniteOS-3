//! The panel under the bar's date and time: the date beside the weather where Weather last looked, over a month calendar to
//! page through.

const std = @import("std");

const days = @import("days.zig");
const desktop = @import("desktop.zig");
const forecast = @import("forecast.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const time = api.time;
const Day = days.Day;

const width = 320;

/// A day of the month: its number over a holiday's dot.
const day_style = gui.Style{

    .grow = 1,
    .height = 32,
    .direction = .stack,

    .radius = 16,

};

// The date.
var date_bytes: [48]u8 = undefined;

var date = gui.label("", .{

    .grow = 1,
    .padding = .axes(0, 6),

});

// The weather, which opens Weather.
var degrees_bytes: [16]u8 = undefined;

var sky_icon = gui.icon(.sun, theme.icon.with(.{

    .width = 20,
    .size = 18,

}));

var degrees = gui.label("", .{});

var weather_parts = [_]*gui.Node{ &sky_icon, &degrees };

var weather = gui.box(.{

    .height = 32,
    .padding = .axes(0, 8),
    .direction = .row,
    .gap = 6,
    .items = .center,

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },

}, &weather_parts);

var day_parts = [_]*gui.Node{ &date, &weather };

var day_row = gui.box(.{

    .direction = .row,
    .items = .center,

}, &day_parts);

/// Whose brief the weather shows, empty while no one is signed in, and the unit they read it in.
var owner: []const u8 = "";
var brief: ?forecast.Brief = null;
var unit = forecast.Unit.fahrenheit;
var settings = api.Config{};

/// When Weather was last started to refresh the brief, in `api.clock` seconds.
var asked: u64 = 0;

// The calendar.
var month_bytes: [24]u8 = undefined;

var month = gui.label("", .{

    .grow = 1,
    .padding = .axes(0, 6),

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },

});

var back = gui.tool(.left, &earlier);
var forward = gui.tool(.right, &later);
var month_parts = [_]*gui.Node{ &month, &back, &forward };

var month_row = gui.box(.{

    .direction = .row,
    .gap = 2,
    .items = .center,

}, &month_parts);

var heads: [7]gui.Node = undefined;
var head_list: [7]*gui.Node = undefined;

var head_row = gui.box(.{

    .direction = .row,
    .gap = 2,

}, &head_list);

var marks: [42]gui.Node = undefined;
var mark_rows: [42]gui.Node = undefined;
var mark_parts: [42][1]*gui.Node = undefined;
var numbers: [42]gui.Node = undefined;
var dots: [42]gui.Node = undefined;
var dot_rows: [42]gui.Node = undefined;
var dot_parts: [42][1]*gui.Node = undefined;
var cell_parts: [42][3]*gui.Node = undefined;
var cells: [42]gui.Node = undefined;
var week_parts: [6][7]*gui.Node = undefined;
var weeks: [6]gui.Node = undefined;
var week_list: [6]*gui.Node = undefined;

var grid = gui.box(.{

    .gap = 2,

}, &week_list);

var calendar_parts = [_]*gui.Node{ &month_row, &head_row, &grid };

var calendar = gui.box(.{

    .gap = 6,

}, &calendar_parts);

var root_parts = [_]*gui.Node{ &day_row, &calendar };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &root_parts);

pub var window: gui.Window = undefined;

/// The month the calendar shows, by its first day, and today.
var page = Day{ .year = 1970, .month = 1, .day = 1 };
var now = Day{ .year = 1970, .month = 1, .day = 1 };

/// Where the panel's top left corner goes.
var corner = gui.Point{};

/// When an open panel next reads the time again.
var due: u64 = 0;

pub fn init() void {

    month.action = &current;
    weather.action = &look;

    for (&heads, 0..) |*head, index| {

        head.* = gui.label(time.days[(index + 1) % 7][0..2], theme.caption.with(.{

            .grow = 1,
            .color = theme.faint,
            .text_align = .center,

        }));

        head_list[index] = head;

    }

    for (&weeks, 0..) |*week, line| {

        for (0..7) |column| {

            const index = line * 7 + column;

            // Today's circle, centred under the number, as the cell is wider than it is tall.
            marks[index] = gui.box(.{

                .width = 30,
                .height = 30,

                .radius = 15,

            }, &.{});

            mark_parts[index] = .{&marks[index]};

            mark_rows[index] = gui.box(.{

                .direction = .row,
                .justify = .center,
                .items = .center,

            }, &mark_parts[index]);

            numbers[index] = gui.label("", .{

                .size = theme.small,
                .text_align = .center,

            });

            dots[index] = gui.box(.{

                .width = 3,
                .height = 3,

                .radius = 2,

            }, &.{});

            dot_parts[index] = .{&dots[index]};

            dot_rows[index] = gui.box(.{

                .padding = .{

                    .bottom = 4,

                },
                .justify = .end,
                .items = .center,

            }, &dot_parts[index]);

            cell_parts[index] = .{ &mark_rows[index], &numbers[index], &dot_rows[index] };
            cells[index] = gui.box(day_style, &cell_parts[index]);
            week_parts[line][column] = &cells[index];

        }

        week.* = gui.box(.{

            .direction = .row,
            .gap = 2,

        }, &week_parts[line]);

        week_list[line] = week;

    }

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .width = width,
        .height = 100,

        .hidden = true,
        .motion = .drop,
        .shadow = true,

    }) catch api.exit(3);

}

/// Opens the panel on this month, with its top left corner at `at`.
pub fn show(at: gui.Point) void {

    corner = at;
    now = Day.today();
    page = first(now);
    renew(10 * 60, 60);
    refresh();
    window.show();

}

/// Reads the brief and unit of user `name` again, as after Weather changed them; an empty name clears the weather.
pub fn load(name: []const u8) void {

    owner = name;
    brief = if (name.len == 0) null else forecast.Brief.load(name);
    settings.open(name, forecast.config);
    unit = forecast.Unit.read(&settings);
    if (shown()) refresh();

}

pub fn hide() void {

    if (shown()) window.hide();

}

pub fn shown() bool {

    return !window.surface.hidden;

}

/// Keeps an open panel's time current, every second, and the brief fresh; call it every pass of the event loop.
pub fn tick() void {

    renew(30 * 60, 10 * 60);
    if (shown() and api.ticks() >= due) refresh();

}

/// Starts Weather without a window to refresh the brief once it is `age` seconds old, at most once every `gap` seconds.
fn renew(age: u64, gap: u64) void {

    const moment = api.clock();

    if (owner.len == 0 or moment < asked + gap) return;
    if (brief) |known| if (moment < known.updated + age) return;

    asked = moment;

    const state = api.net.status() catch return;
    if (!state.online()) return;

    var argument: [80]u8 = undefined;

    _ = api.launch(@tagName(api.abi.Image.weather), std.fmt.bufPrint(&argument, "{s}{s}", .{ forecast.quiet, desktop.home }) catch return) catch {

    };

}

/// Reads the time again, lays the month out, and fits the panel to it.
fn refresh() void {

    const today = api.Date.init(api.clock());

    due = api.ticks() + 100;
    date.content.label = today.long(&date_bytes, false);

    // Past midnight, an open panel still on the old month moves to the new one.
    if (!now.same(Day.today())) {

        if (page.same(first(now))) page = first(Day.today());
        now = Day.today();

    }

    fill();
    weather.hidden = brief == null;

    if (brief) |*known| {

        const seen = forecast.sky(known.code, known.day);

        sky_icon.content.label = seen.icon.text();
        degrees.content.label = unit.temperature(&degrees_bytes, known.temperature);

    }

    const size = root.measure();

    window.move(.{

        .x = corner.x,
        .y = corner.y,
        .width = gui.px(width),
        .height = size.height,

    });

    window.refresh();

}

/// Lays out the month shown: Monday first, days of the months around it faint, today filled, holidays dotted.
fn fill() void {

    const lead = page.weekday();
    const lines = (lead + time.length(page.year, page.month) + 6) / 7;

    month.content.label = std.fmt.bufPrint(&month_bytes, "{s} {d}", .{ time.months[page.month - 1], page.year }) catch "";

    for (0..cells.len) |index| {

        const day = page.add(@as(i32, @intCast(index)) - lead);
        const inside = day.month == page.month;
        const today = day.same(now);

        numbers[index].content.label = days.numerals[day.day];
        numbers[index].style.color = if (today) theme.background else if (!inside) theme.faint else if (index % 7 >= 5) theme.muted else theme.text;
        marks[index].style.background = if (today) theme.accent else null;
        dots[index].hidden = today or days.holiday(day) == null;
        dots[index].style.background = if (inside) theme.accent else theme.faint;

    }

    for (&weeks, 0..) |*week, line| week.hidden = line >= lines;

}

fn first(day: Day) Day {

    return .{

        .year = day.year,
        .month = day.month,
        .day = 1,

    };

}

fn earlier(_: *gui.Node) void {

    page = page.shift(-1);
    refresh();

}

fn later(_: *gui.Node) void {

    page = page.shift(1);
    refresh();

}

/// Back to this month, from the month's title.
fn current(_: *gui.Node) void {

    page = first(now);
    refresh();

}

/// Brings Weather forward, starting it when it is not open.
fn look(_: *gui.Node) void {

    desktop.dismiss();

    for (desktop.listed[0..desktop.count]) |*listed| {

        if (listed.application != @intFromEnum(api.abi.Image.weather)) continue;

        gui.display.activate(listed.id, .raise) catch {

        };

        return;

    }

    desktop.start_app(.weather, desktop.home);

}
