const std = @import("std");

const volume = @import("volume.zig");

const field = volume.field;

/// Microsoft basic data partition ebd0a0a2-b9e5-4433-87c0-68b6b72699c7, in on-disk byte order.
pub const basic = [16]u8{

    0xa2, 0xa0, 0xd0, 0xeb, 0xe5, 0xb9, 0x33, 0x44, 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7,

};

/// Whether a volume can give up its end, or what stops it.
pub const Verdict = enum {

    ready,
    foreign,
    encrypted,
    hibernated,
    dirty,
    used,

};

const record_limit = 4096;
const page_size = 4096;

const log_file = 2;
const volume_file = 3;
const root_file = 5;
const bitmap_file = 6;
const bad_file = 8;

const list_kind = 0x20;
const information_kind = 0x70;
const data_kind = 0x80;
const root_kind = 0x90;
const allocation_kind = 0xa0;

/// An NTFS volume read through `Disk`, which provides `read`, `write` and `flush` over 512-byte sectors.
pub fn Ntfs(comptime Disk: type) type {

    return struct {

        const Self = @This();

        disk: Disk,
        first: u64,

        /// Sectors per cluster, the volume's length in sectors, and the size of a file record in bytes.
        cluster: u64,
        sectors: u64,
        record: usize,

        boot: [512]u8,
        mft: [record_limit]u8,
        scratch: [record_limit]u8,
        page: [2 * page_size]u8,

        /// Reads the volume starting at sector `first`: `foreign` when it is not NTFS, `encrypted` under BitLocker.
        pub fn mount(self: *Self, disk: Disk, first: u64) !Verdict {

            self.disk = disk;
            self.first = first;

            try disk.read(first, &self.boot);

            if (std.mem.eql(u8, self.boot[3..11], "-FVE-FS-")) return .encrypted;
            if (!std.mem.eql(u8, self.boot[3..11], "NTFS    ") or field(u16, &self.boot, 11) != 512) return .foreign;

            const scale: u16 = self.boot[13];

            self.cluster = if (scale <= 0x80) scale else @as(u64, 1) << @intCast(256 - scale);
            if (self.cluster == 0 or self.cluster > 4096 or !std.math.isPowerOfTwo(self.cluster)) return .foreign;

            const size: i8 = @bitCast(self.boot[0x40]);

            self.record = if (size > 0) @as(usize, @intCast(size)) * self.cluster * 512 else @as(usize, 1) << @intCast(@min(-@as(i16, size), 31));
            if (self.record < 512 or self.record > record_limit or self.record % 512 != 0) return .foreign;

            self.sectors = field(u64, &self.boot, 0x28);

            // Record 0 sits at the start of the MFT, and its runlist locates every later record.
            const mft = self.mft[0..self.record];

            try disk.read(first + field(u64, &self.boot, 0x30) * self.cluster, mft);
            if (!fixup(mft, "FILE") or attribute(mft, data_kind, false) == null) return .foreign;

            return .ready;

        }

        /// Whether Windows shut the volume down cleanly and will not resume onto it from hibernation.
        pub fn settled(self: *Self) !Verdict {

            const record = self.scratch[0..self.record];

            if (!try self.load(volume_file, record)) return error.Corrupt;

            const information = value(attribute(record, information_kind, false) orelse return error.Corrupt) orelse return error.Corrupt;

            if (information.len < 12 or field(u16, information, 10) & 1 != 0) return .dirty;
            if (!try self.journal()) return .dirty;
            if (try self.hibernated()) return .hibernated;

            return .ready;

        }

        /// Whether no cluster in `from` up to `to` is allocated.
        pub fn unused(self: *Self, from: u64, to: u64) !bool {

            const record = self.scratch[0..self.record];

            if (!try self.load(bitmap_file, record)) return error.Corrupt;

            const data = attribute(record, data_kind, false) orelse return error.Corrupt;

            if (data[8] != 1 or field(u64, data, 0x30) * 8 < to) return error.Corrupt;

            var bit = from;

            while (bit < to) {

                const start = bit / 8 / 512 * 512;
                const span = @min(self.page.len, self.cluster * 512 - start % (self.cluster * 512));
                const sector = self.locate(data, start) orelse return error.Corrupt;
                const chunk = self.page[0..span];

                try self.disk.read(sector, chunk);

                const limit = @min(to, (start + span) * 8);

                while (bit < limit) {

                    const byte = chunk[bit / 8 - start];

                    if (bit % 8 == 0 and bit + 8 <= limit) {

                        if (byte != 0) return false;
                        bit += 8;

                    } else {

                        if (byte >> @intCast(bit % 8) & 1 != 0) return false;
                        bit += 1;

                    }

                }

            }

            return true;

        }

        /// Ends the volume within the first `keep` sectors of its partition, and has Windows check it on its next start.
        pub fn shrink(self: *Self, keep: u64) !void {

            // The backup boot sector, just past the volume, already lies inside.
            if (keep > self.sectors) return;

            const sectors = keep - 1;
            const clusters = sectors / self.cluster;
            const record = self.scratch[0..self.record];

            // Marked dirty first, so chkdsk settles whatever an interrupted shrink leaves behind.
            if (!try self.load(volume_file, record)) return error.Corrupt;

            const information = value(attribute(record, information_kind, false) orelse return error.Corrupt) orelse return error.Corrupt;

            if (information.len < 12) return error.Corrupt;
            std.mem.writeInt(u16, information[10..12], field(u16, information, 10) | 1, .little);
            try self.save(volume_file, record);

            if (!try self.load(bitmap_file, record)) return error.Corrupt;

            const bitmap = attribute(record, data_kind, false) orelse return error.Corrupt;
            const length = std.mem.alignForward(u64, (clusters + 7) / 8, 8);

            if (bitmap[8] != 1) return error.Corrupt;

            // NTFS marks the bits past the last cluster as allocated.
            var bit = clusters;

            while (bit < length * 8) {

                const sector = self.locate(bitmap, bit / 8) orelse return error.Corrupt;
                const chunk = self.page[0..512];
                const base = bit / 8 / 512 * 512 * 8;

                try self.disk.read(sector, chunk);
                while (bit < @min(length * 8, base + 4096)) : (bit += 1) chunk[(bit - base) / 8] |= @as(u8, 1) << @intCast(bit % 8);
                try self.disk.write(sector, chunk);

            }

            if (length < field(u64, bitmap, 0x30)) {

                std.mem.writeInt(u64, bitmap[0x30..0x38], length, .little);
                std.mem.writeInt(u64, bitmap[0x38..0x40], @min(length, field(u64, bitmap, 0x38)), .little);
                try self.save(bitmap_file, record);

            }

            if (try self.load(bad_file, record)) if (attribute(record, data_kind, true)) |bad| if (trim(bad, clusters, self.cluster * 512)) {

                try self.save(bad_file, record);

            };

            var boot = self.boot;

            std.mem.writeInt(u64, boot[0x28..0x30], sectors, .little);
            try self.disk.write(self.first + sectors, &boot);
            try self.disk.write(self.first, &boot);
            try self.disk.flush();

            self.boot = boot;
            self.sectors = sectors;

        }

        /// Whether the newest restart area of $LogFile says the volume holds no unfinished changes.
        fn journal(self: *Self) !bool {

            const record = self.scratch[0..self.record];

            if (!try self.load(log_file, record)) return error.Corrupt;

            const data = attribute(record, data_kind, false) orelse return error.Corrupt;

            for (0..self.page.len / 512) |index| {

                const sector = self.locate(data, index * 512) orelse return error.Corrupt;

                try self.disk.read(sector, self.page[index * 512 ..][0..512]);

            }

            var newest: ?[]const u8 = null;

            for (0..2) |index| {

                const page = self.page[index * page_size ..][0..page_size];

                if (field(u32, page, 16) != page_size or !fixup(page, "RSTR")) continue;

                const area: usize = field(u16, page, 0x18);

                if (area + 16 > page_size) continue;
                if (newest == null or field(u64, page, area) >= field(u64, newest.?, 0)) newest = page[area..];

            }

            // A journal reset to all ones, as other systems leave it, holds nothing to replay.
            const area = newest orelse return std.mem.allEqual(u8, &self.page, 0xff);

            return field(u16, area, 12) == 0xffff or field(u16, area, 14) & 2 != 0;

        }

        /// Whether hiberfil.sys holds a hibernated session, as Fast Startup leaves after every shutdown.
        fn hibernated(self: *Self) !bool {

            const number = try self.lookup("hiberfil.sys") orelse return false;
            const record = self.scratch[0..self.record];

            if (!try self.load(number, record)) return true;
            if (field(u16, record, 0x16) & 1 == 0) return false;

            const data = attribute(record, data_kind, false) orelse try self.extent(record) orelse return true;
            var signature = std.mem.zeroes([512]u8);

            if (data[8] == 0) {

                const bytes = value(data) orelse return true;

                @memcpy(signature[0..@min(4, bytes.len)], bytes[0..@min(4, bytes.len)]);

            } else if (field(u64, data, 0x30) != 0) {

                if (self.locate(data, 0)) |sector| try self.disk.read(sector, &signature);

            }

            return std.ascii.eqlIgnoreCase(signature[0..4], "hibr");

        }

        /// The first extent of the unnamed $DATA of a file too fragmented to keep it in `record`, found through the
        /// file's resident attribute list and read into `page`.
        fn extent(self: *Self, record: []u8) !?[]u8 {

            const list = value(attribute(record, list_kind, false) orelse return null) orelse return null;
            var offset: usize = 0;

            while (offset + 26 <= list.len) {

                const length = field(u16, list, offset + 4);

                if (length < 26 or offset + length > list.len) return null;

                if (field(u32, list, offset) == data_kind and list[offset + 6] == 0 and field(u64, list, offset + 8) == 0) {

                    const holder = self.page[0..self.record];

                    if (!try self.load(field(u64, list, offset + 16) & 0xffff_ffff_ffff, holder)) return null;

                    return attribute(holder, data_kind, false);

                }

                offset += length;

            }

            return null;

        }

        /// The file record number of `name` in the root directory, or null without one.
        fn lookup(self: *Self, name: []const u8) !?u64 {

            const record = self.scratch[0..self.record];

            if (!try self.load(root_file, record)) return error.Corrupt;

            const root = value(attribute(record, root_kind, true) orelse return error.Corrupt) orelse return error.Corrupt;

            if (root.len < 32) return error.Corrupt;
            if (search(root[16..], name)) |found| return found;

            const allocation = attribute(record, allocation_kind, true) orelse return null;
            const block: usize = field(u32, root, 8);

            if (allocation[8] != 1 or block < 512 or block > page_size or block % 512 != 0) return error.Corrupt;

            var offset: u64 = 0;

            while (offset < field(u64, allocation, 0x30)) : (offset += block) {

                const page = self.page[0..block];

                for (0..block / 512) |index| {

                    const sector = self.locate(allocation, offset + index * 512) orelse return error.Corrupt;

                    try self.disk.read(sector, page[index * 512 ..][0..512]);

                }

                if (!fixup(page, "INDX")) continue;
                if (search(page[0x18..], name)) |found| return found;

            }

            return null;

        }

        /// Reads file record `number` into `out`; false when the MFT does not reach it or it fails its checks.
        fn load(self: *Self, number: u64, out: []u8) !bool {

            const data = attribute(self.mft[0..self.record], data_kind, false) orelse return false;

            for (0..self.record / 512) |index| {

                const sector = self.locate(data, number * self.record + index * 512) orelse return false;

                try self.disk.read(sector, out[index * 512 ..][0..512]);

            }

            return fixup(out[0..self.record], "FILE");

        }

        /// Writes back a record `load` read, which leaves `record` protected and no longer readable.
        fn save(self: *Self, number: u64, record: []u8) !void {

            const data = attribute(self.mft[0..self.record], data_kind, false) orelse return error.Corrupt;

            protect(record);

            for (0..self.record / 512) |index| {

                const sector = self.locate(data, number * self.record + index * 512) orelse return error.Corrupt;

                try self.disk.write(sector, record[index * 512 ..][0..512]);

            }

            // $MFTMirr copies the first cluster of records, at least four, and chkdsk compares the two.
            if (number < @max(4, self.cluster * 512 / self.record)) try self.disk.write(self.first + field(u64, &self.boot, 0x38) * self.cluster + number * self.record / 512, record);

        }

        /// The disk sector holding byte `byte` of the non-resident attribute `data`; null when sparse or beyond it.
        fn locate(self: *const Self, data: []const u8, byte: u64) ?u64 {

            const size = self.cluster * 512;
            const vcn = byte / size;
            var runs = Runs.of(data) orelse return null;

            while (runs.next()) |run| {

                if (vcn < run.vcn or vcn >= run.vcn + run.length) continue;

                const lcn = (run.lcn orelse return null) + vcn - run.vcn;

                if ((lcn + 1) * self.cluster > self.sectors) return null;

                return self.first + lcn * self.cluster + byte % size / 512;

            }

            return null;

        }

    };

}

const Run = struct {

    vcn: u64,
    length: u64,
    lcn: ?u64,

};

/// The runs of a non-resident attribute, in order.
const Runs = struct {

    bytes: []const u8,
    position: usize = 0,
    vcn: u64,
    lcn: i64 = 0,

    fn of(data: []const u8) ?Runs {

        if (data.len < 0x40 or data[8] != 1) return null;

        const start = field(u16, data, 0x20);

        if (start >= data.len) return null;

        return .{

            .bytes = data[start..],
            .vcn = field(u64, data, 0x10),

        };

    }

    fn next(self: *Runs) ?Run {

        if (self.position >= self.bytes.len) return null;

        const header = self.bytes[self.position];
        const width = header & 0xf;
        const reach = header >> 4;

        if (width == 0 or width > 8 or reach > 8 or self.position + 1 + width + reach > self.bytes.len) return null;

        const length = unsigned(self.bytes[self.position + 1 ..][0..width]);
        var lcn: ?u64 = null;

        if (reach != 0) {

            self.lcn +%= signed(self.bytes[self.position + 1 + width ..][0..reach]);
            if (self.lcn < 0) return null;
            lcn = @intCast(self.lcn);

        }

        const run = Run{

            .vcn = self.vcn,
            .length = length,
            .lcn = lcn,

        };

        self.position += 1 + width + reach;
        self.vcn += length;

        return run;

    }

};

/// Cuts $BadClus's $Bad stream to `clusters`, when it is the single sparse run a disk without bad clusters has.
fn trim(bad: []u8, clusters: u64, size: u64) bool {

    if (bad[9] != 4 or bad.len < 0x48) return false;

    const name = bad[field(u16, bad, 10)..][0..8];

    if (!std.mem.eql(u8, name, &[_]u8{ '$', 0, 'B', 0, 'a', 0, 'd', 0 })) return false;

    var runs = Runs.of(bad) orelse return false;
    const run = runs.next() orelse return false;

    if (run.lcn != null or run.vcn != 0 or run.length <= clusters or runs.next() != null) return false;

    const start = field(u16, bad, 0x20);
    const width = bad[start] & 0xf;

    // The same width still fits, and keeps the top byte clear, because the length only shrinks.
    for (0..width) |index| bad[start + 1 + index] = @truncate(clusters >> @intCast(index * 8));

    std.mem.writeInt(u64, bad[0x18..0x20], clusters - 1, .little);
    std.mem.writeInt(u64, bad[0x28..0x30], clusters * size, .little);
    std.mem.writeInt(u64, bad[0x30..0x38], clusters * size, .little);
    std.mem.writeInt(u64, bad[0x38..0x40], clusters * size, .little);

    return true;

}

/// The first attribute of `kind` in `record` that has a name, or that has none.
fn attribute(record: []u8, kind: u32, named: bool) ?[]u8 {

    var offset: usize = field(u16, record, 0x14);
    const used = @min(field(u32, record, 0x18), record.len);

    while (offset + 16 <= used) {

        const found = field(u32, record, offset);

        if (found == 0xffffffff) return null;

        const length = field(u32, record, offset + 4);

        if (length < 16 or offset + length > used) return null;

        const here = record[offset..][0..length];

        if (found == kind and (here[9] != 0) == named) return here;

        offset += length;

    }

    return null;

}

/// The value of a resident attribute.
fn value(here: []u8) ?[]u8 {

    if (here[8] != 0 or here.len < 0x18) return null;

    const offset = field(u16, here, 0x14);
    const length = field(u32, here, 0x10);

    if (offset + length > here.len) return null;

    return here[offset..][0..length];

}

/// The file record number of `name` among the entries after an index header; stale index blocks may name deleted files.
fn search(header: []const u8, name: []const u8) ?u64 {

    if (header.len < 16) return null;

    var offset: usize = field(u32, header, 0);
    const end = @min(field(u32, header, 4), header.len);

    while (offset + 16 <= end) {

        const length = field(u16, header, offset + 8);
        const size = field(u16, header, offset + 10);

        if (field(u16, header, offset + 12) & 2 != 0 or length < 16 or offset + length > end or 16 + size > length) return null;

        const key = header[offset + 16 ..][0..size];

        if (key.len >= 0x42 and key.len >= 0x42 + @as(usize, key[0x40]) * 2 and matches(key[0x42..][0 .. @as(usize, key[0x40]) * 2], name)) {

            return field(u64, header, offset) & 0xffff_ffff_ffff;

        }

        offset += length;

    }

    return null;

}

/// Whether the UTF-16 `units` spell the ASCII `name`, ignoring case.
fn matches(units: []const u8, name: []const u8) bool {

    if (units.len != name.len * 2) return false;

    for (name, 0..) |letter, index| {

        const unit = field(u16, units, index * 2);

        if (unit >= 128 or std.ascii.toLower(@intCast(unit)) != std.ascii.toLower(letter)) return false;

    }

    return true;

}

/// Checks and undoes the update sequence that guards the last two bytes of every sector.
fn fixup(buffer: []u8, magic: *const [4]u8) bool {

    if (!std.mem.eql(u8, buffer[0..4], magic)) return false;

    const offset: usize = field(u16, buffer, 4);
    const count: usize = field(u16, buffer, 6);

    if (count != buffer.len / 512 + 1 or offset + count * 2 > 512) return false;

    for (1..count) |index| {

        const end = buffer[index * 512 - 2 ..][0..2];

        if (!std.mem.eql(u8, end, buffer[offset..][0..2])) return false;
        @memcpy(end, buffer[offset + index * 2 ..][0..2]);

    }

    return true;

}

/// Applies a fresh update sequence, the inverse of `fixup`.
fn protect(buffer: []u8) void {

    const offset: usize = field(u16, buffer, 4);
    const count: usize = field(u16, buffer, 6);
    var sequence = field(u16, buffer, offset) +% 1;

    if (sequence == 0 or sequence == 0xffff) sequence = 1;
    std.mem.writeInt(u16, buffer[offset..][0..2], sequence, .little);

    for (1..count) |index| {

        const end = buffer[index * 512 - 2 ..][0..2];

        @memcpy(buffer[offset + index * 2 ..][0..2], end);
        std.mem.writeInt(u16, end, sequence, .little);

    }

}

fn unsigned(bytes: []const u8) u64 {

    var result: u64 = 0;

    for (bytes, 0..) |byte, index| result |= @as(u64, byte) << @intCast(index * 8);

    return result;

}

fn signed(bytes: []const u8) i64 {

    var result = unsigned(bytes);

    if (bytes.len < 8 and bytes[bytes.len - 1] & 0x80 != 0) result |= ~@as(u64, 0) << @intCast(bytes.len * 8);

    return @bitCast(result);

}
