const std = @import("std");

const end_of_chain = 0x0fffffff;
const date = (2026 - 1980) << 9 | 1 << 5 | 1;

const Slot = struct {

    sector: u64,
    offset: usize,
    cluster: u32,
    attributes: u8,

};

const Search = struct {

    match: ?Slot,
    free: ?Slot,
    last: u32,

};

/// Writes into an existing FAT32 volume, touching only clusters and directory slots the FAT marks free.
pub fn Fat(comptime Disk: type) type {

    return struct {

        const Self = @This();

        disk: Disk,
        base: u64,
        per: u32,
        copies: u32,
        fat: u64,
        size: u32,
        data: u64,
        clusters: u32,
        root: u32,
        info: u16,
        hint: u32,

        sector: [512]u8,
        table: [512]u8,
        cached: ?u64,
        dirty: bool,

        /// False when the partition at `first` is not FAT32 with 512-byte sectors.
        pub fn mount(self: *Self, disk: Disk, first: u64) !bool {

            self.disk = disk;
            self.base = first;
            self.cached = null;
            self.dirty = false;
            self.hint = 2;

            try disk.read(first, &self.sector);

            const boot = &self.sector;
            const total = if (field(u16, boot, 19) != 0) field(u16, boot, 19) else field(u32, boot, 32);

            if (field(u16, boot, 11) != 512 or boot[510] != 0x55 or boot[511] != 0xaa) return false;
            if (boot[13] == 0 or !std.math.isPowerOfTwo(boot[13]) or boot[16] == 0 or field(u16, boot, 17) != 0 or field(u16, boot, 22) != 0) return false;

            self.per = boot[13];
            self.copies = boot[16];
            self.fat = field(u16, boot, 14);
            self.size = field(u32, boot, 36);
            self.data = self.fat + @as(u64, self.copies) * self.size;
            self.root = field(u32, boot, 44);
            self.info = field(u16, boot, 48);

            if (self.size == 0 or total <= self.data) return false;

            self.clusters = @intCast(@min((total - self.data) / self.per, @as(u64, self.size) * 128 - 2));

            return self.root >= 2 and self.root < self.clusters + 2;

        }

        /// The first cluster of directory `name` inside `parent`, or null when it has none.
        pub fn find(self: *Self, parent: u32, name: *const [11]u8) !?u32 {

            const found = try self.search(parent, name);
            const slot = found.match orelse return null;

            return if (slot.attributes & 0x10 != 0) slot.cluster else null;

        }

        /// Returns the cluster of directory `name` inside `parent`, creating it when absent.
        pub fn directory(self: *Self, parent: u32, name: *const [11]u8) !u32 {

            const found = try self.search(parent, name);

            if (found.match) |slot| return if (slot.attributes & 0x10 != 0) slot.cluster else error.Exists;

            const cluster = try self.allocate(0);
            const lba = self.address(cluster);

            @memset(&self.sector, 0);
            for (1..self.per) |offset| try self.disk.write(lba + offset, &self.sector);

            fill(self.sector[0..32], ".          ", 0x10, cluster, 0);
            fill(self.sector[32..64], "..         ", 0x10, if (parent == self.root) 0 else parent, 0);
            try self.disk.write(lba, &self.sector);
            try self.sync();
            try self.record(found.free orelse try self.extend(found.last), name, 0x10, cluster, 0);

            return cluster;

        }

        /// Replaces file `name` in `parent` with `bytes`.
        pub fn write(self: *Self, parent: u32, name: *const [11]u8, bytes: []const u8) !void {

            const found = try self.search(parent, name);

            if (found.match) |slot| {

                if (slot.attributes & 0x10 != 0) return error.Exists;
                if (slot.cluster != 0) try self.release(slot.cluster);

            }

            const unit = @as(usize, self.per) * 512;
            var first: u32 = 0;
            var previous: u32 = 0;
            var run: u32 = 0;
            var start: usize = 0;
            var done: usize = 0;

            // Consecutive clusters are written as one run.
            while (done < bytes.len) {

                const cluster = try self.allocate(previous);

                if (first == 0) first = cluster;

                if (cluster != previous + 1 and done > start) {

                    try self.put(run, bytes[start..done]);
                    start = done;

                }

                if (done == start) run = cluster;
                done = @min(bytes.len, done + unit);
                previous = cluster;

            }

            if (done > start) try self.put(run, bytes[start..done]);
            try self.sync();
            try self.record(found.match orelse found.free orelse try self.extend(found.last), name, 0x20, first, @intCast(bytes.len));
            try self.forget();

        }

        fn search(self: *Self, folder: u32, name: *const [11]u8) !Search {

            var result = Search{

                .match = null,
                .free = null,
                .last = folder,

            };

            var cluster = folder;

            for (0..self.clusters) |_| {

                result.last = cluster;

                for (0..self.per) |offset| {

                    const lba = self.address(cluster) + offset;

                    try self.disk.read(lba, &self.sector);

                    for (0..16) |index| {

                        const entry = self.sector[index * 32 ..][0..32];

                        const slot = Slot{

                            .sector = lba,
                            .offset = index * 32,
                            .cluster = @as(u32, field(u16, entry, 20)) << 16 | field(u16, entry, 26),
                            .attributes = entry[11],

                        };

                        if (entry[0] == 0) {

                            result.free = result.free orelse slot;
                            return result;

                        }

                        if (entry[0] == 0xe5) {

                            result.free = result.free orelse slot;
                            continue;

                        }

                        if (entry[11] != 0x0f and std.mem.eql(u8, entry[0..11], name)) result.match = slot;

                    }

                }

                const next = try self.follow(cluster);
                if (next >= 0x0ffffff8) return result;

                cluster = next;

            }

            return error.Corrupt;

        }

        // Appends a zeroed cluster to a full directory and returns its first slot.
        fn extend(self: *Self, last: u32) !Slot {

            const cluster = try self.allocate(last);

            @memset(&self.sector, 0);
            for (0..self.per) |offset| try self.disk.write(self.address(cluster) + offset, &self.sector);
            try self.sync();

            return .{

                .sector = self.address(cluster),
                .offset = 0,
                .cluster = 0,
                .attributes = 0,

            };

        }

        fn record(self: *Self, slot: Slot, name: *const [11]u8, attributes: u8, cluster: u32, size: u32) !void {

            try self.disk.read(slot.sector, &self.sector);

            const ending = self.sector[slot.offset] == 0;

            fill(self.sector[slot.offset..][0..32], name, attributes, cluster, size);

            // Taking the end-of-directory slot moves that marker one entry along.
            if (ending and slot.offset + 32 < 512) self.sector[slot.offset + 32] = 0;
            try self.disk.write(slot.sector, &self.sector);

        }

        fn put(self: *Self, cluster: u32, bytes: []const u8) !void {

            const whole = bytes.len / 512 * 512;

            try self.disk.write(self.address(cluster), bytes[0..whole]);
            if (whole == bytes.len) return;

            @memset(&self.sector, 0);
            @memcpy(self.sector[0 .. bytes.len - whole], bytes[whole..]);
            try self.disk.write(self.address(cluster) + whole / 512, &self.sector);

        }

        fn allocate(self: *Self, previous: u32) !u32 {

            var cluster = self.hint;

            for (0..self.clusters) |_| {

                if (cluster >= self.clusters + 2) cluster = 2;

                if (try self.follow(cluster) == 0) {

                    try self.link(cluster, end_of_chain);
                    if (previous != 0) try self.link(previous, cluster);
                    self.hint = cluster + 1;

                    return cluster;

                }

                cluster += 1;

            }

            return error.Full;

        }

        fn release(self: *Self, first: u32) !void {

            var cluster = first;

            for (0..self.clusters) |_| {

                const next = try self.follow(cluster);

                try self.link(cluster, 0);
                if (next < 2 or next >= 0x0ffffff8) return self.sync();

                cluster = next;

            }

            return error.Corrupt;

        }

        fn follow(self: *Self, cluster: u32) !u32 {

            try self.load(cluster);

            return field(u32, &self.table, cluster % 128 * 4) & 0x0fffffff;

        }

        fn link(self: *Self, cluster: u32, value: u32) !void {

            try self.load(cluster);

            const at = self.table[cluster % 128 * 4 ..][0..4];

            std.mem.writeInt(u32, at, std.mem.readInt(u32, at, .little) & 0xf0000000 | value, .little);
            self.dirty = true;

        }

        fn load(self: *Self, cluster: u32) !void {

            if (cluster < 2 or cluster >= self.clusters + 2) return error.Corrupt;
            if (self.cached == cluster / 128) return;

            try self.sync();
            try self.disk.read(self.base + self.fat + cluster / 128, &self.table);
            self.cached = cluster / 128;

        }

        fn sync(self: *Self) !void {

            if (!self.dirty) return;

            for (0..self.copies) |copy| try self.disk.write(self.base + self.fat + copy * self.size + self.cached.?, &self.table);
            self.dirty = false;

        }

        // Marks the free-cluster hint unknown, which every FAT32 driver must then recount.
        fn forget(self: *Self) !void {

            if (self.info == 0 or self.info >= self.fat) return;

            try self.disk.read(self.base + self.info, &self.sector);
            if (field(u32, &self.sector, 0) != 0x41615252 or field(u32, &self.sector, 484) != 0x61417272) return;

            std.mem.writeInt(u64, self.sector[488..496], std.math.maxInt(u64), .little);
            try self.disk.write(self.base + self.info, &self.sector);

        }

        fn address(self: *const Self, cluster: u32) u64 {

            return self.base + self.data + @as(u64, cluster - 2) * self.per;

        }

    };

}

/// Lays an empty FAT32 volume of `sectors` 512-byte sectors, one per cluster, over the partition at `first`.
// Zeros written in runs while formatting; too large for a service's stack.
var zeros = std.mem.zeroes([0x10000]u8);

pub fn format(disk: anytype, first: u64, sectors: u32) !void {

    const reserved = 32;
    const size: u32 = (sectors - reserved + 2) * 4 / 512 + 1;
    const clusters = sectors - reserved - 2 * size;

    // Fewer clusters than this would make every driver read the volume as FAT16.
    if (clusters < 65525) return error.Small;

    var boot = std.mem.zeroes([512]u8);

    boot[0..11].* = "\xeb\x58\x90GRANITE ".*;
    std.mem.writeInt(u16, boot[11..13], 512, .little);
    boot[13] = 1;
    std.mem.writeInt(u16, boot[14..16], reserved, .little);
    boot[16] = 2;
    boot[21] = 0xf8;
    std.mem.writeInt(u16, boot[24..26], 63, .little);
    std.mem.writeInt(u16, boot[26..28], 255, .little);
    std.mem.writeInt(u32, boot[28..32], @intCast(first), .little);
    std.mem.writeInt(u32, boot[32..36], sectors, .little);
    std.mem.writeInt(u32, boot[36..40], size, .little);
    std.mem.writeInt(u32, boot[44..48], 2, .little);
    std.mem.writeInt(u16, boot[48..50], 1, .little);
    std.mem.writeInt(u16, boot[50..52], 6, .little);
    boot[64] = 0x80;
    boot[66] = 0x29;
    boot[71..90].* = "GRANITEOS  FAT32   ".*;
    boot[510] = 0x55;
    boot[511] = 0xaa;

    var info = std.mem.zeroes([512]u8);

    std.mem.writeInt(u32, info[0..4], 0x41615252, .little);
    std.mem.writeInt(u32, info[484..488], 0x61417272, .little);
    std.mem.writeInt(u32, info[488..492], clusters - 1, .little);
    std.mem.writeInt(u32, info[492..496], 3, .little);
    std.mem.writeInt(u32, info[508..512], 0xaa550000, .little);

    var done: u32 = 0;

    // Both FATs and the root directory's one cluster start out zeroed.
    while (done < 2 * size + 1) {

        const count: u32 = @min(2 * size + 1 - done, zeros.len / 512);

        try disk.write(first + reserved + done, zeros[0 .. count * 512]);
        done += count;

    }

    var table = std.mem.zeroes([512]u8);

    for ([_]u32{ 0x0ffffff8, 0xffffffff, end_of_chain }, 0..) |value, index| std.mem.writeInt(u32, table[index * 4 ..][0..4], value, .little);

    for (0..2) |copy| try disk.write(first + reserved + copy * size, &table);

    try disk.write(first + 1, &info);
    try disk.write(first + 6, &boot);
    try disk.write(first + 7, &info);
    try disk.write(first, &boot);

}

fn fill(entry: []u8, name: *const [11]u8, attributes: u8, cluster: u32, size: u32) void {

    @memset(entry[0..32], 0);
    entry[0..11].* = name.*;
    entry[11] = attributes;
    std.mem.writeInt(u16, entry[16..18], date, .little);
    std.mem.writeInt(u16, entry[18..20], date, .little);
    std.mem.writeInt(u16, entry[20..22], @truncate(cluster >> 16), .little);
    std.mem.writeInt(u16, entry[24..26], date, .little);
    std.mem.writeInt(u16, entry[26..28], @truncate(cluster), .little);
    std.mem.writeInt(u32, entry[28..32], size, .little);

}

fn field(comptime T: type, bytes: []const u8, offset: usize) T {

    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);

}
