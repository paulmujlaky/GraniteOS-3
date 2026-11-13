//! NVMe controllers for the storage service: one admin and one I/O queue pair each, one command in flight, polled.

const std = @import("std");

const api = @import("api");

/// Queue entries; the service waits on each command, so a few slots are plenty.
const depth = 16;

pub const Error = error{

    Unsupported,
    Timeout,
    Failed,
    Exhausted,

};

const Queue = struct {

    id: u16,
    submissions: api.Page,
    completions: api.Page,

    size: u16 = 2,
    tail: u16 = 0,
    head: u16 = 0,
    phase: bool = true,
    serial: u16 = 0,

};

pub const Controller = struct {

    registers: usize,
    stride: usize,

    admin: Queue,
    io: Queue,

    /// Lists data pages past the first for commands that span more than two.
    list: api.Page,

    /// The most bytes one command may move.
    limit: usize,

    /// Doubles as the identify buffer.
    scratch: api.Page,

};

/// A namespace with 512-byte blocks, addressed as one storage-service disk.
pub const Namespace = struct {

    controller: *Controller,
    id: u32,
    sectors: u64,

};

/// Resets the controller whose first `span` bytes of registers are at `registers` and starts its queues, identifying into `scratch`.
pub fn attach(controller: *Controller, registers: usize, span: usize, scratch: api.Page) Error!void {

    const capabilities = read64(registers, 0x00);

    // Command set NVM, 4 KiB memory pages, and both queue pairs' doorbells mapped.
    if (capabilities >> 37 & 1 == 0 or capabilities >> 48 & 0xf != 0) return error.Unsupported;
    if (0x1000 + 4 * (@as(usize, 4) << @intCast(capabilities >> 32 & 0xf)) > span) return error.Unsupported;

    controller.* = .{

        .registers = registers,
        .stride = @as(usize, 4) << @intCast(capabilities >> 32 & 0xf),

        .admin = try queue(0),
        .io = try queue(1),

        .list = api.dma() catch return error.Exhausted,
        .limit = 0x10000,
        .scratch = scratch,

    };

    // CAP.TO counts the longest a ready transition takes, in 500 ms units.
    const patience = @max(@as(u64, capabilities >> 24 & 0xff), 1) * 50;
    const slots: u32 = @intCast(@min(depth, (capabilities & 0xffff) + 1));

    controller.admin.size = @intCast(slots);
    controller.io.size = @intCast(slots);

    write32(registers, 0x14, read32(registers, 0x14) & ~@as(u32, 1));
    try until(registers, 0, patience);

    write32(registers, 0x0c, 0xffffffff);
    write32(registers, 0x24, (slots - 1) << 16 | (slots - 1));
    write64(registers, 0x28, controller.admin.submissions.physical);
    write64(registers, 0x30, controller.admin.completions.physical);

    // 64-byte submissions, 16-byte completions, round robin, NVM command set.
    write32(registers, 0x14, 4 << 20 | 6 << 16 | 1);
    try until(registers, 1, patience);

    _ = try run(controller, &controller.admin, .{ .opcode = 0x06, .prp = scratch.physical, .words = .{ 1, 0, 0, 0, 0, 0 } });

    // MDTS caps a transfer at a power of two of memory pages; zero means no cap.
    const mdts = scratch.bytes[77];

    if (mdts != 0 and mdts < 4) controller.limit = @as(usize, 4096) << @intCast(mdts);

    _ = try run(controller, &controller.admin, .{ .opcode = 0x05, .prp = controller.io.completions.physical, .words = .{ (slots - 1) << 16 | 1, 1, 0, 0, 0, 0 } });
    _ = try run(controller, &controller.admin, .{ .opcode = 0x01, .prp = controller.io.submissions.physical, .words = .{ (slots - 1) << 16 | 1, 1 << 16 | 1, 0, 0, 0, 0 } });

}

/// Fills `found` with the controller's active namespaces that use 512-byte blocks; returns how many.
pub fn namespaces(controller: *Controller, found: []Namespace) usize {

    var ids: [1024]u32 = undefined;

    // Identify with CNS 2 lists active namespace ids in ascending order, ending at the first zero.
    _ = run(controller, &controller.admin, .{ .opcode = 0x06, .prp = controller.scratch.physical, .words = .{ 2, 0, 0, 0, 0, 0 } }) catch return 0;
    @memcpy(std.mem.asBytes(&ids), controller.scratch.bytes);

    var count: usize = 0;

    for (ids) |id| {

        if (id == 0 or count == found.len) break;

        _ = run(controller, &controller.admin, .{ .opcode = 0x06, .namespace = id, .prp = controller.scratch.physical, .words = .{ 0, 0, 0, 0, 0, 0 } }) catch continue;

        const bytes = controller.scratch.bytes;
        const sectors = std.mem.readInt(u64, bytes[0..8], .little);
        const format = bytes[26] & 0xf;
        const shift = bytes[128 + @as(usize, format) * 4 + 2];

        // ponytail: 512-byte blocks only; 4Kn namespaces need sector scaling.
        if (sectors == 0 or shift != 9) continue;

        found[count] = .{

            .controller = controller,
            .id = id,
            .sectors = sectors,

        };

        count += 1;

    }

    return count;

}

/// Moves `length` bytes between `pages` and the namespace, from sector `lba`.
pub fn transfer(namespace: Namespace, write: bool, lba: u64, length: usize, pages: []const api.Page) bool {

    const controller = namespace.controller;
    var done: usize = 0;

    while (done < length) {

        const size = @min(length - done, controller.limit);
        const first = done / 4096;
        const used = (size + 4095) / 4096;
        const entries: [*]volatile u64 = @ptrCast(controller.list.bytes);

        // The first page goes in PRP1; a second fits PRP2 itself, more need the list.
        for (pages[first + 1 .. first + used], 0..) |page, index| entries[index] = page.physical;

        const second: u64 = if (used == 1) 0 else if (used == 2) pages[first + 1].physical else controller.list.physical;
        const sector = lba + done / 512;

        _ = run(controller, &controller.io, .{

            .opcode = if (write) 0x01 else 0x02,
            .namespace = namespace.id,
            .prp = pages[first].physical,
            .second = second,
            .words = .{ @truncate(sector), @truncate(sector >> 32), @intCast(size / 512 - 1), 0, 0, 0 },

        }) catch return false;

        done += size;

    }

    return true;

}

pub fn flush(namespace: Namespace) bool {

    const controller = namespace.controller;

    _ = run(controller, &controller.io, .{ .opcode = 0x00, .namespace = namespace.id, .words = .{ 0, 0, 0, 0, 0, 0 } }) catch return false;

    return true;

}

const Command = struct {

    opcode: u8,
    namespace: u32 = 0,
    prp: u64 = 0,
    second: u64 = 0,
    words: [6]u32,

};

/// Submits `command` on `target` and waits for its completion; returns its command-specific result.
fn run(self: *Controller, target: *Queue, command: Command) Error!u32 {

    const size = target.size;
    const entry: [*]volatile u32 = @ptrCast(@alignCast(target.submissions.bytes[@as(usize, target.tail) * 64 ..]));

    target.serial +%= 1;

    entry[0] = command.opcode | @as(u32, target.serial) << 16;
    entry[1] = command.namespace;

    for (2..6) |word| entry[word] = 0;

    entry[6] = @truncate(command.prp);
    entry[7] = @truncate(command.prp >> 32);
    entry[8] = @truncate(command.second);
    entry[9] = @truncate(command.second >> 32);

    for (command.words, 10..) |value, word| entry[word] = value;

    target.tail = (target.tail + 1) % size;
    write32(self.registers, 0x1000 + 2 * @as(usize, target.id) * self.stride, target.tail);

    const completion: [*]volatile u32 = @ptrCast(@alignCast(target.completions.bytes[@as(usize, target.head) * 16 ..]));
    const deadline = api.ticks() + 300;
    var polls: usize = 0;

    while (completion[3] >> 16 & 1 != @intFromBool(target.phase)) : (polls += 1) {

        // A controller that stops answering is left alone; its commands simply fail from then on.
        if (api.ticks() >= deadline or read32(self.registers, 0x1c) & 2 != 0) return error.Timeout;

        // Most commands finish within a few polls, and yielding to a busy processor could cost a whole time slice.
        if (polls < 256) std.atomic.spinLoopHint() else _ = api.raw(.yield, 0, 0, 0);

    }

    const result = completion[0];
    const status = completion[3] >> 17 & 0x7fff;

    target.head = (target.head + 1) % size;
    if (target.head == 0) target.phase = !target.phase;
    write32(self.registers, 0x1000 + (2 * @as(usize, target.id) + 1) * self.stride, target.head);

    if (status != 0) return error.Failed;

    return result;

}

fn queue(id: u16) Error!Queue {

    return .{

        .id = id,
        .submissions = api.dma() catch return error.Exhausted,
        .completions = api.dma() catch return error.Exhausted,

    };

}

/// Waits up to `patience` ticks for CSTS.RDY to read `ready`.
fn until(registers: usize, ready: u32, patience: u64) Error!void {

    const deadline = api.ticks() + patience;

    while (read32(registers, 0x1c) & 1 != ready) {

        if (api.ticks() >= deadline) return error.Timeout;
        _ = api.raw(.yield, 0, 0, 0);

    }

}

fn read32(registers: usize, offset: usize) u32 {

    return @as(*volatile u32, @ptrFromInt(registers + offset)).*;

}

fn write32(registers: usize, offset: usize, value: u32) void {

    @as(*volatile u32, @ptrFromInt(registers + offset)).* = value;

}

fn read64(registers: usize, offset: usize) u64 {

    return @as(u64, read32(registers, offset + 4)) << 32 | read32(registers, offset);

}

fn write64(registers: usize, offset: usize, value: u64) void {

    write32(registers, offset, @truncate(value));
    write32(registers, offset + 4, @truncate(value >> 32));

}
