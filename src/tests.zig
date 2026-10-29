const std = @import("std");

const boot = @import("boot/info.zig");
const map = @import("boot/uefi/map.zig");
const graphics = @import("boot/uefi/graphics.zig");
const clock = @import("boot/uefi/clock.zig");
const time = @import("api/time.zig");

comptime {

    _ = @import("kernel/tests.zig");
    _ = @import("services/tests.zig");
    _ = @import("gui/tests.zig");
    _ = @import("media/tests.zig");
    _ = @import("apps/stations.zig");

}

const uefi = std.os.uefi;
const Descriptor = uefi.tables.MemoryDescriptor;

fn descriptor(kind: uefi.tables.MemoryType) Descriptor {

    return .{

        .type = kind,
        .physical_start = 4096,
        .virtual_start = 0,
        .number_of_pages = 8,
        .attribute = @bitCast(@as(u64, 0)),

    };

}

test "memory map honors descriptor stride and protects firmware allocations" {

    var bytes = std.mem.zeroes([96]u8);

    const first = descriptor(.conventional_memory);
    var second = descriptor(.loader_data);

    second.physical_start = 0x100000;

    @memcpy(bytes[0..40], std.mem.asBytes(&first));
    @memcpy(bytes[48..88], std.mem.asBytes(&second));

    var regions: [2]boot.Region = undefined;
    const result = try map.convert(&bytes, 48, 1, &regions);

    try std.testing.expectEqual(2, result.len);
    try std.testing.expectEqual(.available, result[0].kind);
    try std.testing.expectEqual(32768, result[0].size);
    try std.testing.expectEqual(.loader, result[1].kind);

    second.type = .conventional_memory;
    second.attribute.memory_runtime = true;

    @memcpy(bytes[48..88], std.mem.asBytes(&second));

    _ = try map.convert(&bytes, 48, 1, &regions);
    try std.testing.expectEqual(.runtime, regions[1].kind);

    second = descriptor(@enumFromInt(0x70000042));

    @memcpy(bytes[48..88], std.mem.asBytes(&second));

    _ = try map.convert(&bytes, 48, 1, &regions);
    try std.testing.expectEqual(.reserved, regions[1].kind);

}

test "memory map rejects malformed sizes versions and overflowing ranges" {

    var entry = descriptor(.conventional_memory);
    var regions: [1]boot.Region = undefined;

    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 0, 1, &regions));
    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 48, 1, &regions));
    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 40, 2, &regions));
    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 40, 1, regions[0..0]));

    entry.number_of_pages = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 40, 1, &regions));
    entry.number_of_pages = 1;

    entry.physical_start = 0xfffffffffffff000;

    try std.testing.expectError(error.InvalidMemoryMap, map.convert(std.mem.asBytes(&entry), 40, 1, &regions));

}

const Firmware = struct {

    var reads: usize = 0;
    var exits: usize = 0;

    var failure: uefi.Status = .invalid_parameter;

    var grow = false;
    var always_fail = false;

    fn read(size: *usize, buffer: ?[*]align(8) u8, key: *uefi.tables.MemoryMapKey, stride: *usize, version: *u32) callconv(uefi.cc) uefi.Status {

        reads += 1;

        if (grow and exits != 0) return .buffer_too_small;
        if (size.* < 40) return .buffer_too_small;

        size.* = 40;
        stride.* = 40;
        version.* = 1;

        key.* = @enumFromInt(reads);

        const entry = descriptor(.conventional_memory);

        @memcpy(buffer.?[0..40], std.mem.asBytes(&entry));

        return .success;

    }

    fn leave(_: uefi.Handle, key: uefi.tables.MemoryMapKey) callconv(uefi.cc) uefi.Status {

        exits += 1;
        if (@intFromEnum(key) != reads) return .device_error;

        return if (exits == 1 or always_fail) failure else .success;

    }

};

test "ExitBootServices refreshes stale keys and never retries unrelated failures" {

    var services: uefi.tables.BootServices = undefined;

    services._getMemoryMap = Firmware.read;
    services._exitBootServices = Firmware.leave;

    var buffer: [80]u8 align(8) = undefined;
    var regions: [2]boot.Region = undefined;

    var memory = map.Map{

        .buffer = &buffer,
        .regions = &regions,

    };

    const handle: uefi.Handle = @ptrFromInt(1);
    var attempted = false;

    Firmware.reads = 0;
    Firmware.exits = 0;

    Firmware.failure = .invalid_parameter;

    Firmware.grow = false;
    Firmware.always_fail = false;

    _ = try memory.finish(&services, handle, &attempted);

    try std.testing.expect(attempted);
    try std.testing.expectEqual(2, Firmware.reads);
    try std.testing.expectEqual(2, Firmware.exits);

    Firmware.reads = 0;
    Firmware.exits = 0;
    Firmware.failure = .device_error;

    try std.testing.expectError(error.ExitBootServicesFailed, memory.finish(&services, handle, &attempted));
    try std.testing.expectEqual(1, Firmware.exits);

    Firmware.reads = 0;
    Firmware.exits = 0;
    Firmware.failure = .invalid_parameter;
    Firmware.always_fail = true;

    try std.testing.expectError(error.MemoryMapUnstable, memory.finish(&services, handle, &attempted));
    try std.testing.expectEqual(8, Firmware.exits);
    Firmware.always_fail = false;

    Firmware.reads = 0;
    Firmware.exits = 0;
    Firmware.failure = .invalid_parameter;
    Firmware.grow = true;

    try std.testing.expectError(error.MemoryMapUnstable, memory.finish(&services, handle, &attempted));
    try std.testing.expectEqual(1, Firmware.exits);

}

test "framebuffer rejects short storage bad stride and overlapping channels" {

    var framebuffer = boot.Framebuffer{

        .base = 0xe0000000,
        .size = 1920 * 1080 * 4,

        .width = 1920,
        .height = 1080,
        .stride = 1920,

        .red_mask = 0xff0000,
        .green_mask = 0xff00,
        .blue_mask = 0xff,

    };

    try std.testing.expect(graphics.valid(framebuffer));

    framebuffer.stride = 1919;

    try std.testing.expect(!graphics.valid(framebuffer));

    framebuffer.stride = 1920;
    framebuffer.size -= 1;

    try std.testing.expect(!graphics.valid(framebuffer));

    framebuffer.size += 1;
    framebuffer.red_mask = framebuffer.green_mask;

    try std.testing.expect(!graphics.valid(framebuffer));

}

fn moment(date: time.Date) uefi.Time {

    var value = std.mem.zeroes(uefi.Time);

    value.year = date.year;
    value.month = date.month;
    value.day = date.day;
    value.hour = date.hour;
    value.minute = date.minute;
    value.second = date.second;

    return value;

}

test "firmware clock and calendar dates agree across leap years and reject impossible dates" {

    const dates = [_]struct { u64, time.Date }{

        .{ 0, .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .weekday = 4 } },
        .{ 946684799, .{ .year = 1999, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59, .weekday = 5 } },
        .{ 951827696, .{ .year = 2000, .month = 2, .day = 29, .hour = 12, .minute = 34, .second = 56, .weekday = 2 } },
        .{ 1709251199, .{ .year = 2024, .month = 2, .day = 29, .hour = 23, .minute = 59, .second = 59, .weekday = 4 } },
        .{ 1791640987, .{ .year = 2026, .month = 10, .day = 10, .hour = 14, .minute = 3, .second = 7, .weekday = 6 } },
        .{ 4107542400, .{ .year = 2100, .month = 3, .day = 1, .hour = 0, .minute = 0, .second = 0, .weekday = 1 } },

    };

    for (dates) |entry| {

        const seconds, const date = entry;

        try std.testing.expectEqual(date, time.Date.init(seconds));
        try std.testing.expectEqual(seconds, clock.seconds(moment(date)).?);

    }

    // 2100 is no leap year, and the firmware's fields may be garbage.
    var invalid = moment(dates[5][1]);

    invalid.month = 2;
    invalid.day = 29;
    try std.testing.expectEqual(null, clock.seconds(invalid));
    invalid.month = 13;
    invalid.day = 1;
    try std.testing.expectEqual(null, clock.seconds(invalid));
    invalid.month = 12;
    invalid.year = 1969;
    try std.testing.expectEqual(null, clock.seconds(invalid));
    invalid.year = 2026;
    invalid.hour = 24;
    try std.testing.expectEqual(null, clock.seconds(invalid));

}

test "dates read month first on a 12-hour clock" {

    var bytes: [40]u8 = undefined;
    const afternoon = time.Date.init(1791640987);

    try std.testing.expectEqualStrings("2:03 PM", afternoon.clock(&bytes, false));
    try std.testing.expectEqualStrings("2:03:07 PM", afternoon.clock(&bytes, true));
    try std.testing.expectEqualStrings("Sat, Oct 10", afternoon.short(&bytes));
    try std.testing.expectEqualStrings("Saturday, October 10, 2026", afternoon.long(&bytes, true));
    try std.testing.expectEqualStrings("12:00 AM", time.Date.on(2026, 10, 12).clock(&bytes, false));
    try std.testing.expectEqualStrings("Monday, October 12", time.Date.on(2026, 10, 12).long(&bytes, false));

}
