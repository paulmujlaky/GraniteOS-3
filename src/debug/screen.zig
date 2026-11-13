//! Mirrors the kernel log onto the firmware framebuffer, for machines without a serial port.

const boot = @import("../boot/info.zig");

const glyphs = @embedFile("glyphs.bin");

const width = 8;
const height = 16;

/// The newest log bytes, replayed when the screen attaches or after a kernel failure.
var history: [16 * 1024]u8 = undefined;
var written: usize = 0;

var target: ?boot.Framebuffer = null;
var shown = false;

var column: usize = 0;
var row: usize = 0;
var scale: usize = 1;

var foreground: u32 = 0;
var background: u32 = 0;

/// Starts showing log lines on `framebuffer`, beginning with those already written.
pub fn attach(framebuffer: boot.Framebuffer) void {

    target = framebuffer;

    // Glyphs stay legible on high-resolution panels at double size.
    scale = if (framebuffer.width >= 2560) 2 else 1;
    foreground = colour(framebuffer, 0xd0, 0xd0, 0xd0);
    background = colour(framebuffer, 0x10, 0x10, 0x18);

    show();

}

/// Stops drawing, once another owner such as the display service takes the screen.
pub fn release() void {

    shown = false;

}

/// Takes the screen back after a kernel failure and shows the newest lines from the top.
pub fn reclaim() bool {

    if (target == null) return false;

    show();

    return true;

}

/// Copies kept log bytes, oldest first, starting `skip` bytes past the oldest; returns how many.
pub fn recent(buffer: []u8, skip: usize) usize {

    const kept = @min(written, history.len);
    if (skip >= kept) return 0;

    const count = @min(buffer.len, kept - skip);
    const first = written - kept + skip;

    for (buffer[0..count], first..) |*byte, at| byte.* = history[at % history.len];

    return count;

}

/// How many log bytes are kept.
pub fn held() usize {

    return @min(written, history.len);

}

pub fn write(bytes: []const u8) void {

    for (bytes) |byte| {

        history[written % history.len] = byte;
        written += 1;

    }

    if (shown) draw(bytes);

}

fn show() void {

    const framebuffer = target orelse return;

    for (0..framebuffer.height) |y| fill(framebuffer, y, 0, framebuffer.width);

    column = 0;
    row = 0;
    shown = true;

    // Only whole lines replay, since the oldest one kept may have lost its start.
    const kept = @min(written, history.len, rows(framebuffer) * columns(framebuffer) / 2);
    var start = written - kept;

    if (kept < written) {

        while (start < written and history[start % history.len] != '\n') start += 1;
        start += 1;

    }

    while (start < written) : (start += 1) draw(&.{history[start % history.len]});

}

fn draw(bytes: []const u8) void {

    const framebuffer = target orelse return;

    for (bytes) |byte| {

        if (byte == '\n' or column == columns(framebuffer)) advance(framebuffer);
        if (byte == '\n' or byte == '\r') continue;

        glyph(framebuffer, if (byte >= 32 and byte < 127) byte else '?');
        column += 1;

    }

}

/// Moves to the next line, wrapping to the top rather than scrolling, since reading the framebuffer back is very slow.
fn advance(framebuffer: boot.Framebuffer) void {

    column = 0;
    row = (row + 1) % rows(framebuffer);

    // The line after the newest one stays blank, which marks where the log wrapped.
    for (0..2) |ahead| {

        const line = (row + ahead) % rows(framebuffer);

        for (line * height * scale..(line + 1) * height * scale) |y| fill(framebuffer, y, 0, framebuffer.width);

    }

}

fn glyph(framebuffer: boot.Framebuffer, byte: u8) void {

    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
    const bits = glyphs[(@as(usize, byte) - 32) * height ..][0..height];

    for (0..height * scale) |dy| {

        const line = bits[dy / scale];
        const y = row * height * scale + dy;

        for (0..width * scale) |dx| {

            const lit = line & (@as(u8, 0x80) >> @intCast(dx / scale)) != 0;

            pixels[y * framebuffer.stride + column * width * scale + dx] = if (lit) foreground else background;

        }

    }

}

fn fill(framebuffer: boot.Framebuffer, y: usize, from: usize, to: usize) void {

    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);

    for (from..to) |x| pixels[y * framebuffer.stride + x] = background;

}

fn rows(framebuffer: boot.Framebuffer) usize {

    return framebuffer.height / (height * scale);

}

fn columns(framebuffer: boot.Framebuffer) usize {

    return framebuffer.width / (width * scale);

}

fn colour(framebuffer: boot.Framebuffer, red: u32, green: u32, blue: u32) u32 {

    return red << @intCast(@ctz(framebuffer.red_mask)) | green << @intCast(@ctz(framebuffer.green_mask)) | blue << @intCast(@ctz(framebuffer.blue_mask));

}
