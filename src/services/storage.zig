const std = @import("std");

const nvme = @import("nvme.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const pages = 16;

const Port = enum(usize) {

    list = 0x00,
    list_high = 0x04,
    received = 0x08,
    received_high = 0x0c,
    status = 0x10,
    command = 0x18,
    task = 0x20,
    signature = 0x24,
    link = 0x28,
    errors = 0x30,
    issue = 0x38,

};

/// An AHCI port's disk, or an NVMe namespace when `namespace` is set.
const Disk = struct {

    port: usize = 0,
    sectors: u64,
    memory: api.Page = undefined,
    namespace: ?nvme.Namespace = null,

};

var registers: [*]volatile u32 = undefined;
var disks: [32]Disk = undefined;
var count: usize = 0;
var buffers: [pages]api.Page = undefined;
var wide = false;
var controllers: [4]nvme.Controller = undefined;

/// `base` is the AHCI controller's registers, zero without one; the environment's BARs are NVMe controllers' registers.
pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.dma) or api.permits(.ports) or api.permits(.management)) api.exit(2);

    for (&buffers) |*buffer| buffer.* = api.dma() catch api.exit(3);

    if (base != 0) ahci(base);

    for (environment.bars[0..controllers.len], &controllers) |bar, *controller| {

        if (bar.size != 0) drive(controller, bar.base, bar.size);

    }

    var text: [64]u8 = undefined;

    api.log(std.fmt.bufPrint(&text, "storage: ready ({d} disks)\n", .{count}) catch unreachable);

    while (true) {

        const request = api.receive(true) catch continue;

        api.answer(request, handle(request));

    }

}

/// Brings up the NVMe controller at `base` and adds its namespaces as disks.
fn drive(controller: *nvme.Controller, base: u64, size: u64) void {

    var text: [80]u8 = undefined;

    // Registers and the first doorbells fit in two pages unless the controller spaces doorbells widely.
    const span = @min(size, 0x10000);
    const mapped = api.map(base, span) catch |err| {

        api.log(std.fmt.bufPrint(&text, "storage: NVMe registers unmapped ({s})\n", .{@errorName(err)}) catch unreachable);
        return;

    };

    nvme.attach(controller, @intFromPtr(mapped), span, buffers[0]) catch |err| {

        api.log(std.fmt.bufPrint(&text, "storage: NVMe controller failed ({s})\n", .{@errorName(err)}) catch unreachable);
        return;

    };

    var found: [8]nvme.Namespace = undefined;
    const namespaces = nvme.namespaces(controller, found[0..@min(found.len, disks.len - count)]);

    for (found[0..namespaces]) |namespace| {

        disks[count] = .{

            .sectors = namespace.sectors,
            .namespace = namespace,

        };

        count += 1;

    }

    api.log(std.fmt.bufPrint(&text, "storage: NVMe controller with {d} namespaces\n", .{namespaces}) catch unreachable);

}

fn ahci(base: usize) void {

    const page = base & ~@as(usize, 4095);
    const first = (api.checked(api.raw(.map, page, 0, 0)) catch return).first;
    var mapped: usize = 4096;

    if (api.checked(api.raw(.map, page + 4096, 0, 0))) |second| {

        if (second.first == first + 4096) mapped += 4096;

    } else |_| {

    }

    registers = @ptrFromInt(first + base % 4096);
    wide = registers[0] & 1 << 31 != 0;
    registers[1] |= 1 << 31;

    for (buffers) |buffer| {

        if (wide or buffer.physical >> 32 == 0) continue;

        api.log("storage: AHCI controller cannot reach memory above 4 GiB\n");
        return;

    }

    const ports = @min(32, (mapped - base % 4096 - 0x100) / 0x80);
    const implemented = registers[3];

    for (0..ports) |index| {

        if (implemented & @as(u32, 1) << @intCast(index) != 0) attach(index);

    }

}

fn handle(request: api.Request) u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .info => if (value < count) disks[value].sectors else 0,
        .read => transfer(request, false, value),
        .write => transfer(request, true, value),
        .flush => if (value < count and flush(&disks[value])) 0 else protocol.invalid,
        .crash => api.crash(request),
        else => protocol.invalid,

    };

}

/// Moves the caller's window to or from disk `value >> 48`, starting at sector `value & 0xffffffffffff`.
fn transfer(request: api.Request, write: bool, value: u56) u64 {

    const index = value >> 48;
    const lba: u64 = value & 0xffffffffffff;
    const length = request.fourth;

    if (index >= count or length == 0 or length % 512 != 0 or length > pages * 4096) return protocol.invalid;

    const disk = &disks[index];
    const sectors = length / 512;
    const used = (length + 4095) / 4096;

    if (lba + sectors > disk.sectors) return protocol.invalid;

    if (write) {

        for (buffers[0..used], 0..) |buffer, page| api.fetch(request, page * 4096, buffer.bytes[0..@min(4096, length - page * 4096)]) catch return protocol.invalid;

    }

    const moved = if (disk.namespace) |namespace| nvme.transfer(namespace, write, lba, length, buffers[0..used]) else issue(disk, if (write) 0x35 else 0x25, lba, @intCast(sectors), write, length);

    if (!moved) return protocol.invalid;

    if (!write) {

        for (buffers[0..used], 0..) |buffer, page| api.store(request, page * 4096, buffer.bytes[0..@min(4096, length - page * 4096)]) catch return protocol.invalid;

    }

    return 0;

}

fn flush(disk: *const Disk) bool {

    if (disk.namespace) |namespace| return nvme.flush(namespace);

    return issue(disk, 0xea, 0, 0, false, 0);

}

fn attach(index: usize) void {

    if (port(index, .link).* & 0xf != 3 or !stop(index)) return;

    const memory = api.dma() catch return;
    if (!wide and memory.physical >> 32 != 0) return;

    port(index, .list).* = @truncate(memory.physical);
    port(index, .list_high).* = @truncate(memory.physical >> 32);
    port(index, .received).* = @truncate(memory.physical + 0x400);
    port(index, .received_high).* = @truncate((memory.physical + 0x400) >> 32);
    port(index, .errors).* = 0xffffffff;
    port(index, .status).* = 0xffffffff;
    port(index, .command).* |= 1 << 4;

    // ATAPI and port multipliers report other signatures.
    if (!wait(port(index, .task), 0x88, 0, 100) or port(index, .signature).* != 0x101) {

        _ = stop(index);
        return;

    }

    port(index, .command).* |= 1;

    const disk = &disks[count];

    disk.* = .{

        .port = index,
        .sectors = 0,
        .memory = memory,

    };

    if (!issue(disk, 0xec, 0, 0, false, 512)) return;

    const identity: *const [256]u16 = @ptrCast(buffers[0].bytes);

    // ponytail: LBA48 disks with 512-byte logical sectors only; 4Kn disks need sector scaling.
    if (identity[83] & 1 << 10 == 0) return;
    if (identity[106] & 0xd000 == 0x5000 and (@as(u32, identity[118]) << 16 | identity[117]) != 256) return;

    for (0..4) |word| disk.sectors |= @as(u64, identity[100 + word]) << @intCast(word * 16);
    count += 1;

}

fn issue(disk: *const Disk, command: u8, lba: u64, sectors: u16, write: bool, bytes: usize) bool {

    const memory: [*]volatile u8 = disk.memory.bytes;
    const header: [*]volatile u32 = @ptrCast(disk.memory.bytes);
    const table = disk.memory.physical + 0x800;
    const entries = (bytes + 4095) / 4096;

    header[0] = 5 | @as(u32, @intFromBool(write)) << 6 | @as(u32, @intCast(entries)) << 16;
    header[1] = 0;
    header[2] = @truncate(table);
    header[3] = @truncate(table >> 32);

    const fis = memory + 0x800;

    for (0..64) |offset| fis[offset] = 0;
    fis[0] = 0x27;
    fis[1] = 0x80;
    fis[2] = command;
    fis[7] = 0x40;
    fis[12] = @truncate(sectors);
    fis[13] = @truncate(sectors >> 8);

    for ([_]usize{ 4, 5, 6, 8, 9, 10 }, 0..) |offset, shift| fis[offset] = @truncate(lba >> @intCast(shift * 8));

    const prdt: [*]volatile u32 = @ptrCast(@alignCast(memory + 0x880));

    for (0..entries) |entry| {

        prdt[entry * 4] = @truncate(buffers[entry].physical);
        prdt[entry * 4 + 1] = @truncate(buffers[entry].physical >> 32);
        prdt[entry * 4 + 2] = 0;
        prdt[entry * 4 + 3] = @intCast(@min(4096, bytes - entry * 4096) - 1);

    }

    port(disk.port, .status).* = 0xffffffff;
    port(disk.port, .issue).* = 1;

    const deadline = api.ticks() + 500;
    var polls: usize = 0;

    while (port(disk.port, .issue).* & 1 != 0) : (polls += 1) {

        if (port(disk.port, .status).* & 1 << 30 != 0 or api.ticks() >= deadline) {

            recover(disk.port);
            return false;

        }

        // Most commands finish within a few polls, and yielding to a busy processor could cost a whole time slice.
        if (polls < 256) std.atomic.spinLoopHint() else _ = api.raw(.yield, 0, 0, 0);

    }

    return port(disk.port, .task).* & 1 == 0;

}

fn recover(index: usize) void {

    // ponytail: restarting the engine clears command errors; a hung device would need COMRESET.
    if (!stop(index)) return;

    port(index, .errors).* = 0xffffffff;
    port(index, .status).* = 0xffffffff;
    port(index, .command).* |= 1 << 4;
    port(index, .command).* |= 1;

}

fn stop(index: usize) bool {

    port(index, .command).* &= ~@as(u32, 1);
    if (!wait(port(index, .command), 1 << 15, 0, 50)) return false;

    port(index, .command).* &= ~@as(u32, 1 << 4);

    return wait(port(index, .command), 1 << 14, 0, 50);

}

fn wait(register: *volatile u32, mask: u32, value: u32, duration: u64) bool {

    const deadline = api.ticks() + duration;

    while (register.* & mask != value) {

        if (api.ticks() >= deadline) return false;
        _ = api.raw(.yield, 0, 0, 0);

    }

    return true;

}

fn port(index: usize, register: Port) *volatile u32 {

    return &registers[(0x100 + index * 0x80 + @intFromEnum(register)) / 4];

}
