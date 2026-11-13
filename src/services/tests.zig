const std = @import("std");

const policy = @import("policy.zig");
const line = @import("../apps/line.zig");
const protocol = @import("../api/protocol.zig");
const volume = @import("volume.zig");
const gpt = @import("gpt.zig");
const fat = @import("fat.zig");
const ntfs = @import("ntfs.zig");
const gpu = @import("gpu.zig");
const hid = @import("hid.zig");
const wire = @import("wire.zig");
const tcp = @import("tcp.zig");
const dns = @import("dns.zig");
const dhcp = @import("dhcp.zig");
const mixer = @import("mixer.zig");
const chime = @import("chime.zig");
const codec = @import("codec.zig");

test "GPU quads cover exactly their pixels and sample texel centres under either pixel-centre convention" {

    for ([_]f32{ 0.5, 0 }) |shift| {

        // A four-by-two area at (3, 5) of a 16 by 8 frame, where pixel n's centre lies at n + 0.5 - shift.
        const left = (gpu.edge(3, 16, shift) + 1) * 8;
        const right = (gpu.edge(7, 16, shift) + 1) * 8;
        const top = (gpu.edge(5, 8, shift) + 1) * 4;
        const bottom = (gpu.edge(7, 8, shift) + 1) * 4;

        try std.testing.expectApproxEqAbs(0.125, (3.5 - shift - left) / (right - left), 1e-5);
        try std.testing.expectApproxEqAbs(0.875, (6.5 - shift - left) / (right - left), 1e-5);
        try std.testing.expectApproxEqAbs(0.25, (5.5 - shift - top) / (bottom - top), 1e-5);
        try std.testing.expect(2.5 - shift < left and 7.5 - shift > right);

    }

    // Texture coordinates run from a slot's near edge, or its far edge when mirrored.
    try std.testing.expectEqual(10.0 / 1024.0, gpu.texel(8, 6, 2, false));
    try std.testing.expectEqual(12.0 / 1024.0, gpu.texel(8, 6, 2, true));

}

test "restart policy backs off and stops after three replacements" {

    var entry = policy.Entry{

    };

    try std.testing.expect(entry.ready(0));

    entry.id = 42;

    try std.testing.expect(!entry.ready(100));
    entry.failed(100);

    try std.testing.expectEqual(0, entry.id);
    try std.testing.expect(!entry.ready(109));
    try std.testing.expect(entry.ready(110));
    entry.failed(110);

    try std.testing.expect(!entry.ready(129));
    try std.testing.expect(entry.ready(130));
    entry.failed(130);

    try std.testing.expect(!entry.ready(169));
    try std.testing.expect(entry.ready(170));
    entry.failed(170);

    try std.testing.expect(entry.offline);
    try std.testing.expect(!entry.ready(std.math.maxInt(u64)));

}

test "terminal editing handles CRLF erase cancel and full input" {

    var input = line.Line{

    };

    try std.testing.expectEqual(.none, input.push(8));
    try std.testing.expectEqual(.echo, input.push('a'));
    try std.testing.expectEqual(.echo, input.push('b'));
    try std.testing.expectEqual(.erase, input.push(127));
    try std.testing.expectEqualStrings("a", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    try std.testing.expectEqual(.none, input.push('\n'));
    input.reset();

    try std.testing.expectEqual(.cancel, input.push(3));
    try std.testing.expectEqual(0, input.len);

    for (0..input.bytes.len) |_| try std.testing.expectEqual(.echo, input.push('x'));

    try std.testing.expectEqual(.bell, input.push('x'));
    try std.testing.expectEqual(256, input.len);
    try std.testing.expectEqual(.erase, input.push(8));
    try std.testing.expectEqual(.echo, input.push('y'));

}

test "terminal editing moves the cursor and recalls history" {

    var input = line.Line{

    };

    for ("echo hed") |byte| _ = input.push(byte);
    for ("\x1b[D") |byte| _ = input.push(byte);

    try std.testing.expectEqual(.redraw, input.push('l'));
    try std.testing.expectEqualStrings("echo held", input.text());

    for ("\x1b[1~") |byte| _ = input.push(byte);
    for ("\x1b[3~") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("cho held", input.text());
    try std.testing.expectEqual(.redraw, input.push(5));
    try std.testing.expectEqual(.redraw, input.push(23));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    input.reset();

    for ("id\rid\r") |byte| {

        if (input.push(byte) == .submit) input.reset();

    }

    try std.testing.expectEqual(2, input.total);
    _ = input.push('x');
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("id", input.text());
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.bell, input.push(16));
    for ("\x1b[B\x1b[B") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("x", input.text());
    try std.testing.expectEqual(.none, input.push(14));

}

test "service protocol preserves operation and payload boundaries" {

    const value = std.math.maxInt(u56);
    const message = protocol.pack(.ping, value);

    try std.testing.expectEqual(.ping, protocol.operation(message));
    try std.testing.expectEqual(value, protocol.value(message));
    try std.testing.expectEqual(@as(protocol.Operation, @enumFromInt(255)), protocol.operation(255));

}

const Memory = struct {

    bytes: []u8,

    pub fn read(self: Memory, lba: u64, out: []u8) volume.Error!void {

        if (lba * 512 + out.len > self.bytes.len) return error.Device;
        @memcpy(out, self.bytes[lba * 512 ..][0..out.len]);

    }

    pub fn write(self: Memory, lba: u64, bytes: []const u8) volume.Error!void {

        if (lba * 512 + bytes.len > self.bytes.len) return error.Device;
        @memcpy(self.bytes[lba * 512 ..][0..bytes.len], bytes);

    }

    pub fn flush(_: Memory) volume.Error!void {

    }

};

test "volume persists fragmented files and directories and reclaims every block" {

    const allocator = std.testing.allocator;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, 8 << 20),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    var sector: [512]u8 = undefined;
    const capacity = disk.bytes.len / 512;

    try std.testing.expectEqual(null, try volume.find(disk, &sector, capacity));
    @memcpy(disk.bytes[512..520], "EFI PART");
    std.mem.writeInt(u64, disk.bytes[512 + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 80 ..][0..4], 8, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 84 ..][0..4], 128, .little);

    const record = disk.bytes[1024 + 5 * 128 ..][0..128];

    @memcpy(record[0..16], &volume.partition);
    std.mem.writeInt(u64, record[32..40], 64, .little);
    std.mem.writeInt(u64, record[40..48], capacity - 1, .little);

    const range = (try volume.find(disk, &sector, capacity)).?;

    try std.testing.expectEqual(64, range.first);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    try std.testing.expect(try mounted.mount(disk, range));
    const initial = mounted.usage();

    try mounted.create("/docs", .directory);
    try mounted.create("/docs/note", .file);
    try mounted.write("/docs/note", 0, "hello");
    try std.testing.expectError(error.Exists, mounted.create("/docs", .directory));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/note/child", .file));
    try std.testing.expectError(error.Missing, mounted.write("/nowhere", 0, "x"));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/..", .file));

    try mounted.create("/a", .file);
    try mounted.create("/b", .file);

    var block: [volume.block_size]u8 = undefined;

    // Interleaving two files defeats contiguous growth, forcing continuation extent pages.
    for (0..600) |index| {

        @memset(&block, @truncate(index));
        try mounted.write("/a", index * block.len, &block);
        @memset(&block, @truncate(index +% 128));
        try mounted.write("/b", index * block.len, &block);

    }

    try mounted.write("/docs/note", 10000, "!");

    const again = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(again);

    try std.testing.expect(!try again.mount(disk, range));

    var out: [volume.block_size]u8 = undefined;

    try std.testing.expectEqual(out.len, try again.read("/docs/note", 0, &out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    try std.testing.expect(std.mem.allEqual(u8, out[5..], 0));
    try std.testing.expectEqual(11, try again.read("/docs/note", 9990, &out));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 10 ++ [_]u8{'!'}), out[0..11]);
    try std.testing.expectEqual(0, try again.read("/docs/note", 10001, &out));

    for ([_]usize{ 0, 253, 254, 255, 598 }) |index| {

        try std.testing.expectEqual(200, try again.read("/a", index * block.len + 4000, out[0..200]));
        try std.testing.expectEqual(@as(u8, @truncate(index)), out[0]);
        try std.testing.expectEqual(@as(u8, @truncate(index + 1)), out[199]);

    }

    try std.testing.expectEqual(10001, (try again.entry("/docs", 0)).?.size);
    try std.testing.expectEqualStrings("b", (try again.entry("/", 2)).?.name);
    try std.testing.expectEqual(null, try again.entry("/", 3));

    try std.testing.expectError(error.Busy, again.remove("/docs"));
    try again.remove("/a");
    try again.create("/b", .file);
    try std.testing.expectEqual(0, try again.read("/b", 0, &out));
    try again.remove("/docs/note");
    try again.remove("/docs");
    try again.remove("/b");
    try std.testing.expectEqual(null, try again.entry("/", 0));
    try std.testing.expectEqual(initial.free, again.usage().free);

}

test "volume moves large unaligned spans across fragmented extents" {

    const allocator = std.testing.allocator;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, 8 << 20),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    _ = try mounted.mount(disk, .{

        .first = 0,
        .sectors = disk.bytes.len / 512,

    });

    const span = try allocator.alloc(u8, 300_000);
    const out = try allocator.alloc(u8, span.len + 2000);

    defer allocator.free(span);
    defer allocator.free(out);

    for (span, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% index / 251);

    try mounted.create("/big", .file);
    try mounted.create("/gap", .file);

    // Growing another file between pieces leaves the big one in several extents.
    for (0..6) |piece| {

        const from = piece * 50_000;

        try mounted.write("/big", 1234 + from, span[from..][0..50_000]);
        try mounted.write("/gap", piece * 5000, span[0..5000]);

    }

    try std.testing.expectEqual(span.len + 1234, try mounted.read("/big", 0, out));
    try std.testing.expect(std.mem.allEqual(u8, out[0..1234], 0));
    try std.testing.expectEqualSlices(u8, span, out[1234..][0..span.len]);

    // One write over every extent, aligned, then read back from an unaligned offset.
    for (span) |*byte| byte.* ^= 0x5a;
    try mounted.write("/big", 0, span);
    try std.testing.expectEqual(span.len - 777, try mounted.read("/big", 777, out[0 .. span.len - 777]));
    try std.testing.expectEqualSlices(u8, span[777..], out[0 .. span.len - 777]);
    try std.testing.expectEqual(1234, try mounted.read("/big", span.len, out));

    // The tail past the second write still holds the first, from before the bytes flipped.
    for (span[span.len - 1234 ..], out[0..1234]) |now, before| try std.testing.expectEqual(now ^ 0x5a, before);

}

test "volume enforces owner and other permissions" {

    const allocator = std.testing.allocator;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, 2 << 20),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    _ = try mounted.mount(disk, .{

        .first = 0,
        .sectors = disk.bytes.len / 512,

    });

    try mounted.create("/home", .directory);
    try mounted.create("/home/alice", .directory);
    try mounted.change("/home/alice", 0o700, 1000);

    mounted.user = 1000;
    try mounted.create("/home/alice/note", .file);
    try mounted.write("/home/alice/note", 0, "private");
    try std.testing.expectEqual(1000, (try mounted.entry("/home/alice", 0)).?.owner);
    try std.testing.expectError(error.Denied, mounted.create("/home/bob", .directory));
    try std.testing.expectError(error.Denied, mounted.change("/home/alice", 0o755, 1001));

    var out: [16]u8 = undefined;

    mounted.user = 1001;
    try std.testing.expectError(error.Denied, mounted.read("/home/alice/note", 0, &out));
    try std.testing.expectError(error.Denied, mounted.entry("/home/alice", 0));
    try std.testing.expectError(error.Denied, mounted.remove("/home/alice/note"));
    try std.testing.expectError(error.Denied, mounted.change("/home/alice", 0o777, null));

    mounted.user = 1000;
    try mounted.change("/home/alice", 0o755, null);

    mounted.user = 1001;
    try std.testing.expectEqual(7, try mounted.read("/home/alice/note", 0, &out));
    try std.testing.expectError(error.Denied, mounted.write("/home/alice/note", 0, "x"));
    try std.testing.expectError(error.Denied, mounted.create("/home/alice/note", .file));
    try std.testing.expectError(error.Denied, mounted.create("/home/alice/other", .file));

    mounted.user = volume.system;
    try mounted.remove("/home/alice/note");

}

test "GPT edit fills the largest aligned gap and keeps both tables valid" {

    const allocator = std.testing.allocator;
    const sectors = 65536;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, sectors * 512),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const header = disk.bytes[512..1024];
    const entries = disk.bytes[1024..][0 .. 128 * 128];

    @memcpy(header[0..8], "EFI PART");
    std.mem.writeInt(u32, header[12..16], 92, .little);
    std.mem.writeInt(u64, header[24..32], 1, .little);
    std.mem.writeInt(u64, header[32..40], sectors - 1, .little);
    std.mem.writeInt(u64, header[40..48], 34, .little);
    std.mem.writeInt(u64, header[48..56], sectors - 34, .little);
    std.mem.writeInt(u64, header[72..80], 2, .little);
    std.mem.writeInt(u32, header[80..84], 128, .little);
    std.mem.writeInt(u32, header[84..88], 128, .little);

    for ([_][3]u64{ .{ 0, 2048, 4095 }, .{ 1, 4096, 20479 }, .{ 2, 40960, 49151 } }) |part| {

        const entry = entries[part[0] * 128 ..][0..128];

        entry[0..16].* = if (part[0] == 0) gpt.esp else [_]u8{0xaa} ** 16;
        std.mem.writeInt(u64, entry[32..40], part[1], .little);
        std.mem.writeInt(u64, entry[40..48], part[2], .little);

    }

    std.mem.writeInt(u32, header[88..92], std.hash.Crc32.hash(entries), .little);
    std.mem.writeInt(u32, header[16..20], std.hash.Crc32.hash(header[0..92]), .little);
    @memset(disk.bytes[4096 * 512 .. 20480 * 512], 0x5a);

    const table = try allocator.create(gpt.Table);
    defer allocator.destroy(table);

    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expectEqual(2048, table.find(gpt.esp).?.first);

    const free = table.gap();

    try std.testing.expectEqual(20480, free.first);
    try std.testing.expectEqual(20480, free.sectors);
    try table.add(disk, volume.partition, [_]u8{1} ** 16, free, "GraniteOS Data");

    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expectEqual(4, table.find(volume.partition).?.number);
    try std.testing.expectEqual(40959, table.find(volume.partition).?.last);
    try std.testing.expect(std.mem.allEqual(u8, disk.bytes[4096 * 512 .. 20480 * 512], 0x5a));

    var backup = disk.bytes[(sectors - 1) * 512 ..][0..512].*;
    const checksum = std.mem.readInt(u32, backup[16..20], .little);

    try std.testing.expectEqual(1, std.mem.readInt(u64, backup[32..40], .little));
    try std.testing.expectEqual(sectors - 33, std.mem.readInt(u64, backup[72..80], .little));
    try std.testing.expectEqualSlices(u8, entries, disk.bytes[(sectors - 33) * 512 ..][0 .. 128 * 128]);
    @memset(backup[16..20], 0);
    try std.testing.expectEqual(checksum, std.hash.Crc32.hash(backup[0..92]));

    header[40] ^= 1;
    try std.testing.expect(!try table.read(disk, sectors));

}

test "FAT32 writer fills only free clusters and survives fragmentation and rewrites" {

    const allocator = std.testing.allocator;
    const base = 64;
    const total = 4096;

    const disk = Memory{

        .bytes = try allocator.alloc(u8, (base + total) * 512),

    };

    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    const boot = disk.bytes[base * 512 ..][0..512];
    const info = disk.bytes[(base + 1) * 512 ..][0..512];

    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 1;
    std.mem.writeInt(u16, boot[14..16], 32, .little);
    boot[16] = 2;
    std.mem.writeInt(u32, boot[32..36], total, .little);
    std.mem.writeInt(u32, boot[36..40], 32, .little);
    std.mem.writeInt(u32, boot[44..48], 2, .little);
    std.mem.writeInt(u16, boot[48..50], 1, .little);
    boot[510] = 0x55;
    boot[511] = 0xaa;
    std.mem.writeInt(u32, info[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, info[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, info[488..492], 1234, .little);

    // Clusters 0-4 are reserved, root, and an existing two-cluster file; every third from 30 is taken.
    for (0..2) |copy| {

        const table = disk.bytes[(base + 32 + copy * 32) * 512 ..][0..512];

        for ([_]u32{ 0x0ffffff8, 0x0fffffff, 0x0fffffff, 4, 0x0fffffff }, 0..) |value, index| std.mem.writeInt(u32, table[index * 4 ..][0..4], value, .little);

        var cluster: usize = 30;

        while (cluster < 90) : (cluster += 3) std.mem.writeInt(u32, table[cluster * 4 ..][0..4], 0x0fffffff, .little);

    }

    @memset(disk.bytes[(base + 97) * 512 ..][0 .. 2 * 512], 0x77);

    const esp = try allocator.create(fat.Fat(Memory));
    defer allocator.destroy(esp);

    try std.testing.expect(try esp.mount(disk, base));

    const efi = try esp.directory(esp.root, "EFI        ");

    try std.testing.expectEqual(efi, try esp.directory(esp.root, "EFI        "));

    const home = try esp.directory(efi, "GRANITE    ");

    // Twenty more entries overflow the one-cluster root directory.
    for (0..20) |index| {

        var name = "DIR00      ".*;

        name[3] = '0' + @as(u8, @intCast(index / 10));
        name[4] = '0' + @as(u8, @intCast(index % 10));
        _ = try esp.directory(esp.root, &name);

    }

    var data: [9000]u8 = undefined;
    var out: [9000]u8 = undefined;

    for (&data, 0..) |*byte, index| byte.* = @truncate(index * 7 + index / 251);

    try esp.write(home, "BOOTX64 EFI", &data);
    try std.testing.expectEqualSlices(u8, &data, out[0..try fatFile(disk.bytes, base, home, "BOOTX64 EFI", &out)]);
    try esp.write(home, "BOOTX64 EFI", data[0..700]);
    try std.testing.expectEqualSlices(u8, data[0..700], out[0..try fatFile(disk.bytes, base, home, "BOOTX64 EFI", &out)]);
    try std.testing.expectEqual(0, try fatFile(disk.bytes, base, esp.root, "DIR19      ", &out));

    try std.testing.expect(std.mem.allEqual(u8, disk.bytes[(base + 97) * 512 ..][0 .. 2 * 512], 0x77));
    try std.testing.expectEqualSlices(u8, disk.bytes[(base + 32) * 512 ..][0 .. 32 * 512], disk.bytes[(base + 64) * 512 ..][0 .. 32 * 512]);
    try std.testing.expectEqual(0xffffffff, std.mem.readInt(u32, info[488..492], .little));

}

test "a whole-disk install lays a fresh GPT and a FAT32 volume that both read back" {

    const allocator = std.testing.allocator;
    const sectors = 163840;
    const disk = Memory{

        .bytes = try allocator.alloc(u8, sectors * 512),

    };
    defer allocator.free(disk.bytes);

    @memset(disk.bytes, 0xa5);

    const table = try allocator.create(gpt.Table);
    defer allocator.destroy(table);

    try table.create(disk, sectors, [_]u8{1} ** 16);
    try table.add(disk, gpt.esp, [_]u8{2} ** 16, .{ .first = 2048, .sectors = 70000 }, "EFI system partition");
    try table.add(disk, volume.partition, [_]u8{3} ** 16, .{ .first = 72048, .sectors = sectors - 33 - 72048 }, "GraniteOS Data");

    try std.testing.expectEqual(0xee, disk.bytes[446 + 4]);
    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expect(table.only(&.{ gpt.esp, gpt.reserved, volume.partition }));
    try std.testing.expectEqual(2048, table.find(gpt.esp).?.first);
    try std.testing.expectEqual(0, table.gap().sectors);

    try std.testing.expectError(error.Small, fat.format(disk, 2048, 1000));
    try fat.format(disk, 2048, 70000);

    const esp = try allocator.create(fat.Fat(Memory));
    defer allocator.destroy(esp);

    try std.testing.expect(try esp.mount(disk, 2048));

    const efi = try esp.directory(esp.root, "EFI        ");

    try esp.write(try esp.directory(efi, "BOOT       "), "BOOTX64 EFI", "loader");
    try std.testing.expectEqual(efi, (try esp.find(esp.root, "EFI        ")).?);
    try std.testing.expect(try esp.find(efi, "BOOT       ") != null);
    try std.testing.expectEqual(null, try esp.find(efi, "MICROS~1   "));

}

test "shortening a partition and adding one after it writes both to the table at once" {

    const allocator = std.testing.allocator;
    const sectors = 65536;
    const disk = Memory{

        .bytes = try allocator.alloc(u8, sectors * 512),

    };
    defer allocator.free(disk.bytes);

    @memset(disk.bytes, 0);

    const table = try allocator.create(gpt.Table);
    defer allocator.destroy(table);

    try table.create(disk, sectors, [_]u8{1} ** 16);
    try table.add(disk, gpt.esp, [_]u8{2} ** 16, .{ .first = 2048, .sectors = 2048 }, "EFI system partition");
    try table.add(disk, ntfs.basic, [_]u8{3} ** 16, .{ .first = 4096, .sectors = sectors - 34 - 4096 }, "Basic data partition");

    const windows = table.find(ntfs.basic).?;

    try std.testing.expect(table.room());
    try std.testing.expectEqual(0, table.gap().sectors);

    table.shorten(windows, 40959);
    try table.add(disk, volume.partition, [_]u8{4} ** 16, .{ .first = 40960, .sectors = 8192 }, "GraniteOS Data");

    try std.testing.expect(try table.read(disk, sectors));
    try std.testing.expectEqual(40959, table.find(ntfs.basic).?.last);
    try std.testing.expectEqual(40960, table.find(volume.partition).?.first);
    try std.testing.expectEqual(49152, table.gap().first);
    try std.testing.expectEqualSlices(u8, &ntfs.basic, &table.at(1).?.kind);

}

/// Reads `name` from a test volume with one-sector clusters, its FAT at sector 32 and data at 96.
fn fatFile(bytes: []const u8, base: usize, directory: u32, name: []const u8, out: []u8) !usize {

    const table = bytes[(base + 32) * 512 ..];
    var cluster = directory;

    while (cluster < 0x0ffffff8) : (cluster = std.mem.readInt(u32, table[cluster * 4 ..][0..4], .little) & 0x0fffffff) {

        const sector = bytes[(base + 96 + cluster - 2) * 512 ..][0..512];

        for (0..16) |index| {

            const entry = sector[index * 32 ..][0..32];
            if (!std.mem.eql(u8, entry[0..11], name)) continue;

            var file = @as(u32, std.mem.readInt(u16, entry[20..22], .little)) << 16 | std.mem.readInt(u16, entry[26..28], .little);
            const size = std.mem.readInt(u32, entry[28..32], .little);
            var done: usize = 0;

            while (done < size) : (file = std.mem.readInt(u32, table[file * 4 ..][0..4], .little) & 0x0fffffff) {

                const count = @min(512, size - done);

                @memcpy(out[done..][0..count], bytes[(base + 96 + file - 2) * 512 ..][0..count]);
                done += count;

            }

            return size;

        }

    }

    return error.Missing;

}

test "HID descriptors find boot keyboards and pointer reports, and keys translate to set-1 scancodes" {

    // VMware's virtual USB mouse: sixteen buttons, absolute X and Y, then a wheel and a pan.
    const descriptor = [_]u8{ 0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x27, 0xff, 0x7f, 0x00, 0x00, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0x05, 0x0c, 0x0a, 0x38, 0x02, 0x81, 0x06, 0xc0, 0xc0 };
    const shape = hid.layout(&descriptor) orelse return error.TestUnexpectedResult;

    // Right button held, at the middle of the screen, one wheel step towards the user.
    const report = [_]u8{ 0x02, 0x00, 0xff, 0x3f, 0xff, 0x3f, 0xff, 0x00 };

    try std.testing.expectEqual(2, shape.buttons.read(&report));
    try std.testing.expectEqual(0x3fff, shape.x.read(&report));
    try std.testing.expectEqual(0x3fff, shape.y.read(&report));
    try std.testing.expectEqual(-1, shape.wheel.read(&report));
    try std.testing.expect(!shape.x.relative and shape.wheel.relative);

    // A configuration with one boot keyboard interface and its interrupt-in endpoint.
    const configuration = [_]u8{ 9, 2, 34, 0, 1, 1, 0, 0xa0, 50, 9, 4, 0, 0, 1, 3, 1, 1, 0, 9, 0x21, 0x11, 0x01, 0, 1, 0x22, 63, 0, 7, 5, 0x81, 3, 8, 0, 10 };
    const found = hid.find(&configuration) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(.keyboard, found.kind);
    try std.testing.expectEqual(0x81, found.endpoint);
    try std.testing.expectEqual(63, found.report);
    try std.testing.expectEqual(0x1e, hid.translate(0x04));
    try std.testing.expectEqual(0x148, hid.translate(0x52));

    // Mute and the volume keys, as PS/2 keyboards send them.
    try std.testing.expectEqual(0x120, hid.translate(0x7f));
    try std.testing.expectEqual(0x130, hid.translate(0x80));
    try std.testing.expectEqual(0x12e, hid.translate(0x81));

}

/// Turns what a connection wants sent into the segment its peer receives.
fn carried(from: *tcp.Connection, out: tcp.Outgoing, bytes: []u8) wire.Segment {

    var segment = out.segment;

    segment.payload = bytes[0..from.tx.peek(out.offset, bytes[0..out.length])];

    return segment;

}

test "the Internet checksum matches a known IPv4 header and verifies to zero" {

    var header = [_]u8{ 0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7 };

    try std.testing.expectEqual(0xb861, wire.fold(wire.sum(0, &header)));

    wire.writeIp(&header, wire.udp, 0xc0a80001, 0xc0a800c7, 0x73 - 20, 0);

    try std.testing.expect(wire.parseIp(&header) == null);
    try std.testing.expectEqual(0, wire.fold(wire.sum(0, &header)));

}

test "TCP connects, carries data across a lost segment, and closes from both ends" {

    var memory: [4][4096]u8 = undefined;
    var client = tcp.Connection{ .rx = .{ .bytes = &memory[0] }, .tx = .{ .bytes = &memory[1] } };
    var server = tcp.Connection{ .rx = .{ .bytes = &memory[2] }, .tx = .{ .bytes = &memory[3] } };
    var bytes: [1500]u8 = undefined;
    var now: u64 = 1000;

    client.open(50000, 80, 7, 1460);

    const syn = carried(&client, client.output(now).?, &bytes);

    try std.testing.expect(syn.flags.syn and syn.mss == 1460);

    server.accept(syn, 900, 1460);

    const reply = carried(&server, server.output(now).?, &bytes);

    try std.testing.expect(reply.flags.syn and reply.flags.ack and reply.acknowledgment == 8);

    now += 5;
    client.input(reply, now);
    try std.testing.expectEqual(.established, client.state);
    server.input(carried(&client, client.output(now).?, &bytes), now);
    try std.testing.expectEqual(.established, server.state);

    // The first segment goes missing, so nothing arrives until the timer resends it.
    try std.testing.expectEqual(5, client.write("hello"));
    _ = client.output(now).?;
    try std.testing.expect(client.output(now) == null);
    try std.testing.expect(!client.tick(client.due() - 1));

    now = client.due();
    try std.testing.expect(client.tick(now));
    server.input(carried(&client, client.output(now).?, &bytes), now);

    var text: [16]u8 = undefined;

    try std.testing.expectEqualStrings("hello", text[0..server.read(&text)]);
    client.input(carried(&server, server.output(now).?, &bytes), now);
    try std.testing.expectEqual(0, client.tx.length);
    try std.testing.expectEqual(0, client.due());

    // A repeat of what already arrived is acknowledged again but not delivered twice.
    server.input(.{ .source = 50000, .destination = 80, .sequence = 8, .acknowledgment = server.next, .flags = .{ .ack = true }, .window = 4096, .payload = "hello" }, now);
    try std.testing.expectEqual(0, server.rx.length);
    try std.testing.expect(server.acknowledge);
    _ = server.output(now);

    client.close();

    const fin = carried(&client, client.output(now).?, &bytes);

    try std.testing.expect(fin.flags.fin);
    server.input(fin, now);
    try std.testing.expectEqual(.close_wait, server.state);
    try std.testing.expect(server.readable() and server.read(&text) == 0);

    server.close();
    client.input(carried(&server, server.output(now).?, &bytes), now);
    try std.testing.expectEqual(.time_wait, client.state);
    server.input(carried(&client, client.output(now).?, &bytes), now);
    try std.testing.expectEqual(.closed, server.state);
    try std.testing.expect(client.tick(client.due()));
    try std.testing.expectEqual(.closed, client.state);

}

test "TCP gives up an unanswered connection and reports a refused one" {

    var memory: [2][4096]u8 = undefined;
    var client = tcp.Connection{ .rx = .{ .bytes = &memory[0] }, .tx = .{ .bytes = &memory[1] } };
    var now: u64 = 0;

    client.open(50001, 81, 100, 1460);

    while (client.state != .closed) {

        if (client.output(now)) |out| try std.testing.expect(out.segment.flags.syn);
        now = client.due();
        _ = client.tick(now);

    }

    try std.testing.expect(client.expired and client.reset);

    client.open(50002, 81, 200, 1460);
    _ = client.output(now);
    client.input(.{ .source = 81, .destination = 50002, .acknowledgment = 201, .flags = .{ .rst = true, .ack = true } }, now);
    try std.testing.expect(client.reset and !client.expired and client.state == .closed);

}

test "DNS queries encode names and answers skip aliases to the address" {

    var bytes: [512]u8 = undefined;
    const length = dns.query(&bytes, 0x1234, "example.com.").?;

    try std.testing.expectEqualSlices(u8, "\x07example\x03com\x00\x00\x01\x00\x01", bytes[12..length]);
    try std.testing.expect(dns.query(&bytes, 1, "bad..name") == null);

    // The reply: the question, a CNAME pointing back at it, then the A record.
    const answer = [_]u8{ 0x12, 0x34, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0 } ++ "\x07example\x03com\x00".* ++ [_]u8{ 0, 1, 0, 1 } ++
        [_]u8{ 0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xc0, 12 } ++
        [_]u8{ 0xc0, 12, 0, 1, 0, 1, 0, 0, 1, 0, 0, 4, 93, 184, 215, 14 };

    const found = dns.parse(&answer, 0x1234).?;

    try std.testing.expectEqual(0x5db8d70e, found.found.address);
    try std.testing.expectEqual(256, found.found.ttl);
    try std.testing.expect(dns.parse(&answer, 0x4321) == null);

    var missing = answer;

    missing[3] = 0x83;
    try std.testing.expectEqual(.missing, std.meta.activeTag(dns.parse(&missing, 0x1234).?));

}

test "DHCP builds a discover and reads an offer's lease" {

    const mac = wire.Mac{ 0x00, 0x0c, 0x29, 0x01, 0x02, 0x03 };
    var bytes: [576]u8 = undefined;
    const length = dhcp.build(&bytes, .discover, 0xabcd, mac, 0, 0, 0);

    try std.testing.expectEqual(300, length);
    try std.testing.expectEqualSlices(u8, &.{ 53, 1, 1 }, bytes[240..243]);

    // The server's offer: the address, then type, mask, router, DNS, lease, and server options.
    bytes[0] = 2;
    wire.put(u32, bytes[16..20], 0xc0a8640a);
    @memcpy(bytes[240..][0..39], &[_]u8{ 53, 1, 2, 1, 4, 255, 255, 255, 0, 3, 4, 192, 168, 100, 2, 6, 4, 192, 168, 100, 2, 51, 4, 0, 0, 7, 8, 54, 4, 192, 168, 100, 254, 255, 0, 0, 0, 0, 0 });

    const offer = dhcp.parse(bytes[0..length], 0xabcd, mac).?;

    try std.testing.expectEqual(.offer, offer.kind);
    try std.testing.expectEqual(0xc0a8640a, offer.address);
    try std.testing.expectEqual(0xffffff00, offer.mask);
    try std.testing.expectEqual(0xc0a86402, offer.router);
    try std.testing.expectEqual(0xc0a864fe, offer.server);
    try std.testing.expectEqual(1800, offer.lease);
    try std.testing.expectEqual(900, offer.renew);
    try std.testing.expect(dhcp.parse(bytes[0..length], 0xabce, mac) == null);

}

test "mixer passes device-rate streams through exactly across the ring's wrap and stops when it runs dry" {

    const samples = [_]i16{ 100, -100, 200, -200, 300, -300, 400, -400 };

    var ring = mixer.Ring(i16){

        .samples = &samples,
        .channels = 2,
        .capacity = 4,
        .taken = 2,
        .written = 7,

    };

    var resampler = mixer.Resampler.init(mixer.rate);
    var out = [_]mixer.Frame{mixer.silence} ** 8;

    resampler.gain = 1;

    // Frames come out two behind those read, as the window holds two ahead, until the ring runs dry.
    try std.testing.expectEqual(5, resampler.mix(i16, &ring, &out, 1));
    try std.testing.expectEqual(7, ring.taken);

    const expected = [_]i16{ 0, 0, 300, 400, 100 };

    for (expected, out[0..5]) |left, frame| {

        try std.testing.expectEqual(@as(f32, @floatFromInt(left)) / 32768, frame[0]);
        try std.testing.expectEqual(-frame[0], frame[1]);

    }

    try std.testing.expectEqual(mixer.silence, out[5]);

}

test "mixer resamples 44.1 kHz mono to the device rate keeping a tone's pitch and level" {

    const source = 44100;
    var samples: [source / 10]f32 = undefined;

    for (&samples, 0..) |*sample, index| sample.* = 0.5 * @sin(std.math.tau * 1000 * @as(f32, @floatFromInt(index)) / source);

    var ring = mixer.Ring(f32){

        .samples = &samples,
        .channels = 1,
        .capacity = samples.len,
        .taken = 0,
        .written = samples.len,

    };

    var resampler = mixer.Resampler.init(source);
    var out = [_]mixer.Frame{mixer.silence} ** (mixer.rate / 10 + 64);

    resampler.gain = 1;

    const produced = resampler.mix(f32, &ring, &out, 1);

    // A tenth of a second at either rate, give or take the rounding of the step.
    try std.testing.expect(produced >= mixer.rate / 10 - 1 and produced <= mixer.rate / 10 + 1);
    try std.testing.expectEqual(samples.len, ring.taken);
    try std.testing.expect(source - resampler.span(mixer.rate) <= 1);

    var crossings: usize = 0;
    var peak: f32 = 0;

    for (out[8..produced], out[9 .. produced + 1]) |before, after| {

        if ((before[0] < 0) != (after[0] < 0)) crossings += 1;
        peak = @max(peak, @abs(after[0]));
        try std.testing.expectEqual(after[0], after[1]);

    }

    // A thousand cycles a second cross zero about two hundred times in a tenth of a second.
    try std.testing.expect(crossings >= 196 and crossings <= 201);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);

}

test "mixer glides gains, clips the sum, and holds bad floats to full scale" {

    const samples = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 1, std.math.nan(f32), std.math.inf(f32) };

    var ring = mixer.Ring(f32){

        .samples = &samples,
        .channels = 1,
        .capacity = samples.len,
        .taken = 0,
        .written = samples.len,

    };

    var resampler = mixer.Resampler.init(mixer.rate);
    var out = [_]mixer.Frame{mixer.silence} ** 6;

    resampler.window = .{@as(mixer.Frame, @splat(1))} ** 4;
    _ = resampler.mix(f32, &ring, &out, 1);

    // From silence to full gain in even steps over the block.
    for (out, 0..) |frame, index| try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(index)) / 6, frame[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), resampler.gain, 1e-6);

    var loud = [_]mixer.Frame{ .{ 2, -2 }, .{ 0.5, -0.25 }, .{ std.math.nan(f32), 0 } };
    var pcm: [6]i16 = undefined;

    mixer.quantize(&loud, &pcm);
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32767, 16384, -8192, -32767, 0 }, &pcm);

    // The not-a-number and the infinity reach the window as full scale either way.
    var rest = [_]mixer.Frame{mixer.silence} ** 4;

    try std.testing.expectEqual(4, resampler.mix(f32, &ring, &rest, 1));
    try std.testing.expectEqual(@as(mixer.Frame, @splat(-1)), resampler.window[2]);
    try std.testing.expectEqual(@as(mixer.Frame, @splat(1)), resampler.window[3]);

    try std.testing.expectEqual(0, mixer.loudness(0));
    try std.testing.expectEqual(1, mixer.loudness(100));
    try std.testing.expectEqual(1, mixer.loudness(200));
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), mixer.loudness(50), 1e-6);

}

test "mixer cursor counts the device's frames across its ring's wrap" {

    var cursor = mixer.Cursor{

        .size = 4096,

    };

    try std.testing.expectEqual(0, cursor.advance(0));
    try std.testing.expectEqual(512, cursor.advance(2048));
    try std.testing.expectEqual(1024, cursor.advance(4096));
    try std.testing.expectEqual(1280, cursor.advance(1024));
    try std.testing.expectEqual(1281, cursor.advance(1030));
    try std.testing.expectEqual(1282, cursor.advance(1032));

}

test "every chime stays within full scale, swells without a click, and ends in silence" {

    for (chime.tunes) |tune| {

        var voice = chime.Voice{

            .tune = tune,

        };

        const length: usize = @intFromFloat(@ceil(chime.duration(tune) * mixer.rate));
        var out = [_]mixer.Frame{mixer.silence} ** 512;
        var played: usize = 0;
        var peak: f32 = 0;

        try std.testing.expect(length > 0);

        while (!voice.done()) {

            @memset(&out, mixer.silence);
            voice.mix(&out, 1);

            for (out, played..) |frame, index| {

                try std.testing.expect(std.math.isFinite(frame[0]) and @abs(frame[0]) < 1);
                if (index == 0) try std.testing.expectEqual(0, frame[0]);
                if (index >= length) try std.testing.expect(@abs(frame[0]) < 1e-4);
                peak = @max(peak, @abs(frame[0]));

            }

            played += out.len;

        }

        try std.testing.expect(peak > 0.05);
        try std.testing.expect(played >= length and played < length + out.len);

    }

}

/// A codec of nine widgets, as `Fake.nodes` lists them, that records every verb setting something.
const Fake = struct {

    const Node = struct {

        parameters: []const struct { codec.Parameter, u32 } = &.{},
        configuration: u32 = 0,
        connections: []const u32 = &.{},

    };

    const amp = 1 << 31 | 0x05 << 16 | 0x57 << 8 | 0x40;
    const input_amp = 1 << 31 | 0x1f << 8 | 0x17;

    const nodes = [_]Node{

        // The root, then the audio function group.
        .{ .parameters = &.{ .{ .vendor, 0x10ec0892 }, .{ .nodes, 1 << 16 | 1 } } },
        .{ .parameters = &.{ .{ .group, 1 }, .{ .nodes, 2 << 16 | 8 }, .{ .output_amp, amp }, .{ .input_amp, input_amp } } },

        // An analog converter, then a digital one.
        .{ .parameters = &.{.{ .widget, 0x00000005 }} },
        .{ .parameters = &.{.{ .widget, 0x00000201 }} },

        // A mixer of a range of nodes, 2 to 7.
        .{ .parameters = &.{ .{ .widget, 0x00200103 }, .{ .connections, 2 } }, .connections = &.{0x8702} },

        // Headphones on a jack, through the mixer.
        .{ .parameters = &.{ .{ .widget, 0x00400105 }, .{ .pin, 0x18 }, .{ .connections, 1 } }, .configuration = 0x02211020, .connections = &.{0x04} },

        // A built-in speaker that needs its amplifier enabled, listing the digital converter first in long form.
        .{ .parameters = &.{ .{ .widget, 0x00400101 }, .{ .pin, 0x10010 }, .{ .connections, 0x82 } }, .configuration = 0x90170110, .connections = &.{0x0002_0003} },

        // A microphone, line out wired to nothing, and a digital output: none is driven.
        .{ .parameters = &.{ .{ .widget, 0x00400001 }, .{ .pin, 0x20 } }, .configuration = 0x01a19030 },
        .{ .parameters = &.{ .{ .widget, 0x00400101 }, .{ .pin, 0x10 }, .{ .connections, 1 } }, .configuration = 0x411111f0, .connections = &.{0x02} },
        .{ .parameters = &.{ .{ .widget, 0x00400301 }, .{ .pin, 0x10 }, .{ .connections, 1 } }, .configuration = 0x01441150, .connections = &.{0x03} },

    };

    /// Each verb that set something: its node, verb, and payload.
    sets: [64][3]u32 = undefined,
    count: usize = 0,

    fn send(context: *anyopaque, command: u32) ?u32 {

        const self: *Fake = @ptrCast(@alignCast(context));
        const node = &nodes[command >> 20 & 0xff];
        const verb = command >> 8 & 0xfff;
        const payload = command & 0xff;

        switch (verb) {

            0xf00 => {

                for (node.parameters) |entry| {

                    if (@intFromEnum(entry[0]) == payload) return entry[1];

                }

                return 0;

            },
            0xf02 => return node.connections[payload / 4],
            0xf1c => return node.configuration,
            else => {

                // 4-bit verbs carry a 16-bit payload instead.
                const short = verb >> 8 != 0x7;

                self.sets[self.count] = if (short) .{ command >> 20 & 0xff, command >> 16 & 0xf, command & 0xffff } else .{ command >> 20 & 0xff, verb, payload };
                self.count += 1;

                return 0;

            },

        }

    }

    fn set(self: *const Fake, node: u32, verb: u32) ?u32 {

        for (self.sets[0..self.count]) |entry| {

            if (entry[0] == node and entry[1] == verb) return entry[2];

        }

        return null;

    }

    fn amps(self: *const Fake, node: u32, out: []u32) []u32 {

        var count: usize = 0;

        for (self.sets[0..self.count]) |entry| {

            if (entry[0] != node or entry[1] != 0x3) continue;

            out[count] = entry[2];
            count += 1;

        }

        return out[0..count];

    }

};

test "codec routes each analog output pin to a converter and opens its path at unity gain" {

    var fake = Fake{};
    var chip = codec.Codec{};

    const link = codec.Link{

        .context = &fake,
        .send = Fake.send,
        .address = 0,

    };

    try std.testing.expect(chip.probe(link));
    try std.testing.expectEqual(0x10ec0892, chip.vendor);
    try std.testing.expectEqual(1, chip.group);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6, 7 }, chip.find(4).?.inputs[0..chip.find(4).?.count]);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2 }, chip.find(6).?.inputs[0..chip.find(6).?.count]);

    fake.count = 0;
    chip.route(link);

    try std.testing.expectEqual(2, chip.outputs);
    try std.testing.expectEqualSlices(u8, &.{2}, chip.converters[0..chip.converter_count]);

    // Headphones get headphone drive; the speaker skips the digital converter and wakes its amplifier.
    try std.testing.expectEqual(0xc0, fake.set(5, 0x707));
    try std.testing.expectEqual(null, fake.set(5, 0x70c));
    try std.testing.expectEqual(0x40, fake.set(6, 0x707));
    try std.testing.expectEqual(2, fake.set(6, 0x70c));
    try std.testing.expectEqual(1, fake.set(6, 0x701));

    for ([_]u32{ 7, 8, 9 }) |idle| try std.testing.expectEqual(null, fake.set(idle, 0x707));

    // The mixer hears only the converter, at 0 dB; the converter and headphones play at 0 dB too.
    var found: [16]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{ 0x7017, 0x7180, 0x7280, 0x7380, 0x7480, 0x7580 }, fake.amps(4, &found));
    try std.testing.expectEqualSlices(u32, &.{0xb040}, fake.amps(5, &found));
    try std.testing.expectEqual(0xb040, fake.amps(2, &found)[0]);

    fake.count = 0;
    chip.start(link, 1, 0x0011);

    try std.testing.expectEqual(0x10, fake.set(2, 0x706));
    try std.testing.expectEqual(0x0011, fake.set(2, 0x2));
    try std.testing.expectEqual(2, fake.count);

}
