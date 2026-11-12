const std = @import("std");

const volume = @import("volume.zig");
const disk = @import("disk.zig");
const gpt = @import("gpt.zig");
const fat = @import("fat.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const minimum = (64 << 20) / 512;
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

            return install() catch |err| {

                if (err == error.Missing) return protocol.missing;
                api.log("install: failed\n");

                return protocol.invalid;

            };

        },
        else => return protocol.invalid,

    }

}

// Installs onto the first disk whose GPT has a FAT32 ESP and room for a GraniteOS partition; returns the disk and boot entry.
fn install() !u64 {

    if (file.len == 0) file = try map();

    var index: u8 = 0;

    while (index < 32) : (index += 1) {

        const sectors = try disk.sectors(index);
        if (sectors == 0) break;

        const target = disk.Disk{

            .index = index,

        };

        if (!try table.read(target, sectors)) continue;

        const system = table.find(gpt.esp) orelse continue;

        if (!try esp.mount(target, system.first)) continue;

        if (table.find(volume.partition) == null) {

            const free = table.gap();
            if (free.sectors < minimum) continue;

            var unique: [16]u8 = undefined;

            api.random(&unique);
            unique[7] = unique[7] & 0x0f | 0x40;
            unique[8] = unique[8] & 0x3f | 0x80;
            try table.add(target, volume.partition, unique, free, "GraniteOS Data");

            // Old bytes in the free space must never pass for a volume.
            try target.write(free.first, &std.mem.zeroes([512]u8));

        }

        const efi = try esp.directory(esp.root, "EFI        ");
        const home = try esp.directory(efi, "GRANITE    ");

        try esp.write(home, "BOOTX64 EFI", file);
        try target.flush();
        api.log("install: files copied\n");

        return index | @as(u64, try register(system)) << 8;

    }

    return error.Missing;

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
