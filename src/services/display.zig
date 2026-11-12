const std = @import("std");

const svga = @import("svga.zig");
const gpu = @import("gpu.zig");
const intel = @import("intel.zig");
const motion = @import("motion.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

/// The mode until an administrator picks another, which is then saved in `saved`.
const default = gui.Rect{

    .width = 1280,
    .height = 800,

};

// The desktop is laid out for at least this much room.
const smallest = gui.Rect{

    .width = 640,
    .height = 480,

};

// No window shrinks below this, so its title bar keeps room for its controls.
const least = gui.Rect{

    .width = 200,
    .height = 100,

};

/// The boot framebuffer, drawn by the CPU with a software pointer.
const Frame = struct {

    pixels: [*]u32,
    stride: usize,

    /// Bit positions of red, green, and blue.
    shifts: [3]u5,

    fn present(self: *Frame, source: *const gui.Canvas, area: gui.Rect) void {

        const visible = area.intersect(source.bounds()) orelse return;
        var line: [256]u32 = undefined;
        var y: usize = @intCast(visible.y);

        while (y < visible.bottom()) : (y += 1) {

            var x: usize = @intCast(visible.x);

            // Composing in RAM writes each device pixel once, so the pointer never flickers.
            while (x < visible.right()) {

                const row = line[0..@min(line.len, @as(usize, @intCast(visible.right())) - x)];

                for (row, source.pixels[y * source.width + x ..][0..row.len]) |*pixel, color| pixel.* = self.convert(color);
                self.overlay(row, x, y);
                @memcpy(self.pixels[y * self.stride + x ..][0..row.len], row);
                x += row.len;

            }

        }

    }

    fn overlay(self: *Frame, row: []u32, x: usize, y: usize) void {

        const worn = gui.cursor.sprite(look);
        const at = sprite(pointer);
        const line = @as(i64, @intCast(y)) - at.y;
        if (line < 0 or line >= worn.height) return;

        for (worn.pixels[@as(usize, @intCast(line)) * worn.width ..][0..worn.width], 0..) |pixel, column| {

            const offset = at.x + @as(i64, @intCast(column)) - @as(i64, @intCast(x));
            if (pixel >> 24 == 0 or offset < 0 or offset >= row.len) continue;

            row[@intCast(offset)] = self.convert(pixel);

        }

    }

    fn convert(self: *const Frame, color: u32) u32 {

        return (color >> 16 & 0xff) << self.shifts[0] | (color >> 8 & 0xff) << self.shifts[1] | (color & 0xff) << self.shifts[2];

    }

};

const Screen = union(enum) {

    svga: svga.Device,
    frame: Frame,

};

const Layer = api.display.Layer;
const none = api.display.Spec.none;

const border = 1;

/// The invisible band around a window that grabs its edges for resizing, and how far the grip reaches inside its frame.
const grip = 8;
const hold = 3;

/// How far along an edge from a corner the grip takes both edges.
const corner_grip = 20;

/// How far a window's shadow spreads past its frame.
const spread = 20;

/// How near the bottom of the screen the pointer brings back a tucked dock.
const brink = 3;

/// Width of each control at the right of a title bar.
const control = 40;

/// A client's window: drawing commands it shares with us, stacked with the others.
const Surface = struct {

    client: u64 = 0,
    memory: api.Shared = undefined,
    area: gui.Rect = .{},

    layer: Layer = .window,
    options: api.display.Options = .{},
    application: u8 = none,
    title: [64]u8 = undefined,
    length: usize = 0,

    /// Which half of the shared buffer holds the presented commands, and how many bytes of them.
    half: u1 = 0,
    size: usize = 0,

    /// Presented at least once; until then nothing of it shows.
    shown: bool = false,

    minimized: bool = false,
    tile: Tile = .free,

    /// A panel with the `tuck` option, slid away beneath a tiled window.
    tucked: bool = false,

    /// Where a tiled window goes back to.
    restore: gui.Rect = .{},

    /// How it comes and goes, the transition it is in, if any, and the pose it shows in.
    effect: api.display.Motion = .auto,
    transition: ?motion.Transition = null,
    pose: motion.Pose = .rest,

    /// The screen it covered when last drawn in transition.
    painted: gui.Rect = .{},

    /// Closed by its client, and only showing until its leaving transition ends.
    leaving: bool = false,

    /// What the pointer shows over its content, as its client last said.
    cursor: gui.Cursor = .arrow,

    /// The part of its content its commands draw with Quartz, and whether the first of them paints all of it opaque, as an app with a
    /// background of its own does; see `survey`.
    frosted: gui.Rect = .{},
    covered: bool = false,

    fn decorated(self: *const Surface) bool {

        return self.layer == .window;

    }

    /// The content plus its decorations.
    fn frame(self: *const Surface) gui.Rect {

        if (!self.decorated()) return self.area;

        return outline(self.area);

    }

    /// Everything it may draw on: the frame and its shadow.
    fn footprint(self: *const Surface) gui.Rect {

        return if (self.decorated() or self.options.shadow) self.frame().inset(-gui.px(spread)) else self.area;

    }

    /// Where the pointer reaches it, edges included.
    fn reach(self: *const Surface) gui.Rect {

        return if (self.resizable()) self.frame().inset(-gui.px(grip)) else self.frame();

    }

    fn resizable(self: *const Surface) bool {

        return self.decorated() and !self.options.fixed and self.tile != .full;

    }

    /// The radius of its frame's corners: square once tiled, so tiles meet the screen's edges and each other cleanly.
    fn rounding(self: *const Surface) i32 {

        return if (self.tile == .free) gui.px(theme.corner) else 0;

    }

    /// The radius of its content's corners, inside the frame's border.
    fn curve(self: *const Surface) i32 {

        return @max(self.rounding() - border, 0);

    }

    /// The title bar's controls, with the frame beside and above them, which the grip leaves to clicks.
    fn controls(self: *const Surface) gui.Rect {

        const outer = self.frame();
        const width = gui.px(control) * @as(i32, if (self.options.fixed) 2 else 3) + border;

        return .{

            .x = outer.right() - width,
            .y = outer.y,
            .width = width,
            .height = gui.px(theme.title),

        };

    }

    /// Two rectangles crossing in a plus that the window covers wholly, its rounded corners left out; nothing beneath them shows.
    /// Through Quartz it does, so then only content its app paints opaque counts.
    fn solid(self: *const Surface) [2]gui.Rect {

        if (!self.decorated() or !self.visible() or self.transition != null) return .{ .{}, .{} };
        if (translucent and !self.covered) return .{ .{}, .{} };

        const outer = if (translucent) self.area else self.frame();
        const radius = if (translucent) self.curve() else self.rounding();

        return .{ .{

            .x = outer.x,
            .y = outer.y + radius,
            .width = outer.width,
            .height = outer.height - 2 * radius,

        }, .{

            .x = outer.x + radius,
            .y = outer.y,
            .width = outer.width - 2 * radius,
            .height = outer.height,

        } };

    }

    /// Where it draws Quartz on the screen, reading what lies behind as far as `gui.quartz.reach` beyond; empty when it draws none.
    /// A window's frame is Quartz, though content its app paints opaque hides all but the title bar.
    fn pane(self: *const Surface) gui.Rect {

        if (!translucent or !self.drawn() or !(self.decorated() or self.frosted.width > 0)) return .{};
        if (self.transition != null) return self.painted;

        const outer = self.frame();

        const decorations = if (!self.decorated()) gui.Rect{} else if (!self.covered) outer else gui.Rect{

            .x = outer.x,
            .y = outer.y,
            .width = outer.width,
            .height = gui.px(theme.title),

        };

        return decorations.join(gui.draw.move(self.frosted, corner(self.area)));

    }

    /// Showing and taking input.
    fn visible(self: *const Surface) bool {

        return self.client != 0 and self.shown and !self.minimized and !self.tucked and !self.leaving;

    }

    /// On the screen, if only for the rest of a transition.
    fn drawn(self: *const Surface) bool {

        return self.client != 0 and self.shown and (!(self.minimized or self.tucked) or self.transition != null);

    }

    /// Its motion, with `auto` settled: windows zoom, and everything else shows at once.
    fn movement(self: *const Surface) api.display.Motion {

        if (self.effect != .auto) return self.effect;

        return if (self.decorated() and !self.options.fill) .zoom else .none;

    }

    // A client may rewrite these bytes at any moment; the reader checks every command, and only this window suffers.
    fn commands(self: *const Surface) []const u8 {

        const half = self.memory.bytes.len / 2;

        return self.memory.bytes[@as(usize, self.half) * half ..][0..self.size];

    }

    fn name(self: *const Surface) []const u8 {

        return self.title[0..self.length];

    }

};

/// An event waiting for a client, and which of its surfaces it is for.
const Item = struct {

    surface: u8,
    event: api.Event,

};

/// A process with surfaces: its undelivered input, oldest at `head`, and whether it waits for more.
const Client = struct {

    id: u64 = 0,
    events: [128]Item = undefined,
    head: usize = 0,
    queued: usize = 0,
    waiting: ?api.Request = null,

    /// Input was dropped because the client stopped reading; logged once.
    behind: bool = false,

};

/// Pixels a client shared for image commands.
const Picture = struct {

    client: u64 = 0,
    handle: u64 = 0,
    memory: api.Shared = undefined,
    canvas: gui.Canvas = undefined,

};

/// What a press on a window's frame grabbed.
const Part = enum {

    content,
    title,
    minimize,
    maximize,
    close,
    edge,

};

/// A window following the pointer: moved by its title bar, or resized by the `edges` it was grabbed by.
const Grab = struct {

    index: usize,
    start: gui.Point,
    origin: gui.Rect,
    edges: Edges = .{},

};

const Edges = packed struct(u4) {

    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

};

/// Where the window manager fits a window: where its owner left it, the whole work area, or half of it.
const Tile = enum {

    free,
    full,
    left,
    right,

    /// The frame a window tiled this way fills, down to the bottom of the screen, where the dock tucks away beneath it; null when free.
    fn zone(self: Tile) ?gui.Rect {

        var room = work();

        room.height += reserved[1];

        const half = @divTrunc(room.width, 2);

        return switch (self) {

            .free => null,
            .full => room,
            .left => .{ .x = room.x, .y = room.y, .width = half, .height = room.height },
            .right => .{ .x = room.x + half, .y = room.y, .width = room.width - half, .height = room.height },

        };

    }

};

/// A control on a title bar under the pointer, or pressed.
const Hot = struct {

    index: usize,
    part: Part,

};

var settings: *const api.abi.Environment = undefined;
var screen: Screen = undefined;
var back: gui.Canvas = undefined;
var backing: ?api.Shared = null;

/// The mode an administrator picked, kept in the `display` config.
var saved = api.Config{};

var renderer: ?gpu.Gpu = null;

/// Quartz shows what lies behind it, unless the session's user switched it off, when it draws solid.
var translucent = true;

/// Where the CPU softens Quartz, and keeps what lies around an area it redraws; see `ring`.
var scratch: ?api.Shared = null;
var around: ?api.Shared = null;

/// Intel graphics found behind the boot framebuffer, read but not yet driven.
var graphics: ?intel.Intel = null;

var surfaces = [_]Surface{.{}} ** 64;
var clients = [_]Client{.{}} ** 32;
var pictures = [_]Picture{.{}} ** gpu.textures;

/// Surface indices bottom to top, grouped by layer.
var stack: [surfaces.len]usize = undefined;
var depth: usize = 0;

/// The window keys go to unless an overlay is up.
var focused: ?usize = null;

var grabbed: ?Grab = null;

/// Where the window being dragged would tile if dropped now, shown as a translucent outline.
var aimed: Tile = .free;

/// An Alt+Tab went to the session, so the Alt release that ends it goes there too.
var switching = false;

var hot: ?Hot = null;
var armed: ?Hot = null;

/// The surface a press landed in, which keeps the pointer until release.
var capture: ?usize = null;

/// The surface last sent a pointer position.
var hovered: ?usize = null;

/// The last press on a title bar, to spot a double-click.
var titled: ?usize = null;
var titled_at: u64 = 0;

var pointer = gui.Point{};
var buttons: u8 = 0;

/// The buttons each input service last said its devices hold.
var sources = [_]struct { id: u64 = 0, buttons: u8 = 0 }{.{}} ** 4;
var modifiers = api.Event.Modifiers{};

/// Rows at the top and bottom of the screen the session keeps for its bars.
var reserved = [2]i32{ 0, 0 };

/// The window list changed since the session last heard.
var changed = false;

/// The parts of the screen to redraw before waiting for the next request; changes far apart redraw apart.
var stale = [_]gui.Rect{.{}} ** 4;

/// What the pointer shows, and until which tick it shows busy for an app being launched.
var look: gui.Cursor = .arrow;
var launching: u64 = 0;

/// The pointer has followed a device; until then the adapter's own pointer stays hidden, since a position it reported
/// before any input, such as the middle of the screen, lingers in VNC viewers as a second pointer.
var located = false;

var clipboard: [64 * 1024]u8 = undefined;
var copied: usize = 0;

/// The client whose commands are being drawn, so its image commands find only its own images.
var drawing: u64 = 0;

var chrome: [2048]u8 align(4) = undefined;
var outline_bytes: [256]u8 align(4) = undefined;
var kept: gui.Corners = .{};
var listed: [surfaces.len]api.display.Window = undefined;

var sweep: u64 = 0;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, geometry: usize, shifts: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.memory) or api.permits(.management)) api.exit(2);

    settings = environment;

    // The supervisor waits on our handshake, so answer it before asking the files service for the saved mode.
    greet();

    const wanted = load() orelse default;

    if (!open(wanted) and !open(default)) framebuffer(base, geometry, shifts);

    pointer = .{

        .x = @divTrunc(@as(i32, @intCast(back.width)), 2),
        .y = @divTrunc(@as(i32, @intCast(back.height)), 2),

    };

    switch (screen) {

        .svga => |*device| {

            api.log(if (renderer != null) "display: ready (svga, 3D on)\n" else if (device.accelerated) "display: ready (svga, 3D failed)\n" else "display: ready (svga, 3D off)\n");

        },
        .frame => {

            graphics = intel.Intel.init(&settings.bars, settings.device);
            if (graphics) |found| found.describe();
            api.log(if (graphics != null) "display: ready (framebuffer, Intel)\n" else "display: ready (framebuffer)\n");

        },

    }

    compose(back.bounds());

    while (true) {

        // Everything the last requests changed draws once, after their answers let their clients carry on.
        hideaway();

        const moving = animate();

        dress();
        redraw();

        // While something moves, or the pointer shows busy for a while, waiting for a request must not stall what comes next.
        const timed = moving or launching != 0;

        var request = api.receive(!timed) catch {

            if (timed) api.sleep(if (moving) 1 else 5);
            continue;

        };

        // Requests already waiting, such as input and the drawing it leads to, are answered before the screen redraws, up to a frame's worth.
        var answered: usize = 0;

        while (true) : (answered += 1) {

            if (respond(request)) |result| api.answer(request, result);

            if (answered == 31) break;
            request = api.receive(false) catch break;

        }

        announce();

        // ponytail: exited clients are pruned on the next request; add a timer if an idle screen must drop them.
        if (api.ticks() >= sweep) prune();

    }

}

/// Answers the supervisor's `hello`; nothing else should arrive before it.
fn greet() void {

    while (true) {

        const request = api.receive(true) catch continue;
        const hello = protocol.operation(request.second) == .hello;

        api.answer(request, if (hello) protocol.version else protocol.invalid);

        if (hello) return;

    }

}

/// Takes over the SVGA adapter at `size`, drawing on its GPU when it has one; false when the adapter cannot show it.
fn open(size: gui.Rect) bool {

    const width: u32 = @intCast(size.width);
    const height: u32 = @intCast(size.height);
    const device = svga.Device.init(&settings.bars, width, height) orelse return false;

    screen = .{

        .svga = device,

    };

    const memory = api.share((width * height * 4 + 4095) / 4096) catch return false;

    if (!screen.svga.bind(memory.bytes, width * 4)) {

        api.detach(memory.handle);
        return false;

    }

    adopt(memory, size);
    wear(&screen.svga);

    if (renderer) |*old| old.release();
    renderer = gpu.Gpu.init(&screen.svga, width, height);
    frost();

    // A new device forgot every texture, so images go back up.
    if (renderer) |*drawer| {

        for (&pictures, 0..) |*picture, slot| {

            if (picture.client != 0) drawer.upload(slot, picture.canvas.pixels, @intCast(picture.canvas.width), @intCast(picture.canvas.height), picture.canvas.bounds());

        }

    }

    return true;

}

/// Falls back to the boot framebuffer, drawn by the CPU at whatever mode the firmware left.
fn framebuffer(base: usize, geometry: usize, shifts: usize) void {

    if (base == 0) api.exit(3);

    const height = geometry >> 16 & 0xffff;
    const stride = geometry >> 32;
    const mapped = api.map(base, stride * height * 4) catch api.exit(3);

    const size = gui.Rect{

        .width = @intCast(geometry & 0xffff),
        .height = @intCast(height),

    };

    screen = .{

        .frame = .{

            .pixels = @ptrCast(@alignCast(mapped)),
            .stride = stride,
            .shifts = .{ @intCast(shifts & 0xff), @intCast(shifts >> 8 & 0xff), @intCast(shifts >> 16 & 0xff) },

        },

    };

    adopt(api.share((@as(usize, @intCast(size.width * size.height)) * 4 + 4095) / 4096) catch api.exit(3), size);

}

/// Makes `memory` the CPU's copy of a `size` screen, freeing the last one, with room to soften Quartz in.
fn adopt(memory: api.Shared, size: gui.Rect) void {

    for ([_]*?api.Shared{ &backing, &scratch, &around }) |held| if (held.*) |old| {

        api.detach(old.handle);
        held.* = null;

    };

    const count: usize = @intCast(size.width * size.height);
    const needed = gui.quartz.room(@intCast(size.width), @intCast(size.height));

    backing = memory;
    scratch = api.share((needed * 4 + 4095) / 4096) catch null;

    back = .{

        .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
        .width = @intCast(size.width),
        .height = @intCast(size.height),

    };

    frost();

}

/// Tells the GPU whether Quartz shows what lies behind it, and lets the CPU soften it while it does.
fn frost() void {

    if (renderer) |*device| device.translucent = translucent;

    const spare = scratch orelse return;

    back.spare = if (translucent) std.mem.bytesAsSlice(u32, spare.bytes[0 .. gui.quartz.room(back.width, back.height) * 4]) else &.{};

}

/// Switches to a `width` by `height` mode for an administrator, then tells every window.
fn mode(request: api.Request, value: u64) u64 {

    if (!api.sender(request).admin) return protocol.denied;
    if (screen != .svga) return protocol.invalid;

    const size = gui.Rect{

        .width = @intCast(value & 0xffff),
        .height = @intCast(value >> 16 & 0xffff),

    };

    const previous = back.bounds();

    if (size.width < smallest.width or size.height < smallest.height or !screen.svga.fits(@intCast(size.width), @intCast(size.height))) return protocol.invalid;
    if (!open(size) and !open(previous)) api.exit(3);
    if (back.width != size.width or back.height != size.height) return protocol.invalid;

    settle();
    compose(back.bounds());
    save(size);

    return 0;

}

/// Keeps the pointer and every title bar on the new screen, and resizes what follows the screen.
fn settle() void {

    const width: i32 = @intCast(back.width);
    const height: i32 = @intCast(back.height);

    pointer = .{

        .x = @min(pointer.x, width - 1),
        .y = @min(pointer.y, height - 1),

    };

    for (&surfaces, 0..) |*surface, index| {

        // Transitions were drawn for the old screen, so they end at once.
        if (surface.transition != null) conclude(index);
        if (surface.client == 0 or surface.leaving) continue;

        if (surface.options.fill) {

            reshape(index, back.bounds());

        } else if (surface.tile.zone()) |zone| {

            reshape(index, inside(zone));

        } else if (surface.decorated()) {

            surface.area.x = std.math.clamp(surface.area.x, gui.px(theme.title) - surface.area.width, width - gui.px(theme.title));
            surface.area.y = std.math.clamp(surface.area.y, work().y + gui.px(theme.title), height - border);

        }

    }

}

fn load() ?gui.Rect {

    saved.open(api.config.system, "display");

    const percent = saved.number(u8, "scale") orelse 100;

    if (stepped(percent)) gui.style.scale = percent;

    const size = gui.Rect{

        .width = saved.number(u16, "width") orelse return null,
        .height = saved.number(u16, "height") orelse return null,

    };

    return if (size.width >= smallest.width and size.height >= smallest.height) size else null;

}

fn save(size: gui.Rect) void {

    _ = saved.set("width", size.width);
    _ = saved.set("height", size.height);
    saved.save() catch api.log("display: could not save the mode\n");

}

/// What draws the screen, as `info` reports it above the screen's size: an `api.display.Adapter.Kind`, then the PCI device id.
fn describe() u64 {

    const kind: api.display.Adapter.Kind = switch (screen) {

        .svga => if (renderer != null) .accelerated else .svga,
        .frame => if (graphics != null) .intel else .framebuffer,

    };

    const device: u64 = if (graphics) |found| found.device else settings.device >> 16;

    return @as(u64, @intFromEnum(kind)) << 32 | device << 40;

}

/// Returns the reply, or null when the request waits for input.
fn respond(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .info => back.width | back.height << 16 | describe() | @as(u64, @intCast(gui.style.scale)) << 56,
        .surface => attach(request, value),
        .place => place(request, value),
        .mode => mode(request, value),
        .present => present(request, value),
        .wait => wait(request),
        .input => input(request),
        .windows => windows(request),
        .activate => activate(request, value),
        .reserve => reserve(request, value),
        .image => image(request, value),
        .forget => forget(request, value),
        .clipboard => paste(request, value),
        .capture => snapshot(request),
        .cursor => pointing(request, value),
        .quartz => quartz(request, value),
        .accent => accent(request, value),
        .scale => rescale(value),
        .crash => api.crash(request),
        else => protocol.invalid,

    };

}

fn attach(request: api.Request, region: u64) u64 {

    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    var area = rect(spec.area);

    if (!fits(area)) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;
    if (client(request.first) == null) return protocol.full;

    const index = for (&surfaces, 0..) |*surface, slot| {

        if (surface.client == 0) break slot;

    } else return protocol.full;

    const memory = api.attach(region) catch return protocol.denied;

    if (memory.bytes.len < 2 * 4096) {

        api.detach(memory.handle);
        return protocol.invalid;

    }

    if (spec.options.fill) area = back.bounds();
    if (spec.layer == .window) area = arrival(area);
    if (spec.layer == .popup) area = pop(request.first, spec.anchor, area);

    const surface = &surfaces[index];

    surface.* = .{

        .client = request.first,
        .memory = memory,
        .area = area,

        .layer = spec.layer,
        .options = spec.options,
        .application = spec.application,
        .effect = spec.motion,

    };

    name(surface, spec);
    insert(index);

    // A popup takes the keys while it shows without taking focus from the window it opened over.
    if (spec.layer != .background and spec.layer != .popup) focus(index);

    // A window that had to shrink to fit learns its size before it first draws.
    if (area.width != spec.area.width or area.height != spec.area.height) tell(index);

    // The session hears of windows, not of its own bars and menus or apps' popups.
    if (surface.decorated()) changed = true;

    return index;

}

/// Moves, resizes, restacks, or retitles a surface; a placement with no area drops it.
fn place(request: api.Request, id: u64) u64 {

    const surface = owned(request, id) orelse return protocol.invalid;
    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    const index: usize = @intCast(id);

    if (spec.area.width == 0 and spec.area.height == 0) {

        close(index);
        return 0;

    }

    var area = rect(spec.area);

    if (!fits(area)) return protocol.invalid;
    if ((spec.layer == .window) != surface.decorated()) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;

    // The window manager owns where windows sit; apps may only change their size.
    if (surface.decorated()) {

        area.x = surface.area.x;
        area.y = surface.area.y;
        if (surface.tile != .free) area = surface.area;

    }

    if (spec.layer == .popup) area = pop(request.first, spec.anchor, area);

    const before = surface.footprint();

    surface.area = area;
    surface.layer = spec.layer;
    surface.effect = spec.motion;
    name(surface, spec);
    remove(index);
    insert(index);
    if (spec.layer == .overlay) focus(index);
    compose(before.join(surface.footprint()));
    if (surface.decorated()) changed = true;

    return 0;

}

/// Shows the commands a client finished writing into one half of its buffer.
fn present(request: api.Request, value: u64) u64 {

    const surface = owned(request, value & 0xff) orelse return protocol.invalid;
    const length = value >> 9;

    if (length > surface.memory.bytes.len / 2) return protocol.invalid;

    surface.half = @intCast(value >> 8 & 1);
    surface.size = length;

    // Content turning opaque, or no longer, changes how much of its frame's Quartz shows.
    if (survey(surface) and surface.shown) compose(surface.footprint());

    // A surface's first frame plays it in, and a window's ends the busy pointer of the launch that opened it.
    if (!surface.shown) {

        surface.shown = true;
        if (surface.decorated()) launching = 0;
        if (motion.away(surface.movement())) |away| _ = begin(@intCast(value & 0xff), .enter, away.pose, .rest, away.length);

        compose(surface.footprint());

    }

    // Its frame and shadow stay as they were, so only the content that changed draws afresh.
    if (!surface.minimized) compose(if (request.fourth >= @sizeOf(api.display.Area)) changed: {

        const damage = fetch(request, api.display.Area) orelse break :changed surface.area;

        break :changed gui.draw.move(rect(damage), corner(surface.area)).intersect(surface.area) orelse return 0;

    } else surface.area);

    return 0;

}

/// Notes where `surface`'s commands draw Quartz, and whether the first of them paints its content opaque; true when the latter changed.
fn survey(surface: *Surface) bool {

    const was = surface.covered;
    var commands = gui.draw.iterate(surface.commands());
    var first = true;

    const whole = gui.Rect{

        .width = surface.area.width,
        .height = surface.area.height,

    };

    surface.frosted = .{};
    surface.covered = false;

    while (commands.next()) |command| : (first = false) {

        switch (command) {

            .shape => |fill| if (first) {

                surface.covered = fill.color >> 24 == 0 and fill.radius == 0 and (fill.area.intersect(fill.clip) orelse continue).encloses(whole);

            },
            .quartz => |frosted| surface.frosted = surface.frosted.join(frosted.area.intersect(frosted.clip) orelse continue),
            else => {

            },

        }

    }

    return surface.covered != was;

}

/// Sets what the pointer shows over a surface's content; naming no surface, shows it busy while an app the client launched starts.
fn pointing(request: api.Request, value: u64) u64 {

    const shape = std.enums.fromInt(gui.Cursor, value >> 8 & 0xff) orelse return protocol.invalid;

    if (value & 0xff == none) {

        if (shape != .busy) return protocol.invalid;
        launching = api.ticks() + 400;

        return 0;

    }

    const surface = owned(request, value & 0xff) orelse return protocol.invalid;

    surface.cursor = shape;

    return 0;

}

fn wait(request: api.Request) ?u64 {

    const owner = client(request.first) orelse return protocol.full;

    owner.waiting = request;
    deliver(owner);

    return null;

}

/// Session only: describes every window, bottom to top.
fn windows(request: api.Request) u64 {

    if (request.first != session()) return protocol.denied;

    var count: usize = 0;

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];
        if (!surface.decorated() or surface.leaving) continue;

        listed[count] = .{

            .id = @intCast(index),
            .application = surface.application,

            .state = .{

                .focused = focused == index,
                .minimized = surface.minimized,
                .maximized = surface.tile == .full,

            },

            .length = @intCast(surface.length),
            .title = surface.title,

            .area = wire(surface.frame()),

        };

        count += 1;

    }

    const bytes = std.mem.sliceAsBytes(listed[0..@min(count, request.fourth / @sizeOf(api.display.Window))]);

    api.store(request, 0, bytes) catch return protocol.invalid;

    return count;

}

/// Session only: raises, minimises, or closes another client's window.
fn activate(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;

    const index = value & 0xffffffff;
    if (index >= surfaces.len or surfaces[index].client == 0 or surfaces[index].leaving or !surfaces[index].decorated()) return protocol.invalid;

    switch (std.enums.fromInt(api.display.Action, value >> 32) orelse return protocol.invalid) {

        .raise => {

            // A minimised window flies back from wherever its minimising left it.
            if (surfaces[index].minimized) {

                surfaces[index].minimized = false;
                _ = begin(index, .restore, null, .rest, motion.tuck);

            }

            raise(index);
            focus(index);

        },
        .minimize => minimize(index),
        .close => queue(index, .{

            .kind = .close,

        }),
        _ => return protocol.invalid,

    }

    changed = true;

    return 0;

}

/// Session only: shows what lies behind Quartz (`value` 1), or draws it solid (0), as its user chose.
fn quartz(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;
    if (value > 1) return protocol.invalid;
    if (translucent == (value == 1)) return 0;

    translucent = value == 1;
    frost();
    compose(back.bounds());

    return 0;

}

/// Session only: draws the accent as `gui.theme.accents[value]`, as its user chose.
fn accent(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;
    if (value >= gui.theme.accents.len) return protocol.invalid;

    const shades = gui.theme.accents[value].shades;

    if (std.mem.eql(u32, &gui.draw.accent, &shades)) return 0;

    gui.draw.accent = shades;
    compose(back.bounds());

    return 0;

}

/// Whether `percent` is an interface scale people may pick: a step of 25 from 100 to 200.
fn stepped(percent: u64) bool {

    return percent >= 100 and percent <= 200 and percent % 25 == 0;

}

/// Sets the interface scale, which anyone may change as it only changes how things look: windows grow or shrink with it, their
/// title bars too, and every surface hears of it to lay itself out again.
fn rescale(value: u64) u64 {

    if (!stepped(value)) return protocol.invalid;

    const before = gui.style.scale;
    const after: i32 = @intCast(value);

    if (after == before) return 0;

    gui.style.scale = after;

    for (&surfaces, 0..) |*surface, index| {

        if (surface.client == 0 or surface.leaving or !surface.decorated() or surface.options.fill) continue;

        surface.restore = grown(surface.restore, before, after);
        if (surface.tile == .free) reshape(index, grown(surface.area, before, after));

    }

    // Tiles refit under their taller or shorter title bars, and free windows stay on the screen.
    settle();

    for (&surfaces, 0..) |*surface, index| {

        if (surface.client == 0 or surface.leaving) continue;

        queue(index, .{

            .kind = .notice,
            .code = @intFromEnum(api.Event.Notice.scale),

        });

        deliver(client(surface.client).?);

    }

    compose(back.bounds());
    _ = saved.set("scale", after);
    saved.save() catch api.log("display: could not save the scale\n");

    return 0;

}

/// `area` with its size taken from scale `before` to `after`, moved and shrunk as needed to stay within the work area.
fn grown(area: gui.Rect, before: i32, after: i32) gui.Rect {

    const room = inside(work());
    const width = std.math.clamp(@divTrunc(area.width * after, before), 1, @max(room.width, 1));
    const height = std.math.clamp(@divTrunc(area.height * after, before), 1, @max(room.height, 1));

    return .{

        .x = std.math.clamp(area.x, room.x, room.right() - width),
        .y = std.math.clamp(area.y, room.y, room.bottom() - height),
        .width = width,
        .height = height,

    };

}

/// Session only: keeps rows at the top and bottom of the screen for its bars.
fn reserve(request: api.Request, value: u64) u64 {

    if (request.first != session()) return protocol.denied;

    const top: i32 = @intCast(value & 0xffff);
    const bottom: i32 = @intCast(value >> 16 & 0xffff);

    if (top + bottom > @divTrunc(@as(i32, @intCast(back.height)), 2)) return protocol.invalid;

    reserved = .{ top, bottom };

    // Tiles refit, and windows placed before the rows were kept, such as after a restart, come out from under the bar.
    settle();
    compose(back.bounds());

    return 0;

}

/// Takes in, or refreshes, pixels a client shared for image commands.
fn image(request: api.Request, handle: u64) u64 {

    const size = fetch(request, [6]u32) orelse return protocol.invalid;
    const width = size[0];
    const height = size[1];

    if (width == 0 or height == 0 or width > 8192 or height > 8192) return protocol.invalid;

    // Only what changed goes to the GPU, unless the image is new or changed size.
    const whole = gui.Rect{

        .width = @intCast(width),
        .height = @intCast(height),

    };

    var touched = whole.intersect(.{

        .x = @bitCast(size[2]),
        .y = @bitCast(size[3]),
        .width = @bitCast(size[4]),
        .height = @bitCast(size[5]),

    }) orelse return 0;

    var slot = find(request.first, handle);

    if (slot == null or pictures[slot.?].canvas.width != width or pictures[slot.?].canvas.height != height) touched = whole;

    if (slot == null) {

        slot = for (&pictures, 0..) |*picture, index| {

            if (picture.client == 0) break index;

        } else return protocol.full;

        const memory = api.attach(handle) catch return protocol.denied;

        pictures[slot.?] = .{

            .client = request.first,
            .handle = handle,
            .memory = memory,

        };

    }

    const picture = &pictures[slot.?];

    if (picture.memory.bytes.len < @as(usize, width) * height * 4) {

        discard(slot.?);
        return protocol.invalid;

    }

    picture.canvas = .{

        .pixels = std.mem.bytesAsSlice(u32, picture.memory.bytes[0 .. @as(usize, width) * height * 4]),
        .width = width,
        .height = height,

    };

    if (renderer) |*device| device.upload(slot.?, picture.canvas.pixels, width, height, touched);

    // Only where the client's surfaces show the part that changed draws afresh.
    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];
        if (surface.client != request.first or !surface.visible()) continue;

        var commands = gui.draw.iterate(surface.commands());

        while (commands.next()) |command| {

            const shown = switch (command) {

                .image => |shown| shown,
                else => continue,

            };

            if (shown.handle != handle) continue;

            const area = scaled(touched, whole, shown.area).intersect(shown.clip) orelse continue;

            compose(gui.draw.move(area, corner(surface.area)).intersect(surface.area) orelse continue);

        }

    }

    return 0;

}

/// Where `piece` of a `whole` image lands when the image is stretched over `onto`, a pixel wider each way for filtering.
fn scaled(piece: gui.Rect, whole: gui.Rect, onto: gui.Rect) gui.Rect {

    const left = @divFloor(@as(i64, piece.x) * onto.width, whole.width) - 1;
    const top = @divFloor(@as(i64, piece.y) * onto.height, whole.height) - 1;
    const right = std.math.divCeil(i64, @as(i64, piece.right()) * onto.width, whole.width) catch unreachable;
    const bottom = std.math.divCeil(i64, @as(i64, piece.bottom()) * onto.height, whole.height) catch unreachable;

    return .{

        .x = onto.x + @as(i32, @intCast(left)),
        .y = onto.y + @as(i32, @intCast(top)),
        .width = @intCast(right + 1 - left),
        .height = @intCast(bottom + 1 - top),

    };

}

fn forget(request: api.Request, handle: u64) u64 {

    discard(find(request.first, handle) orelse return protocol.invalid);

    return 0;

}

/// Copies into (`value` 1) or out of (`value` 0) the clipboard shared by every app.
fn paste(request: api.Request, value: u64) u64 {

    if (value == 1) {

        const length = @min(request.fourth, clipboard.len);

        api.fetch(request, 0, clipboard[0..length]) catch return protocol.invalid;
        copied = length;

        // The session keeps a history of what was copied.
        inform(.clipboard);

        return 0;

    }

    const length = @min(copied, request.fourth);

    api.store(request, 0, clipboard[0..length]) catch return protocol.invalid;

    return length;

}

/// Marks `area` of the screen for redrawing once the current requests are answered, so a burst of changes draws once;
/// it joins any marked area it touches, and with every slot taken, the one that grows least by taking it in.
fn compose(area: gui.Rect) void {

    var fresh = area.intersect(back.bounds()) orelse return;
    var grew = true;

    // Joining may make the area touch others, which it then takes in too.
    while (grew) {

        grew = false;

        for (&stale) |*marked| {

            if (marked.width == 0 or marked.inset(-1).intersect(fresh) == null) continue;

            fresh = fresh.join(marked.*);
            marked.* = .{};
            grew = true;

        }

    }

    for (&stale) |*marked| {

        if (marked.width != 0) continue;

        marked.* = fresh;
        return;

    }

    var best: usize = 0;
    var cheapest: i64 = std.math.maxInt(i64);

    for (stale, 0..) |marked, index| {

        const joined = marked.join(fresh);
        const growth = @as(i64, joined.width) * joined.height - @as(i64, marked.width) * marked.height;

        if (growth < cheapest) {

            cheapest = growth;
            best = index;

        }

    }

    stale[best] = stale[best].join(fresh);

}

/// Redraws each area `compose` marked.
fn redraw() void {

    for (&stale) |*marked| {

        const visible = marked.*;

        marked.* = .{};
        if (visible.width != 0) render(visible);

    }

}

/// The stack position from which surfaces show in `visible`: the topmost window wholly covering it, or the bottom.
fn floor(visible: gui.Rect) usize {

    var position = depth;

    while (position > 0) {

        position -= 1;

        for (surfaces[stack[position]].solid()) |cover| if (cover.encloses(visible)) return position;

    }

    return 0;

}

/// Redraws `visible` from the surface stack, bottom to top, on the GPU when there is one; Quartz near it redraws with it.
fn render(visible: gui.Rect) void {

    const extent = widen(visible);

    if (renderer) |*device| {

        device.begin(extent.read);

        for (stack[floor(extent.read)..depth]) |index| {

            const surface = &surfaces[index];
            if (!surface.drawn()) continue;

            if (aiming(index)) {

                drawing = 0;
                device.render(guide().commands(), .{}, extent.read, texture);

            }

            if (surface.transition != null) {

                float(device, index, extent.read);

            } else if (surface.footprint().intersect(extent.read)) |limit| {

                layers(device, index, limit, false);

            }

        }

        return device.finish(extent.shown);

    }

    switch (screen) {

        .svga => |*device| device.idle(),
        .frame => {

        },

    }

    // Quartz softens what lies past the area it shows, and draws wrongly out there, so what lay there before goes back.
    const held = !std.meta.eql(extent.read, extent.shown) and ring(extent.read, extent.shown, false);

    paint(if (held) extent.read else extent.shown);
    if (held) _ = ring(extent.read, extent.shown, true);

    switch (screen) {

        .svga => |*device| device.present(extent.shown),
        .frame => |*frame| frame.present(&back, extent.shown),

    }

}

/// What redrawing `visible` takes: the Quartz near it changes with it, so is `shown` too, and reads what lies behind it further out,
/// which is `read` and drawn beneath it.
fn widen(visible: gui.Rect) struct { shown: gui.Rect, read: gui.Rect } {

    const reach = gui.quartz.reach;
    const bottom = floor(visible);
    var shown = visible;
    var position = depth;

    // Nothing below the window hiding all of `visible` shows; above it, Quartz over Quartz takes in what changed beneath it in turn.
    for (stack[bottom..depth]) |index| {

        if (shown.inset(-reach).intersect(surfaces[index].pane())) |near| shown = shown.join(near);

    }

    // A mode switch may leave an area of the old screen marked.
    shown = shown.intersect(visible.inset(-2 * reach)).?.intersect(back.bounds()) orelse return .{

        .shown = visible,
        .read = visible,

    };

    var read = shown;

    while (position > bottom) {

        position -= 1;
        if (read.intersect(surfaces[stack[position]].pane())) |beneath| read = read.join(beneath.inset(-reach));

    }

    return .{

        .shown = shown,
        .read = read.intersect(shown.inset(-2 * reach)).?.intersect(back.bounds()).?,

    };

}

/// Copies what lies in `outer` around `inner` into `around`, or back out of it with `restore`; false without room for it.
fn ring(outer: gui.Rect, inner: gui.Rect, restore: bool) bool {

    // `widen` reads at most twice Quartz's reach past what it shows, so no band is deeper than that along the screen's edges.
    if (around == null) around = api.share((4 * gui.quartz.reach * (back.width + back.height) * 4 + 4095) / 4096) catch return false;

    const store = std.mem.bytesAsSlice(u32, around.?.bytes);
    var offset: usize = 0;

    const bands = [_]gui.Rect{ .{

        .x = outer.x,
        .y = outer.y,
        .width = outer.width,
        .height = inner.y - outer.y,

    }, .{

        .x = outer.x,
        .y = inner.bottom(),
        .width = outer.width,
        .height = outer.bottom() - inner.bottom(),

    }, .{

        .x = outer.x,
        .y = inner.y,
        .width = inner.x - outer.x,
        .height = inner.height,

    }, .{

        .x = inner.right(),
        .y = inner.y,
        .width = outer.right() - inner.right(),
        .height = inner.height,

    } };

    for (bands) |band| {

        if (band.width <= 0 or band.height <= 0) continue;

        const width: usize = @intCast(band.width);

        for (@intCast(band.y)..@intCast(band.bottom())) |y| {

            const row = back.pixels[y * back.width + @as(usize, @intCast(band.x)) ..][0..width];
            const copy = store[offset..][0..width];

            if (restore) @memcpy(row, copy) else @memcpy(copy, row);
            offset += width;

        }

    }

    return true;

}

/// Queues surface `index`'s decorations and content within `limit` on the GPU, a window's content cut to the curve of its frame's bottom corners;
/// `whole` leaves the corners square for a caller that cuts the layer it draws into.
fn layers(device: *gpu.Gpu, index: usize, limit: gui.Rect, whole: bool) void {

    const surface = &surfaces[index];
    const decorations = trim(index);
    const origin = corner(surface.area);

    drawing = 0;
    device.render(decorations.commands(), corner(surface.footprint()), limit, texture);
    drawing = surface.client;

    const content = surface.area.intersect(limit) orelse return;
    if (whole or !surface.decorated() or surface.curve() == 0) return device.render(surface.commands(), origin, content, texture);

    const corners = gui.Corners{

        .area = surface.area,
        .radius = surface.curve(),

    };

    const squares = corners.squares();

    const above = gui.Rect{

        .x = surface.area.x,
        .y = surface.area.y,
        .width = surface.area.width,
        .height = surface.area.height - squares[0].height,

    };

    const between = gui.Rect{

        .x = squares[0].right(),
        .y = squares[0].y,
        .width = squares[1].x - squares[0].right(),
        .height = squares[0].height,

    };

    for ([_]gui.Rect{ above, between }) |piece| if (piece.intersect(content)) |clip| device.render(surface.commands(), origin, clip, texture);

    // The GPU cannot clip to a curve, so each bottom corner is drawn in the layer, cut there, and laid over the frame already drawn beneath it.
    for (squares) |square| {

        const clip = square.intersect(content) orelse continue;

        device.lift(square);
        device.render(surface.commands(), origin, clip, texture);
        device.cut(surface.area, corners.radius);
        device.lower(square, .{ @floatFromInt(square.x), @floatFromInt(square.y), @floatFromInt(square.right()), @floatFromInt(square.bottom()) }, 1, clip);

    }

}

/// Queues surface `index` mid-transition: drawn whole into the GPU's layer, then laid on the frame in its pose.
fn float(device: *gpu.Gpu, index: usize, visible: gui.Rect) void {

    const surface = &surfaces[index];
    if (surface.painted.intersect(visible) == null) return;

    const footprint = surface.footprint();
    const whole = footprint.intersect(back.bounds()) orelse return;

    device.lift(whole);
    layers(device, index, whole, true);

    // As `paint` does on the CPU, content is cut to the curve of the frame's bottom corners, and the frame fills in beneath.
    if (surface.decorated() and surface.curve() != 0) {

        const corners = gui.Corners{

            .area = surface.area,
            .radius = surface.curve(),

        };

        const decorations = trim(index);

        device.cut(surface.area, corners.radius);
        device.blending(.under);
        drawing = 0;

        for (corners.squares()) |square| {

            if (square.intersect(whole)) |limit| device.render(decorations.commands(), corner(footprint), limit, texture);

        }

        device.blending(.over);

    }

    device.lower(whole, surface.pose.box(whole, footprint), surface.pose.opacity, visible);

}

/// Draws `visible` of the screen into the CPU's copy, bottom surface first; surfaces in transition are the GPU's alone.
fn paint(visible: gui.Rect) void {

    back.fill(visible, theme.desktop);

    for (stack[floor(visible)..depth]) |index| {

        const surface = &surfaces[index];

        if (aiming(index)) {

            drawing = 0;
            gui.draw.replay(&back, guide().commands(), .{}, visible, pixels);

        }

        if (!surface.visible() or surface.transition != null or surface.footprint().intersect(visible) == null) continue;

        const decorations = trim(index);

        drawing = 0;
        if (surface.footprint().intersect(visible)) |limit| gui.draw.replay(&back, decorations.commands(), corner(surface.footprint()), limit, pixels);
        drawing = surface.client;

        if (surface.area.intersect(visible)) |limit| {

            // A window's content is cut to the curve of its frame's bottom corners.
            back.save(&kept, surface.area, if (surface.decorated()) surface.curve() else 0, limit);
            gui.draw.replay(&back, surface.commands(), corner(surface.area), limit, pixels);
            back.trim(&kept);

        }

    }

}

/// Session only: draws the whole screen on the CPU and copies it, 0x00RRGGBB row after row, into the lent window; returns its size.
fn snapshot(request: api.Request) u64 {

    if (request.first != session()) return protocol.denied;

    const bytes = std.mem.sliceAsBytes(back.pixels);
    var offset: usize = 0;

    if (request.fourth < bytes.len) return protocol.invalid;

    // A GPU-drawn screen leaves the CPU's copy stale, so it is drawn afresh.
    if (renderer != null) paint(back.bounds());

    while (offset < bytes.len) : (offset += 0x10000) {

        api.store(request, offset, bytes[offset..][0..@min(0x10000, bytes.len - offset)]) catch return protocol.invalid;

    }

    return back.width | back.height << 16;

}

/// Takes the events the input service lends in its window and hands them to surfaces.
fn input(request: api.Request) u64 {

    // Only services run as the system, so clients cannot forge another surface's input.
    if (api.sender(request).user != api.abi.system.user) return protocol.denied;

    var events: [64]api.Event = undefined;
    const count = @min(request.fourth / @sizeOf(api.Event), events.len);

    api.fetch(request, 0, std.mem.sliceAsBytes(events[0..count])) catch return protocol.invalid;
    for (events[0..count]) |event| route(event, request.first);

    for (&clients) |*owner| {

        if (owner.id != 0) deliver(owner);

    }

    return 0;

}

fn route(event: api.Event, source: u64) void {

    switch (event.kind) {

        .key => {

            modifiers = event.modifiers;

            const target = keyboard();
            const owner = session();

            // Super and the arrows tile the window with the keyboard, as dragging it to an edge does.
            if (event.pressed and event.modifiers.super and !event.modifiers.shift) if (target) |index| if (surfaces[index].decorated()) {

                switch (event.key()) {

                    .left => return arrange(index, .left),
                    .right => return arrange(index, .right),
                    .up => return arrange(index, .full),
                    .down => return if (surfaces[index].tile == .free) minimize(index) else arrange(index, .free),
                    else => {

                    },

                }

            };

            // Super chords, Alt+Tab with the Alt release that ends it, and the volume keys are the desktop's, whichever window has the
            // keyboard.
            const cycling = event.modifiers.alt and event.key() == .tab;
            const ending = switching and event.key() == .alt and !event.pressed;

            if (cycling) switching = true;
            if (ending) switching = false;

            if ((event.modifiers.super or cycling or ending or event.key().global()) and owner != 0 and (target == null or surfaces[target.?].client != owner)) {

                for (stack[0..depth]) |index| {

                    if (surfaces[index].client == owner and !surfaces[index].leaving) return queue(index, event);

                }

            }

            if (target) |index| queue(index, event);

        },
        .motion, .pointer => {

            const width: i32 = @intCast(back.width);
            const height: i32 = @intCast(back.height);

            // Relative motion comes from a mouse; absolute positions span 0..32767 across the screen.
            if (event.kind == .motion) {

                if (event.x != 0 or event.y != 0) move(pointer.x + event.x, pointer.y + event.y);

            } else {

                move(@divTrunc(@as(i32, event.x) * width, 32768), @divTrunc(@as(i32, event.y) * height, 32768));

            }

            track();
            press(holding(source, event.code));

        },
        .button => if (event.code >= 3) {

            const index = under(pointer) orelse return;
            if (!surfaces[index].area.contains(pointer)) return;

            queue(index, local(index, .{

                .kind = .button,
                .pressed = true,
                .code = event.code,
                .modifiers = modifiers,

            }));

        },
        else => {

        },

    }

}

/// The buttons held on any pointing device, after input service `source` says its device holds `code`; a touchpad and a USB mouse each report only their own.
fn holding(source: u64, code: u8) u8 {

    const slot = for (&sources, 0..) |entry, index| {

        if (entry.id == source) break index;

    } else for (&sources, 0..) |entry, index| {

        if (entry.id == 0) break index;

    } else 0;

    sources[slot] = .{

        .id = source,
        .buttons = code,

    };

    var all: u8 = 0;

    for (sources) |entry| all |= entry.buttons;

    return all;

}

/// Follows the pointer: drags or resizes a grabbed window, else tells the surfaces under it where it is.
fn track() void {

    if (grabbed) |held| return follow(held);

    const target = capture orelse under(pointer);

    // The surface the pointer left hears a position outside itself, so it drops its hover.
    if (hovered != target) if (hovered) |old| if (surfaces[old].client != 0) queue(old, local(old, .{

        .kind = .pointer,
        .code = buttons,

    }));

    hovered = target;

    const next: ?Hot = if (target) |index| if (capture == null) .{

        .index = index,
        .part = part(index, pointer),

    } else null else null;

    if (!std.meta.eql(next, hot)) {

        const previous = hot;

        hot = next;

        // Only the controls light up under the pointer.
        for ([_]?Hot{ previous, next }) |entry| if (entry) |spot| if (lights(spot.part)) compose(surfaces[spot.index].controls());

    }

    const index = target orelse return;

    queue(index, local(index, .{

        .kind = .pointer,
        .code = buttons,

    }));

}

/// Acts on buttons that went down or up since the last event.
fn press(code: u8) void {

    const change = buttons ^ code;

    buttons = code;

    for (0..3) |button| {

        if (change >> @intCast(button) & 1 == 0) continue;

        const pressed = code >> @intCast(button) & 1 != 0;

        const event = api.Event{

            .kind = .button,
            .pressed = pressed,
            .code = @intCast(button),
            .modifiers = modifiers,

        };

        if (!pressed) {

            if (button == 0) release();

            if (capture) |index| {

                queue(index, local(index, event));
                if (button == 0) capture = null;

            }

            continue;

        }

        const found = under(pointer);

        // A press outside an app's own surfaces closes its popups; inside them, the app decides.
        shut(if (found) |target| surfaces[target].client else 0);

        const index = found orelse continue;
        const surface = &surfaces[index];

        if (button == 0) {

            if (surface.layer == .window or surface.layer == .overlay) {

                raise(index);
                focus(index);

            }

            switch (part(index, pointer)) {

                .content => capture = index,
                .title => {

                    const now = api.ticks();

                    if (titled == index and now - titled_at < 40) {

                        titled = null;
                        if (!surface.options.fixed) toggle(index);

                        continue;

                    }

                    titled = index;
                    titled_at = now;
                    grab(index, .{});

                    continue;

                },
                .edge => {

                    // A half-screen window resized by hand stays where it is left.
                    surface.tile = .free;
                    grab(index, edges(index, pointer));
                    continue;

                },
                else => |control_part| {

                    armed = .{

                        .index = index,
                        .part = control_part,

                    };

                    continue;

                },

            }

        } else if (!surface.area.contains(pointer)) {

            continue;

        }

        queue(index, local(index, event));

    }

}

/// Ends a drag, tiling the window if it was dropped at an edge, or runs the title bar control the press began on if the pointer is still over it.
fn release() void {

    if (grabbed) |held| if (aimed != .free) {

        compose(aimed.zone().?);
        arrange(held.index, aimed);
        aimed = .free;

    };

    grabbed = null;

    const pending = armed orelse return;

    armed = null;
    if (under(pointer) != pending.index or part(pending.index, pointer) != pending.part) return;

    switch (pending.part) {

        .minimize => minimize(pending.index),
        .maximize => toggle(pending.index),
        .close => queue(pending.index, .{

            .kind = .close,

        }),
        else => {

        },

    }

}

/// Starts moving window `index`, or resizing it by `sides` when any are set.
fn grab(index: usize, sides: Edges) void {

    grabbed = .{

        .index = index,
        .start = pointer,
        .origin = surfaces[index].area,
        .edges = sides,

    };

}

fn follow(grab_state: Grab) void {

    const surface = &surfaces[grab_state.index];
    const dx = pointer.x - grab_state.start.x;
    const dy = pointer.y - grab_state.start.y;
    const origin = grab_state.origin;
    const sides = grab_state.edges;
    var area = origin;

    // Dragging a tiled window by its title puts it back to its own size under the pointer, once it really moves.
    if (surface.tile != .free and @as(u4, @bitCast(sides)) == 0) {

        if (@abs(dx) + @abs(dy) < 6) return;

        const ratio = @as(f32, @floatFromInt(pointer.x - surface.area.x)) / @as(f32, @floatFromInt(@max(surface.area.width, 1)));

        area = surface.restore;
        area.x = pointer.x - @as(i32, @intFromFloat(ratio * @as(f32, @floatFromInt(area.width))));
        area.y = surface.area.y;
        surface.tile = .free;
        reshape(grab_state.index, area);
        changed = true;
        grab(grab_state.index, .{});

        return;

    }

    if (@as(u4, @bitCast(sides)) == 0) {

        const before = surface.footprint();
        const target = aim(pointer);

        area.x += dx;
        area.y = std.math.clamp(origin.y + dy, work().y + gui.px(theme.title), @as(i32, @intCast(back.height)) - border);
        surface.area = area;
        compose(before.join(surface.footprint()));

        // Reaching an edge outlines where the window would tile.
        if (target != aimed and !surface.options.fixed) {

            if (aimed.zone()) |zone| compose(zone);
            if (target.zone()) |zone| compose(zone);
            aimed = target;

        }

        return;

    }

    if (sides.left) {

        area.width = @max(origin.width - dx, gui.px(least.width));
        area.x = origin.x + origin.width - area.width;

    }

    if (sides.right) area.width = @max(origin.width + dx, gui.px(least.width));

    if (sides.top) {

        area.height = @max(origin.height - dy, gui.px(least.height));
        area.y = @max(origin.y + origin.height - area.height, work().y + gui.px(theme.title));
        area.height = origin.y + origin.height - area.y;

    }

    if (sides.bottom) area.height = @max(origin.height + dy, gui.px(least.height));

    reshape(grab_state.index, area);

}

/// Gives surface `index` a new area, redraws, and tells its client the new size.
fn reshape(index: usize, area: gui.Rect) void {

    const surface = &surfaces[index];
    const before = surface.footprint();
    const sized = area.width != surface.area.width or area.height != surface.area.height;

    surface.area = area;
    if (sized) tell(index);
    compose(before.join(surface.footprint()));

}

/// Maximises window `index` into the work area, or puts it back.
fn toggle(index: usize) void {

    arrange(index, if (surfaces[index].tile == .full) .free else .full);

}

/// Fits window `index` as `tile` says, remembering where it was, or puts it back where it was when `free`.
fn arrange(index: usize, tile: Tile) void {

    const surface = &surfaces[index];
    if (surface.options.fixed or surface.tile == tile) return;

    if (surface.tile == .free) surface.restore = surface.area;
    surface.tile = tile;
    reshape(index, if (tile.zone()) |zone| inside(zone) else surface.restore);
    changed = true;

}

/// Where a window dragged with the pointer at `at` would tile: maximised at the top edge, a half at either side.
fn aim(at: gui.Point) Tile {

    if (at.y <= 0) return .full;
    if (at.x <= 0) return .left;
    if (at.x >= @as(i32, @intCast(back.width)) - 1) return .right;

    return .free;

}

/// Whether the tiling outline goes just under surface `index`, the window being dragged.
fn aiming(index: usize) bool {

    return aimed != .free and grabbed != null and grabbed.?.index == index;

}

/// Records the translucent outline of where the dragged window would tile, in screen coordinates.
fn guide() gui.draw.List {

    var list = gui.draw.List{

        .bytes = &outline_bytes,
        .width = @intCast(back.width),
        .height = @intCast(back.height),

    };

    const zone = (aimed.zone() orelse return list).inset(8);

    list.round(zone, gui.px(theme.corner) + 2, gui.shade(0xffffff, 40));
    list.round(zone.inset(2), gui.px(theme.corner), gui.shade(0x000000, 60));

    return list;

}

fn minimize(index: usize) void {

    const surface = &surfaces[index];
    if (surface.minimized) return;

    surface.minimized = true;
    if (hot != null and hot.?.index == index) hot = null;
    if (!begin(index, .minimize, null, motion.shrink(surface.footprint(), dock()), motion.tuck)) compose(surface.footprint());
    if (focused == index) refocus();
    changed = true;

}

/// Where keys go: an overlay above everything, else the topmost popup, else the focused window.
fn keyboard() ?usize {

    if (depth == 0) return null;

    const top = stack[depth - 1];
    if (surfaces[top].layer == .overlay and !surfaces[top].leaving) return top;

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.layer == .popup and surface.visible()) return stack[position];
        if (@intFromEnum(surface.layer) < @intFromEnum(Layer.popup)) break;

    }

    const index = focused orelse return null;

    return if (surfaces[index].minimized) null else index;

}

/// Queues `event` for the client of surface `index`.
fn queue(index: usize, event: api.Event) void {

    const owner = client(surfaces[index].client) orelse return;
    const capacity = owner.events.len;

    const item = Item{

        .surface = @intCast(index),
        .event = event,

    };

    // Only the latest position or size matters, so consecutive ones collapse.
    if (owner.queued != 0) {

        const last = &owner.events[(owner.head + owner.queued - 1) % capacity];

        if (last.surface == item.surface and last.event.kind == event.kind and (event.kind == .pointer or event.kind == .resize or (event.kind == .notice and last.event.code == event.code))) {

            last.* = item;
            return;

        }

    }

    // A client this far behind has stopped reading; its oldest input goes first.
    if (owner.queued == capacity) {

        if (!owner.behind) api.log("display: a window stopped reading input; dropping its oldest\n");
        owner.behind = true;
        owner.head = (owner.head + 1) % capacity;
        owner.queued -= 1;

    }

    owner.events[(owner.head + owner.queued) % capacity] = item;
    owner.queued += 1;

}

fn deliver(owner: *Client) void {

    const request = owner.waiting orelse return;
    if (owner.queued == 0) return;

    const item = owner.events[owner.head];
    const which: u64 = item.surface;

    owner.waiting = null;

    api.store(request, 0, std.mem.asBytes(&which)) catch {

    };

    // A timed-out wait keeps its event for the next one.
    api.reply(request, @bitCast(item.event)) catch |err| {

        if (err == error.Missing) drop(owner.id);
        return;

    };

    owner.head = (owner.head + 1) % owner.events.len;
    owner.queued -= 1;

}

/// Tells the session the window list changed, once per batch of changes.
fn announce() void {

    if (!changed) return;

    changed = false;
    inform(.windows);

}

/// Sends the session `notice` through the first of its surfaces.
fn inform(notice: api.Event.Notice) void {

    const owner = session();
    if (owner == 0) return;

    for (stack[0..depth]) |index| {

        if (surfaces[index].client != owner or surfaces[index].leaving) continue;

        queue(index, .{

            .kind = .notice,
            .code = @intFromEnum(notice),

        });

        deliver(client(owner).?);

        return;

    }

}

/// Tells surface `index`'s client its new size.
fn tell(index: usize) void {

    const area = surfaces[index].area;

    queue(index, .{

        .kind = .resize,
        .x = @intCast(area.width),
        .y = @intCast(area.height),

    });

    deliver(client(surfaces[index].client).?);

}

/// The client record for process `id`, made on first use; null when the table is full.
fn client(id: u64) ?*Client {

    for (&clients) |*owner| {

        if (owner.id == id) return owner;

    }

    for (&clients) |*owner| {

        if (owner.id != 0) continue;

        reset(owner, id);

        return owner;

    }

    return null;

}

/// Empties a client record field by field; a whole new record would cost a 2 KiB temporary on our 16 KiB stack.
fn reset(owner: *Client, id: u64) void {

    owner.id = id;
    owner.head = 0;
    owner.queued = 0;
    owner.waiting = null;
    owner.behind = false;

}

/// Puts surface `index` on top of the others in its layer.
fn insert(index: usize) void {

    const layer = @intFromEnum(surfaces[index].layer);
    var position = depth;

    while (position > 0 and @intFromEnum(surfaces[stack[position - 1]].layer) > layer) position -= 1;

    std.mem.copyBackwards(usize, stack[position + 1 .. depth + 1], stack[position..depth]);
    stack[position] = index;
    depth += 1;

}

fn remove(index: usize) void {

    const position = std.mem.indexOfScalar(usize, stack[0..depth], index) orelse return;

    std.mem.copyForwards(usize, stack[position .. depth - 1], stack[position + 1 .. depth]);
    depth -= 1;

}

fn raise(index: usize) void {

    if (stack[depth - 1] == index) return;

    remove(index);
    insert(index);
    compose(surfaces[index].footprint());
    if (surfaces[index].decorated()) changed = true;

}

/// Sends keys to surface `index` and repaints the title bars that changed.
fn focus(index: ?usize) void {

    const previous = focused;
    if (previous == index) return;

    focused = index;
    changed = true;

    // Another app's window coming forward means the pointer or keys went elsewhere.
    if (index) |target| shut(surfaces[target].client);

    for ([_]?usize{ previous, index }) |entry| {

        const target = entry orelse continue;

        if (surfaces[target].decorated()) compose(surfaces[target].frame());

    }

}

/// Focuses the topmost window still showing, if any.
fn refocus() void {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.layer == .window and !surface.minimized and !surface.leaving) return focus(stack[position]);

    }

    focus(null);

}

/// Takes surface `index` out of input and focus at once, and off the screen once it has played out, if it moves.
fn close(index: usize) void {

    const surface = &surfaces[index];
    if (surface.leaving) return;

    if (grabbed != null and grabbed.?.index == index) {

        if (aimed.zone()) |zone| compose(zone);
        grabbed = null;
        aimed = .free;

    }

    if (hot != null and hot.?.index == index) hot = null;
    if (armed != null and armed.?.index == index) armed = null;
    if (capture == index) capture = null;
    if (hovered == index) hovered = null;

    // Its client may already be gone, but the display's own hold keeps the commands it last presented.
    const shown = surface.visible();

    surface.leaving = true;
    if (surface.decorated()) changed = true;

    if (focused == index) {

        focused = null;
        refocus();

    }

    if (shown) if (motion.away(surface.movement())) |away| if (begin(index, .leave, null, away.pose, away.length)) return;

    free(index);

}

/// Frees the slot of surface `index`, closed and done showing.
fn free(index: usize) void {

    const surface = &surfaces[index];

    compose(surface.footprint().join(surface.painted));
    remove(index);
    api.detach(surface.memory.handle);
    surface.* = .{};

}

/// Starts surface `index` moving from `from`, or the pose it shows in, to `to`; false, leaving it be, without a GPU to animate it.
fn begin(index: usize, purpose: motion.Purpose, from: ?motion.Pose, to: motion.Pose, length: u64) bool {

    if (renderer == null) return false;

    const surface = &surfaces[index];

    if (from) |pose| surface.pose = pose;
    surface.transition = motion.Transition.begin(purpose, surface.pose, to, length);
    surface.painted = surface.pose.bounds(surface.footprint());
    compose(surface.painted);

    return true;

}

/// Moves every surface in transition on to its pose for this tick, and ends those done; true while any still moves.
fn animate() bool {

    const now = api.ticks();
    var moving = false;

    // By slot rather than by stack, since freeing a surface done leaving restacks.
    for (&surfaces, 0..) |*surface, index| {

        const current = surface.transition orelse continue;

        if (current.done(now)) {

            conclude(index);
            continue;

        }

        const pose = current.pose(now);
        const area = pose.bounds(surface.footprint());

        moving = true;
        if (std.meta.eql(pose, surface.pose) and std.meta.eql(area, surface.painted)) continue;

        compose(surface.painted.join(area));
        surface.pose = pose;
        surface.painted = area;

    }

    return moving;

}

/// Ends surface `index`'s transition where it was headed; one leaving is freed.
fn conclude(index: usize) void {

    const surface = &surfaces[index];
    const current = surface.transition orelse return;

    surface.transition = null;
    surface.pose = current.to;
    compose(surface.painted.join(surface.footprint()));

    if (current.purpose == .leave) free(index);

}

/// Slides panels with the `tuck` option, such as the dock, away while the topmost window is tiled, and back while the pointer
/// rests at the bottom of the screen, staying until it leaves them.
fn hideaway() void {

    var covered = false;
    var position = depth;

    // The topmost window rather than the focused one, since panels such as notifications take focus as they appear.
    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (!surface.decorated() or !surface.visible()) continue;

        covered = surface.tile != .free;
        break;

    }

    const bottom: i32 = @intCast(back.height);

    for (&surfaces, 0..) |*surface, index| {

        if (!surface.options.tuck or surface.client == 0 or !surface.shown or surface.leaving) continue;

        // A drag reaching the bottom, such as of a window, leaves a tucked panel be.
        const reached = if (surface.tucked) buttons == 0 and pointer.y >= bottom - brink else pointer.y >= surface.area.y - gui.px(grip);
        const tuck = covered and !reached;

        if (tuck == surface.tucked) continue;

        surface.tucked = tuck;
        if (!begin(index, if (tuck) .minimize else .restore, null, if (tuck) motion.sink(surface.area, bottom) else .rest, motion.slide)) compose(surface.footprint());

    }

}

/// Where minimised windows fly to: the middle of the row the session keeps at the bottom for its dock.
fn dock() gui.Point {

    return .{

        .x = @divTrunc(@as(i32, @intCast(back.width)), 2),
        .y = @as(i32, @intCast(back.height)) - @divTrunc(reserved[1], 2),

    };

}

/// Forgets everything of client `id`; its surfaces still leaving play out.
fn drop(id: u64) void {

    for (&surfaces, 0..) |*surface, index| {

        if (surface.client == id) close(index);

    }

    for (&pictures, 0..) |*picture, slot| {

        if (picture.client == id) discard(slot);

    }

    for (&clients) |*owner| {

        if (owner.id == id) reset(owner, 0);

    }

}

/// Drops the surfaces and images of clients that exited.
fn prune() void {

    sweep = api.ticks() + 25;

    for (&clients) |*owner| {

        if (owner.id != 0 and !api.alive(owner.id)) drop(owner.id);

    }

    for (&pictures) |*picture| {

        if (picture.client != 0 and !api.alive(picture.client)) drop(picture.client);

    }

}

fn discard(slot: usize) void {

    if (renderer) |*device| device.discard(slot);
    api.detach(pictures[slot].memory.handle);
    pictures[slot] = .{};

}

fn find(owner: u64, handle: u64) ?usize {

    for (&pictures, 0..) |*picture, slot| {

        if (picture.client == owner and picture.handle == handle and owner != 0) return slot;

    }

    return null;

}

/// The texture slot of image `handle` of the client being drawn.
fn texture(handle: u64) ?usize {

    return find(drawing, handle);

}

/// The pixels of image `handle` of the client being drawn.
fn pixels(handle: u64) ?*const gui.Canvas {

    return &pictures[find(drawing, handle) orelse return null].canvas;

}

/// Records the shadow, title bar, and border of window `index` in footprint coordinates; empty for other layers.
fn trim(index: usize) gui.draw.List {

    const surface = &surfaces[index];
    const footprint = surface.footprint();

    var list = gui.draw.List{

        .bytes = &chrome,
        .width = footprint.width,
        .height = footprint.height,

    };

    const active = focused == index;

    const frame = gui.draw.move(surface.frame(), .{

        .x = -footprint.x,
        .y = -footprint.y,

    });

    var below = frame;
    const radius = surface.rounding();
    const curve = surface.curve();

    // A soft shadow a little below the frame, darker under the window in front.
    below.y += 3;
    if (surface.options.shadow or surface.decorated()) list.shadow(below, radius, gui.px(spread) - 4, gui.shade(0x000000, if (active and surface.decorated()) 96 else 64));
    if (!surface.decorated()) return list;

    const bar = gui.Rect{

        .x = frame.x,
        .y = frame.y,
        .width = frame.width,
        .height = gui.px(theme.title),

    };

    // The title bar and its controls are the frame's rounded inside, cut to their own rectangles.
    const within = frame.inset(border);

    // The frame is Quartz, which content its app paints opaque hides but for the title bar; there, a window growing faster than its app
    // redraws shows a plain background rather than what lay behind.
    list.limit = if (surface.covered) bar else null;
    list.quartz(frame, radius, theme.quartz);

    if (surface.covered) {

        list.limit = gui.draw.move(surface.area, .{

            .x = -footprint.x,
            .y = -footprint.y,

        });

        list.round(within, curve, theme.background);

    }

    list.limit = bar.inset(border);
    list.round(within, curve, theme.pane);
    list.limit = null;
    list.outline(frame, @floatFromInt(radius), border, if (active) theme.selected else theme.line);
    list.limit = bar.inset(border);

    // Controls sit right to left: close, then maximise unless fixed, then minimise.
    var right = bar.right() - border;

    for ([_]Part{ .close, .maximize, .minimize }) |which| {

        if (which == .maximize and surface.options.fixed) continue;

        const spot = gui.Rect{

            .x = right - gui.px(control),
            .y = bar.y + border,
            .width = gui.px(control),
            .height = gui.px(theme.title) - border,

        };

        const lit = hot != null and hot.?.index == index and hot.?.part == which;

        if (lit) {

            list.limit = spot;
            list.round(within, curve, if (which == .close) theme.danger else theme.hover);
            list.limit = bar.inset(border);

        }

        list.icon(switch (which) {

            .close => .close,
            .maximize => .maximize,
            else => .minimize,

        }, @as(f32, if (which == .maximize) 12 else 15) * gui.style.factor(), spot, if (lit and which == .close) 0xffffff else if (active) theme.text else theme.muted);

        right -= gui.px(control);

    }

    list.limit = .{

        .x = bar.x,
        .y = bar.y,
        .width = right - bar.x,
        .height = bar.height,

    };

    list.label(surface.name(), .sans, theme.small * gui.style.factor(), .{

        .x = bar.x + gui.px(theme.spacing),
        .y = bar.y,
        .width = right - bar.x - gui.px(theme.spacing),
        .height = gui.px(theme.title),

    }, if (active) theme.text else theme.muted, .left);

    list.limit = null;

    return list;

}

/// Which part of surface `index` is at `at`: the grip reaches a little inside the frame, but never over the title bar's controls.
fn part(index: usize, at: gui.Point) Part {

    const surface = &surfaces[index];
    if (!surface.decorated()) return .content;

    const frame = surface.frame();
    if (surface.resizable() and !frame.inset(hold).contains(at) and !surface.controls().contains(at)) return .edge;
    if (surface.area.contains(at)) return .content;
    if (at.y >= frame.y + gui.px(theme.title) or at.x < frame.x + border) return .title;

    const slot = @divTrunc(frame.right() - border - 1 - at.x, gui.px(control));
    const fixed = surface.options.fixed;

    return switch (slot) {

        0 => .close,
        1 => if (fixed) .minimize else .maximize,
        2 => if (fixed) .title else .minimize,
        else => .title,

    };

}

/// Which edges of window `index` the pointer at `at` holds; near a corner, both of its edges.
fn edges(index: usize, at: gui.Point) Edges {

    const frame = surfaces[index].frame();

    var sides = Edges{

        .left = at.x < frame.x + hold,
        .right = at.x >= frame.right() - hold,
        .top = at.y < frame.y + hold,
        .bottom = at.y >= frame.bottom() - hold,

    };

    if (sides.left or sides.right) {

        sides.top = sides.top or at.y < frame.y + gui.px(corner_grip);
        sides.bottom = sides.bottom or at.y >= frame.bottom() - gui.px(corner_grip);

    }

    if (sides.top or sides.bottom) {

        sides.left = sides.left or at.x < frame.x + gui.px(corner_grip);
        sides.right = sides.right or at.x >= frame.right() - gui.px(corner_grip);

    }

    return sides;

}

/// Whether `which` part of a title bar lights up under the pointer.
fn lights(which: Part) bool {

    return which == .minimize or which == .maximize or which == .close;

}

/// What the pointer shows where it is: a resizing arrow or a hand on a window's frame, else what the surface's client asked for.
fn appearance() gui.Cursor {

    if (grabbed) |held| return if (@as(u4, @bitCast(held.edges)) == 0) .grabbing else stretching(held.edges);

    // A press in a surface's content keeps its pointer until release, wherever it goes.
    const index = capture orelse under(pointer) orelse return .arrow;

    const chosen = if (capture != null) surfaces[index].cursor else switch (part(index, pointer)) {

        .content => surfaces[index].cursor,
        .title => .grab,
        .edge => stretching(edges(index, pointer)),
        else => .hand,

    };

    // A launch shows busy in place of the pointers that only point.
    return if (launching != 0 and (chosen == .arrow or chosen == .hand)) .busy else chosen;

}

fn stretching(sides: Edges) gui.Cursor {

    if (sides.left and sides.top or sides.right and sides.bottom) return .falling;
    if (sides.right and sides.top or sides.left and sides.bottom) return .rising;

    return if (sides.left or sides.right) .horizontal else .vertical;

}

/// Shows the pointer `appearance` picks, once it changes, and lets a launch's busy pointer lapse.
fn dress() void {

    if (launching != 0 and api.ticks() >= launching) launching = 0;

    const wanted = appearance();
    if (wanted == look) return;

    const before = sprite(pointer);

    look = wanted;

    switch (screen) {

        .svga => |*device| wear(device),
        .frame => |*frame| frame.present(&back, before.join(sprite(pointer))),

    }

}

/// Gives the adapter's own pointer the image of `look`, where the pointer is.
fn wear(device: *svga.Device) void {

    const worn = gui.cursor.sprite(look);

    device.shape(worn.pixels, worn.width, worn.height, worn.hotspot);
    if (located) device.point(pointer);

}

/// The screen minus the rows the session keeps.
fn work() gui.Rect {

    return .{

        .y = reserved[0],
        .width = @intCast(back.width),
        .height = @as(i32, @intCast(back.height)) - reserved[0] - reserved[1],

    };

}

/// The content area of a window whose frame fills `area`.
fn inside(area: gui.Rect) gui.Rect {

    return .{

        .x = area.x + border,
        .y = area.y + gui.px(theme.title),
        .width = area.width - 2 * border,
        .height = area.height - gui.px(theme.title) - border,

    };

}

/// Where client `owner`'s popup asking for `area` goes: moved from its `anchor` surface's content to the screen, then kept wholly on it.
fn pop(owner: u64, anchor: u8, area: gui.Rect) gui.Rect {

    var result = area;

    if (anchor < surfaces.len and surfaces[anchor].client == owner and !surfaces[anchor].leaving) {

        result.x += surfaces[anchor].area.x;
        result.y += surfaces[anchor].area.y;

    }

    const width: i32 = @intCast(back.width);
    const height: i32 = @intCast(back.height);

    result.x = @max(@min(result.x, width - result.width - gui.px(theme.gap)), gui.px(theme.gap));
    result.y = @max(@min(result.y, height - result.height - gui.px(theme.gap)), gui.px(theme.gap));

    return result;

}

/// Closes every popup but those of client `keep`, as a press elsewhere or another window taking focus does.
fn shut(keep: u64) void {

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];

        if (surface.layer == .popup and surface.visible() and surface.client != keep) queue(index, .{

            .kind = .close,

        });

    }

}

/// Where a new window of `area`'s size goes: centred in the work area, stepped down from others, and shrunk to fit.
fn arrival(area: gui.Rect) gui.Rect {

    const room = inside(work());
    var count: i32 = 0;

    for (surfaces) |surface| {

        if (surface.client != 0 and surface.decorated() and !surface.leaving) count += 1;

    }

    const width = std.math.clamp(area.width, gui.px(least.width), room.width);
    const height = std.math.clamp(area.height, gui.px(least.height), room.height);
    const step = @mod(count, 6) * 24 - 60;
    var placed = room.centered(width, height);

    placed.x = std.math.clamp(placed.x + step, room.x, room.right() - width);
    placed.y = std.math.clamp(placed.y + step, room.y, room.bottom() - height);

    return placed;

}

fn name(surface: *Surface, spec: api.display.Spec) void {

    const title = spec.name();

    surface.length = title.len;
    @memcpy(surface.title[0..title.len], title);

}

fn outline(area: gui.Rect) gui.Rect {

    return .{

        .x = area.x - border,
        .y = area.y - gui.px(theme.title),
        .width = area.width + 2 * border,
        .height = area.height + gui.px(theme.title) + border,

    };

}

/// The client holding the background, panels, or overlay: the signed-in session; 0 when there is none.
fn session() u64 {

    for (surfaces) |surface| {

        if (surface.client != 0 and !surface.decorated() and surface.layer != .popup) return surface.client;

    }

    return 0;

}

/// Background, panel, and overlay surfaces cover other windows, so only one client, the session, may hold them; any app may show popups, which close as soon as the user presses elsewhere.
fn allowed(owner: u64, layer: Layer) bool {

    switch (layer) {

        .window, .popup => return true,
        .background, .panel, .overlay => {

        },
        _ => return false,

    }

    const holder = session();

    return holder == 0 or holder == owner;

}

fn fits(area: gui.Rect) bool {

    return area.width > 0 and area.height > 0 and area.width <= 8192 and area.height <= 8192;

}

fn under(at: gui.Point) ?usize {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.visible() and surface.reach().contains(at)) return stack[position];

    }

    return null;

}

fn move(x: i32, y: i32) void {

    const previous = pointer;

    pointer = .{

        .x = std.math.clamp(x, 0, @as(i32, @intCast(back.width)) - 1),
        .y = std.math.clamp(y, 0, @as(i32, @intCast(back.height)) - 1),

    };

    located = true;

    switch (screen) {

        .svga => |*device| device.point(pointer),
        .frame => |*frame| {

            frame.present(&back, sprite(previous));
            frame.present(&back, sprite(pointer));

        },

    }

}

fn owned(request: api.Request, id: u64) ?*Surface {

    if (id >= surfaces.len) return null;

    const surface = &surfaces[id];

    return if (surface.client != 0 and surface.client == request.first and !surface.leaving) surface else null;

}

fn local(index: usize, event: api.Event) api.Event {

    var result = event;
    const area = surfaces[index].area;

    result.x = @intCast(std.math.clamp(pointer.x - area.x, -32768, 32767));
    result.y = @intCast(std.math.clamp(pointer.y - area.y, -32768, 32767));

    return result;

}

fn fetch(request: api.Request, comptime T: type) ?T {

    var value = std.mem.zeroes(T);

    api.fetch(request, 0, std.mem.asBytes(&value)) catch return null;

    return value;

}

fn rect(area: api.display.Area) gui.Rect {

    return .{

        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = area.height,

    };

}

fn wire(from: gui.Rect) api.display.Area {

    return .{

        .x = from.x,
        .y = from.y,
        .width = from.width,
        .height = from.height,

    };

}

fn corner(area: gui.Rect) gui.Point {

    return .{

        .x = area.x,
        .y = area.y,

    };

}

/// Where the pointer's image covers the screen when it points at `at`.
fn sprite(at: gui.Point) gui.Rect {

    const worn = gui.cursor.sprite(look);

    return .{

        .x = at.x - worn.hotspot.x,
        .y = at.y - worn.hotspot.y,
        .width = @intCast(worn.width),
        .height = @intCast(worn.height),

    };

}
