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

/// What setup last reported, such as why installing failed.
var notice: []const u8 = "";
var installed = false;

/// Set by the Install button and acted on by the main loop, once the screen shows that installing has begun.
var installing = false;

/// The disks the installer reported, the one picked, and whether erasing or shrinking it was asked for once already.
var surveys: [6]protocol.Survey = undefined;
var drives: usize = 0;
var target: usize = 0;
var armed = false;

var disk_titles: [6][32]u8 = undefined;
var disk_names: [6]gui.Node = undefined;
var disk_states: [6]gui.Node = undefined;
var disk_parts: [6][2]*gui.Node = undefined;
var disk_rows: [6]gui.Node = undefined;
var disk_list: [6]*gui.Node = undefined;
var detail_bytes: [64]u8 = undefined;
var button_label: [64]u8 = undefined;

/// The setup panel's width while it offers to install; account setup keeps the narrower form.
const wide = 480;

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

var heading = gui.label("Install GraniteOS", .{

    .size = 26,

});

var disks = gui.box(.{

    .gap = 6,

}, &disk_list);

var details: [2]gui.Node = .{

    gui.label("", .{}),
    gui.label("", theme.caption),

};

var detail_parts = [_]*gui.Node{ &details[0], &details[1] };

/// What installing on the picked disk will do, or why it cannot.
var summary = gui.box(.{

    .padding = .all(14),
    .gap = 6,

    .background = gui.shade(0xffffff, 12),
    .radius = theme.radius,

}, &detail_parts);

var problem = gui.label("", .{

    .color = theme.danger,
    .text_align = .center,

});

var setup_parts = [_]*gui.Node{ &heading, &disks, &summary, &problem, &installer };

/// Shown instead of account setup when started from installation media.
var setup = gui.box(theme.panel.with(.{

    .padding = gui.Edges.all(24),
    .gap = 14,

}), &setup_parts);

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

        disk_names[index] = gui.label("", .{

        });

        disk_states[index] = gui.label("", theme.caption);
        disk_parts[index] = .{ &disk_names[index], &disk_states[index] };

        row.* = gui.box(theme.item.with(.{

            .height = 60,
            .padding = gui.Edges.axes(0, 14),
            .direction = .column,
            .gap = 3,
            .justify = .center,
            .items = .stretch,

            .border = gui.shade(0xffffff, 16),
            .border_width = theme.border,

            .hover = gui.Paint{

                .background = gui.shade(0xffffff, 20),

            },
            .selected = gui.Paint{

                .background = gui.shade(0xffffff, 34),
                .border = theme.accent,

            },

        }), &disk_parts[index]);

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
        if (installing) finish();

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
    form.style.width = if (state == .setup and bare) wide else 320;
    if (bare) describe();

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

        // Checking a Windows volume for room reads its free-space map, which can outlast the usual second.
        const result = api.exchangeWithin(service, protocol.pack(.list, @intCast(drives)), std.mem.asBytes(&surveys[drives]), 6000) catch break;

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

    if (installing or installed) return;

    target = row.data;
    armed = false;
    notice = "";
    sync();

}

fn installable(found: protocol.Survey) bool {

    return found.placement == .empty or found.placement == .granite or found.placement == .beside;

}

/// Fills the setup panel: each disk with its size and state, what installing on the picked one does, and the button.
fn describe() void {

    const listing = drives != 0 and !installing and !installed;

    disks.hidden = !listing;

    for (&disk_rows, 0..) |*row, index| {

        row.hidden = index >= drives;
        row.selected = index == target;
        if (index >= drives) continue;

        const found = surveys[index];
        const gigabytes = found.sectors / 1953125;
        const title = if (gigabytes < 1000) std.fmt.bufPrint(&disk_titles[index], "Disk {d}  ·  {d} GB", .{ index, gigabytes }) else std.fmt.bufPrint(&disk_titles[index], "Disk {d}  ·  {d}.{d} TB", .{ index, gigabytes / 1000, gigabytes % 1000 / 100 });

        disk_names[index].content.label = title catch "";
        disk_states[index].content.label = standing(found);

    }

    const lines: [2][]const u8 = if (installed) .{

        "Installed.",
        "Remove the USB stick and restart.",

    } else if (installing) .{

        "Installing...",
        "",

    } else if (drives == 0) .{

        "No disks found.",
        "",

    } else explain(surveys[target]);

    for (&details, lines) |*line, text| {

        line.content.label = text;
        line.hidden = text.len == 0;

    }

    problem.content.label = notice;
    problem.hidden = notice.len == 0;

    installer.hidden = !listing or !installable(surveys[target]);
    if (installer.hidden) return;

    const found = surveys[target];

    installer.style = (if (armed) theme.destructive else theme.primary).with(.{

        .height = 40,

    });

    installer.content.label = if (!armed) (if (found.existing) "Install again" else "Install") else if (found.shrink) "Shrink Windows and install" else std.fmt.bufPrint(&button_label, "Erase disk {d} and install", .{target}) catch "";

}

/// A disk's state in a word or two, under its name in the list.
fn standing(found: protocol.Survey) []const u8 {

    return switch (found.placement) {

        .unreadable => "Unreadable",
        .empty => "Empty",
        .granite => "GraniteOS",
        .beside => if (found.existing) "GraniteOS installed" else if (found.shrink) "Windows" else "Free space",
        .full => switch (found.obstacle) {

            .none => "Full",
            .used => "Windows  ·  end in use",
            .hibernated => "Windows  ·  Fast Startup on",
            .dirty => "Windows  ·  needs chkdsk",
            .encrypted => "Windows  ·  BitLocker on",
            .boot => "EFI partition full",

        },

    };

}

/// What installing on a disk does, or why it cannot and the fix.
fn explain(found: protocol.Survey) [2][]const u8 {

    return switch (found.placement) {

        .unreadable => .{ "Can't read this disk.", "" },
        .empty => .{ "Erases this disk. Uses 25 GB.", "" },
        .granite => .{ "Erases GraniteOS on this disk.", "" },
        .beside => if (found.existing) .{

            "Updates GraniteOS. Files are kept.",
            "",

        } else if (found.shrink) .{

            "Takes 25 GB of free space from Windows.",
            "",

        } else .{

            std.fmt.bufPrint(&detail_bytes, "Uses {d} GB of free space.", .{@min(found.free, protocol.share) / 1953125}) catch "",
            "",

        },
        .full => switch (found.obstacle) {

            .none => .{ "No room.", "Free 25 GB in Windows first." },
            .used => .{ "End of the Windows volume is in use.", "Shrink it by 25 GB in Windows." },
            .hibernated => .{ "Windows is hibernated.", "Turn off Fast Startup, then shut down." },
            .dirty => .{ "Windows needs a disk check.", "Run chkdsk C: /f in Windows." },
            .encrypted => .{ "BitLocker is on.", "Turn it off in Windows." },
            .boot => .{ "EFI partition is full.", "Needs about 20 MB free." },

        },

    };

}

/// Starts installing on the picked disk; erasing a disk or shrinking Windows first asks for a second press.
fn install(_: *gui.Node) void {

    defer sync();

    if (drives == 0 or installed or installing or !installable(surveys[target])) return;

    const found = surveys[target];

    notice = "";

    if ((found.placement == .empty or found.placement == .granite or found.shrink) and !armed) {

        armed = true;
        return;

    }

    armed = false;
    installing = true;

}

/// Runs the install `install` started, once the screen says it has begun.
fn finish() void {

    installing = false;

    defer sync();

    const found = surveys[target];
    const mode: protocol.Mode = if (found.placement == .empty or found.placement == .granite) .erase else .beside;

    const service = api.lookup(0, .install) catch {

        notice = "Installer not running.";
        return;

    };

    const value = @as(u56, @intCast(target)) | @as(u56, @intFromEnum(mode)) << 8;
    const result = (api.checked(api.raw(.call, service, protocol.pack(.install, value), 6000)) catch {

        // A slow disk can outlast the wait; the installer answers a second question only once the install has ended.
        installed = landed(service);
        if (!installed) notice = "Install failed.";

        return;

    }).first;

    installed = result < protocol.offline;
    if (installed) return;

    notice = switch (result) {

        protocol.missing => "No room.",
        protocol.full => "EFI partition full.",
        protocol.busy => "Disk in use; not erased.",
        protocol.denied => "Administrators only.",
        protocol.empty => "Loader missing from media.",
        else => "Install failed.",

    };

    _ = landed(service);

}

/// Surveys the picked disk again, returning whether it now holds GraniteOS.
fn landed(service: u64) bool {

    var found = protocol.Survey{

    };

    const result = api.exchangeWithin(service, protocol.pack(.list, @intCast(target)), std.mem.asBytes(&found), 6000) catch return false;
    if (result != 0) return false;

    surveys[target] = found;

    return found.placement == .granite or found.existing;

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
