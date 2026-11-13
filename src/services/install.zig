const std = @import("std");

const volume = @import("volume.zig");
const disk = @import("disk.zig");
const gpt = @import("gpt.zig");
const fat = @import("fat.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const minimum = (64 << 20) / 512;

/// The EFI system partition a whole disk gets: 256 MiB, room for the loader many times over.
const system_size = (256 << 20) / 512;
const path = "\\EFI\\GRANITE\\BOOTX64.EFI";
const description = "GraniteOS";

var table: gpt.Table = undefined;
var esp: fat.Fat(disk.Disk) = undefined;

var accounts = api.Accounts{

};

var location: usize = 0;
var length: usize = 0;
var file: []const u8 = &.{};

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, size: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.firmware) or api.permits(.ports) or api.permits(.management) or api.permits(.dma)) api.exit(2);

    location = base;
    length = size;

    while (true) {

        const message = api.receive(true) catch continue;

        api.answer(message, handle(message));

    }

}

fn handle(message: api.Request) u64 {

    switch (protocol.operation(message.second)) {

        .hello => return protocol.version,
        .crash => return api.crash(message),
        .install => {

            // An unclaimed machine belongs to whoever sits at it, as with any OS installer.
            if (!api.sender(message).admin) {

                const first = accounts.list(0) catch return protocol.invalid;
                if (first != null) return protocol.denied;

            }

            if (location == 0) return protocol.empty;

            return install(protocol.value(message.second)) catch |err| {

                if (err == error.Missing) return protocol.missing;
                if (err == error.Denied) return protocol.busy;
                api.log("install: failed\n");

                return protocol.invalid;

            };

        },
        .list => return survey(message, protocol.value(message.second)),
        else => return protocol.invalid,

    }

}

/// Installs as `value` asks: a disk index in its low byte and a `protocol.Mode` above; returns the disk and boot entry.
fn install(value: u56) !u64 {

    if (file.len == 0) file = try map();

    const index: u8 = @truncate(value);
    const mode = std.meta.intToEnum(protocol.Mode, @as(u8, @truncate(value >> 8))) catch return error.Invalid;

    if (mode == .erase) return erase(index);
    if (mode == .beside) return try beside(index) orelse error.Missing;

    for (0..32) |number| {

        const sectors = try disk.sectors(@intCast(number));
        if (sectors == 0) break;

        if (try beside(@intCast(number))) |result| return result;

    }

    return error.Missing;

}

/// Installs beside the system on disk `index`, sharing its EFI system partition; null without room or such a partition.
fn beside(index: u8) !?u64 {

    const sectors = try disk.sectors(index);
    if (sectors == 0) return error.Missing;

    const target = disk.Disk{

        .index = index,

    };

    if (!try table.read(target, sectors)) return null;

    const system = table.find(gpt.esp) orelse return null;

    if (!try esp.mount(target, system.first)) return null;

    if (table.find(volume.partition) == null) {

        const free = table.gap();
        if (free.sectors < minimum) return null;

        try table.add(target, volume.partition, unique(), free, "GraniteOS Data");

        // Old bytes in the free space must never pass for a volume.
        try target.write(free.first, &std.mem.zeroes([512]u8));

    }

    try copy(target, false);

    return index | @as(u64, try register(system)) << 8;

}

/// Gives all of disk `index` to GraniteOS: a new partition table, its own EFI system partition, and a data partition after it.
fn erase(index: u8) !u64 {

    const sectors = try disk.sectors(index);
    if (sectors == 0) return error.Missing;

    // Only a disk with nothing on it, or nothing but GraniteOS, is ever erased.
    const found = try examine(index, sectors);
    if (found.placement != .empty and found.placement != .granite) return error.Denied;

    const target = disk.Disk{

        .index = index,

    };

    const data = 2048 + system_size;

    if (sectors < data + minimum + 34) return error.Missing;

    try table.create(target, sectors, unique());
    try table.add(target, gpt.esp, unique(), .{ .first = 2048, .sectors = system_size }, "EFI system partition");
    try table.add(target, volume.partition, unique(), .{ .first = data, .sectors = sectors - 33 - data }, "GraniteOS Data");
    try target.write(data, &std.mem.zeroes([512]u8));
    try fat.format(target, 2048, system_size);

    const system = table.find(gpt.esp) orelse return error.Invalid;

    if (!try esp.mount(target, system.first)) return error.Invalid;

    try copy(target, true);
    api.log("install: disk erased for GraniteOS\n");

    return index | @as(u64, try register(system)) << 8;

}

/// Writes the loader into the mounted EFI system partition, and when GraniteOS owns it, to the path firmware falls back to.
fn copy(target: disk.Disk, own: bool) !void {

    const efi = try esp.directory(esp.root, "EFI        ");
    const home = try esp.directory(efi, "GRANITE    ");

    try esp.write(home, "BOOTX64 EFI", file);
    if (own) try esp.write(try esp.directory(efi, "BOOT       "), "BOOTX64 EFI", file);
    try target.flush();
    api.log("install: files copied\n");

}

/// What disk `index`, of `sectors` sectors, holds and where GraniteOS could go on it.
fn examine(index: u8, sectors: u64) !protocol.Survey {

    const target = disk.Disk{

        .index = index,

    };

    var result = protocol.Survey{

        .sectors = sectors,

    };

    if (!try table.read(target, sectors)) {

        var first: [512]u8 = undefined;

        try target.read(0, &first);

        // Without a GPT, an MBR naming any partition still means another system owns the disk.
        const signed = first[510] == 0x55 and first[511] == 0xaa;
        const named = first[450] != 0 or first[466] != 0 or first[482] != 0 or first[498] != 0;

        result.placement = if (signed and named) .full else .empty;

        return result;

    }

    const system = table.find(gpt.esp);

    if (system) |partition| if (try esp.mount(target, partition.first)) {

        // Windows names its folder Microsoft, whose short name is MICROS~1; MICROSOF stands in for it in test images.
        if (try esp.find(esp.root, "EFI        ")) |efi| result.windows = try esp.find(efi, "MICROS~1   ") != null or try esp.find(efi, "MICROSOF   ") != null;

    };

    result.free = table.gap().sectors;

    const data = table.find(volume.partition) != null;
    const ours = table.only(&.{ gpt.esp, gpt.reserved, volume.partition }) and !result.windows;

    result.placement = if (ours) (if (system != null or data) .granite else .empty) else if (system != null and (data or result.free >= minimum)) .beside else .full;

    return result;

}

/// Reports disk `value` to the caller's window as a `protocol.Survey`; `missing` past the last disk.
fn survey(message: api.Request, value: u56) u64 {

    if (value >= 32) return protocol.invalid;

    const sectors = disk.sectors(@intCast(value)) catch return protocol.invalid;
    if (sectors == 0) return protocol.missing;

    const result = examine(@intCast(value), sectors) catch protocol.Survey{

        .sectors = sectors,

    };

    api.store(message, 0, std.mem.asBytes(&result)) catch return protocol.invalid;

    return 0;

}

/// A random version 4 GUID, in on-disk byte order.
fn unique() [16]u8 {

    var bytes: [16]u8 = undefined;

    api.random(&bytes);
    bytes[7] = bytes[7] & 0x0f | 0x40;
    bytes[8] = bytes[8] & 0x3f | 0x80;

    return bytes;

}

// Adds or reuses a firmware boot entry for the installed loader and puts it first in BootOrder.
fn register(system: gpt.Partition) !u16 {

    var option: [256]u8 = undefined;
    var size: usize = 0;

    append(&option, &size, &std.mem.toBytes(@as(u32, 1)));
    append(&option, &size, &std.mem.toBytes(@as(u16, 0)));
    for (description ++ "\x00") |byte| append(&option, &size, &.{ byte, 0 });

    const start = size;

    append(&option, &size, &.{ 4, 1, 42, 0 });
    append(&option, &size, &std.mem.toBytes(system.number));
    append(&option, &size, &std.mem.toBytes(system.first));
    append(&option, &size, &std.mem.toBytes(system.last - system.first + 1));
    append(&option, &size, &system.unique);
    append(&option, &size, &.{ 2, 2 });
    append(&option, &size, &.{ 4, 4 });
    append(&option, &size, &std.mem.toBytes(@as(u16, 4 + (path.len + 1) * 2)));
    for (path ++ "\x00") |byte| append(&option, &size, &.{ byte, 0 });
    append(&option, &size, &.{ 0x7f, 0xff, 4, 0 });
    std.mem.writeInt(u16, option[4..6], @intCast(size - start), .little);

    var existing: [1024]u8 = undefined;
    var free: ?u16 = null;

    // ponytail: considers Boot0000-Boot00FF; firmware with more entries needs a wider scan.
    const entry = for (0..0x100) |value| {

        const number: u16 = @intCast(value);

        const found = api.variable(&name(number), &existing, false) catch |err| {

            if (err == error.Missing and free == null) free = number;
            continue;

        };

        if (found == size and std.mem.eql(u8, existing[0..size], option[0..size])) break number;

    } else free orelse return error.Full;

    _ = try api.variable(&name(entry), option[0..size], true);

    var order: [2048]u16 = undefined;
    const bytes = std.mem.sliceAsBytes(order[1..]);
    const count = (api.variable(&order_name, bytes, false) catch |err| if (err == error.Missing) 0 else return err) / 2;
    var kept: usize = 1;

    order[0] = entry;

    for (order[1 .. count + 1]) |value| {

        if (value == entry) continue;

        order[kept] = value;
        kept += 1;

    }

    _ = try api.variable(&order_name, std.mem.sliceAsBytes(order[0..kept]), true);

    return entry;

}

const order_name = [_]u16{ 'B', 'o', 'o', 't', 'O', 'r', 'd', 'e', 'r' };

fn name(number: u16) [8]u16 {

    var result = [_]u16{ 'B', 'o', 'o', 't', 0, 0, 0, 0 };

    for (0..4) |digit| result[4 + digit] = "0123456789ABCDEF"[number >> @intCast(12 - digit * 4) & 0xf];

    return result;

}

fn append(buffer: []u8, size: *usize, bytes: []const u8) void {

    @memcpy(buffer[size.*..][0..bytes.len], bytes);
    size.* += bytes.len;

}

// Maps the loader file the kernel kept from boot; the pages must land contiguously.
fn map() ![]const u8 {

    const first_page = location & ~@as(usize, 4095);
    const end = std.mem.alignForward(usize, location + length, 4096);
    var first: usize = 0;
    var page = first_page;

    while (page < end) : (page += 4096) {

        const virtual = (try api.checked(api.raw(.map, page, 0, 0))).first;

        if (first == 0) first = virtual;
        if (virtual != first + (page - first_page)) return error.Invalid;

    }

    return @as([*]const u8, @ptrFromInt(first + location % 4096))[0..length];

}
