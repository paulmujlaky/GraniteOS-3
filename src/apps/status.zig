//! Quick settings under the bar's status icons: a pill for each switch, such as the network, and the volume. The volume keys
//! work here too.

const std = @import("std");

const desktop = @import("desktop.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;

const width = 380;

/// A switch the panel offers: what it shows, how it reads its state into a short detail, and how it flips.
const Tile = struct {

    icon: gui.Icon,
    title: []const u8,

    /// Whether it is on, with a word on how, or null to hide the switch, as when there is nothing to switch.
    read: *const fn () ?State,
    flip: *const fn (on: bool) void,

};

const State = struct {

    on: bool,
    detail: []const u8,

};

const switches = [_]Tile{

    .{ .icon = .ethernet, .title = "Network", .read = network, .flip = power },
    .{ .icon = .mute, .title = "Mute", .read = muted, .flip = hush },
    .{ .icon = .brush, .title = "Transparency", .read = clear, .flip = frost },
    .{ .icon = .bell, .title = "Sounds", .read = chiming, .flip = chime },

};

const columns = 2;
const lines = (switches.len + columns - 1) / columns;

/// A switch: a pill with a round well for its icon at the left, the only part the accent fills while on, beside its name and state.
const pill = gui.Style{

    // Growing from nothing, so every switch takes an equal share whatever its name.
    .width = 0,
    .height = 56,
    .grow = 1,
    .padding = .{

        .left = 6,
        .right = 16,

    },
    .direction = .row,
    .gap = 12,
    .items = .center,

    .background = theme.field,
    .radius = 28,

    .hover = .{

        .background = theme.hover,

    },
    .focus = .{

        .background = theme.lit,

    },

};

const well = theme.icon.with(.{

    .width = 44,
    .height = 44,

    .radius = 22,
    .size = 18,

});

var wells: [switches.len]gui.Node = undefined;
var names: [switches.len]gui.Node = undefined;
var details: [switches.len]gui.Node = undefined;
var word_parts: [switches.len][2]*gui.Node = undefined;
var words: [switches.len]gui.Node = undefined;
var pill_parts: [switches.len][2]*gui.Node = undefined;
var pills: [switches.len]gui.Node = undefined;

/// The switches shown, two to a row, with a filler keeping a lone last one at half width.
var shown_pills: [lines][columns]*gui.Node = undefined;
var fillers: [lines]gui.Node = undefined;
var rows: [lines]gui.Node = undefined;
var row_list: [lines]*gui.Node = undefined;

var grid = gui.box(.{

    .gap = 10,

}, &row_list);

// The volume, beside a button that mutes it; hidden without an audio device.
var speaker = gui.tool(.volume_high, &silence);
var level = gui.Slider{ .changed = &slide };
var level_node: gui.Node = undefined;
var percent_bytes: [8]u8 = undefined;

var percent = gui.label("", theme.caption.with(.{

    .width = 40,
    .text_align = .right,

}));

var sound_parts = [_]*gui.Node{ &speaker, &level_node, &percent };

var sound = gui.box(.{

    .direction = .row,
    .gap = 8,
    .items = .center,

}, &sound_parts);

/// Percent the volume keys move the volume by.
const step = 5;

var root_parts = [_]*gui.Node{ &grid, &sound };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &root_parts);

pub var window: gui.Window = undefined;

/// Where the panel's top right corner goes.
var corner = gui.Point{};

/// When an open panel next reads its switches again.
var due: u64 = 0;

pub fn init() void {

    level_node = level.node(.{

        .grow = 1,

    });

    for (switches, 0..) |entry, index| {

        wells[index] = gui.icon(entry.icon, well);
        names[index] = gui.label(entry.title, .{});
        details[index] = gui.label("", theme.caption);
        word_parts[index] = .{ &names[index], &details[index] };

        words[index] = gui.box(.{

            .grow = 1,
            .gap = 2,

        }, &word_parts[index]);

        pill_parts[index] = .{ &wells[index], &words[index] };
        pills[index] = gui.box(pill, &pill_parts[index]);
        pills[index].action = &choose;
        pills[index].data = index;

    }

    for (&rows, 0..) |*row, line| {

        fillers[line] = gui.box(.{

            .width = 0,
            .grow = 1,

        }, &.{});

        row.* = gui.box(.{

            .direction = .row,
            .gap = 10,

        }, &.{});

        row_list[line] = row;

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

/// Opens the panel with its top right corner at `at`.
pub fn show(at: gui.Point) void {

    corner = at;
    refresh();
    window.show();

}

pub fn hide() void {

    if (shown()) window.hide();

}

pub fn shown() bool {

    return !window.surface.hidden;

}

/// Keeps an open panel's switches current, every second; call it every pass of the event loop.
pub fn tick() void {

    if (shown() and api.ticks() >= due) refresh();

}

/// The speaker icon for `state`'s volume, crossed out when muted or silent.
pub fn speakerIcon(state: api.audio.Status) gui.Icon {

    const loudness: u8 = if (state.muted) 0 else state.volume;

    return if (loudness == 0) .mute else if (loudness < 34) .volume else if (loudness < 67) .volume_low else .volume_high;

}

/// Reads every switch and the volume again, and fits the panel to them.
fn refresh() void {

    due = api.ticks() + 100;
    hear(api.audio.status() catch null);

    var count: usize = 0;

    for (switches, 0..) |entry, index| {

        const state = entry.read() orelse continue;

        details[index].content.label = state.detail;
        wells[index].style.background = if (state.on) theme.accent else theme.hover;
        wells[index].style.color = if (state.on) theme.background else theme.text;
        shown_pills[count / columns][count % columns] = &pills[index];
        count += 1;

    }

    for (&rows, 0..) |*row, line| {

        const from = line * columns;
        const length = @min(count -| from, columns);

        if (length == 1) shown_pills[line][1] = &fillers[line];

        row.content.box = shown_pills[line][0..if (length == 0) 0 else columns];
        row.hidden = length == 0;

    }

    const size = root.measure();

    window.move(.{

        .x = corner.x - gui.px(width),
        .y = corner.y,
        .width = gui.px(width),
        .height = size.height,

    });

    window.refresh();

}

/// Shows the volume as `state` has it, or hides it without audio.
fn hear(state: ?api.audio.Status) void {

    sound.hidden = state == null;

    const known = state orelse return;

    level.value = @as(f32, @floatFromInt(known.volume)) / 100;
    percent.content.label = if (known.muted) "Muted" else std.fmt.bufPrint(&percent_bytes, "{d}%", .{known.volume}) catch "";
    speaker.content.label = speakerIcon(known).text();

}

/// Takes the volume keys, whichever window has the keyboard, playing a tick at the new volume; true when `event` was one.
pub fn press(event: api.Event) bool {

    if (event.kind != .key or !event.key().global()) return false;
    if (!event.pressed) return true;

    const state = api.audio.status() catch return true;

    switch (event.key()) {

        .mute => api.audio.mute(!state.muted) catch {

        },
        .volume_down => api.audio.volume(state.volume -| step) catch {

        },
        else => api.audio.volume(@min(state.volume + step, 100)) catch {

        },

    }

    api.audio.cue(.level);
    if (shown()) refresh();
    desktop.indicate();

    return true;

}

fn slide(slider: *gui.Slider, done: bool) void {

    api.audio.volume(@intFromFloat(@round(slider.value * 100))) catch {

    };

    if (done) api.audio.cue(.level);
    hear(api.audio.status() catch null);
    window.refresh();
    desktop.indicate();

}

fn silence(_: *gui.Node) void {

    const state = api.audio.status() catch return;

    api.audio.mute(!state.muted) catch {

    };

    refresh();
    desktop.indicate();

}

fn choose(node: *gui.Node) void {

    const entry = switches[node.data];

    entry.flip(!(entry.read() orelse return).on);
    refresh();
    desktop.indicate();

}

fn network() ?State {

    const state = api.net.status() catch return null;

    if (state.off) return .{ .on = false, .detail = "Off" };
    if (state.speed == 0) return .{ .on = true, .detail = "Unplugged" };
    if (state.address.empty()) return .{ .on = true, .detail = "Connecting" };

    return .{ .on = true, .detail = "Connected" };

}

fn power(on: bool) void {

    api.net.power(on) catch {

    };

}

fn muted() ?State {

    const state = api.audio.status() catch return null;

    return described(state.muted);

}

fn hush(on: bool) void {

    api.audio.mute(on) catch {

    };

}

fn clear() ?State {

    return described(desktop.translucent);

}

fn chiming() ?State {

    const state = api.audio.status() catch return null;

    return described(state.sounds);

}

fn chime(on: bool) void {

    api.audio.sounds(on) catch return;

    if (on) api.audio.cue(.notice);

}

fn described(on: bool) State {

    return .{ .on = on, .detail = if (on) "On" else "Off" };

}

fn frost(on: bool) void {

    desktop.translucency(on);

}
