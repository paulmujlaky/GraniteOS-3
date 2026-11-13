const std = @import("std");

const boot = @import("../../boot/info.zig");
const process = @import("../../kernel/process.zig");
const memory = @import("../../kernel/memory.zig");
const schedule = @import("../../kernel/schedule.zig");
const acpi = @import("../../board/pc/acpi.zig");
pub const apic = @import("../../board/pc/apic.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const context = @import("context.zig");
const tables = @import("tables.zig");
const Log = @import("../../debug/log.zig").Log;

comptime {

    _ = &@import("dispatch.zig").dispatch;

}

pub const Core = struct {

    next: ?*Core = null,
    id: u32,
    online: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    tables: tables.Tables = .{

    },

    stack: usize,
    emergency: [3]usize,

    current: ?*process.Process = null,
    idle: context.Context,

    /// Sent a `wake` interrupt it has not yet taken.
    kicked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Retirements counted when it last entered the kernel; zero while it is outside.
    seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    ticks: u64 = 0,
    switches: u64 = 0,
    preemptions: u64 = 0,

};

pub var cores: ?*Core = null;
pub var kernel: paging.Space = undefined;
pub var core_count: usize = 0;

/// Device interrupt line `n` arrives as vector `legacy + n`: ISA's sixteen, then message-signalled ones up to `lines`.
pub const legacy = 48;
pub const lines = 32;

/// Interrupts an idle processor so it picks up a process that became ready, rather than at its next timer tick.
pub const wake = 0xf0;

// The MADT, kept to route device interrupts.
var routes: []const u8 = &.{};

var reset_port: u16 = 0;
var reset_value: u8 = 0;

var sleep_ports = [2]u16{ 0, 0 };
var sleep_types = [2]u8{ 0, 0 };

extern fn idle() callconv(.c) noreturn;

extern const trampoline_start: u8;
extern const trampoline_end: u8;
extern const trampoline_gdtr: u8;
extern const trampoline_jump: u8;
extern const trampoline_root: u8;
extern const trampoline_stack: u8;
extern const trampoline_entry: u8;
extern const trampoline_argument: u8;
extern const trampoline_long: u8;
extern const trampoline_gdt: u8;

pub fn prepare(info: *const boot.Info, frames: *memory.Frames, log: Log) !void {

    cpu.features();

    const firmware = try acpi.Acpi.init(info);
    const madt = try firmware.find("APIC") orelse return error.MissingMadt;

    try acpi.validateMadt(madt);

    routes = madt;
    apic.base = acpi.read(u32, madt, 36);

    var offset: usize = 44;

    while (offset < madt.len) : (offset += madt[offset + 1]) {

        if (madt[offset] == 5) apic.base = @intCast(acpi.read(u64, madt, offset + 4));

    }

    if (try firmware.find("FACP")) |fadt| {

        if (fadt.len >= 129 and acpi.read(u32, fadt, 112) & (1 << 10) != 0 and fadt[116] == 1 and fadt[117] == 8 and fadt[118] == 0 and fadt[119] <= 1) {

            const port = acpi.read(u64, fadt, 120);

            if (port <= 65535) {

                reset_port = @intCast(port);
                reset_value = fadt[128];

            }

        }

        if (fadt.len >= 116) {

            // TMR_VAL_EXT widens the PM timer from 24 to 32 bits; the extended block, when in I/O space, overrides the legacy one.
            const extended = fadt.len >= 220 and fadt[208] == 1 and acpi.read(u64, fadt, 212) != 0 and acpi.read(u64, fadt, 212) <= 65535;
            const timer = if (extended) acpi.read(u64, fadt, 212) else acpi.read(u32, fadt, 76);

            if (timer != 0 and timer <= 65535 and (extended or fadt[91] == 4)) {

                apic.pm_port = @intCast(timer);
                apic.pm_mask = if (acpi.read(u32, fadt, 112) & (1 << 8) != 0) 0xffffffff else 0xffffff;

            }

            const dsdt = if (fadt.len >= 148 and acpi.read(u64, fadt, 140) != 0) acpi.read(u64, fadt, 140) else acpi.read(u32, fadt, 40);
            const types = if (firmware.load(dsdt)) |bytes| acpi.sleepTypes(bytes) else |_| null;
            const first = acpi.read(u32, fadt, 64);
            const second = acpi.read(u32, fadt, 68);

            if (types != null and first != 0 and first <= 65535 and second <= 65535) {

                sleep_ports = .{ @intCast(first), @intCast(second) };
                sleep_types = types.?;

            }

        }

    }

    kernel = try paging.Space.init(frames);
    if (kernel.root >= 0x100000000) return error.HighBootstrapRoot;

    for (info.memory) |region| {

        switch (region.kind) {

            .available, .loader, .firmware, .runtime, .acpi, .persistent => try kernel.identity(@intCast(region.base), @intCast(region.size), paging.writable | paging.nx),
            // Runtime images keep their data inside code-typed pages, so firmware calls need both.
            .runtime_code => try kernel.identity(@intCast(region.base), @intCast(region.size), paging.writable),
            else => {

            },

        }

    }

    try kernel.identity(apic.base, 4096, paging.writable | paging.nx | paging.uncached);
    try kernel.protect(apic.base, paging.writable | paging.nx | paging.uncached);
    if (info.framebuffer) |framebuffer| if (reachable(framebuffer)) try kernel.identity(@intCast(framebuffer.base), @intCast(framebuffer.size), paging.writable | paging.nx | paging.combined);

    try protectImage(info);

    try kernel.identity(@intCast(info.trampoline), 4096, paging.writable | paging.nx);
    try kernel.protect(@intCast(info.trampoline), paging.writable);
    try kernel.guard(0);

    apic.choose(info.skip.x2apic);
    apic.init();

    const bsp = apic.id();

    if (bsp >= schedule.capacity) return error.UnsupportedApic;

    try addCore(bsp, frames);

    offset = 44;

    while (offset < madt.len) : (offset += madt[offset + 1]) {

        const kind = madt[offset];

        if (kind != 0 and kind != 9) continue;

        const id = if (kind == 0) @as(u32, madt[offset + 3]) else acpi.read(u32, madt, offset + 4);
        const flags = acpi.read(u32, madt, offset + (if (kind == 0) @as(usize, 4) else 8));

        if (flags & 1 == 0 or id == bsp or info.skip.processors) continue;

        // Interrupt routes name processors in eight bits, so ones past that stay parked.
        if (id >= schedule.capacity) {

            log.decimal("processor left offline", id);
            continue;

        }

        try addCore(id, frames);

    }

    tables.init();
    paging.activate(kernel.root);

    const current = local();

    current.tables.load(current.stack, current.emergency);
    current.online.store(true, .release);

    const source = try apic.calibrate();

    log.line(if (apic.inherited) "local APIC in x2APIC mode, as the firmware left it" else if (apic.x2apic) "local APIC in x2APIC mode" else "local APIC in xAPIC mode");
    log.line(switch (source) {

        .pm => "timer calibrated against the ACPI PM timer",
        .pit => "timer calibrated against the PIT",
        .cpuid => "timer set from CPUID frequencies",

    });
    log.decimal("processors", core_count);
    log.decimal("tsc per ms", apic.tsc_per_ms);
    log.decimal("timer count", apic.timer_count);

}

/// The kernel maps only the first 512 GiB, so a framebuffer above that is left to the display service.
pub fn reachable(framebuffer: boot.Framebuffer) bool {

    return framebuffer.base + framebuffer.size <= memory.physical_limit;

}

fn addCore(id: u32, frames: *memory.Frames) !void {

    var previous = cores;

    while (previous) |core| : (previous = core.next) {

        if (core.id == id) return error.DuplicateProcessor;

    }

    const core: *Core = @ptrFromInt(try frames.alloc());
    const stack = try frames.allocRun(9);
    const emergency = try frames.allocRun(9);

    try kernel.guard(stack);
    try kernel.guard(emergency);
    try kernel.guard(emergency + 3 * 4096);
    try kernel.guard(emergency + 6 * 4096);

    core.* = .{

        .next = cores,
        .id = id,

        .stack = stack + 9 * 4096,
        .emergency = .{

            emergency + 3 * 4096,
            emergency + 6 * 4096,
            emergency + 9 * 4096,

        },

        .idle = context.Context.init(@intFromPtr(&idle), stack + 9 * 4096 - 8, 0, true),

    };

    cores = core;
    core_count += 1;

}

fn protectImage(info: *const boot.Info) !void {

    const bytes = @as([*]const u8, @ptrFromInt(info.image.base))[0..info.image.size];
    const pe = acpi.read(u32, bytes, 0x3c);
    const count = acpi.read(u16, bytes, pe + 6);
    const optional = acpi.read(u16, bytes, pe + 20);

    for (0..count) |index| {

        const section = pe + 24 + optional + index * 40;
        const size = acpi.read(u32, bytes, section + 8);
        const address = info.image.base + acpi.read(u32, bytes, section + 12);
        const characteristics = acpi.read(u32, bytes, section + 36);
        const executable = characteristics & 0x20000000 != 0;
        const write = characteristics & 0x80000000 != 0;

        if (executable and write) return error.WritableCode;

        var page = address;

        while (page < address + size) : (page += 4096) try kernel.protect(@intCast(page), (if (executable) @as(u64, 0) else paging.nx) | (if (write) paging.writable else @as(u64, 0)));

    }

}

/// Delivers ISA interrupt `irq` to processor `target`.
pub fn route(irq: u4, target: u32) !void {

    const line = acpi.isa(routes, irq) orelse return error.NoDevice;
    const address: usize = @intCast(line.controller);

    try kernel.identity(address, 4096, paging.writable | paging.nx | paging.uncached);
    try kernel.protect(address, paging.writable | paging.nx | paging.uncached);
    if (!apic.redirect(line, legacy + @as(u8, irq), target)) return error.NoDevice;

}

/// The address and data a device writes to raise message-signalled line `line` on processor `target`.
pub fn message(line: u5, target: u32) struct { u64, u16 } {

    return .{ 0xfee00000 | @as(u64, target & 0xff) << 12, legacy + @as(u16, line) };

}

/// Sends idle processors other than `self` a `wake` interrupt, one for each process waiting to run; with too few idle, busy
/// processors that a process woke behind are interrupted too, so it need not wait out the timer.
pub fn kick(self: *const Core) void {

    var left = schedule.waiting();

    for ([_]bool{ false, true }) |busy| {

        var current = cores;

        while (current) |core| : (current = core.next) {

            if (left == 0) return;
            if (core == self or (@atomicLoad(?*process.Process, &core.current, .monotonic) != null) != busy or !core.online.load(.acquire)) continue;
            if (busy and !schedule.urgent(core.id)) continue;
            if (core.kicked.swap(true, .acq_rel)) continue;

            apic.send(core.id, 0x4000 | wake);
            left -= 1;

        }

    }

}

pub fn local() *Core {

    const id = apic.id();
    var current = cores;

    while (current) |core| : (current = core.next) {

        if (core.id == id) return core;

    }

    @panic("Unknown processor");

}

pub fn startOthers(info: *const boot.Info, entry: *const fn (*Core) callconv(.c) noreturn) !void {

    const size = @intFromPtr(&trampoline_end) - @intFromPtr(&trampoline_start);

    if (info.trampoline == 0 or info.trampoline >= 0x100000 or size > 4096) return error.InvalidTrampoline;

    const blob = @as([*]u8, @ptrFromInt(info.trampoline))[0..size];

    @memcpy(blob, @as([*]const u8, @ptrCast(&trampoline_start))[0..size]);
    patch(u32, blob, &trampoline_gdtr, 2, @intCast(info.trampoline + relative(&trampoline_gdt)));
    patch(u32, blob, &trampoline_jump, 0, @intCast(info.trampoline + relative(&trampoline_long)));
    patch(u64, blob, &trampoline_root, 0, kernel.root);
    patch(u64, blob, &trampoline_entry, 0, @intFromPtr(entry));

    var current = cores;

    while (current) |core| : (current = core.next) {

        if (core.online.load(.acquire)) continue;

        patch(u64, blob, &trampoline_stack, 0, core.stack);
        patch(u64, blob, &trampoline_argument, 0, @intFromPtr(core));

        apic.send(core.id, 0xc500);
        apic.delay(10);

        // x2APIC has no INIT level de-assert.
        if (!apic.x2apic) apic.send(core.id, 0x8500);
        apic.delay(1);
        apic.send(core.id, 0x600 | @as(u32, @intCast(info.trampoline >> 12)));
        apic.delay(1);
        if (!core.online.load(.acquire)) apic.send(core.id, 0x600 | @as(u32, @intCast(info.trampoline >> 12)));

        const start = cpu.ticks();

        while (!core.online.load(.acquire)) {

            if (cpu.ticks() -% start > apic.tsc_per_ms * 1000) return error.ProcessorStartupTimeout;

            cpu.relax();

        }

    }

    try kernel.protect(@intCast(info.trampoline), paging.nx);
    paging.activate(kernel.root);

}

fn relative(symbol: *const u8) usize {

    return @intFromPtr(symbol) - @intFromPtr(&trampoline_start);

}

fn patch(comptime T: type, blob: []u8, symbol: *const u8, extra: usize, value: T) void {

    std.mem.writeInt(T, blob[relative(symbol) + extra ..][0..@sizeOf(T)], value, .little);

}

/// Enters ACPI S5; returns only when the firmware described no usable sleep state.
pub fn shutdown() void {

    for (sleep_ports, sleep_types) |port, kind| {

        if (port != 0) cpu.out16(port, cpu.in16(port) & ~@as(u16, 0x3c00) | @as(u16, kind & 7) << 10 | 1 << 13);

    }

    if (sleep_ports[0] != 0) apic.delay(1000);

}

pub fn reboot() noreturn {

    if (reset_port != 0) cpu.out(reset_port, reset_value);
    cpu.out(0xcf9, 2);
    cpu.out(0xcf9, 6);

    for (0..100000) |_| {

        if (cpu.in(0x64) & 2 == 0) break;

        cpu.relax();

    }

    cpu.out(0x64, 0xfe);

    const empty = std.mem.zeroes([10]u8);

    asm volatile ("lidt (%[idtr]); int3" // Use an empty interrupt table to force a reset.
        :
        : [idtr] "r" (&empty),
        : .{

            .memory = true,

        });

    cpu.halt();

}

comptime {

    if (@sizeOf(Core) > 4096) @compileError("CPU exceeds a page");

}
