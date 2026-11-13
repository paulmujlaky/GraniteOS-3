const std = @import("std");

const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");
const service = @import("service.zig");
const shared = @import("shared.zig");
const schedule = @import("schedule.zig");
const firmware = @import("../boot/uefi/variable.zig");
const screen = @import("../debug/screen.zig");

const paging = arch.paging;
const CallError = paging.MapError || ipc.IpcError || shared.SharedError || @import("elf.zig").LoadError || error{ Denied, Invalid, Busy, ProcessIdsExhausted, InvalidProcessor, NoDevice };

pub fn handle(task: *process.Process, ticks: u64) schedule.Outcome {

    var request = task.context.request();

    const outcome = invoke(task, ticks, &request) catch |err| failed: {

        request.number = switch (err) {

            error.Denied, error.PermissionDenied => 1,
            error.NoProcess, error.NoDevice => 3,
            error.Deadlock => 4,
            error.OutOfMemory, error.Exhausted, error.ProcessIdsExhausted => 5,
            error.Busy => 7,
            else => 2,

        };

        break :failed .keep;

    };

    // A blocked caller's result comes from whichever processor wakes it, which may already have written it.
    if (outcome != .block) task.context.respond(request);

    return outcome;

}

// Kept out of line, so a failure address names the system call rather than the dispatcher.
noinline fn invoke(task: *process.Process, ticks: u64, frame: *abi.Request) CallError!schedule.Outcome {

    const number = frame.number;

    frame.number = 0;

    switch (@as(abi.Call, @enumFromInt(number))) {

        .yield => return .yield,
        .exit => {

            root.exited(task, frame.first);
            return .exit;

        },
        .send => {

            task.length = 0;
            if (try ipc.send(&root.processes, task, frame.first, frame.second)) return .block;

        },
        .receive => {

            // `second`, when not zero, bounds a blocking receive to that many ticks.
            if (!task.policy.permits(.ipc)) return error.Denied;
            if (frame.first > 1 or frame.second > schedule.longest) return error.Invalid;

            if (frame.first == 1) {

                if (!ipc.poll(task)) return error.NoProcess;

            } else if (ipc.receive(task, if (frame.second == 0) 0 else ticks + frame.second)) return .block;

            frame.* = task.context.request();
            frame.number = 0;

        },
        .write => {

            if (!task.permits(.log, 0, 1)) return error.Denied;
            if (frame.second > 256) return error.Invalid;

            var bytes: [256]u8 = undefined;

            try copyUser(task, frame.first, bytes[0..frame.second], false);
            root.log.write(bytes[0..frame.second]);

        },
        .allocate => {

            if (!task.policy.permits(.memory)) return error.Denied;
            const address = try task.vacant();

            _ = try task.space.allocate(address, paging.user | paging.writable | paging.nx);
            task.mapped(address);

            frame.first = address;

        },
        .release => {

            if (!task.policy.permits(.memory)) return error.Denied;
            if (frame.first < paging.user_base + 0x10000000 or frame.first >= task.allocation or frame.first % 4096 != 0) return error.Invalid;

            try task.space.unmap(frame.first);
            task.cursor = @min(task.cursor, frame.first);

        },
        .port => {

            // Bit 0 of `second` selects a write, bit 1 a 32-bit access.
            const width: u64 = if (frame.second & 2 != 0) 4 else 1;

            if (frame.first > 65535 or frame.second > 3 or frame.third >> @intCast(width * 8) != 0) return error.Invalid;
            if (!task.permits(.port, frame.first, width)) return error.Denied;

            const port: u16 = @intCast(frame.first);

            switch (frame.second) {

                0 => frame.first = arch.cpu.in(port),
                1 => arch.cpu.out(port, @intCast(frame.third)),
                2 => frame.first = arch.cpu.in32(port),
                else => arch.cpu.out32(port, @intCast(frame.third)),

            }

        },
        .map => {

            if (frame.first % 4096 != 0) return error.Invalid;
            if (!task.permits(.mmio, frame.first, 4096)) return error.Denied;

            const address = try task.vacant();

            // A second argument of 1 asks for write-combining, which suits a framebuffer and nothing with side effects.
            const caching = if (frame.second == 1) paging.combined else paging.uncached;

            try task.space.map(address, frame.first, paging.user | paging.writable | paging.nx | caching | paging.borrowed);
            task.mapped(address);

            frame.first = address;

        },
        .reboot => {

            if (!task.permits(.power, 0, 1)) return error.Denied;

            arch.machine.reboot();

        },
        .shutdown => {

            if (!task.permits(.power, 0, 1)) return error.Denied;

            arch.machine.shutdown();
            return error.NoDevice;

        },
        .ticks => {

            if (!task.policy.permits(.time)) return error.Denied;
            frame.first = ticks;

        },
        .clock => {

            if (!task.policy.permits(.time)) return error.Denied;

            // ponytail: counting on from one firmware reading drifts with the timer's calibration; resync from the RTC if that matters.
            frame.first = root.epoch + ticks / 100;

        },
        .stats => {

            if (!task.policy.permits(.time)) return error.Denied;
            // Typed, since @min against a constant narrows to the smallest type holding it, and the size below would overflow.
            const capacity: u64 = @min(frame.third, 4096);

            if (capacity != 0 and (frame.second < paging.user_base or frame.second >= paging.user_end or capacity * @sizeOf(abi.Usage) > paging.user_end - frame.second)) return error.Invalid;

            var summary = abi.Summary{

                .pages = root.frames.total,
                .free = root.frames.free_count,
                .processors = arch.machine.core_count,
                .uptime = ticks,

            };

            var cores = arch.machine.cores;

            while (cores) |core| : (cores = core.next) {

                summary.busy +|= core.preemptions;
                summary.idle +|= core.ticks -| core.preemptions;

            }

            root.processes.lock.acquire();
            defer root.processes.lock.release();

            var entries = root.processes.iterate();

            while (entries.next()) |entry| {

                if (entry.state == .dead) continue;
                summary.processes += 1;
                if (summary.records == capacity) continue;

                var record = entry.usage();

                try copyUser(task, frame.second + summary.records * @sizeOf(abi.Usage), std.mem.asBytes(&record), true);
                summary.records += 1;

            }

            try copyUser(task, frame.first, std.mem.asBytes(&summary), true);

        },
        .identity => frame.first = task.id,
        .owner => frame.first = task.owner,
        .call => {

            if (frame.third == 0 or frame.third > schedule.longest or ticks > ~@as(u64, 0) - frame.third) return error.Invalid;
            if (frame.fifth != 0 and (frame.fourth < paging.user_base or frame.fourth >= paging.user_end or frame.fifth > paging.user_end - frame.fourth)) return error.Invalid;
            const destination = if (frame.first == 0) try service.endpoint(task.owner) else frame.first;

            task.buffer = frame.fourth;
            task.length = frame.fifth;
            try ipc.call(&root.processes, task, destination, frame.second, ticks + frame.third);

            return .block;

        },
        .reply => {

            if (!task.policy.permits(.ipc)) return error.Denied;
            try ipc.reply(&root.processes, task, frame.first, frame.second, frame.third);

        },
        .sleep => {

            if (!task.policy.permits(.time)) return error.Denied;
            if (frame.first == 0 or frame.first > schedule.longest or ticks > ~@as(u64, 0) - frame.first) return error.Invalid;
            ipc.sleep(task, ticks + frame.first);

            return .block;

        },
        .spawn => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            const image = std.enums.fromInt(abi.Image, frame.first) orelse return error.Invalid;
            const identity = if (frame.third == 0) null else try lent(task, frame.third, frame.fourth, image);

            frame.first = (try service.spawn(task, image, frame.second, identity)).id;

        },
        .inspect => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;

            if (frame.first == 0) {

                const image = std.enums.fromInt(abi.Image, frame.second) orelse return error.Invalid;
                const child = service.inspect(task, image) orelse return error.NoProcess;
                frame.first = child.id;
                frame.second = child.generation;
                return .keep;

            }

            const child = root.processes.find(frame.first) orelse return error.NoProcess;
            if (child.owner != task.id) return error.Denied;
            frame.first = child.id;

        },
        .connect => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            try service.connect(task, frame.first, frame.second);

        },
        .stop => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            const child = root.processes.find(frame.first) orelse return error.NoProcess;
            if (child.owner != task.id) return error.Denied;
            root.kill(child, false);

        },
        .dma => {

            if (!task.policy.permits(.dma)) return error.Denied;
            const address = try task.vacant();

            // ponytail: DMA pages leak on exit since a device may still write them; reclaim once drivers quiesce devices on exit.
            frame.second = try task.space.allocate(address, paging.user | paging.writable | paging.nx | paging.borrowed);
            task.mapped(address);

            frame.first = address;

        },
        .fetch, .store => {

            if (!task.policy.permits(.ipc)) return error.Denied;
            const client = try ipc.caller(&root.processes, task, frame.first, frame.second);
            defer task.lock.release();

            if (frame.fifth > 0x10000 or frame.third > client.length or frame.fifth > client.length - frame.third) return error.Invalid;

            const remote = client.buffer + frame.third;

            if (number == @intFromEnum(abi.Call.fetch)) try copy(client, remote, task, frame.fourth, frame.fifth) else try copy(task, frame.fourth, client, remote, frame.fifth);

        },
        .assign => {

            if (!task.policy.permits(.accounts)) return error.Denied;
            const identity: abi.Identity = @bitCast(frame.third);

            // Only a caller blocked on this service can be re-identified, and never as a service.
            const client = try ipc.caller(&root.processes, task, frame.first, frame.second);
            defer task.lock.release();

            if (client.policy.layer != .application or identity.user == abi.system.user or identity.reserved != 0) return error.Invalid;
            client.identity = identity;

        },
        .history => {

            // The log names processes and devices, so administrators and services read it.
            if (!task.identity.admin and task.policy.layer != .service) return error.Denied;

            var bytes: [4096]u8 = undefined;
            const count = screen.recent(bytes[0..@min(frame.third, bytes.len)], frame.second);

            try copyUser(task, frame.first, bytes[0..count], true);
            frame.first = count;

        },
        .variable => {

            if (!task.policy.permits(.firmware)) return error.Denied;
            if (frame.second == 0 or frame.second > 64 or frame.fourth > 4096 or frame.fifth > 1) return error.Invalid;

            var name = std.mem.zeroes([65:0]u16);
            var data: [4096]u8 = undefined;
            const bytes = data[0..frame.fourth];

            try copyUser(task, frame.first, std.mem.sliceAsBytes(name[0..frame.second]), false);
            if (frame.fifth == 1) try copyUser(task, frame.third, bytes, false);

            const size = try firmware.access(root.runtime, &name, bytes, frame.fifth == 1);

            if (frame.fifth == 0) try copyUser(task, frame.third, bytes[0..size], true);
            frame.first = size;

        },
        .share, .attach => {

            if (!task.policy.permits(.memory)) return error.Denied;

            const region = if (number == @intFromEnum(abi.Call.share)) try shared.create(task, frame.first) else try shared.attach(task, frame.first);

            frame.first = region.address;
            frame.second = region.handle;
            frame.third = region.pages;

        },
        .physical => {

            // Only drivers learn where memory physically lives.
            if (!task.policy.permits(.dma)) return error.Denied;
            frame.first = try task.space.translate(frame.first, false);

        },
        .lend => {

            if (!task.policy.permits(.memory)) return error.Denied;
            try shared.lend(task, frame.first, frame.second);

        },
        .detach => try shared.detach(task, frame.first),
        .alive => {

            if (!task.policy.permits(.ipc)) return error.Denied;
            _ = root.processes.find(frame.first) orelse return error.NoProcess;

        },
        else => return error.Invalid,

    }

    return .keep;

}

fn lent(server: *process.Process, id: u64, ticket: u64, image: abi.Image) CallError!abi.Identity {

    // Only a signed-in application blocked on the caller lends its identity, and only to another application.
    const client = try ipc.caller(&root.processes, server, id, ticket);
    defer server.lock.release();

    if (client.policy.layer != .application or client.identity.user == abi.nobody.user or client.identity.user == abi.system.user) return error.Denied;
    if (!image.application()) return error.Invalid;

    return client.identity;

}

fn copy(source: *process.Process, from: u64, target: *process.Process, to: u64, length: u64) !void {

    var offset: u64 = 0;

    while (offset < length) {

        const input = try source.space.translate(from + offset, false);
        const output = try target.space.translate(to + offset, true);
        const size = @min(length - offset, 4096 - (input & 4095), 4096 - (output & 4095));

        @memcpy(@as([*]u8, @ptrFromInt(output))[0..size], @as([*]const u8, @ptrFromInt(input))[0..size]);
        offset += size;

    }

}

fn copyUser(task: *process.Process, address: u64, bytes: []u8, write: bool) !void {

    if (address < paging.user_base or address >= paging.user_end or bytes.len > paging.user_end - address) return error.Invalid;

    var offset: usize = 0;

    while (offset < bytes.len) {

        const physical = try task.space.translate(address + offset, write);
        const size = @min(bytes.len - offset, 4096 - (physical & 4095));
        const page = @as([*]u8, @ptrFromInt(physical))[0..size];

        if (write) @memcpy(page, bytes[offset..][0..size]) else @memcpy(bytes[offset..][0..size], page);
        offset += size;

    }

}
