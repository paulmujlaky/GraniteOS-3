//! The signed-in desktop: wallpaper and its items, top bar, dock, app launcher, menus, notifications, window switcher,
//! clipboard history, quick settings, and snips, all surfaces of the login process.

const std = @import("std");

const about = @import("about.zig");
const catalog = @import("catalog.zig");
const clips = @import("clips.zig");
const controls = @import("controls.zig");
const status = @import("status.zig");
const dock = @import("dock.zig");
const wallpapers = @import("wallpapers.zig");
const launcher = @import("launcher.zig");
const notices = @import("notices.zig");
const pins = @import("pins.zig");
const shortcuts = @import("shortcuts.zig");
const snip = @import("snip.zig");
const switcher = @import("switcher.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const session = @import("root");
const theme = gui.theme;

/// Rows the top bar keeps.
pub const height = 30;
const margin = 8;

// Children span the bar's height, so text and icons centre on their capitals rather than on their line boxes.
const chip = gui.Style{

    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 7,
    .items = .stretch,

    .radius = theme.radius,

    .hover = .{

        .background = gui.shade(0xffffff, 24),

    },
    .pressed = .{

        .background = gui.shade(0xffffff, 40),

    },
    .selected = .{

        .background = gui.shade(0xffffff, 32),

    },

};

pub var wallpaper: gui.Window = undefined;
var bar: gui.Window = undefined;

/// Every surface of the desktop, for the event loop.
var surfaces: [15]*gui.Window = undefined;

/// The picture behind everything, shared with the lock screen.
pub var backdrop: gui.Image = undefined;

/// Which built-in wallpaper the backdrop is, or null for the user's picture.
var built_in: ?usize = 0;

var painting = gui.picture(&backdrop, .{

    .grow = 1,

});

var scenery_parts = [_]*gui.Node{ &painting, &shortcuts.node };

var scenery = gui.box(.{

    .direction = .stack,

}, &scenery_parts);

var files = api.Files{};

/// The `desktop` config, where Settings saves the wallpaper as `wallpaper=PATH` or a built-in's name, `quartz=off` when Quartz
/// draws solid, and `accent=NAME`.
var preferences = api.Config{};

/// Whether Quartz shows what lies behind it, as the user chose.
pub var translucent = true;

/// The accent the user chose, as an index into `theme.accents`.
var tone: u8 = 0;

// Top bar.

var spring = gui.box(theme.spring, &.{});

var time_bytes: [32]u8 = undefined;

var time = gui.label("", .{

    .size = theme.small,

});

/// The network and the volume at a glance, which open the quick settings.
var network_icon = gui.icon(.ethernet, theme.icon);
var sound_icon = gui.icon(.volume_high, theme.icon);
var tray_parts = [_]*gui.Node{ &network_icon, &sound_icon };
var tray = gui.box(chip, &tray_parts);

/// When the tray last read the network and the volume, in `api.clock` seconds.
var looked: u64 = 0;

/// The date and time, which open the calendar.
var clock_parts = [_]*gui.Node{ &time };
var clock = gui.box(chip, &clock_parts);

var user_icon = gui.icon(.user, theme.icon);

var user_label = gui.label("", .{

    .size = theme.small,

});

var user_parts = [_]*gui.Node{ &user_icon, &user_label };
var user = gui.box(chip, &user_parts);
var bar_parts = [_]*gui.Node{ &clock, &spring, &tray, &user };

var bar_root = gui.box(.{

    .padding = .axes(0, 4),
    .direction = .row,
    .gap = 4,
    .items = .stretch,

    .background = theme.quartz,
    .quartz = true,

}, &bar_parts);

/// The session menu under the account name, and the wallpaper's right-click menu.
var account_menu: gui.Menu(&.{

    .{ .icon = .lock, .title = "Lock", .run = session.lock },
    .{ .icon = .logout, .title = "Log out", .run = session.logout },
    .{ .icon = .restart, .title = "Restart", .run = restart },
    .{ .icon = .power, .title = "Shut down", .run = shutdown },

}) = .{};

var desktop_menu: gui.Menu(&.{

    .{ .icon = .folder, .title = "Files", .run = files_open },
    .{ .icon = .terminal, .title = "Terminal", .run = terminal_open },
    .{ .icon = .wallpaper, .title = "Change wallpaper", .run = settings_open },
    .{ .icon = .image, .title = "Take screenshot", .hint = "Super+S", .run = screenshot },
    .{ .icon = .info, .title = "About GraniteOS", .run = about_open },

}) = .{};

/// The windows on the screen, bottom first, as last read.
pub var listed: [64]api.display.Window = undefined;
pub var count: usize = 0;

/// The window that had focus when the list was last read.
var leader: ?u32 = null;

var home_bytes: [48]u8 = undefined;
pub var home: []const u8 = "";
var minute: u64 = std.math.maxInt(u64);

/// The display restarts already seen.
var restarted: u64 = 0;

/// Opens every surface: the wallpaper now, the rest hidden until a session starts.
pub fn init() void {

    clock.action = &settle;
    tray.action = &adjust;
    user.action = &reveal;

    const screen = while (true) break gui.screen() catch {

        api.sleep(50);
        continue;

    };

    backdrop = wallpapers.render(0, @intCast(screen.width), @intCast(screen.height)) catch api.exit(3);
    backdrop.fit = .cover;

    backdrop.publish() catch {

    };

    wallpaper = gui.Window.open(&scenery, .{

        .layer = .background,

    }) catch api.exit(3);

    bar = gui.Window.open(&bar_root, .{

        .layer = .panel,

        .width = screen.width,
        .height = gui.px(height),

        .hidden = true,

    }) catch api.exit(3);

    dock.init();

    launcher.init(launcher.spot(screen, gui.px(dock.reach)));

    account_menu.init(null);
    desktop_menu.init(null);
    pins.init();
    shortcuts.init();
    notices.init(screen, gui.px(height));
    switcher.init(screen);
    clips.init(screen);
    controls.init();
    status.init();
    about.init();
    snip.init();
    surfaces = .{ &wallpaper, &bar, &dock.window, &launcher.window, &account_menu.window, &desktop_menu.window, &pins.app_menu.window, &shortcuts.menu.window, &notices.window, &switcher.window, &clips.window, &controls.window, &status.window, &about.window, &snip.window };

    place(screen);

}

/// Every surface, for the event loop.
pub fn windows() []const *gui.Window {

    return &surfaces;

}

/// Shows the desktop for `name`, whose home is `/home/NAME`.
pub fn start(name: []const u8) void {

    home = std.fmt.bufPrint(&home_bytes, "/home/{s}", .{name}) catch "/";
    user_label.content.label = name;
    minute = std.math.maxInt(u64);

    bar.show();
    dock.window.show();
    reload(.all);
    controls.load(name);
    claim();
    refresh();

}

/// Keeps the rows of the bar and dock out of maximised windows' way, and Quartz as the user chose.
fn claim() void {

    gui.display.reserve(@intCast(gui.px(height)), @intCast(gui.px(dock.reach))) catch {

    };

    gui.display.quartz(translucent) catch {

    };

    gui.display.accent(tone) catch {

    };

}

/// Hides the desktop when the session ends.
pub fn stop() void {

    dismiss();
    snip.cancel();
    notices.clear();
    about.hide();
    bar.hide();
    dock.window.hide();
    pins.load("");
    controls.load("");

    gui.display.reserve(0, 0) catch {

    };

    replace(null);

}

/// Keeps the clock and the launcher's search current; call it every pass of the event loop.
pub fn tick() void {

    launcher.tick();
    notices.tick();
    snip.tick();

    // A restarted display forgot the rows the bar keeps, so once the bar is back it keeps them again.
    if (restarted != gui.lost.* and bar.surface.attached) {

        restarted = gui.lost.*;
        claim();

    }

    controls.tick();
    status.tick();

    const now = api.clock();

    if (now != looked and !bar.surface.hidden) {

        looked = now;
        indicate();

    }

    if (now / 60 == minute or bar.surface.hidden) return;

    const date = api.Date.init(now);
    var day_bytes: [16]u8 = undefined;
    var hour_bytes: [16]u8 = undefined;

    minute = now / 60;
    time.content.label = std.fmt.bufPrint(&time_bytes, "{s}   {s}", .{ date.short(&day_bytes), date.clock(&hour_bytes, false) }) catch "";
    bar.refresh();

}

/// The most ticks the event loop may wait for input, so a delayed snip starts on time.
pub fn patience(longest: u64) u64 {

    return snip.patience(longest);

}

/// Handles input the desktop's surfaces did not; true when it was theirs.
pub fn react(input: gui.Input) bool {

    const event = input.event;
    const window = input.window;

    if (std.mem.indexOfScalar(*gui.Window, &surfaces, window) == null) return false;
    if (snip.react(input)) return true;

    // Alt+Tab reaches whichever desktop surface the display hands it to.
    if (switcher.react(event)) return true;

    switch (event.kind) {

        .notice => switch (@as(api.Event.Notice, @enumFromInt(event.code))) {

            .windows => refresh(),
            .clipboard => clips.copied(),
            .scale => if (window == &wallpaper) rescale(),
            _ => {

            },

        },
        .resize => if (window == &wallpaper) place(.{

            .width = event.x,
            .height = event.y,

        }),
        .close => if (window == &about.window) about.hide(),
        .key => {

            if (!event.pressed) return true;
            if (window == &wallpaper and !event.modifiers.super and shortcuts.react(event)) return true;

            if (event.key() == .escape) {

                dismiss();

            } else if (event.modifiers.super and event.key() == .character) {

                switch (event.char | 0x20) {

                    ' ', 'a' => toggle(),
                    'l' => session.lock(),
                    's' => snip.take(if (event.modifiers.shift) .region else .screen, home),
                    'e' => start_app(.explorer, home),
                    't' => start_app(.terminal, home),
                    'v' => {

                        const shown = !clips.window.surface.hidden;

                        dismiss();
                        if (!shown) clips.toggle();

                    },
                    else => {

                    },

                }

            } else if (event.modifiers.super and event.key() == .tab) {

                cycle();

            }

        },
        else => {

        },

    }

    return true;

}

/// Answers apps the session launched, such as Settings asking for the wallpaper to reload, a timer showing a notification, or Screenshots asking for a snip.
pub fn serve() void {

    while (true) {

        const request = api.receive(false) catch return;

        const result: ?u64 = switch (protocol.operation(request.second)) {

            .reload => blk: {

                reload(std.enums.fromInt(catalog.Reload, protocol.value(request.second)) orelse .all);
                break :blk 0;

            },
            .notify => notify(request),
            .snip => snip.ask(request, home),
            .pin => pins.serve(request),
            else => protocol.invalid,

        };

        // A snip answers once it is saved or cancelled.
        if (result) |value| api.answer(request, value);

    }

}

/// Shows the notification an app sent as its title, a NUL, and its detail.
fn notify(request: api.Request) u64 {

    var bytes: [64 + 1 + 192]u8 = undefined;
    if (request.fourth > bytes.len) return protocol.invalid;

    api.fetch(request, 0, bytes[0..request.fourth]) catch return protocol.invalid;

    const message = bytes[0..request.fourth];
    const split = std.mem.indexOfScalar(u8, message, 0) orelse message.len;

    notices.post(.bell, message[0..split], message[@min(split + 1, message.len)..], null);
    api.audio.cue(.notice);

    return 0;

}

/// Puts the bar, dock, items, and menus where a `screen`-sized display wants them.
fn place(screen: gui.Rect) void {

    bar.move(.{

        .width = screen.width,
        .height = gui.px(height),

    });

    dock.place(screen);
    shortcuts.redraw();
    notices.place(screen, gui.px(height));
    launcher.place(launcher.spot(screen, gui.px(dock.reach)));
    switcher.place(screen);
    clips.place(screen);

}

/// Lays the desktop out again at a new interface scale.
fn rescale() void {

    dismiss();
    place(wallpaper.surface.list.bounds());
    if (!bar.surface.hidden) claim();
    wallpaper.refresh();

}

/// Reads the window list again and updates the dock.
fn refresh() void {

    count = gui.display.windows(&listed) catch 0;

    // A window taking focus means the pointer went elsewhere, so open menus close; other changes, such as a menu opening, leave them.
    const now = if (focused()) |window| window.id else null;

    if (now != null and now != leader) dismiss();
    leader = now;

    bar.refresh();
    dock.arrange();

}

pub fn focused() ?*const api.display.Window {

    for (listed[0..count]) |*window| {

        if (window.state.focused) return window;

    }

    return null;

}

/// Whether app `image` has a window open.
pub fn running(image: api.abi.Image) bool {

    for (listed[0..count]) |*window| {

        if (window.application == @intFromEnum(image)) return true;

    }

    return false;

}

/// Raises the bottom window, so repeated presses walk through them all.
fn cycle() void {

    if (count == 0) return;

    gui.display.activate(listed[0].id, .raise) catch {

    };

}

pub fn start_app(image: api.abi.Image, argument: []const u8) void {

    dismiss();

    catalog.start(image, argument) catch {

    };

}

/// Opens the launcher above the dock, or closes it.
pub fn toggle() void {

    if (launcher.shown()) return dismiss();

    dismiss();
    dock.opened(true);
    launcher.show();

}

/// Opens the calendar under the date and time, or closes it.
fn settle(_: *gui.Node) void {

    if (controls.shown()) return dismiss();

    dismiss();
    clock.selected = true;
    controls.show(.{ .x = gui.px(margin), .y = gui.px(height + margin) });
    bar.refresh();

}

/// Opens the quick settings under the tray, or closes them.
fn adjust(_: *gui.Node) void {

    if (status.shown()) return dismiss();

    dismiss();
    tray.selected = true;
    status.show(.{ .x = tray.rect.right(), .y = gui.px(height + margin) });
    bar.refresh();

}

/// Shows the network, faint while offline, and the volume in the tray, hiding either the system lacks.
pub fn indicate() void {

    const net = api.net.status() catch null;
    const sound = api.audio.status() catch null;

    const shade: u32 = if (net) |state| (if (state.online()) theme.text else theme.faint) else theme.text;
    const speaker = if (sound) |state| status.speakerIcon(state).text() else sound_icon.content.label;

    if (network_icon.hidden == (net == null) and network_icon.style.color == shade and sound_icon.hidden == (sound == null) and std.mem.eql(u8, sound_icon.content.label, speaker)) return;

    network_icon.hidden = net == null;
    network_icon.style.color = shade;
    sound_icon.hidden = sound == null;
    sound_icon.content.label = speaker;
    tray.hidden = network_icon.hidden and sound_icon.hidden;
    bar.refresh();

}

fn reveal(_: *gui.Node) void {

    if (account_menu.shown()) return dismiss();

    dismiss();
    user.selected = true;

    account_menu.show(.{

        .x = wallpaper.surface.list.width,
        .y = gui.px(height + margin),

    });

    bar.refresh();

}

/// Opens the wallpaper's menu at `at`.
pub fn offer(at: gui.Point) void {

    desktop_menu.show(at);

}

/// Closes the launcher, the menus, the clipboard history, and the quick settings.
pub fn dismiss() void {

    launcher.hide();
    account_menu.hide();
    desktop_menu.hide();
    pins.app_menu.hide();
    shortcuts.menu.hide();
    clips.hide();
    controls.hide();
    status.hide();

    dock.opened(false);
    clock.selected = false;
    tray.selected = false;
    user.selected = false;
    bar.refresh();

}

fn files_open() void {

    start_app(.explorer, home);

}

fn terminal_open() void {

    start_app(.terminal, home);

}

fn settings_open() void {

    start_app(.settings, home);

}

fn about_open() void {

    about.show(user_label.content.label);

}

fn screenshot() void {

    snip.take(.screen, home);

}

fn restart() void {

    _ = api.call(0, protocol.pack(.power, 0)) catch {

    };

}

fn shutdown() void {

    _ = api.call(0, protocol.pack(.power, 1)) catch {

    };

}

/// Shows Quartz and the accent and, unless only those changed, the wallpaper as the user chose in Settings: the first built-in
/// when there is none or it will not load.
fn reload(what: catalog.Reload) void {

    if (what == .weather) return controls.load(user_label.content.label);

    preferences.open(user_label.content.label, "desktop");
    translucent = !std.mem.eql(u8, preferences.get("quartz") orelse "", "off");
    tone = theme.accentNamed(preferences.get("accent") orelse "");

    gui.display.quartz(translucent) catch {

    };

    gui.display.accent(tone) catch {

    };

    if (what == .quartz or what == .accent) return;

    replace(preferences.get("wallpaper"));
    pins.load(user_label.content.label);

}

/// Saves whether Quartz shows what lies behind it for the signed-in user, as Settings does, and shows it.
pub fn translucency(on: bool) void {

    preferences.open(user_label.content.label, "desktop");

    if (!preferences.set("quartz", if (on) "on" else "off")) return;

    preferences.save() catch return;
    reload(.quartz);

}

/// Swaps the backdrop for the built-in wallpaper or PNG `choice` names, or the first built-in when null or unreadable.
fn replace(choice: ?[]const u8) void {

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const name = choice orelse "";
    const chosen = if (wallpapers.find(name) != null) null else gui.Image.open(arena.allocator(), &files, name) catch null;
    const which = if (chosen == null) wallpapers.find(name) orelse 0 else null;

    if (which != null and which == built_in) return;

    const area = wallpaper.surface.list.bounds();
    var next = chosen orelse wallpapers.render(which.?, @intCast(area.width), @intCast(area.height)) catch return;

    next.fit = .cover;

    next.publish() catch {

        next.deinit();
        return;

    };

    backdrop.deinit();
    backdrop = next;
    built_in = which;
    wallpaper.refresh();
    session.redraw();

}
