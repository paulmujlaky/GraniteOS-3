//! The dock: pinned apps in the order people drag them into, a divider, then the other apps with windows open; a dot sits
//! under each app with windows.

const std = @import("std");

const catalog = @import("catalog.zig");
const desktop = @import("desktop.zig");
const pins = @import("pins.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const Image = api.abi.Image;

/// The button size, and the room around the buttons and below the dock.
const slot = 46;
const margin = 8;

/// Corners of the buttons; the dock's own sit `margin` further out, so the two curves stay parallel.
const curve = 16;

/// The rows the dock keeps at the bottom of the screen, out of maximised windows' way.
pub const reach = slot + 4 * margin;

var buttons: [catalog.apps.len]gui.Node = undefined;
var dots: [catalog.apps.len]gui.Node = undefined;
var markers: [catalog.apps.len]gui.Node = undefined;
var marker_parts: [catalog.apps.len][1]*gui.Node = undefined;
var slots: [catalog.apps.len]gui.Node = undefined;
var slot_parts: [catalog.apps.len][2]*gui.Node = undefined;

var divider = gui.box(theme.divider.with(.{

    .height = slot - 2 * margin,
    .background = gui.shade(0xffffff, 48),

}), &.{});

/// Opens the launcher, apart from the apps at the dock's left end.
var launch: gui.Node = undefined;

var launch_divider = gui.box(theme.divider.with(.{

    .height = slot - 2 * margin,
    .background = gui.shade(0xffffff, 48),

}), &.{});

var parts: [catalog.apps.len + 3]*gui.Node = undefined;

var root = gui.box(.{

    .padding = .all(margin),
    .direction = .row,
    .gap = 6,
    .items = .center,

    .background = theme.quartz,
    .quartz = true,
    .border = theme.line,
    .border_width = theme.border,
    .radius = curve + margin,

}, &.{});

pub var window: gui.Window = undefined;

/// The screen the dock centres itself along the bottom of.
var screen = gui.Rect{};

/// A press on an app, which becomes a drag along the dock for a pinned one.
var held: ?struct { image: Image, drag: gui.Drag } = null;

pub fn init() void {

    launch = gui.tool(.grid, &openLauncher);

    launch.style = launch.style.with(.{

        .width = slot,
        .height = slot,

        .size = 22,
        .radius = curve,

    });

    for (catalog.apps, 0..) |app, index| {

        buttons[index] = gui.tool(app.icon, &pick);

        buttons[index].style = buttons[index].style.with(.{

            .width = slot,
            .height = slot,

            .size = 22,
            .radius = curve,

        });

        buttons[index].data = index;
        buttons[index].track = &drag;
        buttons[index].menu = &offer;

        dots[index] = gui.box(.{

            .width = 4,
            .height = 4,

            .background = theme.accent,
            .radius = 2,

        }, &.{});

        marker_parts[index] = .{&dots[index]};

        markers[index] = gui.box(.{

            .padding = .{

                .bottom = 1,

            },
            .justify = .end,
            .items = .center,

        }, &marker_parts[index]);

        slot_parts[index] = .{ &buttons[index], &markers[index] };

        slots[index] = gui.box(.{

            .width = slot,
            .height = slot,
            .direction = .stack,

        }, &slot_parts[index]);

    }

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .width = 1,
        .height = 1,

        .hidden = true,
        .tuck = true,

    }) catch api.exit(3);

}

/// Lines the apps up again after the pins or the windows change, resizing the dock to fit them.
pub fn arrange() void {

    parts[0] = &launch;
    parts[1] = &launch_divider;

    var length: usize = 2;

    for (pins.docked[0..pins.docked_count]) |image| {

        parts[length] = &slots[position(image)];
        length += 1;

    }

    parts[length] = &divider;
    length += 1;
    divider.hidden = true;

    for (catalog.apps, 0..) |app, index| {

        const open = desktop.running(app.image);

        dots[index].hidden = !open;
        slots[index].hidden = !open and !pins.docks(app.image);

        if (pins.docks(app.image)) continue;

        parts[length] = &slots[index];
        length += 1;
        if (open and pins.docked_count != 0) divider.hidden = false;

    }

    root.content.box = parts[0..length];
    place(screen);

}

/// Centres the dock along the bottom of a `area`-sized screen.
pub fn place(area: gui.Rect) void {

    const size = root.measure();
    const now = window.surface.spec.area;

    const goal = gui.Rect{

        .x = @divTrunc(area.width - size.width, 2),
        .y = area.height - size.height - gui.px(margin),
        .width = size.width,
        .height = size.height,

    };

    screen = area;

    if (now.x == goal.x and now.y == goal.y and now.width == goal.width and now.height == goal.height) return window.refresh();

    window.move(goal);

}

/// Marks the launcher's button as showing it, or not.
pub fn opened(on: bool) void {

    if (launch.selected == on) return;

    launch.selected = on;
    window.refresh();

}

fn openLauncher(_: *gui.Node) void {

    desktop.toggle();

}

fn position(image: Image) usize {

    for (catalog.apps, 0..) |app, index| {

        if (app.image == image) return index;

    }

    unreachable;

}

/// Starts an app, or brings its windows forward.
fn pick(node: *gui.Node) void {

    // Letting go of a dragged app is no click.
    if (held) |press| {

        held = null;
        if (press.drag.moved) return;

    }

    const app = catalog.apps[node.data];
    var newest: ?*const api.display.Window = null;
    var oldest: ?*const api.display.Window = null;

    desktop.dismiss();

    for (desktop.listed[0..desktop.count]) |*listed| {

        if (listed.application != @intFromEnum(app.image)) continue;

        if (oldest == null) oldest = listed;
        newest = listed;

    }

    const top = newest orelse return desktop.start_app(app.image, desktop.home);
    const current = desktop.focused();

    // Clicking the app already in front shows its next window, or tucks away its only one.
    if (current != null and current.?.application == @intFromEnum(app.image) and !top.state.minimized) {

        if (oldest.? == top) gui.display.activate(top.id, .minimize) catch {

        } else gui.display.activate(oldest.?.id, .raise) catch {

        };

        return;

    }

    gui.display.activate(top.id, .raise) catch {

    };

}

/// Follows a pinned app dragged along the dock, moving it among the others as it passes their middles.
fn drag(node: *gui.Node, track: gui.Track) void {

    const image = catalog.apps[node.data].image;

    switch (track.phase) {

        .down => held = .{

            .image = image,
            .drag = .init(track.at),

        },
        .move => if (held) |*press| {

            if (!press.drag.follow(track.at) or !pins.docks(image)) return;

            node.cursor = .grabbing;
            pins.shift(image, spot(image, track.at.x));

        },
        .up => {

            node.cursor = null;
            if (held) |press| if (press.drag.moved and pins.docks(image)) pins.save();

        },

    }

}

/// How many pinned apps besides `image` lie left of `x`.
fn spot(image: Image, x: i32) usize {

    var count: usize = 0;

    for (pins.docked[0..pins.docked_count]) |other| {

        const area = slots[position(other)].rect;

        if (other != image and x > area.x + @divTrunc(area.width, 2)) count += 1;

    }

    return count;

}

fn offer(node: *gui.Node, at: gui.Point) void {

    const area = window.surface.spec.area;

    desktop.dismiss();

    pins.offer(catalog.apps[node.data].image, .{

        .x = area.x + at.x,
        .y = area.y + at.y,

    });

}
