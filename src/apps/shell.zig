const std = @import("std");

const line = @import("line.zig");
const release = @import("release.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const Error = api.ApiError || error{Usage};

const Mode = enum {

    command,
    plain,
    secret,

};

const Command = struct {

    usage: []const u8,
    description: []const u8,
    run: *const fn ([]const u8) Error!void,

    fn name(self: Command) []const u8 {

        return self.usage[0 .. std.mem.indexOfScalar(u8, self.usage, ' ') orelse self.usage.len];

    }

};

const Group = struct {

    title: []const u8,
    commands: []const Command,

};

const groups = [_]Group{

    .{

        .title = "shell",
        .commands = &.{

            command("help", "List available commands", help),
            command("about", "About GraniteOS 3", about),
            command("clear", "Clear the terminal screen", clear),
            command("echo TEXT", "Print some text back", echo),
            command("history", "List recent commands", history),

        },

    },
    .{

        .title = "accounts",
        .commands = &.{

            command("whoami", "Print the logged-in account", whoami),
            command("users", "List accounts", users),
            command("useradd NAME [admin]", "Create an account (administrators)", useradd),
            command("userdel NAME", "Remove an account (administrators)", userdel),
            command("passwd [NAME]", "Change a password", passwd),
            command("lock", "Lock the terminal until your password is entered", lock),
            command("logout", "End this session", logout),

        },

    },
    .{

        .title = "system",
        .commands = &.{

            command("id", "Print this process' identity", id),
            command("date", "Print the local date and time", date),
            command("uptime", "Time since boot", uptime),
            command("permissions", "List this process' permissions", permissions),
            command("services", "List running services", services),
            command("ps", "List processes with their memory and processor use", ps),
            command("log", "Show the kernel and service log (administrators)", log),
            command("display [WIDTHxHEIGHT]", "Show or set the screen mode (administrators)", display),
            command("install", "Install GraniteOS beside the existing OS", install),
            command("reboot", "Restart the machine", reboot),
            command("shutdown", "Power off the machine", shutdown),

        },

    },
    .{

        .title = "services",
        .commands = &.{

            command("hello", "Call the helper service", hello),
            command("crash NAME", "Crash a service (administrators)", crash),
            command("restart NAME", "Restart a service (administrators)", restart),

        },

    },
    .{

        .title = "files",
        .commands = &.{

            command("ls [PATH]", "List a directory", ls),
            command("cd [PATH]", "Change the working directory", cd),
            command("cat PATH", "Print a file", cat),
            command("write PATH TEXT", "Replace a file with a line of text", write),
            command("mkdir PATH", "Create a directory", mkdir),
            command("rm PATH", "Remove a file or empty directory", rm),
            command("chmod MODE PATH", "Set owner and other permissions (octal)", chmod),
            command("volume", "Show volume capacity and free space", volume),

        },

    },
    .{

        .title = "network",
        .commands = &.{

            command("ping HOST", "Send a host four echo requests", ping),
            command("lookup NAME", "Find the address a name stands for", lookup),
            command("get URL [PATH]", "Download over HTTP or HTTPS into a file", get),

        },

    },
    .{

        .title = "sound",
        .commands = &.{

            command("sound [PERCENT|mute|unmute]", "Show the output, or set the volume", sound),
            command("tone [HERTZ]", "Play a two-second test tone", tone),

        },

    },

};

var terminal: api.Terminal = undefined;

var files = api.Files{

};

var accounts = api.Accounts{

};

var cwd: [200]u8 = undefined;
var cwd_length: usize = 1;
var target: [line.capacity + cwd.len]u8 = undefined;

var editor = line.Line{

};

var shown: []const u8 = "";
var mode: Mode = .command;

var user: [32]u8 = undefined;
var user_length: usize = 0;
var active = false;

var owner_id: u32 = 0;
var owner_name: [32]u8 = undefined;
var owner_length: usize = 0;

var served: u64 = 0;

pub export fn app_main(parent: usize, supervisor: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    terminal = .{

        .supervisor = supervisor,

    };

    // A graphical terminal launches us into its session with the home folder as our argument; the supervisor starts the serial shell with none.
    var home_bytes: [256]u8 = undefined;
    const home = api.argument(&home_bytes);

    if (home.len != 0) {

        terminal.host = parent;
        adopt(home);
        session();
        api.exit(0);

    }

    while (true) {

        terminal.write("\nOBSIDIAN ......... Ready\n") catch {

            api.sleep(10);
            continue;

        };

        break;

    }

    while (true) {

        login();
        session();

    }

}

fn command(usage: []const u8, description: []const u8, run: *const fn ([]const u8) Error!void) Command {

    return .{

        .usage = usage,
        .description = description,
        .run = run,

    };

}

fn serve() void {

    const request = api.receive(false) catch return;

    served += 1;
    const result = if (protocol.operation(request.second) == .ping) served else protocol.invalid;

    api.answer(request, result);

}

/// Takes on the desktop session we were launched into: its user already signed in, starting in `home`.
fn adopt(home: []const u8) void {

    const name = std.fs.path.basename(home);

    user_length = @min(name.len, user.len);
    @memcpy(user[0..user_length], name[0..user_length]);
    cwd_length = @min(home.len, cwd.len);
    @memcpy(cwd[0..cwd_length], home[0..cwd_length]);
    say("OBSIDIAN on GraniteOS 3. Type 'help' for available commands.\n\n", .{});

}

// Runs as nobody until a login succeeds; with no accounts at all, setup proceeds as nobody.
fn login() void {

    user_length = 0;
    cwd_length = 1;
    cwd[0] = '/';

    while (true) {

        const first = accounts.list(0) catch {

            api.sleep(50);
            continue;

        };

        if (first == null) {

            show("\nNo accounts exist yet. Create the administrator with 'useradd NAME'.\n");
            _ = files.usage() catch |err| if (err == error.Missing) show("No GraniteOS volume was found; run 'install' first.\n");
            show("Type 'help' for available commands.\n\n");

            return;

        }

        var name: [line.capacity]u8 = undefined;
        var secret: [line.capacity]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret);

        show("\n");

        const entered = ask("login: ", .plain, &name);
        if (entered.len == 0 or entered.len > user.len) continue;

        const password = ask("password: ", .secret, &secret);

        _ = accounts.login(entered, password) catch |err| {

            show(if (err == error.Denied) "Login incorrect.\n" else "Accounts service unavailable.\n");
            continue;

        };

        @memcpy(user[0..entered.len], entered);
        user_length = entered.len;

        const home = std.fmt.bufPrint(&cwd, "/home/{s}", .{entered}) catch unreachable;

        cwd_length = home.len;
        say("\nWelcome, {s}. Type 'help' for available commands.\n\n", .{entered});

        return;

    }

}

fn session() void {

    active = true;

    while (active) {

        var label: [cwd.len + 16]u8 = undefined;
        var text: [line.capacity]u8 = undefined;
        const prompt = std.fmt.bufPrint(&label, "obsidian [{s}]> ", .{cwd[0..cwd_length]}) catch unreachable;

        execute(std.mem.trim(u8, ask(prompt, .command, &text), " "));

    }

}

// Edits one line after `prompt` into `out`; secret lines are never echoed or recorded.
fn ask(prompt: []const u8, kind: Mode, out: []u8) []const u8 {

    mode = kind;
    shown = prompt;
    editor.reset();
    editor.record = kind == .command;
    show(prompt);

    while (true) {

        switch (editor.push(next())) {

            .none => {

            },
            .submit => break,
            .cancel => {

                show("^C\n");
                show(prompt);

            },
            .clear => {

                show("\x1b[2J\x1b[H");
                redraw();

            },
            .bell => show("\x07"),
            .echo => if (kind != .secret) show(editor.text()[editor.len - 1 ..]),
            .erase => if (kind != .secret) show("\x08 \x08"),
            .redraw => redraw(),
            .complete => if (kind == .command) complete() else show("\x07"),

        }

    }

    show("\n");

    const length = @min(editor.len, out.len);

    @memcpy(out[0..length], editor.text()[0..length]);
    if (kind == .secret) std.crypto.secureZero(u8, &editor.bytes);
    editor.reset();

    return out[0..length];

}

fn next() u8 {

    while (true) {

        serve();

        // A graphical terminal holds our read until a key arrives; once its window closes, we go too.
        const byte = terminal.read() catch |err| if (terminal.host != 0 and err == error.Missing) api.exit(0) else null;

        if (byte) |value| return value;
        if (terminal.host == 0) api.sleep(1);

    }

}

fn show(bytes: []const u8) void {

    terminal.write(bytes) catch {

    };

}

fn say(comptime format: []const u8, arguments: anytype) void {

    terminal.print(format, arguments) catch {

    };

}

fn redraw() void {

    const text = if (mode == .secret) "" else editor.text();

    if (mode == .secret or editor.cursor == editor.len) return say("\r{s}{s}\x1b[K", .{ shown, text });

    say("\r{s}{s}\x1b[K\x1b[{d}D", .{ shown, text, editor.len - editor.cursor });

}

fn complete() void {

    const prefix = editor.text()[0..editor.cursor];
    if (std.mem.indexOfScalar(u8, prefix, ' ') != null) return show("\x07");

    var first: ?[]const u8 = null;
    var shared: usize = 0;
    var matches: usize = 0;

    for (groups) |group| {

        for (group.commands) |entry| {

            const candidate = entry.name();
            if (!std.mem.startsWith(u8, candidate, prefix)) continue;

            if (first) |match| {

                shared = std.mem.indexOfDiff(u8, match[0..shared], candidate) orelse shared;

            } else {

                first = candidate;
                shared = candidate.len;

            }

            matches += 1;

        }

    }

    const match = first orelse return show("\x07");

    if (matches == 1) {

        _ = editor.insert(match[prefix.len..]);
        _ = editor.insert(" ");
        return redraw();

    }

    if (shared > prefix.len) {

        _ = editor.insert(match[prefix.len..shared]);
        return redraw();

    }

    show("\n");

    for (groups) |group| {

        for (group.commands) |entry| {

            if (std.mem.startsWith(u8, entry.name(), prefix)) say("{s}  ", .{entry.name()});

        }

    }

    show("\n");
    redraw();

}

fn execute(text: []const u8) void {

    if (text.len == 0) return;

    const split = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const name = text[0..split];
    const argument = std.mem.trim(u8, text[split..], " ");

    for (groups) |group| {

        for (group.commands) |entry| {

            if (!std.mem.eql(u8, entry.name(), name)) continue;

            const takes = entry.name().len != entry.usage.len;
            const result = if (!takes and argument.len != 0) error.Usage else entry.run(argument);

            result catch |err| {

                if (err == error.Usage) say("usage: {s}\n", .{entry.usage});

            };

            return;

        }

    }

    say("obsidian: {s}: command not found\n", .{name});

}

fn help(_: []const u8) Error!void {

    try terminal.write("\nGraniteOS 3 - Available Commands\n\n");

    for (groups) |group| {

        try terminal.print("{s}\n", .{group.title});
        for (group.commands) |entry| try terminal.print("  {s:<22}{s}\n", .{ entry.usage, entry.description });
        try terminal.write("\n");

    }

}

fn about(_: []const u8) Error!void {

    try terminal.write(
        \\
        \\   ______                 _ __       ____  _____    _____
        \\  / ____/________ _____  (_) /____  / __ \/ ___/   |__  /
        \\ / / __/ ___/ __ `/ __ \/ / __/ _ \/ / / /\__ \     /_ <
        \\/ /_/ / /  / /_/ / / / / / /_/  __/ /_/ /___/ /   ___/ /
        \\\____/_/   \__,_/_/ /_/_/\__/\___/\____//____/   /____/
        \\
        \\
    );

    try terminal.print("{s}\n\nFeatures:\n", .{release.tagline});

    for (release.features) |feature| try terminal.print("  - {s}\n", .{feature});

    try terminal.write("\nType 'help' to see available commands.\n\n");

}

fn clear(_: []const u8) Error!void {

    try terminal.write("\x1b[2J\x1b[H");

}

fn echo(argument: []const u8) Error!void {

    try terminal.print("{s}\n", .{argument});

}

fn history(_: []const u8) Error!void {

    var step = @min(editor.total, editor.history.len);

    while (step > 0) : (step -= 1) {

        try terminal.print("  {d:>3}  {s}\n", .{ editor.total - step + 1, editor.recalled(step).? });

    }

}

fn whoami(_: []const u8) Error!void {

    try terminal.print("{s}\n", .{if (user_length == 0) "nobody" else user[0..user_length]});

}

fn users(_: []const u8) Error!void {

    var index: u56 = 0;

    while (accounts.list(index) catch |err| return report("users", err)) |account| : (index += 1) {

        try terminal.print("  {s:<16}{d:<8}{s}\n", .{ account.name, account.identity.user, if (account.identity.admin) "admin" else "" });

    }

}

fn useradd(argument: []const u8) Error!void {

    var words = std.mem.tokenizeScalar(u8, argument, ' ');
    const name = words.next() orelse return error.Usage;
    const flag = words.next();

    if (words.next() != null or (flag != null and !std.mem.eql(u8, flag.?, "admin"))) return error.Usage;

    var password: [line.capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &password);

    const secret = choose(&password) orelse return;

    accounts.create(name, secret, flag != null) catch |err| return report("useradd", err);
    try terminal.print("useradd: created {s}\n", .{name});

    if (user_length == 0) {

        try terminal.write("Log in to continue.\n");
        active = false;

    }

}

fn userdel(argument: []const u8) Error!void {

    if (argument.len == 0 or std.mem.indexOfScalar(u8, argument, ' ') != null) return error.Usage;

    accounts.remove(argument) catch |err| {

        return if (err == error.Busy) terminal.write("userdel: cannot remove your own account\n") else report("userdel", err);

    };

}

fn passwd(argument: []const u8) Error!void {

    const own = user[0..user_length];
    const name = if (argument.len == 0) own else argument;

    if (name.len == 0 or std.mem.indexOfScalar(u8, name, ' ') != null) return error.Usage;

    var current: [line.capacity]u8 = undefined;
    var password: [line.capacity]u8 = undefined;

    defer std.crypto.secureZero(u8, &current);
    defer std.crypto.secureZero(u8, &password);

    const old = if (std.mem.eql(u8, name, own)) ask("current password: ", .secret, &current) else "";
    const new = choose(&password) orelse return;

    accounts.password(name, new, old) catch |err| return report("passwd", err);
    try terminal.write("passwd: password updated\n");

}

// Asks for a new password twice; null when the entries are empty or differ.
fn choose(out: []u8) ?[]const u8 {

    var again: [line.capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &again);

    const first = ask("new password: ", .secret, out);
    const second = ask("confirm password: ", .secret, &again);

    if (first.len != 0 and std.mem.eql(u8, first, second)) return first;
    show("passwords are empty or do not match\n");

    return null;

}

fn lock(_: []const u8) Error!void {

    if (user_length == 0) return terminal.write("lock: nobody is logged in\n");
    if (terminal.host != 0) return terminal.write("lock: lock the desktop with Super+L\n");

    show("\x1b[2J\x1b[H");

    // Terminal failures must never fall through to an unlocked shell.
    while (true) {

        var secret: [line.capacity]u8 = undefined;
        defer std.crypto.secureZero(u8, &secret);

        say("Locked by {s}.\n", .{user[0..user_length]});

        const password = ask("password: ", .secret, &secret);

        if (accounts.login(user[0..user_length], password)) |_| return else |_| show("Incorrect password.\n\n");

    }

}

fn logout(_: []const u8) Error!void {

    // In a graphical terminal this only ends the shell; the desktop session goes on.
    if (user_length != 0 and terminal.host == 0) accounts.logout() catch |err| return report("logout", err);
    active = false;

}

fn id(_: []const u8) Error!void {

    try terminal.print("{d}\n", .{api.identity()});

}

fn date(_: []const u8) Error!void {

    const now = api.Date.init(api.clock());

    try terminal.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{ now.year, now.month, now.day, now.hour, now.minute, now.second });

}

fn uptime(_: []const u8) Error!void {

    const ticks = api.ticks();
    try terminal.print("{d}.{d:0>2} seconds\n", .{ ticks / 100, ticks % 100 });

}

fn log(_: []const u8) Error!void {

    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;

    while (true) {

        const count = api.history(offset, &buffer) catch return terminal.write("log: administrators only\n");
        if (count == 0) break;

        try terminal.write(buffer[0..count]);
        offset += count;

    }

}

fn permissions(_: []const u8) Error!void {

    for (api.permissions()) |permission| try terminal.print("{s}\n", .{@tagName(permission)});

}

fn services(_: []const u8) Error!void {

    for ([_]api.abi.Image{ .serial, .helper, .storage, .files, .accounts, .install, .input, .display, .audio, .shell }) |image| {

        const peer = api.lookup(terminal.supervisor, image) catch {

            try terminal.print("  {s:<10}unavailable\n", .{@tagName(image)});
            continue;

        };

        try terminal.print("  {s:<10}{d}\n", .{ @tagName(image), peer });

    }

}

fn ps(_: []const u8) Error!void {

    var records: [64]api.abi.Usage = undefined;
    const summary = api.stats(&records) catch |err| return report("ps", err);
    const listed = records[0..summary.records];

    // Block sort would want a 32 KiB cache on this 16 KiB stack.
    std.sort.insertion(api.abi.Usage, listed, {}, earlier);
    try terminal.write("  ID    IMAGE     USER      STATE          MEMORY         CPU\n");

    for (listed) |record| {

        const image = if (std.enums.fromInt(api.abi.Image, record.image)) |known| @tagName(known) else "-";

        try terminal.print("  {d:<6}{s:<10}{s:<10}{s:<10}{d:>7} KiB{d:>7}.{d:0>2} s\n", .{ record.id, image, owner(record.identity.user), @tagName(record.state), record.pages * 4, record.ticks / 100, record.ticks % 100 });

    }

    const used = (summary.pages - summary.free) * 4;
    const busy = summary.busy * 100 / @max(summary.busy + summary.idle, 1);

    try terminal.print("{d} processes; {d} of {d} KiB memory in use; {d} processors {d}% busy since boot\n", .{ summary.processes, used, summary.pages * 4, summary.processors, busy });

}

fn earlier(_: void, left: api.abi.Usage, right: api.abi.Usage) bool {

    return left.id < right.id;

}

fn display(argument: []const u8) Error!void {

    var screen = api.Display{};

    if (argument.len == 0) {

        const size = screen.size() catch |err| return report("display", err);

        return terminal.print("{d}x{d}\n", .{ size.width, size.height });

    }

    const split = std.mem.indexOfScalar(u8, argument, 'x') orelse return error.Usage;
    const width = std.fmt.parseInt(u16, argument[0..split], 10) catch return error.Usage;
    const height = std.fmt.parseInt(u16, argument[split + 1 ..], 10) catch return error.Usage;

    screen.mode(width, height) catch |err| return report("display", err);

}

fn install(_: []const u8) Error!void {

    const installer = api.lookup(terminal.supervisor, .install) catch return terminal.write("install: installer unavailable\n");

    try terminal.write("install: copying GraniteOS beside the existing OS\n");

    const result = (api.checked(api.raw(.call, installer, protocol.pack(.install, 0), 6000)) catch return terminal.write("install: installer disconnected\n")).first;

    try terminal.write(switch (result) {

        protocol.denied => "install: administrators only\n",
        protocol.missing => "install: no GPT disk with an EFI system partition and 64 MiB free\n",
        protocol.empty => "install: the boot file is unavailable on this media\n",
        protocol.invalid => "install: failed\n",
        else => return terminal.print("install: installed to disk {d}; boot entry Boot{X:0>4}\n", .{ result & 0xff, result >> 8 }),

    });

}

fn reboot(_: []const u8) Error!void {

    try power(0, "reboot: restarting\n");

}

fn shutdown(_: []const u8) Error!void {

    try power(1, "shutdown: powering off\n");

}

fn power(value: u56, message: []const u8) Error!void {

    try terminal.write(message);

    const result = try api.call(terminal.supervisor, protocol.pack(.power, value));
    try terminal.write(if (result == protocol.denied) "power: log in first\n" else "power: not supported by this machine\n");

}

fn hello(_: []const u8) Error!void {

    const helper = api.lookup(terminal.supervisor, .helper) catch return terminal.write("hello: helper unavailable\n");
    const value = api.call(helper, protocol.pack(.ping, 41)) catch return terminal.write("hello: helper disconnected\n");

    try terminal.print("{d}\n", .{value});

}

fn crash(argument: []const u8) Error!void {

    try control(.crash, argument);

}

fn restart(argument: []const u8) Error!void {

    try control(.restart, argument);

}

fn control(operation: protocol.Operation, argument: []const u8) Error!void {

    const image = std.meta.stringToEnum(api.abi.Image, argument) orelse return error.Usage;
    if (image == .shell or image == .client) return error.Usage;

    const result = try api.call(terminal.supervisor, protocol.pack(operation, @intCast(@intFromEnum(image))));
    try terminal.print("{s}: {s}\n", .{ argument, if (result == 0) "stopped; supervisor will recover it" else "request denied" });

}

fn ls(argument: []const u8) Error!void {

    const path = try resolve(argument);
    var entries: [32]api.files.Entry = undefined;
    var index: u56 = 0;

    while (true) {

        const count = files.list(path, index, &entries) catch |err| return report("ls", err);
        if (count == 0) return;

        for (entries[0..count]) |entry| {

            var bits: [9]u8 = undefined;

            for (&bits, 0..) |*bit, position| bit.* = if (entry.mode >> @intCast(8 - position) & 1 != 0) "rwx"[position % 3] else '-';

            try terminal.print("{c}{s} {s:<10}", .{ @as(u8, if (entry.kind == .directory) 'd' else '-'), &bits, owner(entry.owner) });

            if (entry.kind == .directory) {

                try terminal.print("{s:>12}  {s}/\n", .{ "-", entry.name });

            } else {

                try terminal.print("{d:>12}  {s}\n", .{ entry.size, entry.name });

            }

        }

        index += @intCast(count);

    }

}

// Names the account owning a file or process, remembering the last answer since listings repeat owners.
fn owner(user_id: u32) []const u8 {

    if (user_id == 0) return "system";
    if (user_id == api.abi.nobody.user) return "nobody";
    if (owner_length != 0 and owner_id == user_id) return owner_name[0..owner_length];

    var index: u56 = 0;

    while (accounts.list(index) catch null) |account| : (index += 1) {

        if (account.identity.user != user_id) continue;

        owner_id = user_id;
        owner_length = @min(account.name.len, owner_name.len);
        @memcpy(owner_name[0..owner_length], account.name[0..owner_length]);

        return owner_name[0..owner_length];

    }

    return "unknown";

}

fn cd(argument: []const u8) Error!void {

    const path = try resolve(argument);
    var entries: [1]api.files.Entry = undefined;

    if (path.len > cwd.len) return terminal.write("cd: path too long\n");
    _ = files.list(path, 0, &entries) catch |err| return report("cd", err);

    @memcpy(cwd[0..path.len], path);
    cwd_length = path.len;

}

fn cat(argument: []const u8) Error!void {

    if (argument.len == 0) return error.Usage;

    const path = try resolve(argument);
    var offset: u56 = 0;
    var last: u8 = '\n';

    while (true) {

        const bytes = files.read(path, offset, files.window.len) catch |err| return report("cat", err);
        if (bytes.len == 0) break;

        try terminal.write(bytes);
        last = bytes[bytes.len - 1];
        offset += @intCast(bytes.len);

    }

    if (last != '\n') try terminal.write("\n");

}

fn write(argument: []const u8) Error!void {

    const split = std.mem.indexOfScalar(u8, argument, ' ') orelse return error.Usage;
    const path = try resolve(argument[0..split]);
    const body = std.mem.trimLeft(u8, argument[split..], " ");
    var text: [line.capacity + 1]u8 = undefined;

    @memcpy(text[0..body.len], body);
    text[body.len] = '\n';

    files.create(path) catch |err| return report("write", err);
    files.write(path, 0, text[0 .. body.len + 1]) catch |err| return report("write", err);

}

fn mkdir(argument: []const u8) Error!void {

    if (argument.len == 0) return error.Usage;
    files.directory(try resolve(argument)) catch |err| return report("mkdir", err);

}

fn rm(argument: []const u8) Error!void {

    if (argument.len == 0) return error.Usage;
    files.remove(try resolve(argument)) catch |err| return report("rm", err);

}

fn chmod(argument: []const u8) Error!void {

    const split = std.mem.indexOfScalar(u8, argument, ' ') orelse return error.Usage;
    const bits = std.fmt.parseInt(u16, argument[0..split], 8) catch return error.Usage;

    if (bits > 0o777) return error.Usage;
    files.change(try resolve(std.mem.trimLeft(u8, argument[split..], " ")), bits, null) catch |err| return report("chmod", err);

}

fn volume(_: []const u8) Error!void {

    const usage = files.usage() catch |err| return report("volume", err);

    try terminal.print("{d} KiB total, {d} KiB free\n", .{ usage.total / 1024, usage.free / 1024 });

}

fn report(name: []const u8, err: api.ServiceError) Error!void {

    const reason = switch (err) {

        error.Missing => "not found",
        error.Exists => "already exists",
        error.Full => "volume full",
        error.Busy => "directory not empty",
        error.Denied => "permission denied",
        error.Invalid => "invalid argument",
        else => "service unavailable",

    };

    try terminal.print("{s}: {s}\n", .{ name, reason });

}

/// Reports why a network command failed.
fn fail(name: []const u8, err: api.http.HttpError) Error!void {

    try terminal.print("{s}: {s}\n", .{ name, api.http.reason(err) });

}

fn ping(argument: []const u8) Error!void {

    if (argument.len == 0) return error.Usage;

    const address = api.net.resolve(argument) catch |err| return fail("ping", err);

    try terminal.print("Pinging {s} ({f})\n", .{ argument, address });

    for (0..4) |round| {

        if (round != 0) api.sleep(100);

        const time = api.net.echo(address) catch |err| {

            try fail("ping", err);
            continue;

        };

        try terminal.print("Reply from {f}: {d}.{d:0>2} ms\n", .{ address, time / 1000, time % 1000 / 10 });

    }

}

fn lookup(argument: []const u8) Error!void {

    if (argument.len == 0) return error.Usage;

    const address = api.net.resolve(argument) catch |err| return fail("lookup", err);

    try terminal.print("{s} is {f}\n", .{ argument, address });

}

/// Downloads a URL into a file, named after the URL's last path part unless given.
fn get(argument: []const u8) Error!void {

    const split = std.mem.indexOfScalar(u8, argument, ' ') orelse argument.len;
    const url = argument[0..split];
    const parsed = api.http.Url.parse(url) orelse return error.Usage;
    const given = std.mem.trim(u8, argument[split..], " ");
    const named = std.fs.path.basenamePosix(parsed.target[0 .. std.mem.indexOfScalar(u8, parsed.target, '?') orelse parsed.target.len]);
    const path = try resolve(if (given.len != 0) given else if (named.len != 0) named else "index.html");

    var body = std.Io.Writer.Allocating.init(api.pages);

    defer body.deinit();

    const code = api.http.get(api.pages, url, &body.writer) catch |err| return fail("get", err);

    if (code < 200 or code >= 300) return terminal.print("get: the server answered {d}\n", .{code});

    files.save(api.pages, path, body.written()) catch |err| return report("get", err);
    try terminal.print("Saved {d} bytes to {s}\n", .{ body.written().len, path });

}

fn sound(argument: []const u8) Error!void {

    if (std.mem.eql(u8, argument, "mute") or std.mem.eql(u8, argument, "unmute")) {

        return api.audio.mute(argument[0] == 'm') catch |err| report("sound", err);

    }

    if (argument.len != 0) {

        const percent = std.fmt.parseInt(u8, argument, 10) catch return error.Usage;

        if (percent > 100) return error.Usage;

        return api.audio.volume(percent) catch |err| report("sound", err);

    }

    const state = api.audio.status() catch |err| return report("sound", err);
    var name: [32]u8 = undefined;

    try terminal.print("{s}, {s}, {d} outputs\n", .{ state.adapter(), state.chip(&name), state.outputs });
    try terminal.print("Volume {d}%{s}, system sounds {s}\n", .{ state.volume, if (state.muted) " (muted)" else "", if (state.sounds) "on" else "off" });
    try terminal.print("{d} streams, {d} ms latency, {d} underruns\n", .{ state.streams, state.latency * 1000 / state.rate, state.underruns });

}

/// Plays a sine at 44.1 kHz, which the audio service resamples, fading in and out so it starts and ends without a click.
fn tone(argument: []const u8) Error!void {

    const rate = 44100;
    const hertz: f32 = if (argument.len == 0) 440 else std.fmt.parseFloat(f32, argument) catch return error.Usage;

    if (hertz < 20 or hertz > 20000) return error.Usage;

    var stream = api.audio.Stream.open(.{ .rate = rate, .channels = 1 }, rate / 4) catch |err| return report("tone", err);

    defer stream.close();

    var chunk: [1024]i16 = undefined;
    var frame: usize = 0;
    const total = 2 * rate;

    while (frame < total) {

        const count = @min(chunk.len, total - frame);

        for (chunk[0..count], frame..) |*sample, index| {

            const t = @as(f32, @floatFromInt(index)) / rate;
            const edge = @min(@min(t, 2 - t) / 0.02, 1);

            sample.* = @intFromFloat(edge * 8000 * @sin(std.math.tau * hertz * t));

        }

        stream.send(i16, chunk[0..count]) catch |err| return report("tone", err);
        frame += count;

    }

    stream.wait(true) catch |err| return report("tone", err);
    try terminal.print("Played {d} frames, {d} underruns\n", .{ stream.position(), stream.header.underruns });

}

/// Joins `argument` onto the working directory, folding `.` and `..`.
fn resolve(argument: []const u8) Error![]const u8 {

    const relative = argument.len == 0 or argument[0] != '/';
    var length: usize = 0;

    for ([_][]const u8{ if (relative) cwd[0..cwd_length] else "", argument }) |source| {

        var parts = std.mem.tokenizeScalar(u8, source, '/');

        while (parts.next()) |part| {

            if (std.mem.eql(u8, part, ".")) continue;

            if (std.mem.eql(u8, part, "..")) {

                length = std.mem.lastIndexOfScalar(u8, target[0..length], '/') orelse 0;
                continue;

            }

            if (length + 1 + part.len > target.len) return error.Usage;

            target[length] = '/';
            @memcpy(target[length + 1 ..][0..part.len], part);
            length += 1 + part.len;

        }

    }

    return if (length == 0) "/" else target[0..length];

}
