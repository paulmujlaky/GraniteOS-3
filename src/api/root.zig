const std = @import("std");

pub const abi = @import("abi");
pub const protocol = @import("protocol.zig");
pub const Terminal = @import("terminal.zig").Terminal;
pub const files = @import("files.zig");
pub const Files = files.Files;
pub const config = @import("config.zig");
pub const Config = config.Config;
pub const Accounts = @import("accounts.zig").Accounts;
pub const display = @import("display.zig");
pub const Display = display.Display;
pub const pages = @import("heap.zig").pages;
pub const Event = @import("event.zig").Event;
pub const Key = @import("event.zig").Key;
pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const http = @import("http.zig");
pub const metrics = @import("metrics.zig");
pub const audio = @import("audio.zig");
pub const Date = time.Date;
pub const Request = abi.Request;
pub const ApiError = error{ Denied, Invalid, Missing, Deadlock, Exhausted, Timeout, Busy };
pub const ServiceError = ApiError || error{ Exists, Full };
var environment: ?*const abi.Environment = null;

/// Makes the system call `request` describes, leaving the results in it.
pub extern fn invoke(request: *Request) callconv(.c) void;

pub const panic = std.debug.FullPanic(fatal);

pub fn start(context: *const abi.Environment, expected: abi.Layer) void {

    if (context.version != 1 or context.length > abi.permission_count or context.layer != expected) exit(97);
    environment = context;

}

pub fn permissions() []const abi.Permission {

    const context = environment orelse exit(97);

    return context.permissions[0..context.length];

}

pub fn permits(permission: abi.Permission) bool {

    for (permissions()) |entry| {

        if (entry == permission) return true;

    }

    return false;

}

pub fn raw(number: abi.Call, first: u64, second: u64, third: u64) Request {

    var request = Request{

        .number = @intFromEnum(number),
        .first = first,
        .second = second,
        .third = third,

    };

    invoke(&request);

    return request;

}

pub fn checked(request: Request) ApiError!Request {

    return switch (request.number) {

        0 => request,
        1 => error.Denied,
        3 => error.Missing,
        4 => error.Deadlock,
        5 => error.Exhausted,
        6 => error.Timeout,
        7 => error.Busy,
        else => error.Invalid,

    };

}

/// A timeout or disconnect does not guarantee the peer performed no work.
pub fn call(peer: u64, message: u64) ApiError!u64 {

    return (try checked(raw(.call, peer, message, 100))).first;

}

/// Lends `window` to the peer until it replies; the peer reads and writes it with `fetch` and `store`.
pub fn exchange(peer: u64, message: u64, window: []u8) ApiError!u64 {

    return exchangeWithin(peer, message, window, 1000);

}

/// As `exchange`, waiting up to `limit` ticks for the reply.
pub fn exchangeWithin(peer: u64, message: u64, window: []u8, limit: u64) ApiError!u64 {

    var request = Request{

        .number = @intFromEnum(abi.Call.call),
        .first = peer,
        .second = message,
        .third = limit,
        .fourth = @intFromPtr(window.ptr),
        .fifth = window.len,

    };

    invoke(&request);

    return (try checked(request)).first;

}

/// Copies from the window lent by a pending `request` into `bytes`.
pub fn fetch(request: Request, offset: u64, bytes: []u8) ApiError!void {

    try transfer(.fetch, request, offset, @intFromPtr(bytes.ptr), bytes.len);

}

/// Copies `bytes` into the window lent by a pending `request`.
pub fn store(request: Request, offset: u64, bytes: []const u8) ApiError!void {

    try transfer(.store, request, offset, @intFromPtr(bytes.ptr), bytes.len);

}

fn transfer(number: abi.Call, request: Request, offset: u64, address: u64, length: u64) ApiError!void {

    var copy = Request{

        .number = @intFromEnum(number),
        .first = request.first,
        .second = request.third,
        .third = offset,
        .fourth = address,
        .fifth = length,

    };

    invoke(&copy);
    _ = try checked(copy);

}

pub const Page = struct {

    bytes: *align(4096) [4096]u8,
    physical: u64,

};

/// Allocates a zeroed page that devices may access directly.
pub fn dma() ApiError!Page {

    const result = try checked(raw(.dma, 0, 0, 0));

    return .{

        .bytes = @ptrFromInt(result.first),
        .physical = result.second,

    };

}

/// Memory that other processes may attach once lent to them; its pages need not be physically adjacent.
pub const Shared = struct {

    handle: u64,
    bytes: []align(4096) u8,

};

pub fn share(count: usize) ApiError!Shared {

    return mapped(try checked(raw(.share, count, 0, 0)));

}

/// Lets process `peer` attach `handle`.
pub fn lend(handle: u64, peer: u64) ApiError!void {

    _ = try checked(raw(.lend, handle, peer, 0));

}

pub fn attach(handle: u64) ApiError!Shared {

    return mapped(try checked(raw(.attach, handle, 0, 0)));

}

pub fn detach(handle: u64) void {

    _ = raw(.detach, handle, 0, 0);

}

fn mapped(result: Request) Shared {

    return .{

        .handle = result.second,
        .bytes = @as([*]align(4096) u8, @ptrFromInt(result.first))[0 .. result.third * 4096],

    };

}

/// The physical address behind `address`, for drivers programming devices.
pub fn physical(address: usize) ApiError!u64 {

    return (try checked(raw(.physical, address, 0, 0))).first;

}

/// Whether process `id` still exists.
pub fn alive(id: u64) bool {

    return raw(.alive, id, 0, 0).number == 0;

}

/// Maps `size` bytes of granted device memory at `base` as one consecutive range.
pub fn map(base: u64, size: u64) ApiError![*]u8 {

    return mapAs(base, size, 0);

}

/// Maps device memory write-combined: writes may merge and reorder, so only for memory without side effects, such as a framebuffer.
pub fn combine(base: u64, size: u64) ApiError![*]u8 {

    return mapAs(base, size, 1);

}

fn mapAs(base: u64, size: u64, caching: u64) ApiError![*]u8 {

    const page = base & ~@as(u64, 4095);
    const first = (try checked(raw(.map, page, caching, 0))).first;
    var offset: u64 = 4096;

    while (offset < base + size - page) : (offset += 4096) {

        if ((try checked(raw(.map, page + offset, caching, 0))).first != first + offset) return error.Exhausted;

    }

    return @ptrFromInt(first + base % 4096);

}

pub fn in32(port: u64) ApiError!u32 {

    return @intCast((try checked(raw(.port, port, 2, 0))).first);

}

pub fn out32(port: u64, value: u32) ApiError!void {

    _ = try checked(raw(.port, port, 3, value));

}

pub fn receive(block: bool) ApiError!Request {

    return try checked(raw(.receive, if (block) 0 else 1, 0, 0));

}

/// Receives as `receive(true)` does, but gives up with `error.Timeout` after `limit` ticks, at most a minute.
pub fn within(limit: u64) ApiError!Request {

    return try checked(raw(.receive, 0, @max(limit, 1), 0));

}

pub fn reply(request: Request, message: u64) ApiError!void {

    _ = try checked(raw(.reply, request.first, request.third, message));

}

/// Replies to `request`, when its caller is still there to hear it.
pub fn answer(request: Request, message: u64) void {

    reply(request, message) catch {

    };

}

/// Exchanges `window` with a supervised service, looking it up afresh once if a restart replaced it.
pub fn query(endpoint: *u64, image: abi.Image, message: u64, window: []u8) ServiceError!u64 {

    for (0..2) |_| {

        if (endpoint.* == 0) endpoint.* = try lookup(0, image);

        const result = exchange(endpoint.*, message, window) catch |err| {

            endpoint.* = 0;
            if (err == error.Missing or err == error.Denied) continue;

            return err;

        };

        return switch (result) {

            protocol.missing => error.Missing,
            protocol.exists => error.Exists,
            protocol.full => error.Full,
            protocol.busy => error.Busy,
            protocol.denied => error.Denied,
            protocol.invalid => error.Invalid,
            else => result,

        };

    }

    return error.Missing;

}

/// Starts app `name` running as the caller, in the caller's session, handing it `detail` as its argument; returns its process id.
/// Only signed-in sessions may; the app may call the caller back.
pub fn launch(name: []const u8, detail: []const u8) ServiceError!u64 {

    var bytes: [32 + 1 + 256]u8 = undefined;
    if (name.len > 32 or detail.len > 256) return error.Invalid;

    @memcpy(bytes[0..name.len], name);
    bytes[name.len] = 0;
    @memcpy(bytes[name.len + 1 ..][0..detail.len], detail);

    const result = try exchange(0, protocol.pack(.launch, 0), bytes[0 .. name.len + 1 + detail.len]);

    try supervised(result);

    return result;

}

/// The argument this app was launched with, copied into `bytes`; empty when there is none.
pub fn argument(bytes: []u8) []const u8 {

    const length = exchange(0, protocol.pack(.argument, 0), bytes) catch return "";

    return if (length <= bytes.len) bytes[0..length] else "";

}

var session: u64 = 0;

/// Shows `title` and `detail` as a notification on the caller's desktop, such as a timer running out.
pub fn notify(title: []const u8, detail: []const u8) ServiceError!void {

    var bytes: [64 + 1 + 192]u8 = undefined;
    if (title.len > 64 or detail.len > 192) return error.Invalid;

    @memcpy(bytes[0..title.len], title);
    bytes[title.len] = 0;
    @memcpy(bytes[title.len + 1 ..][0..detail.len], detail);

    _ = try desktop(protocol.pack(.notify, 0), bytes[0 .. title.len + 1 + detail.len]);

}

/// How a snip picks what it takes: an area dragged out, a window clicked, or the whole screen at once.
pub const Snip = enum(u8) {

    region,
    window,
    screen,
    _,

};

/// Asks the caller's desktop for a snip after `delay` seconds, tucking window `surface` away meanwhile, and waits until it is
/// saved or cancelled; returns the saved picture's path, kept in `out`, or null when cancelled.
pub fn snip(kind: Snip, delay: u8, surface: u64, out: []u8) ServiceError!?[]const u8 {

    if (surface > 0xff) return error.Invalid;

    const length = try desktop(protocol.pack(.snip, @as(u56, @intCast(surface)) << 16 | @as(u56, delay) << 8 | @intFromEnum(kind)), out);

    try supervised(length);
    if (length == protocol.busy) return error.Busy;

    return if (length == 0 or length > out.len) null else out[0..length];

}

/// Puts `target`, an absolute path ending in `/` for a folder, on the caller's desktop, or takes it off.
pub fn pin(target: []const u8, on: bool) ServiceError!void {

    var bytes: [256]u8 = undefined;
    if (target.len > bytes.len) return error.Invalid;

    @memcpy(bytes[0..target.len], target);

    try supervised(try desktop(protocol.pack(.pin, @intFromBool(on)), bytes[0..target.len]));

}

/// Sends `message` and `window` to the caller's desktop, found through the supervisor on first use.
fn desktop(message: u64, window: []u8) ServiceError!u64 {

    if (session == 0) {

        const id = try call(0, protocol.pack(.session, 0));

        try supervised(id);
        session = id;

    }

    return exchange(session, message, window) catch |err| {

        session = 0;
        return err;

    };

}

/// Stops every app of the caller's session; the login process calls it on logout.
pub fn end() ServiceError!void {

    try supervised(try call(0, protocol.pack(.end, 0)));

}

/// Supervisor-only: spawns `image` as an application running as the sender of `request`, which must still await our reply.
pub fn spawn(image: abi.Image, request: Request, parent: u64) ApiError!u64 {

    var message = Request{

        .number = @intFromEnum(abi.Call.spawn),
        .first = @intFromEnum(image),
        .second = parent,
        .third = request.first,
        .fourth = request.third,

    };

    invoke(&message);

    return (try checked(message)).first;

}

fn supervised(result: u64) ServiceError!void {

    return switch (result) {

        protocol.missing => error.Missing,
        protocol.full => error.Full,
        protocol.denied => error.Denied,
        protocol.invalid => error.Invalid,
        else => {

        },

    };

}

/// The identity the kernel attached to a received message.
pub fn sender(message: Request) abi.Identity {

    return @bitCast(message.fifth);

}

/// Reads (`write` false) or writes a global firmware variable; returns the variable's size.
pub fn variable(name: []const u16, data: []u8, write: bool) ApiError!usize {

    var message = Request{

        .number = @intFromEnum(abi.Call.variable),
        .first = @intFromPtr(name.ptr),
        .second = name.len,
        .third = @intFromPtr(data.ptr),
        .fourth = data.len,
        .fifth = @intFromBool(write),

    };

    invoke(&message);

    return (try checked(message)).first;

}

/// Fills `bytes` from the CPU's hardware random generator.
pub fn random(bytes: []u8) void {

    var index: usize = 0;

    while (index < bytes.len) : (index += 8) {

        const value = std.mem.toBytes(entropy());
        const size = @min(8, bytes.len - index);

        @memcpy(bytes[index..][0..size], value[0..size]);

    }

}

fn entropy() u64 {

    for (0..10) |_| {

        var ready: u8 = undefined;

        const value = asm volatile ("rdrand %[value]; setc %[ready]" // Draw from the hardware generator.
            : [value] "=r" (-> u64),
              [ready] "=r" (ready),
        );

        if (ready != 0) return value;

    }

    @panic("Hardware random generator failed");

}

/// Services only: answers requests with `handle` until the supervisor's hello, which must come before calling any other service,
/// such as for settings, as the supervisor cannot find one for us while it waits on us. Returns the signals that arrived meanwhile.
pub fn greet(comptime handle: fn (Request) ?u64) u64 {

    var signals: u64 = 0;

    while (true) {

        const request = receive(true) catch continue;

        if (request.first == 0) {

            signals |= request.second;
            continue;

        }

        if (handle(request)) |result| answer(request, result);

        if (protocol.operation(request.second) == .hello) return signals;

    }

}

pub fn lookup(supervisor: u64, image: abi.Image) ApiError!u64 {

    const id = try call(supervisor, protocol.pack(.lookup, @intCast(@intFromEnum(image))));
    if (id == 0 or id == protocol.invalid) return error.Missing;

    return id;

}

pub fn sleep(duration: u64) void {

    _ = raw(.sleep, duration, 0, 0);

}

pub fn ticks() u64 {

    return raw(.ticks, 0, 0, 0).first;

}

/// Local time in seconds since 1970-01-01 00:00:00, or since boot when the firmware has no clock; `Date` breaks it into calendar fields.
pub fn clock() u64 {

    return raw(.clock, 0, 0, 0).first;

}

/// Fills `processes` with one record per live process, as many as fit, in no particular order; the summary says how many it wrote.
/// Reads kernel log bytes from `offset` past the oldest kept one into `buffer`; zero once past the newest.
pub fn history(offset: usize, buffer: []u8) ApiError!usize {

    return (try checked(raw(.history, @intFromPtr(buffer.ptr), offset, buffer.len))).first;

}

pub fn stats(processes: []abi.Usage) ApiError!abi.Summary {

    var summary = abi.Summary{

    };

    _ = try checked(raw(.stats, @intFromPtr(&summary), @intFromPtr(processes.ptr), processes.len));

    return summary;

}

pub fn identity() u64 {

    return raw(.identity, 0, 0, 0).first;

}

pub fn log(bytes: []const u8) void {

    _ = raw(.write, @intFromPtr(bytes.ptr), bytes.len, 0);

}

pub fn exit(status: u64) noreturn {

    _ = raw(.exit, status, 0, 0);

    while (true) asm volatile ("ud2");

}

/// Answers a service's `crash` request: faults when its owner sent it, so restarts can be tested, and refuses anyone else.
pub fn crash(request: Request) u64 {

    if (request.first != raw(.owner, 0, 0, 0).first) return protocol.invalid;

    fault();

}

/// Ends the service with an invalid instruction, as a real fault would.
pub fn fault() noreturn {

    asm volatile ("ud2");
    exit(1);

}

/// Logs a safety check's message and where it failed, for symbolizing against the image, then exits.
fn fatal(message: []const u8, address: ?usize) noreturn {

    var bytes: [160]u8 = undefined;

    log(std.fmt.bufPrint(&bytes, "panic: {s} at 0x{x}\n", .{ message[0..@min(message.len, 100)], address orelse @returnAddress() }) catch "panic\n");
    exit(98);

}
