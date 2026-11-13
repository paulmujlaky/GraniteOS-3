const cpu = @import("../../arch/x86/cpu.zig");
const acpi = @import("acpi.zig");

pub var base: usize = 0xfee00000;
pub var timer_count: u32 = 0;
pub var tsc_per_ms: u64 = 0;

/// Every processor reaches its local APIC through MSRs rather than memory-mapped registers.
pub var x2apic = false;

/// The firmware had already switched to x2APIC mode.
pub var inherited = false;

/// The ACPI PM timer's port, zero when the firmware described none, and which bits of it count.
pub var pm_port: u16 = 0;
pub var pm_mask: u32 = 0xffffff;

/// What the timer was calibrated against.
pub const Source = enum {

    pm,
    pit,
    cpuid,

};

pub const CalibrationError = error{TimerCalibration};

// The PM timer counts at 3.579545 MHz.
const pm_per_10ms = 35795;

pub fn read(offset: usize) u32 {

    if (x2apic) return @truncate(cpu.readMsr(msr(offset)));

    return @as(*volatile u32, @ptrFromInt(base + offset)).*;

}

pub fn write(offset: usize, value: u32) void {

    if (x2apic) return cpu.writeMsr(msr(offset), value);

    @as(*volatile u32, @ptrFromInt(base + offset)).* = value;
    _ = read(0x20);

}

/// The x2APIC MSR that mirrors xAPIC register `offset`.
fn msr(offset: usize) u32 {

    return @intCast(0x800 + offset / 16);

}

pub fn id() u32 {

    return if (x2apic) read(0x20) else read(0x20) >> 24;

}

/// Picks the register interface every processor uses; call once on the first processor, before `init`.
pub fn choose(legacy: bool) void {

    // Firmware that handed over in x2APIC mode cannot go back without disabling the APIC, which some platforms forbid.
    inherited = cpu.readMsr(0x1b) & 0x400 != 0;
    x2apic = inherited or !legacy and cpu.cpuid(1, 0)[2] & (1 << 21) != 0;

}

pub fn init() void {

    const value = cpu.readMsr(0x1b);

    if (x2apic) {

        // Entering x2APIC mode from xAPIC or disabled mode takes both enable bits at once.
        cpu.writeMsr(0x1b, value | 0xc00);

    } else {

        if (value & 0x400 != 0) @panic("x2APIC mode on one processor only");
        cpu.writeMsr(0x1b, base | (value & 0x100) | 0x800);

    }

    write(0x80, 0);
    write(0xf0, 0x1ff);

    write(0x320, 1 << 16);
    write(0x350, 1 << 16);
    write(0x360, 1 << 16);
    write(0x370, 1 << 16);

    write(0x280, 0);
    write(0xb0, 0);

}

/// Measures the TSC and the APIC timer against the ACPI PM timer, then the PIT, then the frequencies CPUID reports.
pub fn calibrate() CalibrationError!Source {

    cpu.out(0x21, 0xff);
    cpu.out(0xa1, 0xff);

    write(0x3e0, 3);

    if (pm()) return .pm;
    if (pit()) return .pit;
    if (frequencies()) return .cpuid;

    return error.TimerCalibration;

}

fn pm() bool {

    if (pm_port == 0) return false;

    const first = pmCount();
    var start = first;
    var attempts: usize = 0;

    // Starting on a tick edge keeps the measurement within one PM tick; a counter that never moves is absent.
    while (start == first) : (attempts += 1) {

        if (attempts == 1_000_000) return false;
        start = pmCount();

    }

    write(0x380, 0xffffffff);
    const begin = cpu.ticks();

    attempts = 0;

    while ((pmCount() -% start) & pm_mask < pm_per_10ms) : (attempts += 1) {

        if (attempts == 100_000_000) return false;
        cpu.relax();

    }

    return measured(begin);

}

fn pmCount() u32 {

    return cpu.in32(pm_port) & pm_mask;

}

fn pit() bool {

    const speaker = cpu.in(0x61);
    defer cpu.out(0x61, speaker);

    cpu.out(0x61, speaker & ~@as(u8, 3));
    cpu.out(0x43, 0xb0);
    cpu.out(0x42, 0x9c);
    cpu.out(0x42, 0x2e);

    write(0x380, 0xffffffff);

    const begin = cpu.ticks();

    cpu.out(0x61, (speaker & ~@as(u8, 2)) | 1);

    // Channel 2's output stays low until the count runs out, so one already high means a gated or missing PIT.
    if (cpu.in(0x61) & 0x20 != 0) return false;

    var attempts: usize = 0;

    while (cpu.in(0x61) & 0x20 == 0) : (attempts += 1) {

        if (attempts == 1_000_000) return false;
        cpu.relax();

    }

    return measured(begin);

}

/// Records a 10 ms measurement that began at TSC `begin`; implausibly slow clocks mean the reference lied.
fn measured(begin: u64) bool {

    const tsc = (cpu.ticks() - begin) / 10;
    const count = 0xffffffff - read(0x390);

    if (tsc < 200_000 or count < 100) return false;

    tsc_per_ms = tsc;
    timer_count = count;

    return true;

}

fn frequencies() bool {

    const top = cpu.cpuid(0, 0)[0];

    // Hypervisors report TSC and APIC bus rates in kHz at leaf 0x40000010.
    if (cpu.cpuid(1, 0)[2] & (1 << 31) != 0 and cpu.cpuid(0x40000000, 0)[0] >= 0x40000010) {

        const rates = cpu.cpuid(0x40000010, 0);

        if (rates[0] != 0 and rates[1] != 0) return set(rates[0], @as(u64, rates[1]) * 1000);

    }

    if (top < 0x15) return false;

    const ratio = cpu.cpuid(0x15, 0);

    if (ratio[0] == 0 or ratio[1] == 0) return false;

    var crystal: u64 = ratio[2];

    // Without a crystal rate, the base frequency times the ratio's inverse gives it.
    if (crystal == 0 and top >= 0x16) crystal = @as(u64, cpu.cpuid(0x16, 0)[0] & 0xffff) * 1_000_000 * ratio[0] / ratio[1];
    if (crystal == 0) return false;

    // The APIC timer runs from the core crystal on processors that report one.
    return set(crystal * ratio[1] / ratio[0] / 1000, crystal);

}

fn set(tsc_khz: u64, apic_hz: u64) bool {

    if (tsc_khz < 200_000 or apic_hz / 1600 < 100 or apic_hz / 1600 > 0xffffffff) return false;

    tsc_per_ms = tsc_khz;
    timer_count = @intCast(apic_hz / 1600);

    return true;

}

pub fn timer() void {

    write(0x3e0, 3);
    write(0x320, 32 | (1 << 17));
    write(0x380, timer_count);

}

pub fn delay(milliseconds: u64) void {

    const start = cpu.ticks();

    while (cpu.ticks() -% start < milliseconds * tsc_per_ms) cpu.relax();

}

pub fn send(target: u32, command: u32) void {

    // x2APIC interrupt commands are accepted at once, with the destination in the upper half.
    if (x2apic) return cpu.writeMsr(0x830, @as(u64, target) << 32 | command);

    const start = cpu.ticks();

    while (read(0x300) & (1 << 12) != 0) {

        if (cpu.ticks() -% start > tsc_per_ms * 1000) @panic("APIC delivery timeout");
        cpu.relax();

    }

    write(0x310, target << 24);
    write(0x300, command);

}

pub fn stopOthers() void {

    write(0x300, 0xc0400);

}

/// Sends I/O APIC input `route` to processor `target` as `vector`; false when the controller lacks that input.
pub fn redirect(route: acpi.Route, vector: u8, target: u32) bool {

    const select: *volatile u32 = @ptrFromInt(route.controller);
    const window: *volatile u32 = @ptrFromInt(route.controller + 0x10);

    // Register 1 holds the last input's index in bits 16-23.
    select.* = 1;
    if (route.pin > window.* >> 16 & 0xff) return false;

    // ponytail: level-triggered lines refire until the device is serviced; mask them until the service is done if one appears.
    select.* = 0x11 + route.pin * 2;
    window.* = target << 24;
    select.* = 0x10 + route.pin * 2;
    window.* = vector | @as(u32, @intFromBool(route.low)) << 13 | @as(u32, @intFromBool(route.level)) << 15;

    return true;

}
