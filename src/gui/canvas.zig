const std = @import("std");

const font = @import("font.zig");
const softening = @import("quartz.zig");

pub const Point = struct {

    x: i32 = 0,
    y: i32 = 0,

};

pub const Rect = struct {

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn right(self: Rect) i32 {

        return self.x + self.width;

    }

    pub fn bottom(self: Rect) i32 {

        return self.y + self.height;

    }

    /// The rectangle with corners at `from` and `to`, each pixel under them included, as a pointer sweeps one out.
    pub fn spanning(from: Point, to: Point) Rect {

        return .{

            .x = @min(from.x, to.x),
            .y = @min(from.y, to.y),
            .width = @as(i32, @intCast(@abs(to.x - from.x))) + 1,
            .height = @as(i32, @intCast(@abs(to.y - from.y))) + 1,

        };

    }

    pub fn contains(self: Rect, point: Point) bool {

        return point.x >= self.x and point.y >= self.y and point.x < self.right() and point.y < self.bottom();

    }

    /// Whether `other` lies wholly inside.
    pub fn encloses(self: Rect, other: Rect) bool {

        return other.x >= self.x and other.y >= self.y and other.right() <= self.right() and other.bottom() <= self.bottom();

    }

    /// The part inside `limit`, or all of it without one; empty, which draws nothing, when they do not meet.
    pub fn within(self: Rect, limit: ?Rect) Rect {

        const outer = limit orelse return self;

        return outer.intersect(self) orelse .{};

    }

    pub fn intersect(self: Rect, other: Rect) ?Rect {

        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right_edge = @min(self.right(), other.right());
        const bottom_edge = @min(self.bottom(), other.bottom());

        if (left >= right_edge or top >= bottom_edge) return null;

        return .{

            .x = left,
            .y = top,
            .width = right_edge - left,
            .height = bottom_edge - top,

        };

    }

    /// The smallest rectangle covering both.
    pub fn join(self: Rect, other: Rect) Rect {

        if (self.width <= 0 or self.height <= 0) return other;
        if (other.width <= 0 or other.height <= 0) return self;

        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);

        return .{

            .x = left,
            .y = top,
            .width = @max(self.right(), other.right()) - left,
            .height = @max(self.bottom(), other.bottom()) - top,

        };

    }

    pub fn inset(self: Rect, amount: i32) Rect {

        return .{

            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - 2 * amount,
            .height = self.height - 2 * amount,

        };

    }

    /// A `width` by `height` rectangle centered within this one.
    pub fn centered(self: Rect, width: i32, height: i32) Rect {

        return .{

            .x = self.x + @divTrunc(self.width - width, 2),
            .y = self.y + @divTrunc(self.height - height, 2),
            .width = width,
            .height = height,

        };

    }

};

pub const Alignment = enum {

    left,
    center,
    right,

};

pub const Bounds = struct {

    left: usize,
    top: usize,
    right: usize,
    bottom: usize,

};

/// `color` made `amount` (0 to 255) opaque; colours are 0xTTRRGGBB, where TT is transparency, so plain 0xRRGGBB is opaque.
pub fn shade(color: u32, amount: u8) u32 {

    return (@as(u32, 255 - amount) << 24) | (color & 0xffffff);

}

/// How opaque colour `color` is, from 0 to 1.
pub fn opacity(color: u32) f32 {

    return @as(f32, @floatFromInt(255 - (color >> 24))) / 255;

}

/// The side of the largest shadow corner: its radius plus twice its blur.
pub const penumbra = 96;

/// The widest blur a shadow takes; wider ones soften this far.
pub const widest = 32;

/// A soft shadow fitted to its area: a shape with corners of `radius`, blurred over `blur` pixels either side of its edge.
/// It draws as four corners `side` pixels square, cut from one tile, and edges stretched from that tile's innermost row and column; its middle is left to whatever casts it.
pub const Shadow = struct {

    radius: u32,
    blur: u32,

    /// The shadow of `area` with corners of `radius`, softened over up to `blur` pixels; null when nothing is left to soften.
    pub fn fit(area: Rect, radius: i32, blur: i32) ?Shadow {

        const short = @min(area.width, area.height);
        const r = std.math.clamp(radius, 0, @divTrunc(short, 2));

        // Corners must not overlap, so a small area softens less; the tile also caps both.
        const b = @min(blur, widest, @divTrunc(short - 2 * r, 2), @divTrunc(penumbra - r, 2));

        if (b <= 0 or r + 2 * b > penumbra) return null;

        return .{

            .radius = @intCast(r),
            .blur = @intCast(b),

        };

    }

    pub fn side(self: Shadow) u32 {

        return self.radius + 2 * self.blur;

    }

    /// Fills `tile`, `side` squared, with how much the shadow covers each pixel of its top-left corner, from the outer corner inwards; `scratch` holds `side` by `side + blur`.
    pub fn soften(self: Shadow, tile: []f32, scratch: []f32) void {

        const n = self.side();
        const b: f32 = @floatFromInt(self.blur);
        const r: f32 = @floatFromInt(self.radius);
        const reach: i32 = @intCast(self.blur);
        var weights: [2 * widest + 1]f32 = undefined;
        var total: f32 = 0;

        // A Gaussian whose three standard deviations span the blur, normalised over the samples taken.
        for (0..2 * self.blur + 1) |index| {

            const k = @as(f32, @floatFromInt(index)) - b;

            weights[index] = @exp(-k * k * 4.5 / (b * b));
            total += weights[index];

        }

        for (weights[0 .. 2 * self.blur + 1]) |*weight| weight.* /= total;

        // The blur is separable: across each row of the sharp shape first, then down each column of that.
        for (0..n + self.blur) |y| {

            for (0..n) |x| {

                var sum: f32 = 0;

                for (weights[0 .. 2 * self.blur + 1], 0..) |weight, index| {

                    const px = @as(f32, @floatFromInt(@as(i32, @intCast(x)) + @as(i32, @intCast(index)) - reach)) + 0.5;
                    const qx = b + r - px;
                    const qy = b + r - (@as(f32, @floatFromInt(y)) + 0.5);
                    const distance = std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - r;

                    sum += weight * std.math.clamp(0.5 - distance, 0, 1);

                }

                scratch[y * n + x] = sum;

            }

        }

        for (0..n) |y| {

            for (0..n) |x| {

                var sum: f32 = 0;

                for (weights[0 .. 2 * self.blur + 1], 0..) |weight, index| {

                    const row = @as(i32, @intCast(y)) + @as(i32, @intCast(index)) - reach;

                    if (row >= 0) sum += weight * scratch[@as(usize, @intCast(row)) * n + x];

                }

                tile[y * n + x] = sum;

            }

        }

    }

};

/// One screen row's Quartz grid, mixed between the two grid rows it lies between; wide enough for an 8192-pixel screen.
var mixed: [2048]softening.Channels = undefined;

/// Where each pixel across that row samples the grid.
var samples: [8192]Sample = undefined;

/// The last shadow tile the CPU softened, kept since shadows repeat.
var softened: [penumbra * penumbra]f32 = undefined;
var softened_scratch: [penumbra * (penumbra + widest)]f32 = undefined;
var softened_for: ?Shadow = null;

/// What lay under the bottom corners of an area before drawing in it; see `Canvas.save`.
pub const Corners = struct {

    /// The widest curve kept; larger radii round as this.
    pub const largest = 16;

    area: Rect = .{},
    radius: i32 = 0,
    limit: Rect = .{},
    pixels: [2][largest * largest]u32 = undefined,

    /// The bottom-left and bottom-right squares the curve cuts into.
    pub fn squares(self: *const Corners) [2]Rect {

        const r = @max(@min(self.radius, @divTrunc(@min(self.area.width, self.area.height), 2)), 0);

        return .{

            .{ .x = self.area.x, .y = self.area.bottom() - r, .width = r, .height = r },
            .{ .x = self.area.right() - r, .y = self.area.bottom() - r, .width = r, .height = r },

        };

    }

};

/// Pixels as 0x00RRGGBB, row after row.
pub const Canvas = struct {

    pixels: []u32,
    width: usize,
    height: usize,

    /// Drawing outside this, when set, is discarded.
    limit: ?Rect = null,

    /// Room to soften what lies under Quartz in, as `quartz.room` sizes it; without it, Quartz draws solid.
    spare: []u32 = &.{},

    pub fn bounds(self: *const Canvas) Rect {

        return .{

            .width = @intCast(self.width),
            .height = @intCast(self.height),

        };

    }

    pub fn fill(self: *Canvas, area: Rect, color: u32) void {

        self.round(area, 0, color);

    }

    /// Fills `area` with anti-aliased corners of `radius` pixels.
    pub fn round(self: *Canvas, area: Rect, radius: i32, color: u32) void {

        const limit = @max(@min(radius, @divTrunc(@min(area.width, area.height), 2)), 0);
        const clipped = self.clip(area) orelse return;
        const solid = color >> 24 == 0;
        const alpha = opacity(color);
        const r: f32 = @floatFromInt(limit);
        const left: f32 = @floatFromInt(area.x);
        const top: f32 = @floatFromInt(area.y);
        const right: f32 = @floatFromInt(area.right());
        const bottom: f32 = @floatFromInt(area.bottom());

        for (clipped.top..clipped.bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = fy - std.math.clamp(fy, top + r, bottom - r);

            // Rows between the corners are solid.
            if (dy == 0 and solid) {

                @memset(row[clipped.left..clipped.right], color);
                continue;

            }

            for (clipped.left..clipped.right) |x| {

                const fx = @as(f32, @floatFromInt(x)) + 0.5;

                blend(&row[x], color, covered(fx - std.math.clamp(fx, left + r, right - r), dy, r) * alpha);

            }

        }

    }

    /// Fills `area`, corners rounded to `radius`, with what is already drawn under it softened, under `tint`; see `quartz`. Without
    /// `spare` room to soften in, as with Quartz switched off, it draws `tint` solid.
    pub fn quartz(self: *Canvas, area: Rect, radius: i32, tint: u32) void {

        const size = softening.grid(self.width, self.height);

        if (self.spare.len < softening.room(self.width, self.height) or size[0] > mixed.len or self.width > samples.len) return self.round(area, radius, tint & 0xffffff);

        const visible = area.intersect(self.region() orelse return) orelse return;
        const plan = softening.Plan.of(visible, size[0], size[1]) orelse return;
        const soft = self.spare[0 .. size[0] * size[1]];
        const r: f32 = @floatFromInt(@max(@min(radius, @divTrunc(@min(area.width, area.height), 2)), 0));
        const left: f32 = @floatFromInt(area.x);
        const top: f32 = @floatFromInt(area.y);
        const right: f32 = @floatFromInt(area.right());
        const bottom: f32 = @floatFromInt(area.bottom());

        softening.soften(self, plan, self.spare, tint);

        // The grid columns the area samples, which each row mixes between its two grid rows once rather than per pixel.
        const first = between(@intCast(visible.x), size[0]).first;
        const last = between(@as(usize, @intCast(visible.right())) - 1, size[0]).second;

        for (samples[0..@intCast(visible.width)], @intCast(visible.x)..) |*sample, x| sample.* = between(x, size[0]);

        for (@intCast(visible.y)..@intCast(visible.bottom())) |y| {

            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = fy - std.math.clamp(fy, top + r, bottom - r);
            const down = between(y, size[1]);
            const upper = soft[down.first * size[0] ..][0..size[0]];
            const lower = soft[down.second * size[0] ..][0..size[0]];
            const row = self.pixels[y * self.width ..];

            for (first..last + 1) |column| mixed[column] = softening.split(upper[column]) * softening.splat(8 - down.along) + softening.split(lower[column]) * softening.splat(down.along);

            for (@intCast(visible.x)..@intCast(visible.right()), samples[0..@intCast(visible.width)]) |x, across| {

                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const inside = covered(fx - std.math.clamp(fx, left + r, right - r), dy, r);
                if (inside <= 0) continue;

                const value = mixed[across.first] * softening.splat(8 - across.along) + mixed[across.second] * softening.splat(across.along);

                blend(&row[x], softening.join(value, 64), inside);

            }

        }

    }

    /// Lays a soft shadow of `area`, with corners of `radius`, over `blur` pixels either side of its edge; the middle is left for whatever casts it.
    pub fn shadow(self: *Canvas, area: Rect, radius: i32, blur: i32, color: u32) void {

        const fit = Shadow.fit(area, radius, blur) orelse return;
        const side: i32 = @intCast(fit.side());
        const outer = area.inset(-@as(i32, @intCast(fit.blur)));
        const clipped = self.clip(outer) orelse return;
        const alpha = opacity(color);

        if (!std.meta.eql(softened_for, fit)) {

            fit.soften(&softened, &softened_scratch);
            softened_for = fit;

        }

        // Rows past the corners soften only their left and right bands; the middle between is the caster's.
        const near: usize = @intCast(std.math.clamp(outer.x + side, @as(i32, @intCast(clipped.left)), @as(i32, @intCast(clipped.right))));
        const far: usize = @intCast(std.math.clamp(outer.right() - side, @as(i32, @intCast(near)), @as(i32, @intCast(clipped.right))));

        for (clipped.top..clipped.bottom) |y| {

            const fy: i32 = @intCast(y);
            const down = @min(fy - outer.y, outer.bottom() - 1 - fy);
            const row = @min(down, side - 1);
            const spans = if (down >= side) [2][2]usize{ .{ clipped.left, near }, .{ far, clipped.right } } else [2][2]usize{ .{ clipped.left, clipped.right }, .{ 0, 0 } };

            for (spans) |span| {

                for (span[0]..span[1]) |x| {

                    const fx: i32 = @intCast(x);
                    const across = @min(fx - outer.x, outer.right() - 1 - fx);

                    blend(&self.pixels[y * self.width + x], color, softened[@as(usize, @intCast(row * side + @min(across, side - 1)))] * alpha);

                }

            }

        }

    }

    /// Saves the pixels in the bottom corners of `area` within `limit`, so `trim` can round off what is drawn there next.
    pub fn save(self: *const Canvas, kept: *Corners, area: Rect, radius: i32, limit: Rect) void {

        kept.* = .{

            .area = area,
            .radius = @min(radius, Corners.largest),
            .limit = limit.intersect(self.bounds()) orelse return,

        };

        for (kept.squares(), &kept.pixels) |square, *saved| {

            const visible = square.intersect(kept.limit) orelse continue;

            for (0..@intCast(visible.height)) |y| {

                const row = self.pixels[(@as(usize, @intCast(visible.y)) + y) * self.width + @as(usize, @intCast(visible.x)) ..];

                @memcpy(saved[y * Corners.largest ..][0..@intCast(visible.width)], row[0..@intCast(visible.width)]);

            }

        }

    }

    /// Blends the pixels `save` kept back over everything drawn outside the curve of its corners.
    pub fn trim(self: *Canvas, kept: *const Corners) void {

        const squares = kept.squares();
        const r: f32 = @floatFromInt(squares[0].width);
        const left: f32 = @floatFromInt(kept.area.x);
        const right: f32 = @floatFromInt(kept.area.right());
        const bottom: f32 = @floatFromInt(kept.area.bottom());

        for (squares, &kept.pixels) |square, *saved| {

            const visible = square.intersect(kept.limit) orelse continue;

            for (0..@intCast(visible.height)) |y| {

                for (0..@intCast(visible.width)) |x| {

                    const point = Point{

                        .x = visible.x + @as(i32, @intCast(x)),
                        .y = visible.y + @as(i32, @intCast(y)),

                    };

                    const fx = @as(f32, @floatFromInt(point.x)) + 0.5;
                    const dx = fx - std.math.clamp(fx, left + r, right - r);
                    const dy = @max(@as(f32, @floatFromInt(point.y)) + 0.5 - (bottom - r), 0);

                    blend(self.at(point), saved[y * Corners.largest + x], 1 - std.math.clamp(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1));

                }

            }

        }

    }

    /// Draws UTF-8 `string` at `size` pixels with its baseline starting at (`x`, `baseline`).
    pub fn text(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, x: i32, baseline: i32, color: u32) void {

        const scale = size / face.units;
        const visible = self.region() orelse return;
        const alpha = opacity(color);
        const reach: i32 = @intFromFloat(@ceil(size * 1.5));
        var pen: f32 = @floatFromInt(x);
        var previous: u16 = 0;
        var characters = font.decode(string);

        // Rasterising is the slow part, so glyphs wholly outside the visible area are skipped, such as when redrawing a window's corner.
        if (baseline + reach < visible.y or baseline - reach > visible.bottom()) return;

        while (characters.next()) |char| {

            const glyph = face.lookup(char);

            pen += face.kerning(previous, glyph) * scale;
            previous = glyph;

            const advance = face.advance(glyph) * scale;

            // Runs only move right, so nothing further along shows either.
            if (pen > @as(f32, @floatFromInt(visible.right() + reach))) return;

            if (pen + advance + size < @as(f32, @floatFromInt(visible.x))) {

                pen += advance;
                continue;

            }

            if (face.render(glyph, scale, pen - @floor(pen))) |bitmap| {

                const left = @as(i32, @intFromFloat(@floor(pen))) + bitmap.left;
                const top = baseline + bitmap.top;

                for (0..bitmap.height) |row| {

                    for (0..bitmap.width) |column| {

                        const point = Point{

                            .x = left + @as(i32, @intCast(column)),
                            .y = top + @as(i32, @intCast(row)),

                        };

                        if (visible.contains(point)) blend(self.at(point), color, bitmap.coverage[row * bitmap.width + column] * alpha);

                    }

                }

            }

            pen += advance;

        }

    }

    /// Draws `string` vertically centered in `area`.
    pub fn label(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, area: Rect, color: u32, alignment: Alignment) void {

        const start = anchor(face, string, size, area, alignment);

        self.text(face, string, size, start.x, start.y, color);

    }

    /// Copies `source`, placed with its corner at `origin`, wherever it overlaps `area`.
    pub fn blit(self: *Canvas, source: *const Canvas, origin: Point, area: Rect) void {

        const placed = Rect{

            .x = origin.x,
            .y = origin.y,
            .width = @intCast(source.width),
            .height = @intCast(source.height),

        };

        const visible = area.intersect(placed) orelse return;
        const clipped = self.clip(visible) orelse return;
        const span = clipped.right - clipped.left;
        const column: usize = @intCast(@as(i64, @intCast(clipped.left)) - origin.x);

        for (clipped.top..clipped.bottom) |y| {

            const row: usize = @intCast(@as(i64, @intCast(y)) - origin.y);

            @memcpy(self.pixels[y * self.width + clipped.left ..][0..span], source.pixels[row * source.width + column ..][0..span]);

        }

    }

    /// Draws premultiplied 0xAARRGGBB `source` stretched over `area`, sampling the nearest pixel.
    pub fn image(self: *Canvas, source: *const Canvas, area: Rect) void {

        const clipped = self.clip(area) orelse return;
        if (source.width == 0 or source.height == 0) return;

        // Columns step through the source in 16.16 fixed point, rather than dividing for every pixel.
        const step = (@as(u64, source.width) << 16) / @as(u64, @intCast(area.width));
        const offset: u64 = @intCast(@as(i64, @intCast(clipped.left)) - area.x);
        const first = offset * source.width * 65536 / @as(u64, @intCast(area.width));

        for (clipped.top..clipped.bottom) |y| {

            const row = @divTrunc((@as(i64, @intCast(y)) - area.y) * @as(i64, @intCast(source.height)), area.height);
            const line = source.pixels[@as(usize, @intCast(row)) * source.width ..][0..source.width];
            var along = first;

            for (clipped.left..clipped.right) |x| {

                const pixel = line[@min(along >> 16, source.width - 1)];
                const target = &self.pixels[y * self.width + x];

                along += step;
                const keep = 255 - (pixel >> 24);

                if (keep == 0) {

                    target.* = pixel & 0xffffff;
                    continue;

                }

                var result: u32 = 0;

                for ([_]u5{ 0, 8, 16 }) |shift| result |= @as(u32, @min((pixel >> shift & 0xff) + (target.* >> shift & 0xff) * keep / 255, 255)) << shift;

                target.* = result;

            }

        }

    }

    /// Blends `color` over every pixel `shape` touches inside the limit, as far as it covers it; `shape` gives `box` and `distance`, as `sketch.Form` does.
    pub fn cover(self: *Canvas, color: u32, shape: anytype) void {

        const visible = self.region() orelse return;
        const area = touched(shape.box(), visible) orelse return;
        const alpha = opacity(color);

        for (area.top..area.bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;

            for (area.left..area.right) |x| blend(&row[x], color, std.math.clamp(0.5 - shape.distance(@as(f32, @floatFromInt(x)) + 0.5, fy), 0, 1) * alpha);

        }

    }

    /// Blends `color` over pixel (`x`, `y`), `alpha` opaque.
    pub fn mix(self: *Canvas, x: usize, y: usize, color: u32, alpha: f32) void {

        blend(&self.pixels[y * self.width + x], color, alpha);

    }

    fn at(self: *Canvas, point: Point) *u32 {

        return &self.pixels[@as(usize, @intCast(point.y)) * self.width + @as(usize, @intCast(point.x))];

    }

    /// Where drawing may land: the limit within the canvas.
    pub fn region(self: *const Canvas) ?Rect {

        const limit = self.limit orelse return self.bounds();

        return limit.intersect(self.bounds());

    }

    fn clip(self: *const Canvas, area: Rect) ?Bounds {

        const visible = area.intersect(self.region() orelse return null) orelse return null;

        return .{

            .left = @intCast(visible.x),
            .top = @intCast(visible.y),
            .right = @intCast(visible.right()),
            .bottom = @intCast(visible.bottom()),

        };

    }

};

/// Pixel rows and columns a box (left, top, right, bottom) of an anti-aliased shape touches inside `limit`.
pub fn touched(box: [4]f32, limit: Rect) ?Bounds {

    const left = std.math.clamp(@floor(box[0] - 1), @as(f32, @floatFromInt(limit.x)), @as(f32, @floatFromInt(limit.right())));
    const top = std.math.clamp(@floor(box[1] - 1), @as(f32, @floatFromInt(limit.y)), @as(f32, @floatFromInt(limit.bottom())));
    const right = std.math.clamp(@ceil(box[2] + 1), @as(f32, @floatFromInt(limit.x)), @as(f32, @floatFromInt(limit.right())));
    const bottom = std.math.clamp(@ceil(box[3] + 1), @as(f32, @floatFromInt(limit.y)), @as(f32, @floatFromInt(limit.bottom())));

    if (right <= left or bottom <= top) return null;

    return .{

        .left = @intFromFloat(left),
        .top = @intFromFloat(top),
        .right = @intFromFloat(right),
        .bottom = @intFromFloat(bottom),

    };

}

/// Where a label's baseline starts so it sits vertically centred in `area`.
pub fn anchor(face: *const font.Font, string: []const u8, size: f32, area: Rect, alignment: Alignment) Point {

    const scale = size / face.units;
    const span: i32 = @intFromFloat(@ceil(face.measure(string, scale)));
    const tall: f32 = @floatFromInt(area.height);
    const height = @as(f32, @floatFromInt(face.capital)) * scale;
    const descent = @as(f32, @floatFromInt(@abs(face.descent))) * scale;

    // Capitals, or a whole icon, sit midway down the area, unless descenders would then hang out of it, as in a box one line tall,
    // where the baseline sits at the font's ascent instead.
    return .{

        .x = switch (alignment) {

            .left => area.x,
            .center => area.x + @divTrunc(area.width - span, 2),
            .right => area.right() - span,

        },
        .y = area.y + @as(i32, @intFromFloat(@round(@min((tall + height) / 2, tall - descent)))),

    };

}

/// How much of a pixel a shape with corners of radius `r` covers, its centre `dx` and `dy` past the centres of the corners' curves.
fn covered(dx: f32, dy: f32, r: f32) f32 {

    return if (dx == 0 and dy == 0) 1 else @min(r - @sqrt(dx * dx + dy * dy) + 0.5, 1);

}

/// Two neighbouring texels of a Quartz grid line, and how far along, in eighths, a pixel lies from the first.
const Sample = struct {

    first: u16,
    second: u16,
    along: u8,

};

/// The two texels of a `count`-texel Quartz grid line that pixel `pixel` samples between.
fn between(pixel: usize, count: usize) Sample {

    // A texel spans `quartz.scale` pixels, so the pixel's centre lies (2 * pixel - 3) / 8 texels past the centre of texel 0.
    const at = 2 * @as(i64, @intCast(pixel)) - 3;
    const first = @divFloor(at, 8);

    return .{

        .first = @intCast(std.math.clamp(first, 0, @as(i64, @intCast(count)) - 1)),
        .second = @intCast(std.math.clamp(first + 1, 0, @as(i64, @intCast(count)) - 1)),
        .along = @intCast(at - 8 * first),

    };

}

fn blend(pixel: *u32, color: u32, alpha: f32) void {

    if (alpha <= 0) return;

    if (alpha >= 1) {

        pixel.* = color;
        return;

    }

    var result: u32 = 0;

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const under: f32 = @floatFromInt(pixel.* >> shift & 0xff);
        const over: f32 = @floatFromInt(color >> shift & 0xff);

        result |= @as(u32, @intFromFloat(under + (over - under) * alpha + 0.5)) << shift;

    }

    pixel.* = result;

}
