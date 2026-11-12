//! The network stack: the Ethernet controller, ARP, IPv4 with DHCP or a manual address, ICMP echoes, UDP, TCP, DNS
//! names, and the clock from SNTP. Apps granted `network` reach it, and each socket answers only the process that
//! opened it.

const std = @import("std");

const e1000 = @import("e1000.zig");
const wire = @import("wire.zig");
const tcp = @import("tcp.zig");
const dhcp = @import("dhcp.zig");
const dns = @import("dns.zig");

const api = @import("api");

const protocol = api.protocol;
const net = api.net;
pub const panic = api.panic;

/// Mozilla's trusted certificate authorities, which apps fetch for HTTPS.
const roots = @embedFile("roots.pem");

/// Sockets in all, and per process.
const most = 64;
const allowance = 16;

/// Bytes each TCP connection buffers each way, and a UDP socket keeps of datagrams.
const window = 64 * 1024;
const datagrams = 16 * 1024;

/// Ticks a request waits on the network before it is answered anyway, well inside its caller's own timeout.
const patience = 800;

/// Ticks a hasty read or write waits, for apps that keep painting between waits.
const brief = 5;

/// The largest TCP segment we take, filling one Ethernet frame.
const mss = wire.mtu - wire.ip_length - wire.tcp_length;

/// Ports our own DNS and SNTP clients send from, which apps may not listen on.
const resolver_port = 40053;
const clock_port = 40123;
const ephemeral = 49152;

/// How often the clock is set again once SNTP answered, and retried while it has not.
const clock_period = 6 * 60 * 60 * 100;
const clock_retry = 60 * 100;

const clock_server = "pool.ntp.org";

const Kind = enum {

    free,
    tcp,
    udp,
    listener,

};

/// What a deferred request waits for.
const Wait = enum {

    none,
    connect,
    read,
    write,
    accept,

};

const Socket = struct {

    kind: Kind = .free,
    generation: u32 = 0,

    /// The process that opened it, and its user; a connection to a listener belongs to the listener's process.
    owner: u64 = 0,
    user: u32 = 0,

    /// The app let it go; a TCP connection lingers until it finishes closing.
    released: bool = false,

    /// Accepted by its listener but not yet handed to the app, and which listener that is.
    pending: bool = false,
    listener: usize = 0,

    remote: u32 = 0,
    local_port: u16 = 0,
    remote_port: u16 = 0,

    connection: tcp.Connection = .{},

    /// Received datagrams, each a big-endian length then its bytes.
    inbox: tcp.Ring = .{},

    memory: []u8 = &.{},

    /// The request waiting on it, and when it is answered regardless.
    waiter: api.Request = undefined,
    wait: Wait = .none,
    until: u64 = 0,

    fn handle(self: *const Socket) u64 {

        return @as(u64, self.generation) << 8 | index(self);

    }

    fn open(self: *const Socket) bool {

        return self.kind != .free and !self.released and !self.pending;

    }

};

/// A neighbour on the link, by IPv4 address.
const Neighbour = struct {

    address: u32 = 0,
    mac: wire.Mac = undefined,
    known: bool = false,
    asked: u64 = 0,
    tries: u8 = 0,
    used: u64 = 0,

};

/// A packet held until its next hop's address resolves.
const Held = struct {

    hop: u32 = 0,
    length: usize = 0,
    bytes: [wire.mtu]u8 = undefined,

};

const Purpose = enum {

    free,
    echo,
    resolve,
    clock,

};

/// An echo or name lookup in flight: for a waiting app, or for setting the clock.
const Query = struct {

    purpose: Purpose = .free,
    waiter: ?api.Request = null,
    target: u32 = 0,
    id: u16 = 0,
    name: [253]u8 = undefined,
    length: usize = 0,
    sent: u64 = 0,
    stamp: u64 = 0,
    tries: u8 = 0,
    until: u64 = 0,

    fn named(self: *const Query) []const u8 {

        return self.name[0..self.length];

    }

};

const Cached = struct {

    name: [253]u8 = undefined,
    length: usize = 0,
    address: u32 = 0,
    expires: u64 = 0,

};

const Phase = enum {

    idle,
    selecting,
    requesting,
    bound,
    renewing,

};

var nic: e1000.Nic = undefined;
var device: u32 = 0;
var signal: u64 = 0;
var speed: u32 = 0;

var source = net.Source.none;
var address: u32 = 0;
var mask: u32 = 0;
var gateway: u32 = 0;
var server: u32 = 0;
var manual = net.Setting{};

/// Turned off for everyone, as any signed-in user may: nothing is sent or received.
var off = false;

var received: u64 = 0;
var sent: u64 = 0;
var identifier: u16 = 0;
var next_port: u16 = ephemeral;

/// UTC seconds since 1970 at tick `synced`, once SNTP answered.
var utc: u64 = 0;
var synced: u64 = 0;
var clock_due: u64 = 0;

/// The DHCP client: where it stands, its transaction, the offer it takes, and when it acts next.
var phase = Phase.idle;
var xid: u32 = 0;
var offered: u32 = 0;
var offerer: u32 = 0;
var lease_due: u64 = 0;
var expires: u64 = 0;

/// The time-stamp counter's start, for timing echoes finer than a tick.
var stamp_start: u64 = 0;
var tick_start: u64 = 0;

var sockets = [_]Socket{.{}} ** most;
var neighbours = [_]Neighbour{.{}} ** 16;
var held = [_]Held{.{}} ** 8;
var queries = [_]Query{.{}} ** 16;
var cache = [_]Cached{.{}} ** 16;

/// Where outgoing packets are put together: an IPv4 header, then its payload.
var scratch: [wire.mtu]u8 = undefined;

var configuration = api.Config{};

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.dma) or api.permits(.ports) or api.permits(.management)) api.exit(2);

    const registers = environment.bars[0];

    device = environment.device;
    signal = environment.signal;

    nic.init(registers.base, registers.size) catch {

        api.log("net: the Ethernet controller did not start\n");
        api.exit(3);

    };

    var line: [96]u8 = undefined;

    api.log(std.fmt.bufPrint(&line, "net: {s} ready, {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}{s}\n", .{

        (net.Status{ .device = device }).adapter(),
        nic.mac[0], nic.mac[1], nic.mac[2], nic.mac[3], nic.mac[4], nic.mac[5],
        if (signal == 0) ", polled" else "",

    }) catch "net: ready\n");

    stamp_start = stamp();
    tick_start = api.ticks();

    const signals = api.greet(handle);

    load();
    link();
    if (signals & signal != 0) arrive();

    while (true) {

        const now = api.ticks();

        // Without interrupts, the controller is polled every tick.
        const limit = if (signal == 0) 1 else @max(soonest(now) -| now, 1);

        const request = api.within(@min(limit, 100)) catch {

            if (signal == 0) arrive();
            maintain();
            continue;

        };

        if (request.first == 0) {

            if (request.second & signal != 0) arrive();

        } else if (handle(request)) |result| {

            api.answer(request, result);

        }

        maintain();

    }

}

/// Takes in what the controller received, and notices the link coming and going.
fn arrive() void {

    if (nic.acknowledge() or speed == 0) link();
    nic.receive({}, frame);

}

fn link() void {

    const now = nic.speed();

    if (now == speed) return;

    speed = now;
    api.log(if (speed == 0) "net: link down\n" else "net: link up\n");

    if (speed == 0) {

        if (source == .automatic) forget();
        phase = .idle;
        return;

    }

    if (!off and manual.manual == 0) discover();

}

/// Runs every timer that is due: TCP, waiting requests, queries, DHCP, ARP, the clock, and sockets whose process ended.
fn maintain() void {

    const now = api.ticks();

    for (&sockets) |*socket| {

        if (socket.kind == .tcp and socket.connection.tick(now)) pump(socket);
        if (socket.kind != .free) settle(socket);

    }

    for (&queries) |*query| {

        if (query.purpose == .free or now < query.until) continue;
        retry(query);

    }

    if (phase != .idle and now >= lease_due) lapse();

    if (now >= expires and phase == .renewing) {

        forget();
        discover();

    }

    for (&neighbours) |*neighbour| {

        if (neighbour.known or neighbour.address == 0 or now < neighbour.asked + 100) continue;

        if (neighbour.tries >= 3) {

            drop(neighbour.address);
            neighbour.* = .{};
            continue;

        }

        ask(neighbour);

    }

    if (address != 0 and now >= clock_due) setClock();

    reap();

}

/// The tick by which `maintain` next has work.
fn soonest(now: u64) u64 {

    var result = now + 100;

    for (sockets) |socket| {

        if (socket.kind == .tcp and socket.connection.due() != 0) result = @min(result, socket.connection.due());
        if (socket.wait != .none) result = @min(result, socket.until);

    }

    for (queries) |query| {

        if (query.purpose != .free) result = @min(result, query.until);

    }

    if (phase != .idle) result = @min(result, lease_due);

    return result;

}

/// Stops sockets whose process has ended; a TCP connection is closed rather than dropped.
fn reap() void {

    for (&sockets) |*socket| {

        if (socket.kind == .free or socket.released or socket.pending or api.alive(socket.owner)) continue;
        release(socket);

    }

}

fn handle(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .crash => api.crash(request),
        .info => describe(request),
        .list => count(request),
        .change => change(request),
        .roots => share(request, value),
        .enable => enable(request, value != 0),
        .resolve => lookup(request),
        .echo => echo(request, @truncate(value)),
        .connect => connect(request, value),
        .listen => listen(request, @truncate(value)),
        .accept => wait(request, value, .accept, false),
        .read => wait(request, value & ~net.hasty, .read, (value & net.hasty) != 0),
        .write => wait(request, value & ~net.hasty, .write, (value & net.hasty) != 0),
        .close => close(request, value),
        else => protocol.invalid,

    };

}

fn describe(request: api.Request) u64 {

    const now = api.ticks();

    var status = net.Status{

        .device = device,
        .speed = speed,
        .mac = nic.mac,
        .source = source,
        .off = off,
        .address = net.Address.from(address),
        .mask = net.Address.from(mask),
        .gateway = net.Address.from(gateway),
        .server = net.Address.from(server),
        .lease = if (source == .automatic and expires > now) @intCast((expires - now) / 100) else 0,
        .received = received,
        .sent = sent,
        .utc = utc,
        .synced = synced,

    };

    for (sockets) |socket| {

        if (socket.open()) status.connections += 1;

    }

    if (request.fourth < @sizeOf(net.Status)) return protocol.invalid;
    api.store(request, 0, std.mem.asBytes(&status)) catch return protocol.invalid;

    return 0;

}

/// Each process's connection count, for Monitor.
fn count(request: api.Request) u64 {

    var counts: [most]net.Count = undefined;
    var length: usize = 0;

    for (sockets) |socket| {

        if (!socket.open() or socket.kind == .listener) continue;

        const entry = for (counts[0..length]) |*entry| {

            if (entry.process == socket.owner) break entry;

        } else added: {

            counts[length] = .{

                .process = socket.owner,
                .connections = 0,

            };

            length += 1;

            break :added &counts[length - 1];

        };

        entry.connections += 1;

    }

    const fitting = @min(length, request.fourth / @sizeOf(net.Count));

    api.store(request, 0, std.mem.sliceAsBytes(counts[0..fitting])) catch return protocol.invalid;

    return fitting;

}

/// Sets a manual address or returns to DHCP, keeping the choice in `/cfgs/system/net.config`.
fn change(request: api.Request) u64 {

    if (!api.sender(request).admin) return protocol.denied;

    var setting = net.Setting{};

    if (request.fourth < @sizeOf(net.Setting)) return protocol.invalid;
    api.fetch(request, 0, std.mem.asBytes(&setting)) catch return protocol.invalid;

    if (setting.manual != 0 and (setting.address.empty() or setting.mask.empty())) return protocol.invalid;

    manual = setting;
    save();
    apply();

    return 0;

}

/// Turns networking on or off for everyone; any signed-in user may, and the choice is kept.
fn enable(request: api.Request, on: bool) u64 {

    if (api.sender(request).user == api.abi.nobody.user) return protocol.denied;
    if (off != on) return 0;

    off = !on;
    save();
    apply();
    api.log(if (off) "net: turned off\n" else "net: turned on\n");

    return 0;

}

/// Applies the manual setting, or starts DHCP afresh, unless networking is off.
fn apply() void {

    forget();

    if (off) {

        phase = .idle;
        return;

    }

    if (manual.manual != 0) {

        address = manual.address.value();
        mask = manual.mask.value();
        gateway = manual.gateway.value();
        server = manual.server.value();
        source = .manual;
        phase = .idle;
        clock_due = 0;

        return;

    }

    if (speed != 0) discover();

}

fn load() void {

    configuration.open(api.config.system, "net");
    off = std.mem.eql(u8, configuration.get("power") orelse "", "off");

    if (!std.mem.eql(u8, configuration.get("mode") orelse "", "manual")) return;

    manual = .{

        .manual = 1,
        .address = net.Address.parse(configuration.get("address") orelse "") orelse return,
        .mask = net.Address.parse(configuration.get("mask") orelse "") orelse return,
        .gateway = net.Address.parse(configuration.get("gateway") orelse "") orelse .{},
        .server = net.Address.parse(configuration.get("dns") orelse "") orelse .{},

    };

    apply();

}

fn save() void {

    var bytes: [4][16]u8 = undefined;

    configuration.open(api.config.system, "net");

    const values = [_]net.Address{ manual.address, manual.mask, manual.gateway, manual.server };
    const keys = [_][]const u8{ "address", "mask", "gateway", "dns" };

    _ = configuration.set("power", if (off) "off" else "on");
    _ = configuration.set("mode", if (manual.manual != 0) "manual" else "automatic");

    for (values, keys, &bytes) |value, key, *text| {

        if (manual.manual == 0) {

            configuration.erase(key);
            continue;

        }

        _ = configuration.set(key, std.fmt.bufPrint(text, "{f}", .{value}) catch "");

    }

    configuration.save() catch api.log("net: could not save the setting\n");

}

/// Copies the trusted roots from `offset` into the caller's window; returns how many bytes it copied.
fn share(request: api.Request, offset: u64) u64 {

    if (offset >= roots.len) return 0;

    const size = @min(roots.len - offset, request.fourth, 0x10000);

    api.store(request, 0, roots[offset..][0..size]) catch return protocol.invalid;

    return size;

}

/// Resolves a name, from the cache or by asking the DNS server; the reply waits for the answer.
fn lookup(request: api.Request) ?u64 {

    if (address == 0 or speed == 0) return protocol.offline;

    const query = vacancy() orelse return protocol.full;

    if (request.fourth == 0 or request.fourth > query.name.len) return protocol.invalid;
    api.fetch(request, 0, query.name[0..request.fourth]) catch return protocol.invalid;
    query.length = request.fourth;

    if (cached(query.named())) |found| return found;

    query.purpose = .resolve;
    query.waiter = request;
    askName(query);

    return null;

}

fn echo(request: api.Request, target: u32) ?u64 {

    if (address == 0 or speed == 0) return protocol.offline;

    const query = vacancy() orelse return protocol.full;

    query.* = .{

        .purpose = .echo,
        .waiter = request,
        .target = target,
        .id = random(u16),
        .until = api.ticks() + 300,

    };

    query.sent = api.ticks();
    query.stamp = stamp();

    // An echo request: type 8, code 0, then its identifier, sequence number, and a little data.
    const message = scratch[wire.ip_length..][0..40];

    @memset(message, 0);
    message[0] = 8;
    wire.put(u16, message[4..6], 0x4752);
    wire.put(u16, message[6..8], query.id);
    @memcpy(message[8..][0..18], "GraniteOS 3 echo..");
    wire.put(u16, message[2..4], wire.fold(wire.sum(0, message)));
    transmit(wire.icmp, target, message.len);

    return null;

}

fn connect(request: api.Request, value: u56) ?u64 {

    if (address == 0 or speed == 0) return protocol.offline;

    const kind: net.Kind = std.enums.fromInt(net.Kind, @as(u8, @truncate(value >> 48))) orelse return protocol.invalid;
    const remote: u32 = @truncate(value);
    const port: u16 = @truncate(value >> 32);

    if (port == 0 or remote == 0) return protocol.invalid;

    const socket = claim(request, if (kind == .tcp) .tcp else .udp) orelse return protocol.full;

    socket.remote = remote;
    socket.remote_port = port;
    socket.local_port = vacantPort();

    if (kind == .udp) return socket.handle();

    socket.connection.open(socket.local_port, port, random(u32), mss);
    pump(socket);
    hold(socket, request, .connect, false);

    return null;

}

fn listen(request: api.Request, port: u16) u64 {

    const identity = api.sender(request);

    if (port == 0 or port == resolver_port or port == clock_port) return protocol.invalid;
    if (port < 1024 and !identity.admin and identity.user != api.abi.system.user) return protocol.denied;

    for (sockets) |socket| {

        if (socket.kind == .listener and socket.local_port == port) return protocol.exists;

    }

    const socket = claim(request, .listener) orelse return protocol.full;

    socket.local_port = port;

    return socket.handle();

}

/// Holds a read, write, or accept until it can be answered.
fn wait(request: api.Request, handle_value: u64, kind: Wait, hasty: bool) ?u64 {

    const socket = find(request, handle_value) orelse return protocol.missing;

    if (socket.wait != .none) return protocol.busy;
    if ((kind == .accept) != (socket.kind == .listener)) return protocol.invalid;

    hold(socket, request, kind, hasty);
    settle(socket);

    return null;

}

fn close(request: api.Request, handle_value: u64) u64 {

    const socket = find(request, handle_value) orelse return protocol.missing;

    release(socket);

    return 0;

}

/// Lets a socket go: a TCP connection finishes sending and closes, and the rest end at once, with any connection its
/// listener had not handed out.
fn release(socket: *Socket) void {

    if (socket.wait != .none) api.answer(socket.waiter, protocol.missing);
    socket.wait = .none;
    socket.released = true;

    if (socket.kind == .listener) {

        for (&sockets) |*other| {

            if (other.pending and other.listener == index(socket)) release(other);

        }

    }

    if (socket.kind != .tcp) return free(socket);

    socket.pending = false;
    socket.connection.close();
    pump(socket);

}

fn free(socket: *Socket) void {

    if (socket.memory.len != 0) api.pages.free(socket.memory);

    socket.* = .{

        .generation = socket.generation +% 1,

    };

}

/// A new socket of `kind` for the process behind `request`, with buffers for what it carries.
fn claim(request: api.Request, kind: Kind) ?*Socket {

    var held_count: usize = 0;

    for (sockets) |socket| {

        if (socket.kind != .free and socket.owner == request.first) held_count += 1;

    }

    if (held_count >= allowance) return null;

    return claimFor(request.first, api.sender(request).user, kind);

}

fn claimFor(owner: u64, user: u32, kind: Kind) ?*Socket {

    const socket = for (&sockets) |*socket| {

        if (socket.kind == .free) break socket;

    } else return null;

    const size: usize = switch (kind) {

        .tcp => 2 * window,
        .udp => datagrams,
        else => 0,

    };

    const memory: []u8 = if (size == 0) &.{} else api.pages.alloc(u8, size) catch return null;

    socket.* = .{

        .kind = kind,
        .generation = socket.generation,
        .owner = owner,
        .user = user,
        .memory = memory,

    };

    if (kind == .tcp) {

        socket.connection.rx = .{ .bytes = memory[0..window] };
        socket.connection.tx = .{ .bytes = memory[window..] };

    }

    if (kind == .udp) socket.inbox = .{ .bytes = memory };

    return socket;

}

/// The open socket `value` names, if the process behind `request` owns it.
fn find(request: api.Request, value: u64) ?*Socket {

    const socket = &sockets[@as(u8, @truncate(value))];

    if (!socket.open() or socket.owner != request.first or socket.handle() != value) return null;

    return socket;

}

fn hold(socket: *Socket, request: api.Request, kind: Wait, hasty: bool) void {

    socket.waiter = request;
    socket.wait = kind;
    socket.until = api.ticks() + @as(u64, if (hasty) brief else patience);

}

/// Answers the request waiting on `socket` once it can be, or once it has waited long enough.
fn settle(socket: *Socket) void {

    if (socket.kind == .tcp and socket.released and socket.connection.state == .closed) return free(socket);
    if (socket.wait == .none) return;

    const request = socket.waiter;
    const late = api.ticks() >= socket.until;

    const result = switch (socket.wait) {

        .none => null,
        .connect => established(socket, late),
        .read => if (socket.kind == .udp) take(socket, request) else deliver(socket, request),
        .write => if (socket.kind == .udp) post(socket, request) else queue(socket, request),
        .accept => hand(socket, request),

    } orelse (if (late) protocol.empty else return);

    socket.wait = .none;
    api.answer(request, result);

}

/// The handle once a connection is established, or why it never will be; a connection that failed is let go.
fn established(socket: *Socket, late: bool) ?u64 {

    const connection = &socket.connection;

    if (connection.state == .established or connection.state == .close_wait) return socket.handle();

    if (connection.state != .closed and !late) return null;

    connection.state = .closed;
    socket.released = true;

    return if (connection.expired or late) protocol.timeout else protocol.refused;

}

/// Copies received bytes into the waiting reader's window; zero once the peer finished sending.
fn deliver(socket: *Socket, request: api.Request) ?u64 {

    const connection = &socket.connection;

    if (connection.rx.length == 0) {

        if (connection.reset) return protocol.refused;

        return if (connection.finished or connection.state == .closed) 0 else null;

    }

    const parts = connection.rx.queued(0, request.fourth);

    api.store(request, 0, parts[0]) catch return protocol.invalid;
    api.store(request, parts[0].len, parts[1]) catch return protocol.invalid;
    connection.consumed(parts[0].len + parts[1].len);
    pump(socket);

    return parts[0].len + parts[1].len;

}

/// Queues as much of the waiting writer's window as fits, and sends what the connection allows.
fn queue(socket: *Socket, request: api.Request) ?u64 {

    const connection = &socket.connection;

    if (!connection.writable()) {

        const open = connection.state == .established or connection.state == .close_wait;

        return if (connection.reset or !open or connection.finishing) protocol.refused else null;

    }

    const parts = connection.tx.vacant(request.fourth);

    api.fetch(request, 0, parts[0]) catch return protocol.invalid;
    api.fetch(request, parts[0].len, parts[1]) catch return protocol.invalid;
    connection.tx.fill(parts[0].len + parts[1].len);
    pump(socket);

    return parts[0].len + parts[1].len;

}

/// Hands the waiting reader one datagram, cut to its window.
fn take(socket: *Socket, request: api.Request) ?u64 {

    var header: [2]u8 = undefined;

    if (socket.inbox.peek(0, &header) != 2) return null;

    const size = wire.be(u16, &header);
    const parts = socket.inbox.queued(2, @min(size, request.fourth));

    api.store(request, 0, parts[0]) catch return protocol.invalid;
    api.store(request, parts[0].len, parts[1]) catch return protocol.invalid;
    socket.inbox.discard(2 + @as(usize, size));

    return parts[0].len + parts[1].len;

}

/// Sends the waiting writer's window as one datagram.
fn post(socket: *Socket, request: api.Request) u64 {

    const room = wire.mtu - wire.ip_length - wire.udp_length;

    if (request.fourth > room) return protocol.invalid;

    const payload = scratch[wire.ip_length + wire.udp_length ..][0..request.fourth];

    api.fetch(request, 0, payload) catch return protocol.invalid;
    datagram(socket.remote, socket.local_port, socket.remote_port, payload.len);

    return payload.len;

}

/// Hands the waiting accepter the oldest connection its listener established.
fn hand(socket: *Socket, request: api.Request) ?u64 {

    for (&sockets) |*other| {

        if (!other.pending or other.listener != index(socket)) continue;
        if (other.connection.state != .established and other.connection.state != .close_wait) continue;

        var peer: [6]u8 = undefined;

        wire.put(u32, peer[0..4], other.remote);
        wire.put(u16, peer[4..6], other.remote_port);
        if (request.fourth < peer.len) return protocol.invalid;
        api.store(request, 0, &peer) catch return protocol.invalid;

        other.pending = false;

        return other.handle();

    }

    return null;

}

/// Sends every segment `socket`'s connection has due, then answers its waiter if that is now possible.
fn pump(socket: *Socket) void {

    const now = api.ticks();
    const connection = &socket.connection;

    while (connection.output(now)) |out| {

        var segment = out.segment;
        const header: usize = if (segment.mss == null) wire.tcp_length else wire.tcp_length + 4;
        const payload = scratch[wire.ip_length + header ..][0..out.length];

        _ = connection.tx.peek(out.offset, payload);
        segment.payload = payload;
        _ = wire.writeTcp(scratch[wire.ip_length..], address, socket.remote, segment);
        transmit(wire.tcp, socket.remote, header + payload.len);

    }

}

fn index(socket: *const Socket) usize {

    return (@intFromPtr(socket) - @intFromPtr(&sockets)) / @sizeOf(Socket);

}

/// An unused port for an outgoing connection.
fn vacantPort() u16 {

    while (true) {

        const port = next_port;

        next_port = if (next_port == 65535) ephemeral else next_port + 1;

        for (sockets) |socket| {

            if (socket.kind != .free and socket.local_port == port) break;

        } else return port;

    }

}

// Receiving.

fn frame(_: void, bytes: []const u8) void {

    if (off) return;

    received += bytes.len;

    const parsed = wire.frame(bytes) orelse return;

    if (!std.mem.eql(u8, &parsed.destination, &nic.mac) and !std.mem.eql(u8, &parsed.destination, &wire.broadcast)) return;

    switch (parsed.kind) {

        wire.arp => resolved(wire.parseArp(parsed.payload) orelse return),
        wire.ipv4 => packet(wire.parseIp(parsed.payload) orelse return),
        else => {

        },

    }

}

fn resolved(message: wire.Arp) void {

    if (message.sender_address != 0) learn(message.sender_address, message.sender);
    if (!message.request or address == 0 or message.target_address != address) return;

    var reply: [28]u8 = undefined;

    wire.writeArp(&reply, nic.mac, address, message.sender, message.sender_address);
    emit(message.sender, wire.arp, &reply);

}

fn packet(ip: wire.Ip) void {

    // Before DHCP gives us an address, only broadcasts and offers made to the address are taken.
    const ours = ip.destination == address or ip.destination == 0xffffffff or (mask != 0 and ip.destination == address | ~mask);

    if (!ours and address != 0) return;

    switch (ip.protocol) {

        wire.icmp => control(ip),
        wire.udp => datagramArrived(ip, wire.parseUdp(ip) orelse return),
        wire.tcp => segmentArrived(ip, wire.parseTcp(ip) orelse return),
        else => {

        },

    }

}

fn control(ip: wire.Ip) void {

    const message = ip.payload;

    if (message.len < 8 or wire.fold(wire.sum(0, message)) != 0) return;

    // Echo requests are answered in kind; echo replies end the query that sent them.
    if (message[0] == 8 and address != 0 and message.len <= wire.mtu - wire.ip_length) {

        const reply = scratch[wire.ip_length..][0..message.len];

        @memcpy(reply, message);
        reply[0] = 0;
        wire.put(u16, reply[2..4], 0);
        wire.put(u16, reply[2..4], wire.fold(wire.sum(0, reply)));
        transmit(wire.icmp, ip.source, reply.len);

        return;

    }

    if (message[0] != 0 or wire.be(u16, message[4..6]) != 0x4752) return;

    for (&queries) |*query| {

        if (query.purpose != .echo or query.target != ip.source or query.id != wire.be(u16, message[6..8])) continue;

        finish(query, @max(microseconds(query.stamp), 1));

        return;

    }

}

fn datagramArrived(ip: wire.Ip, message: wire.Udp) void {

    switch (message.destination) {

        dhcp.client => return offer(message.payload),
        resolver_port => return named(message.payload),
        clock_port => return timed(message.payload),
        else => {

        },

    }

    for (&sockets) |*socket| {

        if (socket.kind != .udp or socket.local_port != message.destination) continue;
        if (socket.remote != ip.source or socket.remote_port != message.source) continue;

        var header: [2]u8 = undefined;

        wire.put(u16, &header, @intCast(message.payload.len));
        if (socket.inbox.free() < 2 + message.payload.len) return;

        _ = socket.inbox.push(&header);
        _ = socket.inbox.push(message.payload);
        settle(socket);

        return;

    }

}

fn segmentArrived(ip: wire.Ip, segment: wire.Segment) void {

    const now = api.ticks();

    for (&sockets) |*socket| {

        if (socket.kind != .tcp or socket.connection.state == .closed) continue;
        if (socket.local_port != segment.destination or socket.remote != ip.source or socket.remote_port != segment.source) continue;

        socket.connection.input(segment, now);
        pump(socket);
        settle(socket);

        return;

    }

    // A SYN for a listening port starts a connection its listener hands out once established.
    if (segment.flags.syn and !segment.flags.ack and !segment.flags.rst) {

        for (&sockets) |*listener| {

            if (listener.kind != .listener or listener.released or listener.local_port != segment.destination) continue;

            const socket = claimFor(listener.owner, listener.user, .tcp) orelse break;

            socket.pending = true;
            socket.listener = index(listener);
            socket.remote = ip.source;
            socket.remote_port = segment.source;
            socket.local_port = segment.destination;
            socket.connection.accept(segment, random(u32), mss);
            pump(socket);

            return;

        }

    }

    refuse(ip, segment);

}

/// Answers a segment no connection takes with a reset, unless it is one.
fn refuse(ip: wire.Ip, segment: wire.Segment) void {

    if (segment.flags.rst or address == 0) return;

    var reply = wire.Segment{

        .source = segment.destination,
        .destination = segment.source,
        .flags = .{ .rst = true },

    };

    if (segment.flags.ack) {

        reply.sequence = segment.acknowledgment;

    } else {

        reply.flags.ack = true;
        reply.acknowledgment = segment.sequence +% segment.span();

    }

    _ = wire.writeTcp(scratch[wire.ip_length..], address, ip.source, reply);
    transmit(wire.tcp, ip.source, wire.tcp_length);

}

// Sending.

/// Sends the `length` bytes after `scratch`'s IPv4 header to `destination`.
fn transmit(kind: u8, destination: u32, length: usize) void {

    identifier +%= 1;
    wire.writeIp(&scratch, kind, address, destination, length, identifier);

    const bytes = scratch[0 .. wire.ip_length + length];

    if (destination == 0xffffffff or (mask != 0 and destination == address | ~mask)) return emit(wire.broadcast, wire.ipv4, bytes);

    const hop = if (mask == 0 or destination & mask == address & mask or gateway == 0) destination else gateway;
    const neighbour = neighbourFor(hop);

    neighbour.used = api.ticks();
    if (neighbour.known) return emit(neighbour.mac, wire.ipv4, bytes);

    // The packet waits for the address to resolve, displacing the oldest held one if need be.
    const slot = for (&held) |*slot| {

        if (slot.length == 0) break slot;

    } else &held[identifier % held.len];

    slot.hop = hop;
    slot.length = bytes.len;
    @memcpy(slot.bytes[0..bytes.len], bytes);

    if (neighbour.tries == 0) ask(neighbour);

}

/// Sends a UDP datagram whose `length` bytes of payload already follow its header in `scratch`.
fn datagram(destination: u32, source_port: u16, destination_port: u16, length: usize) void {

    wire.writeUdp(scratch[wire.ip_length..][0 .. wire.udp_length + length], address, destination, source_port, destination_port);
    transmit(wire.udp, destination, wire.udp_length + length);

}

fn emit(destination: wire.Mac, kind: u16, payload: []const u8) void {

    if (off) return;

    const buffer = nic.buffer() orelse return;
    const size = wire.ethernet_length + payload.len;

    wire.ethernet(buffer, destination, nic.mac, kind);
    @memcpy(buffer[wire.ethernet_length..][0..payload.len], payload);
    nic.send(size);
    sent += size;

}

// ARP.

/// The entry for `hop`, made in place of the least recently used one if it has none.
fn neighbourFor(hop: u32) *Neighbour {

    var oldest = &neighbours[0];

    for (&neighbours) |*neighbour| {

        if (neighbour.address == hop) return neighbour;
        if (neighbour.used < oldest.used) oldest = neighbour;

    }

    oldest.* = .{

        .address = hop,

    };

    return oldest;

}

fn ask(neighbour: *Neighbour) void {

    var request: [28]u8 = undefined;

    neighbour.asked = api.ticks();
    neighbour.tries += 1;
    wire.writeArp(&request, nic.mac, address, null, neighbour.address);
    emit(wire.broadcast, wire.arp, &request);

}

/// Records where `hop` is, and sends what waited on it.
fn learn(hop: u32, mac: wire.Mac) void {

    for (&neighbours) |*neighbour| {

        if (neighbour.address != hop) continue;

        neighbour.mac = mac;
        neighbour.known = true;

        for (&held) |*slot| {

            if (slot.length == 0 or slot.hop != hop) continue;

            emit(mac, wire.ipv4, slot.bytes[0..slot.length]);
            slot.length = 0;

        }

        return;

    }

}

fn drop(hop: u32) void {

    for (&held) |*slot| {

        if (slot.hop == hop) slot.length = 0;

    }

}

// DHCP.

fn discover() void {

    phase = .selecting;
    xid = random(u32);
    offered = 0;
    offerer = 0;
    lease_due = api.ticks() + 400;
    requestLease(.discover, 0);

}

fn requestLease(kind: dhcp.Kind, current: u32) void {

    const payload = scratch[wire.ip_length + wire.udp_length ..];
    const length = dhcp.build(payload, kind, xid, nic.mac, current, if (current == 0) offered else 0, if (current == 0) offerer else 0);

    datagram(0xffffffff, dhcp.client, dhcp.server, length);

}

fn offer(message: []const u8) void {

    const reply = dhcp.parse(message, xid, nic.mac) orelse return;
    const now = api.ticks();

    switch (reply.kind) {

        .offer => {

            if (phase != .selecting) return;

            phase = .requesting;
            offered = reply.address;
            offerer = reply.server;
            lease_due = now + 400;
            requestLease(.request, 0);

        },
        .ack => {

            if (phase != .requesting and phase != .renewing) return;

            const fresh = address != reply.address;

            address = reply.address;
            mask = if (reply.mask != 0) reply.mask else 0xffffff00;
            gateway = reply.router;
            server = reply.dns;
            source = .automatic;
            phase = .bound;
            lease_due = now + @as(u64, @max(reply.renew, 30)) * 100;
            expires = now + @as(u64, @max(reply.lease, 60)) * 100;

            if (!fresh) return;

            var line: [64]u8 = undefined;

            api.log(std.fmt.bufPrint(&line, "net: address {f} from DHCP\n", .{net.Address.from(address)}) catch "net: address from DHCP\n");
            clock_due = now;

        },
        .nak => {

            forget();
            discover();

        },
        else => {

        },

    }

}

/// A DHCP timer ran out: try again, or renew the lease.
fn lapse() void {

    switch (phase) {

        .selecting, .requesting => discover(),
        .bound, .renewing => {

            phase = .renewing;
            lease_due = api.ticks() + 1000;
            requestLease(.request, address);

        },
        .idle => {

        },

    }

}

/// Drops the address and every connection made through it.
fn forget() void {

    if (address != 0) {

        for (&sockets) |*socket| {

            if (socket.kind == .tcp and socket.connection.state != .closed) {

                socket.connection.state = .closed;
                socket.connection.reset = true;
                settle(socket);

            }

        }

    }

    address = 0;
    mask = 0;
    gateway = 0;
    server = 0;
    source = .none;
    neighbours = [_]Neighbour{.{}} ** neighbours.len;

    for (&held) |*slot| slot.length = 0;

}

// DNS.

fn vacancy() ?*Query {

    for (&queries) |*query| {

        if (query.purpose == .free) {

            query.* = .{};
            return query;

        }

    }

    return null;

}

/// Sends `query`'s name to the DNS server.
fn askName(query: *Query) void {

    if (server == 0) return finish(query, protocol.offline);

    query.id = random(u16);
    query.tries += 1;
    query.until = api.ticks() + 200;

    const payload = scratch[wire.ip_length + wire.udp_length ..];
    const length = dns.query(payload, query.id, query.named()) orelse return finish(query, protocol.invalid);

    datagram(server, resolver_port, dns.port, length);

}

fn named(message: []const u8) void {

    if (message.len < 2) return;

    const id = wire.be(u16, message[0..2]);

    for (&queries) |*query| {

        if ((query.purpose != .resolve and query.purpose != .clock) or query.id != id or query.target != 0) continue;

        const reply = dns.parse(message, id) orelse return;

        switch (reply) {

            .found => |found| {

                remember(query.named(), found.address, found.ttl);

                if (query.purpose == .clock) return askClock(query, found.address);

                finish(query, found.address);

            },
            .missing => finish(query, protocol.missing),
            .failed => finish(query, protocol.busy),

        }

        return;

    }

}

fn cached(name: []const u8) ?u32 {

    const now = api.ticks();

    for (cache) |entry| {

        if (entry.expires > now and std.ascii.eqlIgnoreCase(entry.name[0..entry.length], name)) return entry.address;

    }

    return null;

}

fn remember(name: []const u8, found: u32, ttl: u32) void {

    var oldest = &cache[0];

    for (&cache) |*entry| {

        if (entry.expires < oldest.expires) oldest = entry;

    }

    @memcpy(oldest.name[0..name.len], name);
    oldest.length = name.len;
    oldest.address = found;
    oldest.expires = api.ticks() + @as(u64, std.math.clamp(ttl, 60, 86400)) * 100;

}

/// A query's time ran out: it is asked again, or ends.
fn retry(query: *Query) void {

    if (query.purpose == .echo or query.tries >= 3) return finish(query, protocol.timeout);

    if (query.purpose == .clock and query.target != 0) return askClock(query, query.target);

    askName(query);

}

/// Ends `query`, answering the app that waits on it; a clock query that failed tries again later.
fn finish(query: *Query, result: u64) void {

    if (query.waiter) |request| api.answer(request, result);
    if (query.purpose == .clock) clock_due = api.ticks() + clock_retry;

    query.* = .{};

}

// SNTP.

fn setClock() void {

    clock_due = api.ticks() + clock_retry;

    for (queries) |query| {

        if (query.purpose == .clock) return;

    }

    const query = vacancy() orelse return;

    query.purpose = .clock;
    @memcpy(query.name[0..clock_server.len], clock_server);
    query.length = clock_server.len;

    if (cached(clock_server)) |found| return askClock(query, found);

    askName(query);

}

fn askClock(query: *Query, target: u32) void {

    query.target = target;
    query.tries += 1;
    query.until = api.ticks() + 300;

    // A client request: no leap warning, version 4, mode 3.
    const payload = scratch[wire.ip_length + wire.udp_length ..][0..48];

    @memset(payload, 0);
    payload[0] = 0x23;
    datagram(target, clock_port, 123, payload.len);

}

fn timed(message: []const u8) void {

    // A server's reply in mode 4, whose transmit time counts seconds from 1900.
    if (message.len < 48 or message[0] & 7 != 4) return;

    const seconds = wire.be(u32, message[40..44]);

    for (&queries) |*query| {

        if (query.purpose != .clock or query.target == 0) continue;
        if (seconds < 2208988800) return finish(query, 0);

        utc = seconds - 2208988800;
        synced = api.ticks();
        query.* = .{};
        clock_due = synced + clock_period;

        return;

    }

}

// Helpers.

fn random(comptime T: type) T {

    var bytes: [@sizeOf(T)]u8 = undefined;

    api.random(&bytes);

    return std.mem.bytesToValue(T, &bytes);

}

/// The processor's time-stamp counter.
fn stamp() u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc" // Read the time-stamp counter.
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );

    return @as(u64, high) << 32 | low;

}

/// Microseconds since time stamp `start`, using the counter's rate measured against ticks since the service started.
fn microseconds(start: u64) u64 {

    const ticks = @max(api.ticks() -| tick_start, 1);
    const rate = (stamp() -| stamp_start) / ticks;

    return if (rate == 0) 0 else (stamp() -| start) * 10000 / rate;

}
