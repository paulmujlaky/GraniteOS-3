const std = @import("std");

const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");
const schedule = @import("schedule.zig");
const pci = @import("../board/pc/pci.zig");
const screen = @import("../debug/screen.zig");
const machine = @import("../arch/root.zig").machine;
const Lock = @import("lock.zig").Lock;

// Guards the supervisor's restart, device probing, and interrupt routing.
var lock: Lock = .{};

var listeners = [_]u64{0} ** machine.lines;
var supervisor: u64 = 0;
var restarting = false;
var attempts: u8 = 0;
var due: u64 = 0;
var controller: ?pci.Bar = null;
var drives = [_]?pci.Bar{null} ** 4;
var disks_probed = false;
var host: ?pci.Bar = null;

/// A device a driver service runs through BAR 0 alone: its PCI function, vendor and device ids, and registers.
const Function = struct {

    at: u32,
    device: u32,
    registers: pci.Bar,

};

var nic: ?Function = null;
var sound: ?Function = null;

/// The message-signalled lines the Ethernet and HD Audio controllers raise.
const ethernet_line = 16;
const audio_line = 17;

/// The display's graphics device: its PCI vendor and device ids, and the BARs it needs.
const Graphics = struct {

    device: u32,
    bars: [3]pci.Bar,

};

const vmware = 0x0405_15ad;

var adapter: ?Graphics = null;
var probed = false;

pub fn start() !void {

    const task = try root.spawn(@embedFile("supervisor"), @intFromBool(supervisor != 0), root.primary);
    errdefer root.kill(task, true);

    try task.configure(.service, &.{

        .ipc, .time, .management, .diagnostics, .power

    });

    try task.grant(.manage, 0, 1);
    try task.grant(.power, 0, 1);
    try task.grant(.log, 0, 1);
    try adopt(task);

    lock.acquire();
    supervisor = task.id;
    restarting = false;
    lock.release();

    schedule.start(task);
    root.log.line("supervisor started");

}

/// Hands the previous supervisor's children to `task`.
fn adopt(task: *process.Process) !void {

    root.processes.lock.acquire();
    defer root.processes.lock.release();

    var children = root.processes.iterate();

    while (children.next()) |child| {

        if (child.owner != supervisor or child.image == null or child.state == .dead) continue;
        try child.grant(.send, task.id, 1);
        try task.grant(.send, child.id, 1);

    }

    // Publish ownership only after every replacement capability exists.
    children = root.processes.iterate();

    while (children.next()) |child| {

        if (child.owner == supervisor and child.image != null) child.owner = task.id;

    }

}

pub fn endpoint(owner: u64) ipc.IpcError!u64 {

    lock.acquire();
    defer lock.release();

    if (owner == 0 or owner != supervisor) return error.PermissionDenied;
    if (restarting or root.processes.find(supervisor) == null) return error.NoProcess;

    return supervisor;

}

pub fn departed(id: u64) void {

    lock.acquire();
    defer lock.release();

    if (id != supervisor) return;
    restarting = true;
    due = root.ticks.load(.monotonic) +| 10;

}

pub fn maintain() void {

    if (!@atomicLoad(bool, &restarting, .monotonic)) return;

    lock.acquire();

    // Clearing `restarting` claims this attempt, so only one processor makes it.
    const ready = restarting and attempts != 3 and root.ticks.load(.monotonic) >= due;

    if (ready) {

        attempts += 1;
        restarting = false;

    }

    lock.release();

    if (!ready) return;

    start() catch {

        lock.acquire();
        restarting = true;
        due = root.ticks.load(.monotonic) +| 100;
        lock.release();
        root.log.line("supervisor recovery failed");

    };

}

/// Starts `image` for `owner`, lending it `identity` when given.
pub fn spawn(owner: *process.Process, image: abi.Image, argument: u64, identity: ?abi.Identity) !*process.Process {

    const bytes = switch (image) {

        inline else => |tag| @embedFile(@tagName(tag)),

    };

    try probe(image);

    const task = try root.spawn(bytes, argument, schedule.quietest());
    errdefer root.kill(task, true);

    task.owner = owner.id;
    task.image = image;
    task.generation = argument;
    task.context.frame.rsi = 0;

    switch (image) {

        .serial => try task.configure(.service, &.{

            .ipc, .time, .ports

        }),
        .helper => try task.configure(.service, &.{

            .ipc

        }),
        .storage => {

            try task.configure(.service, &.{

                .ipc, .time, .mmio, .dma, .diagnostics

            });

            try task.grant(.log, 0, 1);

            if (controller) |ahci| {

                const page = ahci.base & ~@as(u64, 4095);

                try task.grant(.mmio, page, std.mem.alignForward(u64, ahci.base + ahci.size, 4096) - page);
                task.context.frame.rsi = ahci.base;

            }

            for (drives, 0..) |entry, index| {

                const nvme = entry orelse continue;

                try task.grant(.mmio, nvme.base, nvme.size);
                task.environment.bars[index] = .{

                    .base = nvme.base,
                    .size = nvme.size,

                };

            }

        },
        .files => {

            try task.configure(.service, &.{

                .ipc, .diagnostics

            });

            try task.grant(.log, 0, 1);

        },
        .accounts => {

            try task.configure(.service, &.{

                .ipc, .accounts, .diagnostics

            });

            try task.grant(.log, 0, 1);

        },
        .install => {

            try task.configure(.service, &.{

                .ipc, .mmio, .firmware, .diagnostics

            });

            try task.grant(.log, 0, 1);

            if (root.efi) |file| {

                const page = file.base & ~@as(u64, 4095);

                try task.grant(.mmio, page, std.mem.alignForward(u64, file.base + file.size, 4096) - page);
                task.context.frame.rsi = file.base;
                task.context.frame.rcx = file.size;

            }

        },
        .display => {

            try task.configure(.service, &.{

                .ipc, .time, .memory, .mmio, .ports, .dma, .diagnostics

            });

            try task.grant(.log, 0, 1);

            if (root.framebuffer) |display| {

                const page = display.base & ~@as(u64, 4095);

                try task.grant(.mmio, page, std.mem.alignForward(u64, display.base + @as(u64, display.stride) * display.height * 4, 4096) - page);
                task.context.frame.rsi = display.base;
                task.context.frame.rcx = display.width | @as(u64, display.height) << 16 | @as(u64, display.stride) << 32;
                task.context.frame.r8 = @ctz(display.red_mask) | @as(u64, @ctz(display.green_mask)) << 8 | @as(u64, @ctz(display.blue_mask)) << 16;

            }

            // The display draws the screen from now on; the log keeps its history for a kernel failure.
            screen.release();

            if (adapter) |graphics| {

                const bars = graphics.bars;

                // Screen objects keep VRAM on the device side, so only the ports and command FIFO are granted; Intel's registers and GTT share BAR 0.
                if (graphics.device == vmware) {

                    try task.grant(.port, bars[0].base, bars[0].size);
                    try task.grant(.mmio, bars[2].base, bars[2].size);

                } else {

                    try task.grant(.mmio, bars[0].base, bars[0].size);

                }

                task.environment.device = graphics.device;

                for (bars, 0..) |entry, index| task.environment.bars[index] = .{

                    .base = entry.base,
                    .size = entry.size,
                    .ports = entry.ports,

                };

            }

        },
        .input => {

            try task.configure(.service, &.{

                .ipc, .time, .ports, .diagnostics

            });

            try task.grant(.port, 0x60, 1);
            try task.grant(.port, 0x64, 1);
            try task.grant(.log, 0, 1);

            // The PS/2 keyboard and mouse.
            try listen(task, 1);
            try listen(task, 12);

        },
        .usb => {

            try task.configure(.service, &.{

                .ipc, .time, .mmio, .dma, .diagnostics

            });

            const page = host.?.base & ~@as(u64, 4095);

            try task.grant(.mmio, page, std.mem.alignForward(u64, host.?.base + host.?.size, 4096) - page);
            try task.grant(.log, 0, 1);
            task.context.frame.rsi = host.?.base;
            task.context.frame.rcx = host.?.size;

        },
        .net => try drive(task, nic.?, ethernet_line),
        .audio => try drive(task, sound.?, audio_line),
        .metrics => {

            try task.configure(.service, &.{

                .ipc, .time, .memory, .network, .diagnostics

            });

            try task.grant(.log, 0, 1);

        },
        // Applications keep the default application policy, with the network for those granted it.
        else => if (image.networked()) try task.configure(.application, &.{

            .ipc, .memory, .time, .network

        }),

    }

    try task.grant(.send, owner.id, 1);
    if (image == .serial) try task.grant(.port, 0x2f8, 8);
    try owner.grant(.send, task.id, 1);
    if (identity) |value| task.identity = value;
    schedule.start(task);

    return task;

}

/// Finds the device `image` drives, the first time it starts; fails when there is none.
fn probe(image: abi.Image) !void {

    lock.acquire();
    defer lock.release();

    const skip = root.skip;

    if (image == .usb and skip.usb or image == .audio and skip.audio or image == .net and skip.network) return error.NoDevice;

    if (image == .storage and !disks_probed) {

        disks_probed = true;

        // AHCI: mass storage, SATA, AHCI 1.0; ABAR is BAR 5. NVMe: mass storage, non-volatile memory, NVMe; BAR 0.
        controller = if (pci.find(.{ .class = 0x010601 })) |at| pci.bar(at, 5) else null;

        if (!skip.nvme) for (&drives, 0..) |*entry, index| {

            entry.* = if (pci.nth(.{ .class = 0x010802 }, index)) |at| pci.bar(at, 0) else null;

        };

    }

    if (image == .storage and controller == null and drives[0] == null) return error.NoDevice;

    if (image == .display and !probed) {

        probed = true;
        adapter = svga() orelse intel();

    }

    if (image == .display and root.framebuffer == null and adapter == null) return error.NoDevice;

    // xHCI: serial bus, USB, xHCI; its registers are BAR 0. The chipset's own controller serves most ports, so it comes first.
    if (image == .usb and host == null) host = if (intelHost() orelse pci.find(.{ .class = 0x0c0330 })) |at| pci.bar(at, 0) else null;
    if (image == .usb and host == null) return error.NoDevice;

    if (image == .net and nic == null) nic = ethernet();
    if (image == .net and nic == null) return error.NoDevice;

    if (image == .audio and sound == null) sound = audio();
    if (image == .audio and sound == null) return error.NoDevice;

}

fn intelHost() ?u32 {

    var index: usize = 0;

    while (pci.nth(.{ .class = 0x0c0330 }, index)) |at| : (index += 1) {

        if (pci.id(at) & 0xffff == 0x8086) return at;

    }

    return null;

}

/// Grants a driver service `function`'s registers and DMA, routing its interrupts to it as `line`.
fn drive(task: *process.Process, function: Function, line: u5) !void {

    try task.configure(.service, &.{

        .ipc, .time, .memory, .mmio, .dma, .diagnostics

    });

    try task.grant(.mmio, function.registers.base, function.registers.size);
    try task.grant(.log, 0, 1);

    task.environment.device = function.device;
    task.environment.bars[0] = .{

        .base = function.registers.base,
        .size = function.registers.size,

    };

    task.environment.signal = message(task, function.at, line);

}

fn listen(task: *process.Process, irq: u4) !void {

    lock.acquire();
    defer lock.release();

    try machine.route(irq, task.home);
    @atomicStore(u64, &listeners[irq], task.id, .release);

}

/// Routes function `at`'s message-signalled interrupts to `task` as `line`; returns the signal bit, or zero when it has none.
fn message(task: *process.Process, at: u32, line: u5) u64 {

    lock.acquire();
    defer lock.release();

    const address, const data = machine.message(line, task.home);

    // The listener comes first, so no interrupt goes to the process this one replaces.
    @atomicStore(u64, &listeners[line], task.id, .release);
    if (!pci.msi(at, address, data)) return 0;

    return @as(u64, 1) << line;

}

/// Hands interrupt line `line` to its listener, if that process still runs.
pub fn interrupt(line: u5) void {

    const task = root.processes.find(@atomicLoad(u64, &listeners[line], .acquire)) orelse return;

    ipc.signal(task, @as(u64, 1) << line);

}

/// VMware SVGA II: I/O ports, VRAM, and command FIFO.
fn svga() ?Graphics {

    const at = pci.find(.{ .id = vmware }) orelse return null;

    return .{

        .device = vmware,
        .bars = .{

            pci.bar(at, 0) orelse return null,
            pci.bar(at, 1) orelse return null,
            pci.bar(at, 2) orelse return null,

        },

    };

}

/// The I225 and I226 2.5GbE controllers, whose registers and descriptors the e1000e driver does not speak.
const igc = [_]u16{ 0x15f2, 0x15f3, 0x15f7, 0x15f8, 0x15fd, 0x125b, 0x125c, 0x125d, 0x125f, 0x3100, 0x3101, 0x3102, 0x5502 };

/// An Intel Ethernet controller of the e1000e family, such as VMware's 82574L or the I219-V: its registers are BAR 0.
fn ethernet() ?Function {

    const at = pci.find(.{ .class = 0x020000 }) orelse return null;
    const device = pci.id(at);

    if (device & 0xffff != 0x8086) return null;
    if (std.mem.indexOfScalar(u16, &igc, @intCast(device >> 16)) != null) return null;

    return .{

        .at = at,
        .device = device,
        .registers = pci.bar(at, 0) orelse return null,

    };

}

/// Intel PCH audio controllers that only snoop the processor's caches when told to: Sunrise Point, Kaby Point, and Cannon Point.
const unsnooped = [_]u16{ 0xa170, 0x9d70, 0x9d71, 0xa2f0, 0xa348, 0x9dc8 };

/// An HD Audio controller, such as VMware's or the Coffee Lake PCH's: a multimedia audio device whose registers are BAR 0.
fn audio() ?Function {

    const at = pci.find(.{ .family = 0x0403 }) orelse return null;
    const device = pci.id(at);

    if (device & 0xffff == 0x8086) {

        // Traffic class 0, as some codecs crackle otherwise.
        pci.modify(at, 0x44, 0x7, 0);

        if (std.mem.indexOfScalar(u16, &unsnooped, @intCast(device >> 16)) != null) pci.modify(at, 0x78, 1 << 11, 0);

    }

    return .{

        .at = at,
        .device = device,
        .registers = pci.bar(at, 0) orelse return null,

    };

}

/// Intel integrated graphics, such as the UHD Graphics 630: a display controller from Intel, whose registers and GTT are BAR 0.
fn intel() ?Graphics {

    const at = pci.find(.{ .class = 0x030000 }) orelse return null;
    const device = pci.id(at);

    if (device & 0xffff != 0x8086) return null;

    return .{

        .device = device,
        .bars = .{ pci.bar(at, 0) orelse return null, .{ .base = 0, .size = 0 }, .{ .base = 0, .size = 0 } },

    };

}

pub fn inspect(owner: *process.Process, image: abi.Image) ?*process.Process {

    root.processes.lock.acquire();
    defer root.processes.lock.release();

    var tasks = root.processes.iterate();

    while (tasks.next()) |task| {

        if (task.owner == owner.id and task.image == image and task.state != .dead) return task;

    }

    return null;

}

pub fn connect(owner: *process.Process, source: u64, destination: u64) !void {

    const sender = root.processes.find(source) orelse return error.NoProcess;
    const receiver = root.processes.find(destination) orelse return error.NoProcess;

    if (sender.owner != owner.id or receiver.owner != owner.id) return error.Denied;
    if (receiver.image) |image| if (image.gate()) |needed| if (!sender.policy.permits(needed)) return error.Denied;
    try sender.allow(.send, destination, 1);

}

pub fn revoke(id: u64) void {

    root.processes.lock.acquire();
    defer root.processes.lock.release();

    var tasks = root.processes.iterate();

    while (tasks.next()) |task| task.withdraw(id);

}
