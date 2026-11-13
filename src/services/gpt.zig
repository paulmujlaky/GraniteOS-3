const std = @import("std");

const volume = @import("volume.zig");

const Crc32 = std.hash.Crc32;
const field = volume.field;

/// EFI system partition type c12a7328-f81f-11d2-ba4b-00a0c93ec93b, in on-disk byte order.
pub const esp = [16]u8{

    0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,

};

/// Microsoft reserved partition e3c9e316-0b5c-4db8-817d-f92df00215ae, which Windows adds to disks and which holds no files.
pub const reserved = [16]u8{

    0x16, 0xe3, 0xc9, 0xe3, 0x5c, 0x0b, 0xb8, 0x4d, 0x81, 0x7d, 0xf9, 0x2d, 0xf0, 0x02, 0x15, 0xae,

};

const alignment = 2048;
const limit = 128 * 128;

pub const Partition = struct {

    number: u32,
    first: u64,
    last: u64,
    unique: [16]u8,

};

/// A GPT whose primary header and entry array both passed their checksums.
pub const Table = struct {

    header: [512]u8,
    entries: [limit]u8,

    /// False when the disk holds no intact GPT, which the installer then leaves alone.
    pub fn read(self: *Table, disk: anytype, capacity: u64) !bool {

        try disk.read(1, &self.header);
        if (!std.mem.eql(u8, self.header[0..8], "EFI PART")) return false;

        const size = field(u32, &self.header, 12);
        const count = field(u32, &self.header, 80);
        const width = field(u32, &self.header, 84);

        if (size < 92 or size > 512 or field(u64, &self.header, 24) != 1 or field(u64, &self.header, 32) >= capacity) return false;
        if (width < 128 or width % 8 != 0 or @as(u64, count) * width > limit) return false;

        var copy = self.header;

        std.mem.writeInt(u32, copy[16..20], 0, .little);
        if (Crc32.hash(copy[0..size]) != field(u32, &self.header, 16)) return false;

        const bytes = self.span();

        if (field(u64, &self.header, 72) + bytes / 512 > capacity) return false;
        try disk.read(field(u64, &self.header, 72), self.entries[0..bytes]);

        return Crc32.hash(self.entries[0 .. count * width]) == field(u32, &self.header, 88);

    }

    /// Starts an empty table for a disk of `capacity` sectors behind a protective MBR; `add` writes both copies out.
    pub fn create(self: *Table, disk: anytype, capacity: u64, unique: [16]u8) !void {

        var mbr = std.mem.zeroes([512]u8);

        mbr[446 + 2] = 2;
        mbr[446 + 4] = 0xee;
        @memset(mbr[446 + 5 .. 446 + 8], 0xff);
        std.mem.writeInt(u32, mbr[446 + 8 ..][0..4], 1, .little);
        std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], @intCast(@min(capacity - 1, 0xffffffff)), .little);
        mbr[510] = 0x55;
        mbr[511] = 0xaa;

        @memset(&self.header, 0);
        @memset(&self.entries, 0);

        self.header[0..8].* = "EFI PART".*;
        std.mem.writeInt(u32, self.header[8..12], 0x10000, .little);
        std.mem.writeInt(u32, self.header[12..16], 92, .little);
        std.mem.writeInt(u64, self.header[24..32], 1, .little);
        std.mem.writeInt(u64, self.header[32..40], capacity - 1, .little);
        std.mem.writeInt(u64, self.header[40..48], 34, .little);
        std.mem.writeInt(u64, self.header[48..56], capacity - 34, .little);
        self.header[56..72].* = unique;
        std.mem.writeInt(u64, self.header[72..80], 2, .little);
        std.mem.writeInt(u32, self.header[80..84], 128, .little);
        std.mem.writeInt(u32, self.header[84..88], 128, .little);

        try disk.write(0, &mbr);

    }

    /// Every partition is one of `kinds`, as on a disk nothing but GraniteOS uses.
    pub fn only(self: *const Table, kinds: []const [16]u8) bool {

        for (0..field(u32, &self.header, 80)) |index| {

            if (!self.used(index)) continue;

            for (kinds) |kind| {

                if (std.mem.eql(u8, self.record(index)[0..16], &kind)) break;

            } else return false;

        }

        return true;

    }

    pub fn find(self: *const Table, kind: [16]u8) ?Partition {

        for (0..field(u32, &self.header, 80)) |index| {

            const entry = self.record(index);
            if (!std.mem.eql(u8, entry[0..16], &kind)) continue;

            return .{

                .number = @intCast(index + 1),
                .first = field(u64, entry, 32),
                .last = field(u64, entry, 40),
                .unique = entry[16..32].*,

            };

        }

        return null;

    }

    /// The largest 1 MiB-aligned run of usable sectors that no partition covers.
    pub fn gap(self: *const Table) volume.Range {

        const first = field(u64, &self.header, 40);
        const last = field(u64, &self.header, 48);
        const count = field(u32, &self.header, 80);

        var best = volume.Range{

            .first = 0,
            .sectors = 0,

        };

        // Every gap starts at the first usable sector or just past some partition.
        for (0..count + 1) |candidate| {

            const after = if (candidate == count) first else field(u64, self.record(candidate), 40) + 1;

            if (candidate != count and !self.used(candidate)) continue;

            const start = std.mem.alignForward(u64, @max(after, first), alignment);
            var end = last + 1;

            for (0..count) |index| {

                if (!self.used(index)) continue;

                const entry = self.record(index);

                if (start >= field(u64, entry, 32) and start <= field(u64, entry, 40)) end = 0;
                if (field(u64, entry, 32) >= start) end = @min(end, field(u64, entry, 32));

            }

            if (end > start and end - start > best.sectors) best = .{

                .first = start,
                .sectors = end - start,

            };

        }

        return best;

    }

    /// Records a partition in the first empty slot, writing the backup table before the primary.
    pub fn add(self: *Table, disk: anytype, kind: [16]u8, unique: [16]u8, range: volume.Range, name: []const u8) !void {

        const count = field(u32, &self.header, 80);

        const slot = for (0..count) |index| {

            if (!self.used(index)) break index;

        } else return error.Full;

        const entry = self.entries[slot * field(u32, &self.header, 84) ..][0..128];

        @memset(entry, 0);
        entry[0..16].* = kind;
        entry[16..32].* = unique;
        std.mem.writeInt(u64, entry[32..40], range.first, .little);
        std.mem.writeInt(u64, entry[40..48], range.first + range.sectors - 1, .little);

        for (name, 0..) |byte, index| entry[56 + index * 2] = byte;

        const bytes = self.span();
        const backup = field(u64, &self.header, 32);
        var mirror = self.header;

        std.mem.writeInt(u32, self.header[88..92], Crc32.hash(self.entries[0 .. count * field(u32, &self.header, 84)]), .little);
        std.mem.writeInt(u32, mirror[88..92], field(u32, &self.header, 88), .little);
        std.mem.writeInt(u64, mirror[24..32], backup, .little);
        std.mem.writeInt(u64, mirror[32..40], 1, .little);
        std.mem.writeInt(u64, mirror[72..80], backup - bytes / 512, .little);
        seal(&self.header);
        seal(&mirror);

        try disk.write(backup - bytes / 512, self.entries[0..bytes]);
        try disk.write(backup, &mirror);
        try disk.write(field(u64, &self.header, 72), self.entries[0..bytes]);
        try disk.write(1, &self.header);

    }

    fn record(self: *const Table, index: usize) *const [128]u8 {

        return self.entries[index * field(u32, &self.header, 84) ..][0..128];

    }

    fn used(self: *const Table, index: usize) bool {

        return !std.mem.allEqual(u8, self.record(index)[0..16], 0);

    }

    fn span(self: *const Table) usize {

        return std.mem.alignForward(usize, @as(usize, field(u32, &self.header, 80)) * field(u32, &self.header, 84), 512);

    }

};

fn seal(header: *[512]u8) void {

    const size = field(u32, header, 12);

    std.mem.writeInt(u32, header[16..20], 0, .little);
    std.mem.writeInt(u32, header[16..20], Crc32.hash(header[0..size]), .little);

}
