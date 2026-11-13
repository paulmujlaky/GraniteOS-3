const std = @import("std");

const status = @import("status.zig");
const desktop = @import("desktop.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

const lock_keys = api.Event.Modifiers{

    .shift = true,
    .control = true,

};

const State = enum {

    setup,
    choose,
    locked,
    session,

};

const avatar = gui.Style{

    .width = 36,
    .height = 36,

    .background = theme.selected,
    .radius = 18,
    .text_align = .center,

    .selected = .{

        .background = theme.accent,
        .color = theme.background,

    },

};

var greeter: gui.Window = undefined;
var accounts = api.Accounts{};
var files = api.Files{};
var state = State.choose;

/// No GraniteOS volume exists, as when started from installation media, so setup offers to install instead.
var bare = false;

/// What setup last reported, such as how installing went.
var notice: []const u8 = "";
var installed = false;

/// The disks the installer reported, the one picked, and whether erasing it was asked for once already.
var surveys: [6]protocol.Survey = undefined;
var drives: usize = 0;
var target: usize = 0;
var armed = false;

var disk_labels: [6][96]u8 = undefined;
var disk_rows: [6]gui.Node = undefined;
var disk_list: [6]*gui.Node = undefined;
var button_label: [64]u8 = undefined;

var names: [8][32]u8 = undefined;
var lengths: [8]usize = undefined;
var initials: [8]u8 = undefined;
var count: usize = 0;
var selected: usize = 0;

var name_bytes: [64]u8 = undefined;

var name_text = gui.Text{

    .buffer = &name_bytes,
    .placeholder = "Administrator name",

};

var password_bytes: [64]u8 = undefined;

var password_text = gui.Text{

    .buffer = &password_bytes,
    .placeholder = "Password",
    .secret = true,

};

var name = gui.input(&name_text);
var password = gui.input(&password_text);

var avatars: [8]gui.Node = undefined;
var labels: [8]gui.Node = undefined;
var rows: [8]gui.Node = undefined;
var parts: [8][2]*gui.Node = undefined;
var list: [8]*gui.Node = undefined;

var time_bytes: [8]u8 = undefined;
var date_bytes: [40]u8 = undefined;
var minute: u64 = std.math.maxInt(u64);

var backdrop = gui.picture(&desktop.backdrop, .{

});

var dim = gui.box(.{

    .background = gui.shade(0x000000, 150),

}, &.{});

var time = gui.label("", .{

    .size = 76,
    .text_align = .center,

});

var half = gui.label("", .{

    .padding = .{

        .bottom = 14,

    },
    .size = 24,
    .color = theme.muted,

});

var clock_parts = [_]*gui.Node{ &time, &half };

var clock = gui.box(.{

    .direction = .row,
    .gap = 8,
    .items = .end,

}, &clock_parts);

var date = gui.label("", .{

    .size = 18,
    .color = theme.muted,
    .text_align = .center,

});

// Labels keep to one line, so the greeting takes two to fit the form.
var welcome = gui.label("Welcome to GraniteOS.", theme.caption.with(.{

    .text_align = .center,

}));

var instruction = gui.label("Create the administrator account to begin.", theme.caption.with(.{

    .text_align = .center,

}));

var greeting_parts = [_]*gui.Node{ &welcome, &instruction };

var greeting = gui.box(.{

    .gap = 2,

}, &greeting_parts);

var users = gui.box(.{

    .gap = 4,

}, &list);

var hint = gui.label("", theme.caption.with(.{

    .text_align = .center,

}));

var installer = gui.button("Install", &install);

var disks = gui.box(.{

    .gap = 4,

}, &disk_list);

var heading = gui.label("Install GraniteOS", theme.title_text);
var setup_parts = [_]*gui.Node{ &heading, &disks, &installer };

/// Shown instead of account setup when started from installation media.
var setup = gui.box(theme.panel, &setup_parts);

var form_parts = [_]*gui.Node{ &greeting, &name, &users, &password, &hint, &setup };

var form = gui.box(.{

    .width = 320,
    .gap = theme.spacing,

}, &form_parts);

var spacer = gui.box(.{

    .height = 40,

}, &.{});

var center_parts = [_]*gui.Node{ &clock, &date, &spacer, &form };

var center = gui.box(.{

    .justify = .center,
    .items = .center,
    .gap = 6,

}, &center_parts);

var screen_parts = [_]*gui.Node{ &backdrop, &dim, &center };

var screen = gui.box(.{

    .direction = .stack,
    .background = theme.desktop,

}, &screen_parts);

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    for (&rows, 0..) |*row, index| {

        avatars[index] = gui.label("", avatar);

        labels[index] = gui.label("", .{

            .grow = 1,

        });

        parts[index] = .{ &avatars[index], &labels[index] };

        row.* = gui.box(theme.item.with(.{

            .height = 50,
            .hover = gui.Paint{

                .background = gui.shade(0xffffff, 20),

            },
            .selected = gui.Paint{

                .background = gui.shade(0xffffff, 34),

            },

        }), &parts[index]);

        row.data = index;
        list[index] = row;

    }

    for (&disk_rows, 0..) |*row, index| {

        row.* = gui.label("", theme.item.with(.{

            .height = 40,
            .hover = gui.Paint{

                .background = gui.shade(0xffffff, 20),

            },
            .selected = gui.Paint{

                .background = gui.shade(0xffffff, 34),

            },

        }));

        row.data = index;
        row.action = &pickDisk;
        disk_list[index] = row;

    }

    name.action = &advance;
    password.action = &submit;

    password.style = password.style.with(.{

        .height = 40,

    });

    name.style = password.style;

    desktop.init();

    greeter = gui.Window.open(&screen, .{

        .layer = .overlay,

    }) catch api.exit(3);

    load();
    sync();

    const surfaces = desktop.windows();
    var all: [16]*gui.Window = undefined;

    @memcpy(all[0..surfaces.len], surfaces);
    all[surfaces.len] = &greeter;

    while (true) {

        tick();
        desktop.tick();

        if (gui.wait(all[0 .. surfaces.len + 1], desktop.patience(50))) |input| {

            if (!status.press(input.event) and !desktop.react(input)) react(input.event);

        }

        if (state == .session) desktop.serve();

    }

}

/// Repaints the lock screen, such as after the wallpaper changed.
pub fn redraw() void {

    greeter.refresh();

}

/// Reads the account list, retrying while the accounts service is unavailable.
fn load() void {

    count = 0;

    while (count < names.len) {

        const account = accounts.list(@intCast(count)) catch {

            api.sleep(50);
            continue;

        } orelse break;

        lengths[count] = @min(account.name.len, names[count].len);
        @memcpy(names[count][0..lengths[count]], account.name[0..lengths[count]]);
        count += 1;

    }

    selected = @min(selected, count -| 1);
    state = if (count == 0) .setup else .choose;

    // Accounts live on the volume, so without one only installing can go ahead.
    bare = count == 0 and if (files.usage()) |_| false else |err| err == error.Missing;
    if (bare) survey();
    name.invalid = false;
    password.invalid = false;

}

/// Shows what the current state calls for.
fn sync() void {

    name.hidden = state != .setup or bare;
    password.hidden = state == .setup and bare;
    greeting.hidden = state != .setup or bare;
    users.hidden = state == .setup;
    setup.hidden = state != .setup or !bare;
    installer.hidden = drives == 0 or !installable(surveys[target]);
    disks.hidden = installed;

    for (&disk_rows, 0..) |*row, index| {

        row.hidden = index >= drives;
        row.selected = index == target;

    }

    if (bare and drives != 0) describe();

    hint.content.label = switch (state) {

        .setup => "",
        .locked => "Locked. Enter your password to unlock.",
        else => if (count > 1) "Choose an account, then enter its password." else "",

    };

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= count or (state == .locked and index != selected);
        row.selected = index == selected;
        row.action = if (state == .choose) &pick else null;
        avatars[index].selected = row.selected;

        if (index < count) {

            labels[index].content.label = names[index][0..lengths[index]];
            initials[index] = std.ascii.toUpper(names[index][0]);
            avatars[index].content.label = initials[index .. index + 1];

        }

    }

    if (state == .session) {

        greeter.hide();

    } else {

        greeter.show();
        if (!bare) greeter.focus(if (state == .setup and name_text.length == 0) &name else &password);

    }

    greeter.refresh();

}

/// Keeps the lock screen's clock current.
fn tick() void {

    const now = api.clock();
    if (now / 60 == minute) return;

    const today = api.Date.init(now);

    minute = now / 60;
    time.content.label = std.fmt.bufPrint(&time_bytes, "{d}:{d:0>2}", .{ today.twelve(), today.minute }) catch "";
    half.content.label = today.half();
    date.content.label = today.long(&date_bytes, false);
    greeter.refresh();

}

fn react(event: api.Event) void {

    if (state == .session) {

        if (event.chord(lock_keys, 'l')) lock() else if (event.chord(lock_keys, 'q')) logout();
        return;

    }

    if (state != .choose or event.kind != .key or !event.pressed) return;

    switch (event.key()) {

        .up => if (selected > 0) select(selected - 1),
        .down => if (selected + 1 < count) select(selected + 1),
        else => {

        },

    }

}

fn pick(row: *gui.Node) void {

    select(row.data);

}

fn select(index: usize) void {

    if (index == selected) return;

    selected = index;
    password_text.clear();
    password.invalid = false;
    sync();

}

fn advance(_: *gui.Node) void {

    greeter.focus(&password);

}

fn submit(_: *gui.Node) void {

    defer sync();
    defer password_text.clear();

    if (state == .setup) {

        accounts.create(name_text.text(), password_text.text(), true) catch {

            name.invalid = true;
            return;

        };

    }

    const user = if (state == .setup) name_text.text() else names[selected][0..lengths[selected]];

    _ = accounts.login(user, password_text.text()) catch {

        if (state == .setup) load();
        password.invalid = true;
        api.audio.cue(.alert);

        return;

    };

    if (state == .setup) {

        load();

        for (0..count) |index| {

            if (std.mem.eql(u8, names[index][0..lengths[index]], user)) selected = index;

        }

        name_text.clear();

    }

    // Unlocking returns to the same desktop; signing in starts it.
    if (state != .locked) {

        desktop.start(names[selected][0..lengths[selected]]);
        api.audio.cue(.login);

    }

    state = .session;

}

/// Asks the installer about every disk, then picks the first that GraniteOS can have to itself, or else one it fits beside.
fn survey() void {

    drives = 0;
    target = 0;
    armed = false;

    const service = api.lookup(0, .install) catch return;

    while (drives < surveys.len) : (drives += 1) {

        surveys[drives] = .{};
        const result = api.exchange(service, protocol.pack(.list, @intCast(drives)), std.mem.asBytes(&surveys[drives])) catch break;

        if (result != 0) break;

    }

    for ([_]protocol.Placement{ .empty, .granite, .beside }) |wanted| {

        for (surveys[0..drives], 0..) |found, index| if (found.placement == wanted) {

            target = index;
            return;

        };

    }

}

fn pickDisk(row: *gui.Node) void {

    target = row.data;
    armed = false;
    notice = "";
    sync();

}

fn installable(found: protocol.Survey) bool {

    return found.placement == .empty or found.placement == .granite or found.placement == .beside;

}

/// Labels each disk with its size and what it holds, and the button with what pressing it does.
fn describe() void {

    for (surveys[0..drives], 0..) |found, index| {

        const what = switch (found.placement) {

            .unreadable => "unreadable",
            .empty => "empty",
            .granite => "GraniteOS",
            .beside, .full => if (found.windows) "Windows" else "in use",

        };

        disk_rows[index].content.label = std.fmt.bufPrint(&disk_labels[index], "Disk {d} · {d} GB · {s}", .{ index, found.sectors / 1953125, what }) catch "";

    }

    // The button says how the last press went: installed, failed, or what the next press does.
    installer.content.label = if (notice.len != 0) notice else if (armed) std.fmt.bufPrint(&button_label, "Erase disk {d} and install", .{target}) catch "" else "Install";

}

/// Installs on the picked disk: in its free space beside another system, or, asked twice, erasing a disk nothing else uses.
fn install(_: *gui.Node) void {

    defer sync();

    if (drives == 0 or installed) return;

    const found = surveys[target];
    const erase = found.placement == .empty or found.placement == .granite;

    if (erase and !armed) {

        armed = true;
        return;

    }

    const service = api.lookup(0, .install) catch {

        notice = "Install failed";
        return;

    };

    const mode: protocol.Mode = if (erase) .erase else .beside;
    const result = (api.checked(api.raw(.call, service, protocol.pack(.install, @as(u56, @intCast(target)) | @as(u56, @intFromEnum(mode)) << 8), 6000)) catch {

        notice = "Install failed";
        return;

    }).first;

    notice = switch (result) {

        protocol.missing => "No room on this disk",
        protocol.denied, protocol.busy, protocol.empty, protocol.invalid => "Install failed",
        else => "Installed: remove USB and restart",

    };

    installed = result < protocol.denied;

}

pub fn lock() void {

    desktop.dismiss();
    state = .locked;
    sync();

}

pub fn logout() void {

    api.end() catch {

    };

    accounts.logout() catch {

    };

    desktop.stop();
    load();
    sync();

}
