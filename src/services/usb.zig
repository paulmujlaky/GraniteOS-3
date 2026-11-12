//! USB keyboards and mice on an xHCI controller's root ports, read through the HID boot protocol and polled every tick.

const std = @import("std");

const hid = @import("hid.zig");
const keys = @import("keys.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

// TRB types, numbered as in the xHCI specification.
const normal = 1;
const setup = 2;
const data = 3;
const status = 4;
const link = 6;
const enable = 9;
const address = 11;
const configure = 12;
const evaluate = 13;
const transfer = 32;
const completion = 33;

// TRB control bits.
const cycle = 1 << 0;
const toggle = 1 << 1;
const short = 1 << 2;
const notify = 1 << 5;
const immediate = 1 << 6;
const inward = 1 << 16;

// Completion codes worth telling apart: done, and done with less data than asked.
const success = 1;
const shortfall = 13;

// Port status and control bits.
const connected = 1 << 0;
const enabled = 1 << 1;
const resetting = 1 << 4;
const reset_change = 1 << 21;

/// Bits of a port's status that writing back leaves as they are; the rest either clear on a one or act.
const neutral: u32 = (1 << 0) | (1 << 3) | (0xf << 10) | (1 << 30) | (0xf << 5) | (1 << 9) | (0x3 << 14) | (0x7 << 25);

/// Most devices kept, and reports queued for each.
const most = 8;
const queued = 8;

/// One transfer request block: the unit every ring holds.
const Trb = extern struct {

    parameter: u64 = 0,
    status: u32 = 0,
    control: u32 = 0,

};

/// A ring the controller reads requests from, one page of them ending in a link back to the start.
const Ring = struct {

    page: api.Page,
    index: usize = 0,
    state: u32 = cycle,

    fn init() !Ring {

        const page = try api.dma();

        @memset(page.bytes, 0);

        const trbs = blocks(page);

        trbs[255] = .{

            .parameter = page.physical,
            .control = link << 10 | toggle,

        };

        return .{

            .page = page,

        };

    }

    /// Hands the controller `trb`, owned by it once the cycle bit flips; returns where it went.
    fn push(self: *Ring, trb: Trb) u64 {

        const trbs = blocks(self.page);
        const at = self.page.physical + self.index * @sizeOf(Trb);

        trbs[self.index].parameter = trb.parameter;
        trbs[self.index].status = trb.status;
        trbs[self.index].control = trb.control & ~@as(u32, cycle) | self.state;
        self.index += 1;

        // The link at the end goes to the controller too, and flips the cycle for the next lap.
        if (self.index == 255) {

            trbs[255].control = link << 10 | toggle | self.state;
            self.index = 0;
            self.state ^= cycle;

        }

        return at;

    }

};

/// A boot keyboard or mouse in a slot, with its interrupt endpoint's ring and report buffers.
const Device = struct {

    slot: u8,
    port: u8,
    kind: hid.Kind,

    /// The endpoint's device context index, and how much each report may hold.
    target: u8,
    size: u16,

    ring: Ring,
    buffers: api.Page,

    /// The keyboard's last report, to see which keys went down and up.
    last: [8]u8 = @splat(0),

    /// Where a pointer's report keeps its parts; null for boot reports.
    layout: ?hid.Layout = null,

};

var registers: usize = 0;
var operational: usize = 0;
var runtime: usize = 0;
var doorbells: usize = 0;

/// Bytes in each context: 32, or 64 on controllers that say so.
var context_size: usize = 32;
var slots: u32 = 0;
var ports: u32 = 0;

var contexts: api.Page = undefined;
var commands: Ring = undefined;
var events: api.Page = undefined;
var event_index: usize = 0;
var event_state: u32 = cycle;

/// Pages for each slot's device context, which the controller fills.
var outputs: [most + 1]?api.Page = @splat(null);

var devices: [most]?Device = @splat(null);

/// A port changed, so the ports are looked over again.
var rescan = true;

/// Ports whose device was already looked at.
var seen: [256]bool = @splat(false);

var board = keys.Keyboard{};
var relay = keys.Relay{};

/// The key held longest without a release, which repeats as a PS/2 keyboard's would.
var held: ?u8 = null;
var due: u64 = 0;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, size: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.dma) or api.permits(.ports) or api.permits(.management)) api.exit(2);

    registers = @intFromPtr(api.map(base, size) catch api.exit(3));

    start() catch {

        api.log("usb: the controller did not start\n");
        api.exit(3);

    };

    while (true) {

        // Requests come first, so the supervisor's hello never waits on a slow device.
        const message = api.receive(false) catch {

            if (rescan) scan();
            drain();
            repeat();
            relay.forward();
            api.sleep(1);
            continue;

        };

        const result: u64 = switch (protocol.operation(message.second)) {

            .hello => protocol.version,
            .crash => api.crash(message),
            else => protocol.invalid,

        };

        api.answer(message, result);

    }

}

/// Takes the controller from the firmware, resets it, and starts it with a command ring and an event ring.
fn start() !void {

    const parameters = read(0x04);
    const capabilities = read(0x10);

    operational = read(0x00) & 0xff;
    runtime = read(0x18) & ~@as(u32, 0x1f);
    doorbells = read(0x14) & ~@as(u32, 3);
    slots = @min(parameters & 0xff, most);
    ports = parameters >> 24;
    if (capabilities & 4 != 0) context_size = 64;

    claim(capabilities >> 16);

    // Stopped, then reset; a controller still settling holds off until ready.
    write(operational, read(operational) & ~@as(u32, 1));
    try until(operational + 4, 1, 1);
    write(operational, 2);
    try until(operational, 2, 0);
    try until(operational + 4, 1 << 11, 0);

    write(operational + 0x38, slots);

    // The device context table, its first entry pointing at the scratch pages the controller asks for.
    contexts = try api.dma();
    @memset(contexts.bytes, 0);

    const second = read(0x08);
    const scratch = (second >> 21 & 0x1f) << 5 | second >> 27;

    if (scratch != 0) {

        const list = try api.dma();
        const entries: *[512]u64 = @ptrCast(list.bytes);

        for (0..@min(scratch, 512)) |index| entries[index] = (try api.dma()).physical;
        table()[0] = list.physical;

    }

    write64(operational + 0x30, contexts.physical);

    commands = try Ring.init();
    write64(operational + 0x18, commands.page.physical | cycle);

    // One event ring segment, described by a one-entry table in the same page's tail.
    events = try api.dma();
    @memset(events.bytes, 0);

    const segment: *[2]u64 = @ptrCast(@alignCast(events.bytes[4096 - 16 ..]));

    segment.* = .{ events.physical, 255 };

    const interrupter = runtime + 0x20;

    write(interrupter + 0x08, 1);
    write64(interrupter + 0x18, events.physical);
    write64(interrupter + 0x10, events.physical + 4096 - 16);

    write(operational, 1);
    try until(operational + 4, 1, 0);

    var line: [64]u8 = undefined;

    api.log(std.fmt.bufPrint(&line, "usb: ready ({d} ports)\n", .{ports}) catch unreachable);

}

/// Asks the firmware to hand over the controller, through the legacy support capability if it has one, and turns its SMIs off.
fn claim(offset: u32) void {

    var at: usize = offset * 4;

    while (at != 0 and at < 0x10000) {

        const header = read(at);

        if (header & 0xff == 1) {

            write(at, header | 1 << 24);
            until(at, 1 << 16, 0) catch api.log("usb: the firmware kept the controller\n");
            write(at + 4, read(at + 4) & 0xffff1fee | 0xe0000000);

            return;

        }

        const step = header >> 8 & 0xff;
        if (step == 0) return;

        at += step * 4;

    }

}

/// Looks for keyboards and mice on ports that connected, and forgets those on ports that went away.
fn scan() void {

    rescan = false;

    for (1..ports + 1) |port| {

        const register = operational + 0x400 + (port - 1) * 0x10;
        const state = read(register);

        // Changes clear by writing them back as ones.
        write(register, (state & neutral) | (state & 0x00fe0000));

        if (state & connected == 0) {

            for (&devices) |*spot| if (spot.*) |device| if (device.port == port) {

                // The slot goes back to the controller for whatever plugs in next.
                _ = command(.{

                    .control = 10 << 10 | @as(u32, device.slot) << 24,

                }) catch {

                };

                spot.* = null;

            };

            seen[port] = false;
            continue;

        }

        // Each connection is looked at once, whether it turned out to be a keyboard, a mouse, or neither.
        if (seen[port]) continue;

        seen[port] = true;

        attach(@intCast(port), register) catch |err| {

            var line: [64]u8 = undefined;

            api.log(std.fmt.bufPrint(&line, "usb: port {d} skipped ({s})\n", .{ port, @errorName(err) }) catch unreachable);

        };

    }

}

/// Resets the device on `port`, gives it an address, and starts reading reports if it is a boot keyboard or mouse.
fn attach(port: u8, register: usize) !void {

    // USB 3 links enable themselves; USB 2 ports need a reset first.
    if (read(register) & enabled == 0) {

        write(register, read(register) & neutral | resetting);
        try until(register, reset_change, reset_change);
        write(register, read(register) & neutral | reset_change);
        if (read(register) & enabled == 0) return error.Disabled;

    }

    const speed = read(register) >> 10 & 0xf;

    const answer = try command(.{

        .control = enable << 10,

    });

    const slot: u8 = @intCast(answer.control >> 24);

    if (slot == 0 or slot > slots) return error.NoSlot;

    const output = outputs[slot] orelse try api.dma();

    outputs[slot] = output;
    @memset(output.bytes, 0);
    table()[slot] = output.physical;

    var control = try Ring.init();
    const input = try api.dma();
    const buffer = try api.dma();

    // Address the device with endpoint 0 at the packet size its speed starts with.
    @memset(input.bytes, 0);
    entry(input, 0)[1] = 0b11;
    entry(input, 1)[0] = speed << 20 | 1 << 27;
    entry(input, 1)[1] = @as(u32, port) << 16;

    endpoint(entry(input, 2), 4, switch (speed) {

        3 => 64,
        4 => 512,
        else => 8,

    }, 0, control.page.physical);

    _ = try command(.{

        .parameter = input.physical,
        .control = address << 10 | @as(u32, slot) << 24,

    });

    // A full-speed device says its real packet size in the first eight bytes of its descriptor.
    try request(slot, &control, buffer, 0x80, 6, 0x0100, 0, 8);

    if (speed == 1 and buffer.bytes[7] != 8) {

        entry(input, 0)[1] = 0b10;
        endpoint(entry(input, 2), 4, buffer.bytes[7], 0, control.page.physical);

        _ = try command(.{

            .parameter = input.physical,
            .control = evaluate << 10 | @as(u32, slot) << 24,

        });

    }

    try request(slot, &control, buffer, 0x80, 6, 0x0200, 0, 9);
    try request(slot, &control, buffer, 0x80, 6, 0x0200, 0, @min(std.mem.readInt(u16, buffer.bytes[2..4], .little), 1024));

    const found = hid.find(buffer.bytes[0..@min(std.mem.readInt(u16, buffer.bytes[2..4], .little), 1024)]) orelse return error.NotInput;
    const target: u8 = (found.endpoint & 0xf) * 2 + 1;

    const index = for (&devices, 0..) |*spot, at| {

        if (spot.* == null) break at;

    } else return error.Full;

    try request(slot, &control, buffer, 0x00, 9, found.configuration, 0, 0);

    // The interrupt endpoint, polled as often as it asks: high-speed and later give an exponent, slower ones milliseconds.
    @memset(input.bytes, 0);
    entry(input, 0)[1] = 1 | @as(u32, 1) << @intCast(target);
    entry(input, 1)[0] = speed << 20 | @as(u32, target) << 27;
    entry(input, 1)[1] = @as(u32, port) << 16;

    var ring = try Ring.init();
    const interval: u32 = if (speed >= 3) std.math.clamp(found.interval, 1, 16) - 1 else std.math.clamp(std.math.log2_int(u32, @as(u32, @max(found.interval, 1)) * 8), 3, 10);

    endpoint(entry(input, target + 1), 7, found.size, interval, ring.page.physical);

    _ = try command(.{

        .parameter = input.physical,
        .control = configure << 10 | @as(u32, slot) << 24,

    });

    // Pointers say in their report descriptor where buttons, motion, and the wheel sit; keyboards, and mice that will not say, send boot reports.
    var described: ?hid.Layout = null;

    if (found.kind == .mouse) {

        const length = @min(found.report, 1024);

        request(slot, &control, buffer, 0x81, 6, 0x2200, found.interface, length) catch {

        };

        described = hid.layout(buffer.bytes[0..length]);

    }

    if (described == null and !found.boot) return error.NotInput;

    // Only on change, as a PS/2 device would send them; a device without the boot subclass may refuse to switch, keeping its own reports.
    request(slot, &control, buffer, 0x21, 0x0b, if (described == null) 0 else 1, found.interface, 0) catch if (described == null) return error.NotBoot;

    request(slot, &control, buffer, 0x21, 0x0a, 0, found.interface, 0) catch {

    };

    const reports = try api.dma();

    for (0..queued) |which| _ = ring.push(.{

        .parameter = reports.physical + which * 64,
        .status = @min(found.size, 64),
        .control = normal << 10 | notify | short,

    });

    devices[index] = .{

        .slot = slot,
        .port = port,
        .kind = found.kind,

        .target = target,
        .size = @min(found.size, 64),

        .ring = ring,
        .buffers = reports,

        .layout = described,

    };

    ring_doorbell(slot, target);

    var line: [64]u8 = undefined;

    api.log(std.fmt.bufPrint(&line, "usb: {s} on port {d}\n", .{ @tagName(found.kind), port }) catch unreachable);

}

/// Fills endpoint context `fields`: its type, packet size, polling interval, and ring.
fn endpoint(fields: *volatile [8]u32, kind: u32, size: u32, interval: u32, ring: u64) void {

    fields[0] = interval << 16;
    fields[1] = 3 << 1 | kind << 3 | size << 16;
    fields[2] = @truncate(ring | cycle);
    fields[3] = @intCast(ring >> 32);
    fields[4] = if (kind == 4) 8 else size | size << 16;

}

/// Runs a control transfer on endpoint 0 of `slot`, reading or writing up to `length` bytes of `buffer`.
fn request(slot: u8, ring: *Ring, buffer: api.Page, kind: u8, code: u8, value: u16, index: u16, length: u16) !void {

    const reading = kind & 0x80 != 0;
    const packet = @as(u64, kind) | @as(u64, code) << 8 | @as(u64, value) << 16 | @as(u64, index) << 32 | @as(u64, length) << 48;
    const direction: u32 = if (length == 0) 0 else if (reading) 3 else 2;

    _ = ring.push(.{

        .parameter = packet,
        .status = 8,
        .control = setup << 10 | immediate | direction << 16,

    });

    if (length != 0) _ = ring.push(.{

        .parameter = buffer.physical,
        .status = length,
        .control = data << 10 | if (reading) @as(u32, inward) else 0,

    });

    const last = ring.push(.{

        .control = status << 10 | notify | if (reading and length != 0) 0 else @as(u32, inward),

    });

    ring_doorbell(slot, 1);

    const event = try wait(transfer, last);
    const result = event.status >> 24;

    if (result != success and result != shortfall) return error.Stalled;

}

/// Runs a command and returns its completion event.
fn command(trb: Trb) !Trb {

    const at = commands.push(trb);

    ring_doorbell(0, 0);

    const event = try wait(completion, at);

    if (event.status >> 24 != success) return error.Refused;

    return event;

}

/// Waits up to a second for the event of `kind` about the request at `at`, handling any others that come first.
fn wait(kind: u32, at: u64) !Trb {

    const deadline = api.ticks() + 100;

    while (api.ticks() < deadline) {

        const event = next() orelse {

            _ = api.raw(.yield, 0, 0, 0);
            continue;

        };

        if (event.control >> 10 & 0x3f == kind and event.parameter == at) return event;

        handle(event);

    }

    return error.Timeout;

}

/// Handles every event waiting.
fn drain() void {

    while (next()) |event| handle(event);

}

/// Takes the next event off the event ring, if the controller wrote one.
fn next() ?Trb {

    const trbs = blocks(events);
    const event = trbs[event_index];

    if (event.control & cycle != event_state) return null;

    event_index += 1;

    if (event_index == 255) {

        event_index = 0;
        event_state ^= cycle;

    }

    // Tells the controller how far we got, clearing its busy flag.
    write64(runtime + 0x20 + 0x18, events.physical + event_index * @sizeOf(Trb) | 1 << 3);

    return .{

        .parameter = event.parameter,
        .status = event.status,
        .control = event.control,

    };

}

fn handle(event: Trb) void {

    switch (event.control >> 10 & 0x3f) {

        transfer => report(event),
        34 => rescan = true,
        else => {

        },

    }

}

/// Turns a finished interrupt transfer into input, then queues its buffer again.
fn report(event: Trb) void {

    const slot = event.control >> 24;
    const target = event.control >> 16 & 0x1f;
    const result = event.status >> 24;

    const device = for (&devices) |*spot| {

        if (spot.*) |*found| if (found.slot == slot and found.target == target) break found;

    } else return;

    // The TRB that finished says which buffer the report sits in.
    if (event.parameter < device.ring.page.physical or event.parameter >= device.ring.page.physical + 4096) return;

    const finished = blocks(device.ring.page)[(event.parameter - device.ring.page.physical) / @sizeOf(Trb)];
    const offset = finished.parameter -% device.buffers.physical;
    if (offset >= 4096) return;

    const length = device.size -| @as(u16, @truncate(event.status & 0xffffff));
    const bytes = device.buffers.bytes[offset..][0..@min(length, 64)];

    if (result == success or result == shortfall) switch (device.kind) {

        .keyboard => if (bytes.len >= 8) keyboard(device, bytes[0..8]),
        .mouse => if (device.layout) |shape| pointer(shape, bytes) else if (bytes.len >= 3) {

            relay.report(.motion, bytes[0] & 7, @as(i8, @bitCast(bytes[1])), @as(i8, @bitCast(bytes[2])));

        },

    };

    _ = device.ring.push(.{

        .parameter = finished.parameter,
        .status = device.size,
        .control = normal << 10 | notify | short,

    });

    ring_doorbell(device.slot, device.target);

}

/// Turns a pointer's report into motion, or a position for absolute ones such as tablets, then wheel steps.
fn pointer(shape: hid.Layout, bytes: []const u8) void {

    if (shape.id != 0 and (bytes.len == 0 or bytes[0] != shape.id)) return;

    const fields = if (shape.id != 0) bytes[1..] else bytes;
    const buttons: u8 = @intCast(@as(u32, @bitCast(shape.buttons.read(fields))) & 7);
    const x = shape.x.read(fields);
    const y = shape.y.read(fields);

    if (shape.x.relative) {

        relay.report(.motion, buttons, x, y);

    } else {

        relay.report(.pointer, buttons, scale(x, shape.x), scale(y, shape.y));

    }

    // Positive wheel values turn away from the user, which the display numbers as negative steps.
    if (shape.wheel.size != 0) relay.scroll(@intCast(-std.math.clamp(shape.wheel.read(fields), -127, 127)));

}

/// An absolute value across its range, as the display's 0 to 32767.
fn scale(value: i32, field: hid.Field) i32 {

    const span = @as(i64, field.maximum) - field.minimum;
    if (span <= 0) return 0;

    return @intCast(std.math.clamp(@divTrunc((@as(i64, value) - field.minimum) * 32767, span), 0, 32767));

}

/// Compares a keyboard's report with its last, sending set-1 scancodes for each modifier and key that changed.
fn keyboard(device: *Device, now: *const [8]u8) void {

    // Too many keys held at once; the report says nothing about which.
    if (now[2] == 1) return;

    const last = device.last;
    const changed = now[0] ^ last[0];

    for (0..8) |bit| {

        if (changed >> @intCast(bit) & 1 == 0) continue;

        scancode(hid.modifiers[bit], now[0] >> @intCast(bit) & 1 != 0);

    }

    for (last[2..8]) |usage| {

        if (usage != 0 and std.mem.indexOfScalar(u8, now[2..8], usage) == null) {

            scancode(hid.translate(usage), false);
            if (held == usage) held = null;

        }

    }

    for (now[2..8]) |usage| {

        if (usage != 0 and std.mem.indexOfScalar(u8, last[2..8], usage) == null) {

            scancode(hid.translate(usage), true);
            held = usage;
            due = api.ticks() + 25;

        }

    }

    device.last = now.*;

}

/// Sends the held key again, after 250 ms and then about 30 times a second, as the PS/2 keyboard is set to.
fn repeat() void {

    const usage = held orelse return;
    if (api.ticks() < due) return;

    scancode(hid.translate(usage), true);
    due = api.ticks() + 3;

}

/// Feeds set-1 `code`, with 0x100 for an 0xe0 prefix, through the shared keyboard.
fn scancode(code: u16, pressed: bool) void {

    if (code == 0) return;
    if (code & 0x100 != 0) _ = board.scancode(0xe0);
    if (board.scancode(@as(u8, @truncate(code)) | if (pressed) 0 else @as(u8, 0x80))) |event| relay.push(event);

}

/// Entry `index` of the device context base address table.
fn table() *[256]u64 {

    return @ptrCast(contexts.bytes);

}

/// Context `index` of the input or output context in `page`.
fn entry(page: api.Page, index: usize) *volatile [8]u32 {

    return @ptrCast(@alignCast(page.bytes[index * context_size ..][0..32]));

}

fn blocks(page: api.Page) *volatile [256]Trb {

    return @ptrCast(page.bytes);

}

fn ring_doorbell(slot: u8, target: u8) void {

    write(doorbells + @as(usize, slot) * 4, target);

}

/// Waits up to a second for the bits `mask` of register `offset` to read `value`.
fn until(offset: usize, mask: u32, value: u32) !void {

    const deadline = api.ticks() + 100;

    while (read(offset) & mask != value) {

        if (api.ticks() >= deadline) return error.Timeout;
        _ = api.raw(.yield, 0, 0, 0);

    }

}

fn read(offset: usize) u32 {

    return @as(*volatile u32, @ptrFromInt(registers + offset)).*;

}

fn write(offset: usize, value: u32) void {

    @as(*volatile u32, @ptrFromInt(registers + offset)).* = value;

}

fn write64(offset: usize, value: u64) void {

    write(offset, @truncate(value));
    write(offset + 4, @intCast(value >> 32));

}
