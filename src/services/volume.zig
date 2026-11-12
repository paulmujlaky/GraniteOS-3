const std = @import("std");

pub const block_size = 4096;
pub const name_limit = 247;
pub const Error = error{ Missing, Exists, Invalid, Full, Busy, Corrupt, Device, Denied };

/// The user every check admits; matches `abi.system`.
pub const system: u32 = 0;

/// GPT partition type c9fd8a72-4f14-4449-ae67-540225bb22a4, in on-disk byte order.
pub const partition = [16]u8{

    0x72, 0x8a, 0xfd, 0xc9, 0x14, 0x4f, 0x49, 0x44, 0xae, 0x67, 0x54, 0x02, 0x25, 0xbb, 0x22, 0xa4,

};

const sectors = block_size / 512;
const bits = block_size * 8;
const record_size = 256;
const magic = std.mem.readInt(u64, "GRANITFS", .little);

pub const Kind = enum(u8) {

    file = 1,
    directory = 2,
    _,

};

pub const Range = struct {

    first: u64,
    sectors: u64,

};

pub const Entry = struct {

    name: []const u8,
    kind: Kind,
    size: u64,
    mode: u16,
    owner: u32,

};

pub const Usage = struct {

    total: u64,
    free: u64,

};

const Extent = extern struct {

    start: u64,
    length: u64,

};

const Node = extern struct {

    next: u64,
    count: u64,
    size: u64,

    kind: Kind,
    reserved: u8,
    mode: u16,
    owner: u32,

    extents: [254]Extent,

};

const Record = extern struct {

    node: u64,
    length: u8,
    name: [name_limit]u8,

};

const Super = extern struct {

    magic: u64,
    version: u64,
    blocks: u64,
    free: u64,
    root: u64,

};

comptime {

    if (@sizeOf(Node) != block_size or @sizeOf(Record) != record_size) @compileError("Volume layout");

}

/// Locates the first GraniteOS partition on a GPT disk of `capacity` sectors.
pub fn find(disk: anytype, sector: *[512]u8, capacity: u64) Error!?Range {

    try disk.read(1, sector);
    if (!std.mem.eql(u8, sector[0..8], "EFI PART")) return null;

    const table = field(u64, sector, 72);
    const count = field(u32, sector, 80);
    const size = field(u32, sector, 84);

    if (size < 128 or 512 % size != 0 or table >= capacity) return null;

    const per = 512 / size;
    var index: u64 = 0;

    while (index < count) : (index += 1) {

        if (index % per == 0) try disk.read(table + index / per, sector);

        const entry = sector[(index % per) * size ..][0..128];
        if (!std.mem.eql(u8, entry[0..16], &partition)) continue;

        const first = field(u64, entry, 32);
        const last = field(u64, entry, 40);

        if (first > last or last >= capacity) return error.Corrupt;

        return .{

            .first = first,
            .sectors = last - first + 1,

        };

    }

    return null;

}

/// A mounted volume; `Disk` provides `read`, `write` and `flush` over 512-byte sectors.
pub fn Volume(comptime Disk: type) type {

    return struct {

        const Self = @This();

        const Found = struct {

            node: u64,
            index: u64,

        };

        disk: Disk,
        base: u64,
        super: Super,

        /// Whose permissions the next operation checks.
        user: u32,

        node: Node,
        page: Node,
        record: Record,

        map: [block_size]u8,
        data: [block_size]u8,
        scan: [block_size]u8 align(8),

        /// Formats the partition when it holds no volume; returns whether it did.
        pub fn mount(self: *Self, disk: Disk, range: Range) Error!bool {

            self.disk = disk;
            self.base = range.first;
            self.user = system;

            const blocks = range.sectors / sectors;

            try self.disk.read(self.base, self.data[0..512]);
            self.super = std.mem.bytesToValue(Super, self.data[0..@sizeOf(Super)]);

            if (self.super.magic != magic) {

                try self.format(blocks);
                return true;

            }

            if (self.super.version != 1 or self.super.blocks > blocks or self.super.free > self.super.blocks or self.super.root != 1 + bitmaps(self.super.blocks)) return error.Corrupt;

            return false;

        }

        pub fn usage(self: *const Self) Usage {

            return .{

                .total = self.super.blocks * block_size,
                .free = self.super.free * block_size,

            };

        }

        pub fn create(self: *Self, path: []const u8, kind: Kind) Error!void {

            const parent, const name = try split(path);
            const directory = try self.resolve(parent);

            if (try self.lookup(directory, name)) |found| {

                try self.open(found.node);
                if (kind != .file or self.node.kind != .file) return error.Exists;
                try self.require(2);

                try self.resize(found.node, 0);
                return self.disk.flush();

            }

            try self.open(directory);
            try self.require(2);
            if (self.super.free < 3) return error.Full;

            const block = (try self.allocate(directory + 1, 1)).start;

            self.node = std.mem.zeroes(Node);
            self.node.kind = kind;
            self.node.mode = if (kind == .directory) 0o755 else 0o644;
            self.node.owner = self.user;
            try self.save(block, std.mem.asBytes(&self.node));

            self.record = std.mem.zeroes(Record);
            self.record.node = block;
            self.record.length = @intCast(name.len);
            @memcpy(self.record.name[0..name.len], name);

            try self.open(directory);
            try self.put(directory, self.node.size, std.mem.asBytes(&self.record));
            try self.disk.flush();

        }

        pub fn remove(self: *Self, path: []const u8) Error!void {

            const parent, const name = try split(path);
            const directory = try self.resolve(parent);
            const found = try self.lookup(directory, name) orelse return error.Missing;

            try self.open(directory);
            try self.require(2);
            try self.open(found.node);
            if (self.node.kind == .directory and self.node.size != 0) return error.Busy;

            try self.open(directory);
            const last = self.node.size / record_size - 1;

            if (found.index != last) {

                _ = try self.get(directory, last * record_size, std.mem.asBytes(&self.record));
                try self.put(directory, found.index * record_size, std.mem.asBytes(&self.record));

            }

            try self.open(directory);
            try self.resize(directory, last * record_size);

            try self.open(found.node);
            try self.resize(found.node, 0);

            try self.release(.{

                .start = found.node,
                .length = 1,

            });

            try self.disk.flush();

        }

        /// Moves `from` to `to`, which must not exist yet, within or between directories; a directory never moves into itself.
        pub fn rename(self: *Self, from: []const u8, to: []const u8) Error!void {

            const source_parent, const source_name = try split(from);
            const target_parent, const target_name = try split(to);

            if (std.mem.startsWith(u8, to, from) and to.len > from.len and to[from.len] == '/') return error.Invalid;

            const source = try self.resolve(source_parent);
            const target = try self.resolve(target_parent);
            const found = try self.lookup(source, source_name) orelse return error.Missing;

            if (try self.lookup(target, target_name) != null) return error.Exists;

            try self.open(source);
            try self.require(2);
            try self.open(target);
            try self.require(2);

            // The new name goes in first, so a failure in between leaves two names rather than none.
            self.record = std.mem.zeroes(Record);
            self.record.node = found.node;
            self.record.length = @intCast(target_name.len);
            @memcpy(self.record.name[0..target_name.len], target_name);
            try self.put(target, self.node.size, std.mem.asBytes(&self.record));

            try self.open(source);
            const last = self.node.size / record_size - 1;

            if (found.index != last) {

                _ = try self.get(source, last * record_size, std.mem.asBytes(&self.record));
                try self.put(source, found.index * record_size, std.mem.asBytes(&self.record));

            }

            try self.open(source);
            try self.resize(source, last * record_size);
            try self.disk.flush();

        }

        pub fn read(self: *Self, path: []const u8, offset: u64, out: []u8) Error!usize {

            return self.get(try self.file(path, 4), offset, out);

        }

        pub fn write(self: *Self, path: []const u8, offset: u64, bytes: []const u8) Error!void {

            try self.put(try self.file(path, 2), offset, bytes);
            try self.disk.flush();

        }

        pub fn flush(self: *Self) Error!void {

            try self.disk.flush();

        }

        /// Describes entry `index` of a directory; the name lives until the next call.
        pub fn entry(self: *Self, path: []const u8, index: u64) Error!?Entry {

            const directory = try self.resolve(path);

            try self.open(directory);
            if (self.node.kind != .directory) return error.Invalid;
            try self.require(4);
            if (index >= self.node.size / record_size) return null;

            _ = try self.get(directory, index * record_size, std.mem.asBytes(&self.record));
            if (self.record.length > name_limit) return error.Corrupt;
            try self.open(self.record.node);

            return .{

                .name = self.record.name[0..self.record.length],
                .kind = self.node.kind,
                .size = self.node.size,
                .mode = self.node.mode,
                .owner = self.node.owner,

            };

        }

        /// Owners may change permission bits; only `system` may also hand a node to another owner.
        pub fn change(self: *Self, path: []const u8, mode: u16, owner: ?u32) Error!void {

            const node = try self.resolve(path);

            try self.open(node);
            if (mode > 0o777) return error.Invalid;
            if (self.user != system and (self.node.owner != self.user or (owner orelse self.user) != self.user)) return error.Denied;

            self.node.mode = mode;
            self.node.owner = owner orelse self.node.owner;
            try self.save(node, std.mem.asBytes(&self.node));
            try self.disk.flush();

        }

        pub fn resolve(self: *Self, path: []const u8) Error!u64 {

            if (path.len == 0 or path[0] != '/') return error.Invalid;

            var node = self.super.root;
            var parts = std.mem.tokenizeScalar(u8, path, '/');

            while (parts.next()) |name| node = (try self.lookup(node, name) orelse return error.Missing).node;

            return node;

        }

        /// The node of file `path` once `need` (4 read, 2 write) is checked, for `get` and `put` to reuse without resolving it again.
        pub fn file(self: *Self, path: []const u8, need: u16) Error!u64 {

            const node = try self.resolve(path);

            try self.open(node);
            if (self.node.kind != .file) return error.Invalid;
            try self.require(need);

            return node;

        }

        // Checks `need` (4 read, 2 write, 1 search) against `self.node`; group bits are unused until groups exist.
        fn require(self: *const Self, need: u16) Error!void {

            const shift: u4 = if (self.node.owner == self.user) 6 else 0;

            if (self.user != system and (self.node.mode >> shift) & need != need) return error.Denied;

        }

        fn lookup(self: *Self, directory: u64, name: []const u8) Error!?Found {

            try valid(name);
            try self.open(directory);
            if (self.node.kind != .directory) return error.Invalid;
            try self.require(1);

            // ponytail: linear scan; index directories if they reach thousands of entries.
            const count = self.node.size / record_size;
            var index: u64 = 0;

            while (index < count) : (index += 1) {

                if (index % (block_size / record_size) == 0) _ = try self.get(directory, index * record_size, &self.scan);

                const record: *const Record = @ptrCast(@alignCast(self.scan[index % (block_size / record_size) * record_size ..][0..record_size]));

                if (record.length <= name_limit and std.mem.eql(u8, record.name[0..record.length], name)) return .{

                    .node = record.node,
                    .index = index,

                };

            }

            return null;

        }

        pub fn get(self: *Self, id: u64, offset: u64, out: []u8) Error!usize {

            try self.open(id);
            if (offset >= self.node.size) return 0;

            const total = @min(out.len, self.node.size - offset);
            var done: usize = 0;

            while (done < total) {

                const position = offset + done;
                const within = position % block_size;
                const place = try self.locate(position / block_size);

                // Whole blocks lying together on disk move in one transfer.
                if (within == 0 and total - done >= block_size) {

                    const size = @min(place.length, (total - done) / block_size) * block_size;

                    try self.disk.read(try self.address(place.start, size), out[done..][0..size]);
                    done += size;
                    continue;

                }

                const size = @min(block_size - within, total - done);

                try self.load(place.start, &self.data);
                @memcpy(out[done..][0..size], self.data[within..][0..size]);
                done += size;

            }

            return total;

        }

        /// Writes without flushing, so a caller writing a file piece by piece flushes once at the end.
        pub fn put(self: *Self, id: u64, offset: u64, bytes: []const u8) Error!void {

            try self.open(id);

            const end = std.math.add(u64, offset, bytes.len) catch return error.Invalid;
            const old = self.node.size;

            if (end > old) try self.resize(id, end);

            // Blocks past the old end start zeroed, so gaps never expose freed data.
            var position = @min(offset, old) / block_size * block_size;

            while (position < end) : (position += block_size) {

                const place = try self.locate(position / block_size);
                const block = place.start;

                if (position >= offset and end - position >= block_size) {

                    const size = @min(place.length, (end - position) / block_size) * block_size;

                    try self.disk.write(try self.address(block, size), bytes[position - offset ..][0..size]);
                    position += size - block_size;
                    continue;

                }

                if (position < old) {

                    try self.load(block, &self.data);
                    if (old - position < block_size) @memset(self.data[old - position ..], 0);

                } else {

                    @memset(&self.data, 0);

                }

                const from = @max(offset, position);
                const to = @min(end, position + block_size);

                if (from < to) @memcpy(self.data[from - position .. to - position], bytes[from - offset .. to - offset]);
                try self.save(block, &self.data);

            }

        }

        fn open(self: *Self, id: u64) Error!void {

            if (id < self.super.root) return error.Corrupt;
            try self.load(id, std.mem.asBytes(&self.node));
            if ((self.node.kind != .file and self.node.kind != .directory) or self.node.count > self.node.extents.len) return error.Corrupt;

        }

        fn follow(self: *Self, id: u64) Error!void {

            try self.load(id, std.mem.asBytes(&self.page));
            if (self.page.count == 0 or self.page.count > self.page.extents.len) return error.Corrupt;

        }

        /// Where block `index` of `self.node` lies, and how many of its blocks lie together from there.
        fn locate(self: *Self, index: u64) Error!Extent {

            var remaining = index;
            var page = &self.node;
            var hops: u64 = 0;

            while (true) {

                for (page.extents[0..page.count]) |extent| {

                    if (remaining < extent.length) return .{

                        .start = extent.start + remaining,
                        .length = extent.length - remaining,

                    };

                    remaining -= extent.length;

                }

                hops += 1;
                if (page.next == 0 or hops > self.super.blocks) return error.Corrupt;

                try self.follow(page.next);
                page = &self.page;

            }

        }

        /// Expects `self.node` to hold node `id`.
        fn resize(self: *Self, id: u64, size: u64) Error!void {

            const old = blocksOf(self.node.size);
            const new = blocksOf(size);

            if (new > old) try self.grow(id, new - old);
            if (new < old) try self.shrink(id, old - new);

            self.node.size = size;
            try self.save(id, std.mem.asBytes(&self.node));

        }

        fn grow(self: *Self, id: u64, amount: u64) Error!void {

            if (self.super.free < amount +| amount / self.node.extents.len +| 1) return error.Full;

            var tail = &self.node;
            var tail_id = id;
            var hops: u64 = 0;

            while (tail.next != 0) : (hops += 1) {

                if (hops > self.super.blocks) return error.Corrupt;

                tail_id = tail.next;
                try self.follow(tail_id);
                tail = &self.page;

            }

            var remaining = amount;

            while (remaining > 0) {

                const hint = if (tail.count > 0) tail.extents[tail.count - 1].start + tail.extents[tail.count - 1].length else id + 1;
                const run = try self.allocate(hint, remaining);

                remaining -= run.length;

                if (tail.count > 0) {

                    const last = &tail.extents[tail.count - 1];

                    if (last.start + last.length == run.start) {

                        last.length += run.length;
                        continue;

                    }

                }

                if (tail.count == tail.extents.len) {

                    const fresh = (try self.allocate(run.start + run.length, 1)).start;

                    tail.next = fresh;
                    if (tail != &self.node) try self.save(tail_id, std.mem.asBytes(tail));

                    self.page = std.mem.zeroes(Node);
                    tail = &self.page;
                    tail_id = fresh;

                }

                tail.extents[tail.count] = run;
                tail.count += 1;

            }

            if (tail != &self.node) try self.save(tail_id, std.mem.asBytes(tail));

        }

        fn shrink(self: *Self, id: u64, amount: u64) Error!void {

            var remaining = amount;

            while (remaining > 0) {

                var tail = &self.node;
                var tail_id = id;
                var previous: u64 = 0;
                var hops: u64 = 0;

                while (tail.next != 0) : (hops += 1) {

                    if (hops > self.super.blocks) return error.Corrupt;

                    previous = tail_id;
                    tail_id = tail.next;
                    try self.follow(tail_id);
                    tail = &self.page;

                }

                if (tail.count == 0) return error.Corrupt;

                const last = &tail.extents[tail.count - 1];
                const cut = @min(last.length, remaining);

                last.length -= cut;
                remaining -= cut;

                try self.release(.{

                    .start = last.start + last.length,
                    .length = cut,

                });

                if (last.length == 0) tail.count -= 1;
                if (tail == &self.node) continue;

                if (tail.count != 0) {

                    try self.save(tail_id, std.mem.asBytes(tail));
                    continue;

                }

                try self.release(.{

                    .start = tail_id,
                    .length = 1,

                });

                if (previous == id) {

                    self.node.next = 0;
                    continue;

                }

                try self.follow(previous);
                self.page.next = 0;
                try self.save(previous, std.mem.asBytes(&self.page));

            }

        }

        fn allocate(self: *Self, hint: u64, wanted: u64) Error!Extent {

            const chunks = bitmaps(self.super.blocks);
            const start = hint % self.super.blocks;

            // One extra step revisits the first chunk below the hint.
            for (0..chunks + 1) |step| {

                const chunk = (start / bits + step) % chunks;
                const limit = @min(bits, self.super.blocks - chunk * bits);
                var bit: u64 = if (step == 0) start % bits else 0;

                try self.load(1 + chunk, &self.map);

                while (bit < limit) : (bit += 1) {

                    if (self.map[bit / 8] == 0xff) {

                        bit |= 7;
                        continue;

                    }

                    if (!self.available(bit)) continue;

                    var length: u64 = 0;

                    while (bit + length < limit and length < wanted and self.available(bit + length)) : (length += 1) {

                        self.map[(bit + length) / 8] |= mask(bit + length);

                    }

                    if (length > self.super.free) return error.Corrupt;

                    try self.save(1 + chunk, &self.map);
                    self.super.free -= length;
                    try self.commit();

                    return .{

                        .start = chunk * bits + bit,
                        .length = length,

                    };

                }

            }

            return error.Full;

        }

        fn release(self: *Self, extent: Extent) Error!void {

            if (extent.start <= self.super.root or extent.start >= self.super.blocks or extent.length > self.super.blocks - extent.start) return error.Corrupt;

            var block = extent.start;
            const end = extent.start + extent.length;

            while (block < end) {

                const chunk = block / bits;

                try self.load(1 + chunk, &self.map);

                while (block < end and block / bits == chunk) : (block += 1) {

                    if (self.available(block % bits)) return error.Corrupt;
                    self.map[block % bits / 8] &= ~mask(block % bits);

                }

                try self.save(1 + chunk, &self.map);

            }

            self.super.free += extent.length;
            try self.commit();

        }

        fn format(self: *Self, blocks: u64) Error!void {

            const root = 1 + bitmaps(blocks);

            if (blocks <= root + 1) return error.Invalid;

            self.super = .{

                .magic = magic,
                .version = 1,
                .blocks = blocks,
                .free = blocks - root - 1,
                .root = root,

            };

            for (0..bitmaps(blocks)) |chunk| {

                @memset(&self.map, 0);

                var block = chunk * bits;

                while (block <= root and block < (chunk + 1) * bits) : (block += 1) self.map[block % bits / 8] |= mask(block % bits);

                try self.save(1 + chunk, &self.map);

            }

            self.node = std.mem.zeroes(Node);
            self.node.kind = .directory;
            self.node.mode = 0o755;

            try self.save(root, std.mem.asBytes(&self.node));
            try self.commit();
            try self.disk.flush();

        }

        fn commit(self: *Self) Error!void {

            var sector = std.mem.zeroes([512]u8);

            @memcpy(sector[0..@sizeOf(Super)], std.mem.asBytes(&self.super));
            try self.disk.write(self.base, &sector);

        }

        fn load(self: *Self, block: u64, bytes: *[block_size]u8) Error!void {

            try self.disk.read(try self.address(block, block_size), bytes);

        }

        fn save(self: *Self, block: u64, bytes: *const [block_size]u8) Error!void {

            try self.disk.write(try self.address(block, block_size), bytes);

        }

        /// The sector of `block`, once `size` bytes from it are known to stay on the volume.
        fn address(self: *const Self, block: u64, size: u64) Error!u64 {

            if (block >= self.super.blocks or size / block_size > self.super.blocks - block) return error.Corrupt;

            return self.base + block * sectors;

        }

        fn available(self: *const Self, bit: u64) bool {

            return self.map[bit / 8] & mask(bit) == 0;

        }

    };

}

fn split(path: []const u8) Error!struct { []const u8, []const u8 } {

    const trimmed = std.mem.trimRight(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.Invalid;

    return .{ trimmed[0 .. slash + 1], trimmed[slash + 1 ..] };

}

fn valid(name: []const u8) Error!void {

    if (name.len == 0 or name.len > name_limit or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\x00") != null) return error.Invalid;

}

fn bitmaps(blocks: u64) u64 {

    return blocks / bits + @intFromBool(blocks % bits != 0);

}

fn blocksOf(size: u64) u64 {

    return size / block_size + @intFromBool(size % block_size != 0);

}

fn mask(bit: u64) u8 {

    return @as(u8, 1) << @intCast(bit % 8);

}

/// The little-endian `T` at `offset`, as GPT and the volume store their fields.
pub fn field(comptime T: type, bytes: []const u8, offset: usize) T {

    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);

}
