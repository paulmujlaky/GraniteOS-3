const std = @import("std");

const memory = @import("../../kernel/memory.zig");

pub const user_base = 0x8000000000;
pub const user_end = 0x10000000000;
pub const nx: u64 = 1 << 63;
pub const writable: u64 = 2;
pub const user: u64 = 4;
pub const uncached: u64 = 24;

/// PWT alone selects PAT entry 1, which `cpu.features` makes write-combining.
pub const combined: u64 = 8;
pub const borrowed: u64 = 1 << 9;
const mask: u64 = 0x000ffffffffff000;
pub const MapError = memory.MemoryError || error{ InvalidAddress, AlreadyMapped, NotMapped, PermissionDenied };
pub const Table = [512]u64;

pub const Space = struct {

    root: usize,
    frames: *memory.Frames,

    pub fn init(frames: *memory.Frames) MapError!Space {

        const root = try frames.alloc();

        @memset(table(root), 0);

        return .{

            .root = root,
            .frames = frames,

        };

    }

    pub fn process(kernel: Space) MapError!Space {

        const result = try init(kernel.frames);

        table(result.root)[0] = table(kernel.root)[0];

        return result;

    }

    pub fn map(self: *Space, address: usize, physical: usize, flags: u64) MapError!void {

        // Device registers may sit anywhere the processor can address, far above RAM.
        if (address % 4096 != 0 or physical % 4096 != 0 or address >= user_end or physical & ~mask != 0) return error.InvalidAddress;
        if (flags & user != 0 and (address < user_base or flags & (writable | nx) == writable)) return error.PermissionDenied;

        const entry = try self.walk(address, 12, true, flags & user);

        if (entry.* & 1 != 0) return error.AlreadyMapped;

        entry.* = physical | flags | 1;

    }

    pub fn allocate(self: *Space, address: usize, flags: u64) MapError!usize {

        const physical = try self.frames.alloc();
        errdefer self.frames.release(physical) catch @panic("Page ownership");

        @memset(@as(*[memory.page_size]u8, @ptrFromInt(physical)), 0);
        try self.map(address, physical, flags);

        return physical;

    }

    pub fn identity(self: *Space, base: usize, size: usize, flags: u64) MapError!void {

        const end = std.math.add(usize, base, size) catch return error.InvalidAddress;

        if (end > memory.physical_limit) return error.InvalidAddress;

        var address = base & ~@as(usize, 0x1fffff);

        while (address < end) : (address += 0x200000) {

            const entry = try self.walk(address, 21, true, 0);

            if (entry.* == 0) entry.* = address | flags | 0x81;

            // ponytail: a 2 MiB page shared with firmware code stays executable as a whole; split to 4 KiB if that matters.
            if (flags & nx == 0) entry.* &= ~nx;

        }

    }

    pub fn protect(self: *Space, address: usize, flags: u64) MapError!void {

        const entry = try self.walk(address, 12, false, 0);

        if (entry.* & 1 == 0) return error.NotMapped;

        entry.* = (entry.* & mask) | flags | 1;

    }

    pub fn translate(self: Space, address: usize, write: bool) MapError!usize {

        if (address < user_base or address >= user_end) return error.InvalidAddress;

        var current = table(self.root);

        for ([_]u6{

            39,
            30,
            21,
            12,

        }) |shift| {

            const entry = current[(address >> shift) & 511];

            if (entry & (1 | user) != (1 | user) or (write and entry & writable == 0)) return error.PermissionDenied;
            if (shift == 12) return @as(usize, @intCast(entry & mask)) + (address & 4095);
            if (entry & 128 != 0) return error.PermissionDenied;

            current = table(entry & mask);

        }

        return error.NotMapped;

    }

    pub fn guard(self: *Space, address: usize) MapError!void {

        const entry = try self.walk(address, 12, false, 0);

        entry.* = 0;

    }

    pub fn present(self: Space, address: usize) bool {

        if (address < user_base or address >= user_end) return false;

        var current = table(self.root);

        for ([_]u6{

            39, 30, 21, 12

        }) |shift| {

            const entry = current[(address >> shift) & 511];

            if (entry & 1 == 0) return false;
            if (shift == 12 or entry & 128 != 0) return true;

            current = table(entry & mask);

        }

        return false;

    }

    pub fn unmap(self: *Space, address: usize) MapError!void {

        if (address < user_base or address >= user_end or address % 4096 != 0) return error.InvalidAddress;

        const entry = try self.walk(address, 12, false, 0);

        if (entry.* & 1 == 0) return error.NotMapped;

        const previous = entry.*;

        entry.* = 0;
        if (previous & borrowed == 0) try self.frames.release(@intCast(previous & mask));

    }

    /// Counts the user pages backed by RAM; device mappings and the tables themselves are left out.
    pub fn resident(self: Space) usize {

        const entry = table(self.root)[1];

        return if (entry & 1 != 0) tally(@intCast(entry & mask), 3) else 0;

    }

    fn tally(address: usize, depth: usize) usize {

        var pages: usize = 0;

        for (table(address)) |entry| {

            if (entry & 1 == 0) continue;
            pages += if (depth > 1) tally(@intCast(entry & mask), depth - 1) else @intFromBool(entry & uncached == 0);

        }

        return pages;

    }

    pub fn destroy(self: *Space) void {

        const entry = table(self.root)[1];

        if (entry & 1 != 0) self.freeTable(@intCast(entry & mask), 3);
        self.frames.release(self.root) catch @panic("Page table ownership");
        self.root = 0;

    }

    fn freeTable(self: *Space, address: usize, depth: usize) void {

        for (table(address)) |entry| {

            if (entry & 1 == 0) continue;

            const child: usize = @intCast(entry & mask);

            if (depth > 1) {

                self.freeTable(child, depth - 1);

            } else if (entry & borrowed == 0) {

                self.frames.release(child) catch @panic("User page ownership");

            }

        }

        self.frames.release(address) catch @panic("Page table ownership");

    }

    fn walk(self: *Space, address: usize, level: u6, create: bool, flags: u64) MapError!*u64 {

        var current = table(self.root);
        var shift: u6 = 39;

        while (shift > level) : (shift -= 9) {

            const entry = &current[(address >> shift) & 511];

            if (entry.* & 1 == 0) {

                if (!create) return error.NotMapped;

                const next = try self.frames.alloc();

                @memset(table(next), 0);
                entry.* = next | flags | 3;

            } else if (shift == 21 and entry.* & 128 != 0) {

                const next = try self.frames.alloc();
                const base = entry.* & mask;
                const attributes = entry.* & ~mask & ~@as(u64, 128);

                for (table(next), 0..) |*page, i| page.* = (base + i * 4096) | attributes;
                entry.* = next | 3;

            }

            current = table(entry.* & mask);

        }

        return &current[(address >> level) & 511];

    }

};

pub fn table(address: usize) *Table {

    return @ptrFromInt(address);

}

pub fn activate(root: usize) void {

    asm volatile ("mov %[root], %%cr3" // Activate these page tables; flush the TLB.
        :
        : [root] "r" (root),
        : .{

            .memory = true,

        });

}
