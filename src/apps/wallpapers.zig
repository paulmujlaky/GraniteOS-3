//! The built-in wallpapers: dark graphite with a faint glow of colour, drawn at whatever size is asked for.

const std = @import("std");

const gui = @import("gui");

pub const Wallpaper = struct {

    name: []const u8,

    base: u32,
    glow: u32,

};

/// Settings lists them in this order; the first shows when none is chosen.
pub const all = [_]Wallpaper{

    .{ .name = "Graphite", .base = 0x0f1012, .glow = 0x2a2c31 },
    .{ .name = "Ocean", .base = 0x0d1014, .glow = 0x1b345a },
    .{ .name = "Lagoon", .base = 0x0d1112, .glow = 0x163f39 },
    .{ .name = "Ember", .base = 0x110f0d, .glow = 0x46311a },
    .{ .name = "Dusk", .base = 0x0f0e13, .glow = 0x2f2752 },
    .{ .name = "Rose", .base = 0x110e10, .glow = 0x45202f },

};

/// Scales every wallpaper's light, keeping them quieter than the windows over them.
const brightness = 0.5;

/// The wallpaper called `name`, if one is.
pub fn find(name: []const u8) ?usize {

    for (all, 0..) |entry, index| {

        if (std.mem.eql(u8, entry.name, name)) return index;

    }

    return null;

}

/// Draws wallpaper `which` into a new `width` by `height` image; publish it to show it.
pub fn render(which: usize, width: u32, height: u32) !gui.Image {

    var picture = try gui.Image.init(width, height);
    const pixels = picture.pixels();

    const chosen = all[which];
    const base = channels(chosen.base);
    const glow = channels(chosen.glow);
    const sheen = channels(0x1c1d21);

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);

    for (0..height) |y| {

        const v = @as(f32, @floatFromInt(y)) / h;

        for (0..width) |x| {

            const u = @as(f32, @floatFromInt(x)) / w;

            // A wide glow of colour rising from the lower right, and a faint neutral sheen at the upper left.
            const warm = falloff(u - 0.82, v - 1.08, 0.95, 0.9);
            const cool = 0.55 * falloff(u - 0.05, v + 0.1, 0.75, 0.75);

            // Noise of under one step hides the banding a slow, dark gradient shows in eight bits a channel.
            const noise = dither(x, y);
            var color: u32 = 0xff000000;

            for (0..3) |channel| {

                const lit = brightness * (base[channel] + (glow[channel] - base[channel]) * warm + (sheen[channel] - base[channel]) * cool);
                const level: u32 = @intFromFloat(std.math.clamp(lit + noise, 0, 255));

                color |= level << @intCast(16 - 8 * channel);

            }

            pixels[y * width + x] = color;

        }

    }

    return picture;

}

fn channels(color: u32) [3]f32 {

    return .{

        @floatFromInt(color >> 16 & 0xff),
        @floatFromInt(color >> 8 & 0xff),
        @floatFromInt(color & 0xff),

    };

}

/// How strongly a glow `rx` by `ry` reaches `dx`, `dy` from its centre: 1 there, easing to 0 at its edge.
fn falloff(dx: f32, dy: f32, rx: f32, ry: f32) f32 {

    const reach = @max(1 - (dx * dx) / (rx * rx) - (dy * dy) / (ry * ry), 0);

    return reach * reach;

}

/// A steady pseudo-random offset from -0.5 to 0.5 for each pixel, plus a half to round.
fn dither(x: usize, y: usize) f32 {

    var hash: u32 = @truncate(x *% 0x9e3779b1 ^ y *% 0x85ebca6b);

    hash ^= hash >> 15;
    hash *%= 0x2c1b3c6d;
    hash ^= hash >> 12;

    return @as(f32, @floatFromInt(hash & 0xff)) / 255;

}
