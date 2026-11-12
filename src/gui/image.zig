const std = @import("std");

const api = @import("api");

const png = @import("png.zig");

const Canvas = @import("canvas.zig").Canvas;
const Rect = @import("canvas.zig").Rect;
const Sketch = @import("sketch.zig").Sketch;

/// Premultiplied 0xAARRGGBB pixels shared with the display, so image nodes and commands can draw them.
pub const Image = struct {

    /// The shared pages, kept as plain fields so toolkit tests need no system API.
    handle: u64,
    bytes: []align(4096) u8,
    width: u32,
    height: u32,
    fit: Fit = .contain,

    pub const Fit = enum {

        /// Whole and centred, keeping its shape.
        contain,

        /// Filling the area, keeping its shape, cropping what spills over.
        cover,

        stretch,

    };

    /// Zeroed, so fully transparent until drawn into.
    pub fn init(width: u32, height: u32) !Image {

        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.Invalid;

        const memory = try api.share(std.math.divCeil(usize, @as(usize, width) * height * 4, 4096) catch unreachable);

        return .{

            .handle = memory.handle,
            .bytes = memory.bytes,
            .width = width,
            .height = height,

        };

    }

    /// A new image of the PNG in `bytes`, decoding with `allocator`'s scratch space; publish it to show it.
    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {

        const size = try png.size(bytes);
        var picture = try Image.init(size.width, size.height);

        errdefer picture.deinit();
        _ = try png.decode(allocator, bytes, picture.pixels());

        return picture;

    }

    /// A new image of the PNG file at `path`, read and decoded with `allocator`'s scratch space.
    pub fn open(allocator: std.mem.Allocator, files: *api.Files, path: []const u8) !Image {

        if (path.len == 0) return error.Missing;

        return decode(allocator, try files.load(allocator, path));

    }

    pub fn deinit(self: *Image) void {

        unpublish(self);
        api.detach(self.handle);

    }

    pub fn pixels(self: *const Image) []u32 {

        return std.mem.bytesAsSlice(u32, self.bytes[0 .. @as(usize, self.width) * self.height * 4]);

    }

    /// The pixels as a canvas, for drawing into on the CPU; opaque colours stay opaque.
    pub fn canvas(self: *const Image) Canvas {

        return .{

            .pixels = self.pixels(),
            .width = self.width,
            .height = self.height,

        };

    }

    /// The pixels as a sketch, for anti-aliased lines, rings, and other shapes.
    pub fn sketch(self: *const Image) Sketch {

        return .{

            .pixels = self.pixels(),
            .width = self.width,
            .height = self.height,

        };

    }

    /// Makes every pixel fully opaque, after drawing into the image through `canvas`, whose colours keep the top byte clear.
    pub fn solid(self: *Image) void {

        for (self.pixels()) |*pixel| pixel.* |= 0xff000000;

    }

    /// Hands the pixels to the display, and again after changing them.
    pub fn publish(self: *Image) !void {

        try self.change(null);

    }

    /// Hands the display what changed in `area` after it was published, such as a brush stroke, or every pixel when null.
    pub fn change(self: *Image, area: ?Rect) !void {

        try display.image(self.handle, self.width, self.height, if (area) |changed| .{

            .x = changed.x,
            .y = changed.y,
            .width = changed.width,
            .height = changed.height,

        } else null);

        const record = Published{

            .handle = self.handle,
            .width = self.width,
            .height = self.height,

        };

        for (&published) |*entry| if (entry.* != null and entry.*.?.handle == self.handle) {

            entry.* = record;
            return;

        };

        for (&published) |*entry| if (entry.* == null) {

            entry.* = record;
            return;

        };

    }

    /// Where the image lands in `area` under its fit.
    pub fn place(self: *const Image, area: Rect) Rect {

        if (self.fit == .stretch) return area;

        const wide = @as(u64, @intCast(area.width)) * self.height > @as(u64, @intCast(area.height)) * self.width;
        const by_height = wide == (self.fit == .contain);

        const width: i32 = if (by_height) @intCast(@divTrunc(@as(i64, area.height) * self.width, self.height)) else area.width;
        const height: i32 = if (by_height) area.height else @intCast(@divTrunc(@as(i64, area.width) * self.height, self.width));

        return area.centered(width, height);

    }

};

/// The display connection every surface and image of this app shares.
pub var display = api.Display{};

/// What was published, by value rather than by pointer, since apps often publish an image and then move it elsewhere.
const Published = struct {

    handle: u64,
    width: u32,
    height: u32,

};

var published = [_]?Published{null} ** 32;

/// Hands every published image to the display again, after it restarted and forgot them.
pub fn republish() void {

    for (published) |entry| {

        if (entry) |picture| display.image(picture.handle, picture.width, picture.height, null) catch {

        };

    }

}

fn unpublish(picture: *Image) void {

    for (&published) |*entry| if (entry.* != null and entry.*.?.handle == picture.handle) {

        entry.* = null;
        display.forget(picture.handle);

    };

}
