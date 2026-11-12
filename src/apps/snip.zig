//! Snips: the screen frozen under a dimmed overlay, where dragging takes an area and clicking takes a window, saved as PNG
//! pictures in `~/Screenshots`; Super+Shift+S starts one, Super+S takes the whole screen, and the Screenshots app asks for them too.

const std = @import("std");

const catalog = @import("catalog.zig");
const notices = @import("notices.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;

/// Ticks a window tucked away for a snip takes to leave the screen.
const settle = 30;

/// How far the pointer moves with the button down before a click becomes a drag.
const slack = 4;

const dimmed = gui.shade(0x000000, 120);

var overlay = gui.custom(&paint, .{});

pub var window: gui.Window = undefined;

/// The screen as the snip began, and how it picks.
var frozen: ?gui.Image = null;
var kind: api.Snip = .region;

/// The windows on the screen as the snip began, bottom to top.
var listed: [64]api.display.Window = undefined;
var count: usize = 0;

/// Where a drag began, and where the pointer is.
var anchor: ?gui.Point = null;
var pointer = gui.Point{};

/// An app waiting for its snip, the window it tucked away meanwhile, and the tick a delayed snip starts at.
var asker: ?api.Request = null;
var hidden: ?u32 = null;
var due: ?u64 = null;

var home_bytes: [48]u8 = undefined;
var home: []const u8 = "";
var saved_bytes: [128]u8 = undefined;
var files = api.Files{};

pub fn init() void {

    overlay.cursor = .crosshair;
    overlay.track = &drag;

    window = gui.Window.open(&overlay, .{

        .layer = .overlay,
        .hidden = true,

    }) catch api.exit(3);

}

/// Starts a snip `how` says for the signed-in user whose home is `owner`, unless one is under way.
pub fn take(how: api.Snip, owner: []const u8) void {

    if (busy()) return;

    remember(owner);
    begin(how);

}

/// Answers an app asking for a snip after its window tucks away: later, with the saved picture's path, or at once when busy.
pub fn ask(request: api.Request, owner: []const u8) ?u64 {

    if (busy()) return protocol.busy;

    const value = protocol.value(request.second);
    const how = std.enums.fromInt(api.Snip, value & 0xff) orelse return protocol.invalid;
    const surface: u32 = @intCast(value >> 16 & 0xff);

    remember(owner);
    gui.display.activate(surface, .minimize) catch {

    };

    asker = request;
    hidden = surface;
    kind = how;
    due = api.ticks() + @max(@as(u64, value >> 8 & 0xff) * 100, settle);

    return null;

}

/// Starts a delayed snip once due, and follows the pointer over the overlay; call it every pass of the event loop.
pub fn tick() void {

    if (due) |at| if (api.ticks() >= at) {

        due = null;
        begin(kind);

    };

    if (!window.surface.hidden and anchor == null) follow(window.pointer);

}

/// The most ticks the event loop may wait, so a delayed snip starts on time.
pub fn patience(longest: u64) u64 {

    const at = due orelse return longest;

    return std.math.clamp(at -| api.ticks(), 1, longest);

}

/// Handles input to the overlay; true when it was the overlay's.
pub fn react(input: gui.Input) bool {

    if (input.window != &window) return false;

    const event = input.event;

    if (event.kind == .key and event.pressed and event.key() == .escape) finish(null);

    return true;

}

/// Gives up any snip under way, such as when the session ends.
pub fn cancel() void {

    due = null;
    if (busy()) finish(null);

}

fn busy() bool {

    return frozen != null or due != null or asker != null;

}

fn remember(owner: []const u8) void {

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{owner}) catch "";

}

/// Freezes the screen, then saves all of it at once or shows the overlay to pick from.
fn begin(how: api.Snip) void {

    const screen = window.surface.list.bounds();
    var picture = gui.Image.init(@intCast(screen.width), @intCast(screen.height)) catch return finish(null);

    _ = gui.display.capture(picture.pixels()) catch {

        picture.deinit();
        return finish(null);

    };

    picture.solid();
    frozen = picture;
    kind = how;
    if (how == .screen) return finish(screen);

    frozen.?.publish() catch return finish(null);
    count = gui.display.windows(&listed) catch 0;
    anchor = null;
    pointer = window.pointer;
    window.show();

}

fn drag(_: *gui.Node, track: gui.Track) void {

    switch (track.phase) {

        .down => {

            pointer = track.at;
            anchor = track.at;

        },
        .move => follow(track.at),
        .up => {

            const start = anchor orelse return;

            pointer = track.at;
            anchor = null;
            if (kind == .region and moved(start)) return finish(gui.Rect.spanning(start, track.at));

            finish(under(start) orelse window.surface.list.bounds());

        },

    }

}

/// Moves the pointer to `at`, repainting only around what the snip took before and takes now, the size beneath it included.
fn follow(at: gui.Point) void {

    const before = chosen();

    pointer = at;

    const after = chosen();
    if (std.meta.eql(before, after)) return;

    for ([_]?gui.Rect{ before, after }) |entry| {

        window.damage = window.damage.join(if (entry) |area| area.inset(-64) else window.surface.list.bounds());

    }

}

fn moved(start: gui.Point) bool {

    return @abs(pointer.x - start.x) + @abs(pointer.y - start.y) > slack;

}


/// The frame of the topmost window at `at`, on the screen.
fn under(at: gui.Point) ?gui.Rect {

    var index = count;

    while (index > 0) {

        index -= 1;

        const found = listed[index];
        if (found.state.minimized) continue;

        const frame = gui.Rect{

            .x = found.area.x,
            .y = found.area.y,
            .width = found.area.width,
            .height = found.area.height,

        };

        if (frame.contains(at)) return frame.intersect(window.surface.list.bounds());

    }

    return null;

}

/// What the snip takes if the button comes up now.
fn chosen() ?gui.Rect {

    if (anchor) |start| if (kind == .region and moved(start)) return gui.Rect.spanning(start, pointer);

    return under(anchor orelse pointer);

}

/// The frozen screen, dimmed but for what the snip would take, with a hint above.
fn paint(node: *gui.Node, list: *gui.List) void {

    const picture = frozen orelse return;
    const screen = node.rect;

    list.image(picture.handle, screen);

    if (chosen()) |area| {

        const pieces = [_]gui.Rect{

            .{ .x = screen.x, .y = screen.y, .width = screen.width, .height = area.y - screen.y },
            .{ .x = screen.x, .y = area.bottom(), .width = screen.width, .height = screen.bottom() - area.bottom() },
            .{ .x = screen.x, .y = area.y, .width = area.x - screen.x, .height = area.height },
            .{ .x = area.right(), .y = area.y, .width = screen.right() - area.right(), .height = area.height },

        };

        for (pieces) |piece| if (piece.width > 0 and piece.height > 0) list.fill(piece, dimmed);

        // A white edge just outside the area, so it shows on any picture without covering what is taken.
        list.outline(area.inset(-1), 0, 1, theme.accent);

        var size_bytes: [32]u8 = undefined;
        const size = std.fmt.bufPrint(&size_bytes, "{d} x {d}", .{ area.width, area.height }) catch "";

        chip(list, size, area.x + @divTrunc(area.width, 2), @min(area.bottom() + theme.gap, screen.bottom() - 30));

    } else {

        list.fill(screen, dimmed);

    }

    chip(list, if (kind == .window) "Click a window to snip it." else "Drag to snip an area, or click a window.", screen.x + @divTrunc(screen.width, 2), screen.y + 48);

}

/// Draws `string` on a small dark chip centred on `middle`, its top at `top`.
fn chip(list: *gui.List, string: []const u8, middle: i32, top: i32) void {

    list.tag(null, string, gui.draw.tagged(null, string, .{

        .x = middle,
        .y = top,

    }, true));

}

/// Saves `area` of the frozen screen, or gives up when null, then tells whoever asked and puts everything back.
fn finish(area: ?gui.Rect) void {

    const path = if (area) |taken| save(taken) catch |err| failed: {

        notices.post(.warning, "Could not save the screenshot", catalog.reason(err), null);
        api.audio.cue(.alert);
        break :failed null;

    } else null;

    if (path != null) api.audio.cue(.capture);

    window.hide();
    anchor = null;

    if (frozen) |*picture| picture.deinit();
    frozen = null;

    if (asker) |request| {

        const length = if (path) |saved| if (api.store(request, 0, saved)) |_| saved.len else |_| 0 else 0;

        api.answer(request, length);

    } else if (path) |saved| {

        notices.post(.image, "Screenshot saved", std.fs.path.basename(saved), .{

            .image = .screenshots,
            .argument = saved,

        });

    }

    if (hidden) |surface| gui.display.activate(surface, .raise) catch {

    };

    asker = null;
    hidden = null;

}

/// Writes `area` of the frozen screen to `~/Screenshots/Screenshot DATE.png`; returns its path.
fn save(area: gui.Rect) api.ServiceError![]const u8 {

    const picture = frozen orelse return error.Invalid;
    const width: usize = @intCast(area.width);
    const height: usize = @intCast(area.height);

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const allocator = arena.allocator();
    const pixels = allocator.alloc(u32, width * height) catch return error.Exhausted;
    const source = picture.pixels();

    for (0..height) |row| {

        const from = (@as(usize, @intCast(area.y)) + row) * picture.width + @as(usize, @intCast(area.x));

        @memcpy(pixels[row * width ..][0..width], source[from..][0..width]);

    }

    const bytes = gui.png.encode(allocator, pixels, @intCast(width), @intCast(height)) catch return error.Exhausted;
    const date = api.Date.init(api.clock());
    const folder = std.fmt.bufPrint(&saved_bytes, "{s}/{s}", .{ home, catalog.screenshots }) catch return error.Invalid;

    files.directory(folder) catch |err| if (err != error.Exists) return err;

    const path = std.fmt.bufPrint(&saved_bytes, "{s}/{s}/Screenshot {d}-{d:0>2}-{d:0>2} {d:0>2}.{d:0>2}.{d:0>2}.png", .{ home, catalog.screenshots, date.year, date.month, date.day, date.hour, date.minute, date.second }) catch return error.Invalid;

    try files.save(allocator, path, bytes);

    return path;

}
