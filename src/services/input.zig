//! The PS/2 keyboard and mouse, and VMware's absolute pointer behind them.

const std = @import("std");

const keys = @import("keys.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const data = 0x60;
const control = 0x64;

// Held keys repeat after 250 ms at 30 per second, as Linux and Windows set them; the power-on default is 500 ms at 10.9.
const typematic = 0x00;

// Backdoor calls for VMware's absolute pointer, numbered as in Linux's vmmouse driver.
const Backdoor = enum(u32) {

    data = 39,
    status = 40,
    command = 41,

};

var board = keys.Keyboard{};
var relay = keys.Relay{};

var packet: [4]u8 = undefined;
var size: usize = 3;
var received: usize = 0;

/// Whether VMware's absolute pointer supplies pointer data, leaving PS/2 mouse bytes only to announce it.
var absolute = false;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ports) or api.permits(.mmio) or api.permits(.management)) api.exit(2);

    command(0xad);
    command(0xa7);
    flush();

    command(0x20);
    const configuration = receive() orelse api.exit(3);

    // Both clocks and both interrupts on, and translation to scancode set 1.
    command(0x60);
    send(configuration & ~@as(u8, 0x30) | 0x43);
    command(0xae);
    command(0xa8);
    flush();

    _ = device(false, 0xf3) and device(false, typematic);
    const keyboard = device(false, 0xf4);
    const mouse = device(true, 0xf6) and wheel() and device(true, 0xf4);

    if (!keyboard and !mouse) api.exit(3);

    absolute = mouse and vmware() and attach();
    api.log(if (absolute) "input: ready (vmmouse)\n" else "input: ready\n");

    while (true) {

        const request = api.receive(true) catch continue;

        // The kernel reports controller interrupts as a message from no process.
        if (request.first == 0) {

            drain();
            relay.forward();
            continue;

        }

        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .crash => api.crash(request),
            else => protocol.invalid,

        };

        api.answer(request, result);

    }

}

fn drain() void {

    for (0..256) |_| {

        const status = input(control);
        if (status & 1 == 0) break;

        const byte = input(data);

        if (status & 0x20 == 0) {

            if (board.scancode(byte)) |event| relay.push(event);

        } else if (!absolute) {

            pointer(byte);

        }

    }

    if (absolute) poll();

}

fn pointer(byte: u8) void {

    // A first byte without bit 3 means the stream lost sync.
    if (received == 0 and byte & 8 == 0) return;

    packet[received] = byte;
    received += 1;
    if (received < size) return;

    received = 0;
    if (packet[0] & 0xc0 != 0) return;

    const dx = @as(i32, packet[1]) - (@as(i32, packet[0] & 0x10) << 4);
    const dy = @as(i32, packet[2]) - (@as(i32, packet[0] & 0x20) << 3);

    relay.report(.motion, packet[0] & 7, dx, -dy);
    if (size == 4) relay.scroll(@bitCast(packet[3]));

}

/// Reports every packet waiting in VMware's pointer queue, handing the pointer back to PS/2 on a protocol error.
fn poll() void {

    for (0..256) |_| {

        const words = waiting() orelse return detach();
        if (words == 0) return;
        if (words % 4 != 0) return detach();

        const status, const x, const y, const z = backdoor(.data, 4);

        // VMware holds left, right, and middle in bits 5, 4, and 3; events count them up from bit 0.
        const buttons: u8 = @intCast((status >> 5 & 1) | (status >> 3 & 2) | (status >> 1 & 4));

        // Relative packets come when the host asks for them, with y growing upwards as in PS/2.
        if (status & 0x10000 != 0) {

            relay.report(.motion, buttons, @bitCast(x), -%@as(i32, @bitCast(y)));

        } else {

            relay.report(.pointer, buttons, @intCast(x >> 1), @intCast(y >> 1));

        }

        relay.scroll(@bitCast(@as(u8, @truncate(z))));

    }

}

/// Sends `byte` to the keyboard or, through the controller, the mouse; true when it acknowledges.
fn device(auxiliary: bool, byte: u8) bool {

    if (auxiliary) command(0xd4);
    send(byte);

    return receive() == 0xfa;

}

/// Unlocks an IntelliMouse wheel with the sample rate knock; a device ID of 3 then means four-byte packets.
fn wheel() bool {

    for ([_]u8{ 200, 100, 80 }) |rate| {

        if (!device(true, 0xf3) or !device(true, rate)) return false;

    }

    if (!device(true, 0xf2)) return false;
    if (receive() == 3) size = 4;

    // The knock leaves the rate at 80; restore the default.
    return device(true, 0xf3) and device(true, 100);

}

/// Whether CPUID reports a hypervisor that names itself VMware.
fn vmware() bool {

    if (cpuid(1)[2] & 0x80000000 == 0) return false;

    const leaf = cpuid(0x40000000);

    return std.mem.eql(u8, std.mem.asBytes(leaf[1..4]), "VMwareVMware");

}

/// Switches VMware's pointer to absolute positions; false leaves it off when it does not answer as expected.
fn attach() bool {

    // A restarted service may find the device still on with stale packets queued, so start it afresh.
    detach();
    _ = backdoor(.command, 0x45414552);

    // Enabling queues a version word, which proves the device is there.
    const words = waiting() orelse 0;

    if (words == 0 or backdoor(.data, 1)[0] != 0x3442554a) {

        detach();
        return false;

    }

    // Request absolute positions instead of relative motion.
    _ = backdoor(.command, 0x53424152);

    return true;

}

/// Disables VMware's pointer, handing pointer data back to the PS/2 stream.
fn detach() void {

    if (absolute) api.log("input: vmmouse failed; using PS/2\n");

    _ = backdoor(.command, 0xf5);
    absolute = false;
    received = 0;

}

/// Words queued by VMware's pointer, or null when it reports an error.
fn waiting() ?u16 {

    const status = backdoor(.status, 0)[0];

    return if (status & 0xffff0000 == 0xffff0000) null else @truncate(status);

}

/// One call through VMware's backdoor port, which the hypervisor answers even from ring 3.
fn backdoor(call: Backdoor, argument: u32) [4]u32 {

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("inl %%dx, %%eax" // Trap to VMware, which reads the call from the registers.
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [magic] "{eax}" (@as(u32, 0x564d5868)),
          [argument] "{ebx}" (argument),
          [call] "{ecx}" (@intFromEnum(call)),
          [port] "{edx}" (@as(u32, 0x5658)),
        : .{

            .rsi = true,
            .rdi = true,
            .memory = true,

        });

    return .{ eax, ebx, ecx, edx };

}

fn cpuid(leaf: u32) [4]u32 {

    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid" // Identify the processor, which ring 3 may do.
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );

    return .{ eax, ebx, ecx, edx };

}

fn flush() void {

    for (0..16) |_| {

        if (input(control) & 1 == 0) break;
        _ = input(data);

    }

}

fn command(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(control, byte);

}

fn send(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(data, byte);

}

fn receive() ?u8 {

    return if (wait(1, 1)) input(data) else null;

}

fn wait(mask: u8, value: u8) bool {

    const deadline = api.ticks() + 10;

    while (input(control) & mask != value) {

        if (api.ticks() >= deadline) return false;
        _ = api.raw(.yield, 0, 0, 0);

    }

    return true;

}

fn input(port: u16) u8 {

    const result = api.raw(.port, port, 0, 0);
    if (result.number != 0) api.exit(1);

    return @intCast(result.first);

}

fn output(port: u16, byte: u8) void {

    if (api.raw(.port, port, 1, byte).number != 0) api.exit(1);

}
