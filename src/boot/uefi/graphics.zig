const std = @import("std");

const boot = @import("../info.zig");
const Log = @import("../../debug/log.zig").Log;

const uefi = std.os.uefi;
const Graphics = uefi.protocol.GraphicsOutput;

pub fn capture(services: *uefi.tables.BootServices, log: Log) !?boot.Framebuffer {

    const graphics = try services.locateProtocol(Graphics, null) orelse return null;

    if (prefer(graphics)) log.line("screen mode set to 1920x1080");

    const mode = graphics.mode;

    if (mode.size_of_info < @sizeOf(Graphics.Mode.Info)) return null;

    const info = mode.info;

    const masks: Graphics.PixelBitmask = switch (info.pixel_format) {

        .red_green_blue_reserved_8_bit_per_color => .{

            .red_mask = 0xff,
            .green_mask = 0xff00,
            .blue_mask = 0xff0000,
            .reserved_mask = 0xff000000,

        },
        .blue_green_red_reserved_8_bit_per_color => .{

            .red_mask = 0xff0000,
            .green_mask = 0xff00,
            .blue_mask = 0xff,
            .reserved_mask = 0xff000000,

        },
        .bit_mask => info.pixel_information,
        .blt_only => return null,

    };

    const framebuffer = boot.Framebuffer{

        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,

        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .stride = info.pixels_per_scan_line,

        .red_mask = masks.red_mask,
        .green_mask = masks.green_mask,
        .blue_mask = masks.blue_mask,

    };

    if (!valid(framebuffer)) return null;

    // The diagnostic renderer writes 32-bit pixels; narrower bit-mask modes are left untouched.
    if (info.pixel_format == .bit_mask and (masks.red_mask | masks.green_mask | masks.blue_mask | masks.reserved_mask) <= 0xffffff) return null;

    return framebuffer;

}

/// The CPU draws every pixel without a GPU driver, so a mode larger than 1920x1080 drops to that one when the display offers it.
fn prefer(graphics: *Graphics) bool {

    const current = graphics.mode.info;

    if (graphics.mode.size_of_info < @sizeOf(Graphics.Mode.Info)) return false;
    if (@as(u64, current.horizontal_resolution) * current.vertical_resolution <= 1920 * 1080) return false;

    for (0..graphics.mode.max_mode) |index| {

        const info = graphics.queryMode(@intCast(index)) catch continue;

        if (info.horizontal_resolution != 1920 or info.vertical_resolution != 1080) continue;
        if (info.pixel_format != .blue_green_red_reserved_8_bit_per_color and info.pixel_format != .red_green_blue_reserved_8_bit_per_color) continue;

        graphics.setMode(@intCast(index)) catch return false;

        return true;

    }

    return false;

}

pub fn valid(framebuffer: boot.Framebuffer) bool {

    if (framebuffer.base == 0 or framebuffer.base % 4 != 0) return false;
    if (framebuffer.width == 0 or framebuffer.height == 0 or framebuffer.stride < framebuffer.width) return false;

    const pixels = std.math.mul(u64, framebuffer.stride, framebuffer.height) catch return false;
    const bytes = std.math.mul(u64, pixels, 4) catch return false;

    _ = std.math.add(u64, framebuffer.base, framebuffer.size) catch return false;
    if (bytes > framebuffer.size) return false;

    const red = framebuffer.red_mask;
    const green = framebuffer.green_mask;
    const blue = framebuffer.blue_mask;

    return red != 0 and green != 0 and blue != 0 and (red & green) == 0 and (red & blue) == 0 and (green & blue) == 0;

}
