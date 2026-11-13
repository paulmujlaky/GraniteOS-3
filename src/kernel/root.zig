const std = @import("std");

const boot = @import("../boot/info.zig");
const arch = @import("../arch/root.zig");
const memory = @import("memory.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const check = @import("check.zig");
const service = @import("service.zig");
const shared = @import("shared.zig");
const schedule = @import("schedule.zig");
const debug = @import("../debug/log.zig");
const screen = @import("../debug/screen.zig");
const firmware = @import("../boot/uefi/variable.zig");
const Lock = @import("lock.zig").Lock;
const Table = @import("table.zig").Table;
const Log = debug.Log;

const options = @import("options");

const machine = arch.machine;
const List = std.DoublyLinkedList;
pub var frames: memory.Frames = undefined;
pub var processes: Table = .{};
pub var log: Log = undefined;
var launched = std.atomic.Value(bool).init(false);
pub var failed = std.atomic.Value(bool).init(false);
var initialized = false;
pub var framebuffer: ?boot.Framebuffer = null;
pub var primary: u32 = 0;
pub var ticks = std.atomic.Value(u64).init(0);
pub var runtime: u64 = 0;
pub var efi: ?boot.Region = null;

/// What the boot menu left out.
pub var skip: boot.Skip = .{};

/// Local time in seconds since 1970 when the loader read the firmware clock; `ticks` counts on from there.
pub var epoch: u64 = 0;

// Each processor records this count on entering the kernel, so a process retired since is freed only once all have left.
var retirements = std.atomic.Value(u64).init(1);
var retired: List = .{};
var retired_lock: Lock = .{};

pub fn start(info: *const boot.Info, output: Log) !noreturn {

    log = output;
    framebuffer = info.framebuffer;
    if (framebuffer) |display| if (machine.reachable(display)) screen.attach(display);
    runtime = info.runtime;
    efi = info.efi;
    skip = info.skip;
    epoch = info.clock;
    if (info.version != 3 or info.memory.len == 0) return error.InvalidBootInfo;

    log.line("start");
    log.hex("image base", info.image.base);

    const size = try memory.Frames.storageSize(info.memory);
    var storage: ?[]u8 = null;

    for (info.memory) |region| {

        if (region.kind != .available or region.base < 0x100000 or region.size < std.mem.alignForward(usize, size, 4096)) continue;

        storage = @as([*]u8, @ptrFromInt(region.base))[0..size];

        break;

    }

    const bits = storage orelse return error.OutOfMemory;

    frames = try memory.Frames.init(info.memory, bits, @intFromPtr(bits.ptr), std.mem.alignForward(usize, size, 4096));
    log.decimal("free pages", frames.free_count);

    try machine.prepare(info, &frames, log);
    initialized = true;
    primary = machine.local().id;
    try arrange();
    log.line("memory protected");

    if (options.self_test) try check.start(info);
    try machine.startOthers(info, secondary);
    log.line("all processors online");

    if (!options.self_test) {

        try service.start();
        ready();

    }

    launched.store(true, .release);
    machine.apic.timer();
    arch.context.restore(&machine.local().idle);

}

/// Sizes the process table and gives every processor its alarms.
fn arrange() !void {

    // Each process takes well over 16 pages, so there are never more processes than buckets.
    processes.buckets = try zeroed(?*process.Process, @max(frames.total / 16, 1));

    var cores = machine.cores;

    while (cores) |core| : (cores = core.next) schedule.prepare(core.id, try zeroed(List, schedule.slots));

}

/// Room for `count` zeroed values, in pages of their own.
fn zeroed(comptime T: type, count: usize) ![]T {

    const size = std.mem.alignForward(usize, count * @sizeOf(T), 4096);
    const base = try frames.allocRun(size / 4096);

    @memset(@as([*]u8, @ptrFromInt(base))[0..size], 0);

    return @as([*]T, @ptrFromInt(base))[0..count];

}

/// Creates a process homed on processor `home`, held until `schedule.start` queues it.
pub fn spawn(bytes: []const u8, argument: usize, home: u32) !*process.Process {

    var cores = machine.cores;

    while (cores) |core| : (cores = core.next) {

        if (core.id == home) break;

    } else return error.InvalidProcessor;

    const task = try process.Process.create(machine.kernel, bytes, 0, argument, home);
    errdefer task.destroy();

    try processes.insert(task);
    _ = schedule.processors[home].homed.fetchAdd(1, .monotonic);

    return task;

}

pub fn ready() void {

    if (framebuffer) |display| {

        if (!machine.reachable(display)) return;

        const pixels: [*]volatile u32 = @ptrFromInt(display.base);

        for (0..@min(display.height, 24)) |y| {

            for (0..display.width) |x| pixels[y * display.stride + x] = display.green_mask;

        }

    }

    log.line("ready");

}

fn secondary(core: *machine.Core) callconv(.c) noreturn {

    arch.cpu.features();
    arch.paging.activate(machine.kernel.root);
    core.tables.load(core.stack, core.emergency);
    machine.apic.init();
    core.online.store(true, .release);

    while (!launched.load(.acquire)) arch.cpu.relax();

    machine.apic.timer();
    arch.context.restore(&core.idle);

}

pub fn exited(task: *process.Process, status: u64) void {

    if (options.self_test) check.exited(task, status);
    log.decimal("exited process", task.id);
    log.decimal("exit status", status);

}

/// Ends `task`, which the caller holds when `holder` is set; another processor holding it ends it on letting go instead.
pub fn kill(task: *process.Process, holder: bool) void {

    const guard = ipc.guard(task);

    if (task.state == .dead or !schedule.claim(task, holder)) {

        guard.lock.release();
        return;

    }

    if (guard != task) ipc.leave(guard, task);
    task.state = .dead;
    guard.lock.release();

    ipc.cancel(task);
    service.revoke(task.id);
    service.departed(task.id);
    shared.departed(task.id);
    retire(task);

}

/// Takes `task` out of the table, to be freed once no processor can still hold a pointer to it.
fn retire(task: *process.Process) void {

    retired_lock.acquire();
    defer retired_lock.release();

    processes.remove(task);
    task.retired = retirements.fetchAdd(1, .seq_cst);
    retired.append(&task.link);

}

/// Frees retired processes once no processor can still hold a pointer to them.
pub fn collect() void {

    if (@atomicLoad(?*List.Node, &retired.first, .monotonic) == null) return;

    retired_lock.acquire();
    defer retired_lock.release();

    while (retired.first) |node| {

        const task = process.Process.from("link", node);

        if (!passed(task.retired)) break;

        retired.remove(node);
        task.destroy();

    }

}

/// Every processor left the kernel, or entered it again, after retirement `mark`.
fn passed(mark: u64) bool {

    var cores = machine.cores;

    while (cores) |core| : (cores = core.next) {

        const seen = core.seen.load(.seq_cst);

        if (seen != 0 and seen <= mark) return false;

    }

    return true;

}

/// Records that `core` is in the kernel, where it may hold pointers to processes retired from now on.
pub fn enter(core: *machine.Core) void {

    core.seen.store(retirements.load(.seq_cst), .seq_cst);

}

pub fn leave(core: *machine.Core) void {

    core.seen.store(0, .release);

}

/// No process is left, alive or awaiting release.
pub fn settled() bool {

    retired_lock.acquire();
    defer retired_lock.release();

    return @atomicLoad(usize, &processes.count, .monotonic) == 0 and retired.first == null;

}

pub fn failure(message: []const u8) noreturn {

    failureAt(message, @returnAddress());

}

pub fn failureAt(message: []const u8, address: ?usize) noreturn {

    beginFailure();
    reportFailure(message, address);

}

pub fn beginFailure() void {

    arch.cpu.disable();
    if (failed.swap(true, .acq_rel)) arch.cpu.halt();
    if (initialized) machine.apic.stopOthers();
    debug.stopped = true;

}

/// Saves the end of the log in a firmware variable, so the next boot can show what went wrong.
fn keep() void {

    var tail: [2048]u8 = undefined;
    const count = screen.recent(&tail, screen.held() -| tail.len);

    firmware.keepFailure(runtime, tail[0..count]) catch {

    };

}

pub fn reportFailure(message: []const u8, address: ?usize) noreturn {

    const visible = screen.reclaim();

    log.err(message);
    if (address) |value| log.hex("failure address", value);
    // Without a serial port the screen is the only record, so it stays up to be read: until reset if no clock is calibrated yet.
    if (visible and !initialized) {

        log.line("halted after kernel failure; reset to restart");
        keep();
        arch.cpu.halt();

    }

    keep();
    log.line("rebooting after kernel failure");
    if (initialized) machine.apic.delay(if (visible) 60_000 else 1000);
    machine.reboot();

}
