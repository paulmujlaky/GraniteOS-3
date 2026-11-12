const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;

/// A pixel rectangle as it travels between clients and the display.
pub const Area = extern struct {

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

};

/// Where a surface stacks; the window manager decorates `window` surfaces and lets users move and resize them.
pub const Layer = enum(u8) {

    background,
    window,

    /// Undecorated chrome above windows, such as bars, docks, and launchers.
    panel,

    /// Short-lived lists above everything but overlays, such as menus; any app may show one, which takes the keys while it shows.
    /// A press anywhere outside the app's own surfaces closes it with a `close` event.
    popup,

    overlay,
    _,

};

pub const Options = packed struct(u8) {

    /// Follows the screen's size, such as a wallpaper.
    fill: bool = false,

    /// Keeps its size: no resizing or maximising.
    fixed: bool = false,

    /// Casts a soft shadow, as windows do; for undecorated surfaces such as menus.
    shadow: bool = false,

    /// Slides away beneath tiled windows until the pointer reaches the bottom of the screen, as the dock does; for panels.
    tuck: bool = false,

    reserved: u4 = 0,

};

/// How a surface comes onto and leaves the screen; the display animates it on the GPU, and shows it at once without one.
pub const Motion = enum(u8) {

    /// Windows zoom; other layers, and surfaces filling the screen, show at once.
    auto,
    none,

    /// Fades while growing slightly into place.
    zoom,

    /// Fades while sliding down into place, like a menu hanging from a bar.
    drop,

    /// Fades while sliding up into place, like a sheet rising from a dock.
    rise,

    fade,
    _,

};

/// How a surface asks to be shown: `area` is its content in screen coordinates.
pub const Spec = extern struct {

    area: Area = .{},
    layer: Layer = .window,
    options: Options = .{},

    /// The app it belongs to as an `abi.Image` index, so the session can group windows; `none` otherwise.
    application: u8 = none,
    motion: Motion = .auto,

    /// A popup's `area` is relative to the content of this surface of the same app, such as the window a menu opens in; `none` for the screen.
    anchor: u8 = none,

    length: u8 = 0,
    title: [64]u8 = undefined,

    pub const none = 0xff;

    pub fn init(area: Area, layer: Layer, title: []const u8) Spec {

        var spec = Spec{

            .area = area,
            .layer = layer,

        };

        spec.rename(title);

        return spec;

    }

    pub fn rename(self: *Spec, title: []const u8) void {

        self.length = @intCast(@min(title.len, self.title.len));
        @memcpy(self.title[0..self.length], title[0..self.length]);

    }

    pub fn name(self: *const Spec) []const u8 {

        return self.title[0..@min(self.length, self.title.len)];

    }

};

/// A decorated window as the session sees it, for docks and switchers.
pub const Window = extern struct {

    id: u32 = 0,
    application: u8 = Spec.none,
    state: State = .{},
    length: u8 = 0,
    title: [64]u8 = undefined,

    /// Its frame on the screen, title bar included.
    area: Area = .{},

    pub const State = packed struct(u8) {

        focused: bool = false,
        minimized: bool = false,
        maximized: bool = false,
        reserved: u5 = 0,

    };

    pub fn name(self: *const Window) []const u8 {

        return self.title[0..@min(self.length, self.title.len)];

    }

};

/// What the session may do to another client's window.
pub const Action = enum(u8) {

    /// Restores, raises, and focuses it.
    raise,
    minimize,

    /// Asks its app to close it.
    close,
    _,

};

/// What draws the screen: the graphics device and how the display uses it.
pub const Adapter = struct {

    kind: Kind = .framebuffer,

    /// The PCI device id, for telling models apart.
    device: u16 = 0,

    pub const Kind = enum(u8) {

        /// The firmware's framebuffer, drawn by the CPU.
        framebuffer,

        /// VMware's SVGA II, drawn by the CPU.
        svga,

        /// VMware's SVGA II with its 3D GPU drawing.
        accelerated,

        /// Intel integrated graphics, showing the firmware's framebuffer drawn by the CPU until the GPU is driven.
        intel,

        _,

    };

    /// What people call it, such as `Intel UHD Graphics 630`.
    pub fn name(self: Adapter) []const u8 {

        return switch (self.kind) {

            .svga, .accelerated => "VMware SVGA II",
            .intel => switch (self.device) {

                0x3e91, 0x3e92, 0x3e98, 0x9bc5, 0x9bc8 => "Intel UHD Graphics 630",
                else => "Intel graphics",

            },
            else => "Firmware framebuffer",

        };

    }

    /// How it draws, such as `GPU-accelerated`.
    pub fn rendering(self: Adapter) []const u8 {

        return if (self.kind == .accelerated) "GPU-accelerated" else "drawn by the CPU";

    }

};

/// An input event and the surface it is for.
pub const Input = struct {

    surface: u64,
    event: api.Event,

};

/// The display service from a client's side: screen size, surfaces, their drawing, and input events.
pub const Display = struct {

    endpoint: u64 = 0,

    pub fn size(self: *Display) api.ServiceError!Area {

        const value = try self.request(.info, 0, &.{});

        return .{

            .width = @intCast(value & 0xffff),
            .height = @intCast(value >> 16 & 0xffff),

        };

    }

    /// Shows the shared memory `handle`, two halves of drawing commands, as `spec` describes; returns the surface id.
    pub fn surface(self: *Display, handle: u64, spec: Spec) api.ServiceError!u64 {

        try self.share(handle);

        var placement = spec;

        return self.request(.surface, @intCast(handle), std.mem.asBytes(&placement));

    }

    /// What draws the screen.
    pub fn adapter(self: *Display) api.ServiceError!Adapter {

        const value = try self.request(.info, 0, &.{});

        return .{

            .kind = @enumFromInt(value >> 32 & 0xff),
            .device = @intCast(value >> 40 & 0xffff),

        };

    }

    /// Moves, resizes, restacks, or retitles surface `id`.
    pub fn place(self: *Display, id: u64, spec: Spec) api.ServiceError!void {

        var placement = spec;

        _ = try self.request(.place, @intCast(id), std.mem.asBytes(&placement));

    }

    /// The interface scale in percent, from 100 to 200.
    pub fn scale(self: *Display) api.ServiceError!i32 {

        const value: i32 = @intCast((try self.request(.info, 0, &.{})) >> 56);

        return if (value == 0) 100 else value;

    }

    /// Sets the interface scale to `percent`, a step of 25 from 100 to 200, and remembers it; every surface hears of it.
    pub fn rescale(self: *Display, percent: u8) api.ServiceError!void {

        _ = try self.request(.scale, percent, &.{});

    }

    /// Switches the screen to `width` by `height` and remembers it; administrators only.
    pub fn mode(self: *Display, width: u16, height: u16) api.ServiceError!void {

        _ = try self.request(.mode, @as(u56, height) << 16 | width, &.{});

    }

    /// Shows the first `length` bytes of commands in buffer half `half` of surface `id`; only the `changed` part of its content
    /// is drawn afresh, or all of it when null.
    pub fn present(self: *Display, id: u64, half: u1, length: usize, changed: ?Area) api.ServiceError!void {

        if (id > 0xff or length > 0xffff_ffff) return error.Invalid;

        var area = changed orelse Area{};
        const window: []u8 = if (changed == null) &.{} else std.mem.asBytes(&area);

        _ = try self.request(.present, @intCast(id | @as(u64, half) << 8 | @as(u64, length) << 9), window);

    }

    /// Shows pointer `look`, a `gui.Cursor`, while the pointer is over surface `id`'s content; with `id` `Spec.none`, the busy look
    /// shows everywhere until the next new window appears or a few seconds pass, as after launching an app.
    pub fn cursor(self: *Display, id: u64, look: u8) api.ServiceError!void {

        if (id > 0xff) return error.Invalid;

        _ = try self.request(.cursor, @intCast(id | @as(u64, look) << 8), &.{});

    }

    /// Waits up to `timeout` ticks for the next input event on any of our surfaces.
    pub fn wait(self: *Display, timeout: u64) api.ServiceError!?Input {

        const endpoint = try self.peer();
        var which: u64 = 0;

        var message = api.Request{

            .number = @intFromEnum(api.abi.Call.call),
            .first = endpoint,
            .second = protocol.pack(.wait, 0),
            .third = timeout,
            .fourth = @intFromPtr(&which),
            .fifth = @sizeOf(u64),

        };

        api.invoke(&message);

        const result = api.checked(message) catch |err| {

            if (err == error.Timeout) return null;
            self.endpoint = 0;

            return err;

        };

        if (result.first == protocol.invalid) return error.Invalid;

        return .{

            .surface = which,
            .event = @bitCast(result.first),

        };

    }

    /// Session only: lists the decorated windows into `out`, bottom to top; returns how many there are.
    pub fn windows(self: *Display, out: []Window) api.ServiceError!usize {

        return @min(try self.request(.windows, 0, std.mem.sliceAsBytes(out)), out.len);

    }

    /// Session only: raises, minimises, or closes window `id`.
    pub fn activate(self: *Display, id: u32, action: Action) api.ServiceError!void {

        _ = try self.request(.activate, @as(u56, @intFromEnum(action)) << 32 | id, &.{});

    }

    /// Session only: keeps `top` and `bottom` rows of the screen for bars and docks, out of maximised windows' way.
    pub fn reserve(self: *Display, top: u16, bottom: u16) api.ServiceError!void {

        _ = try self.request(.reserve, @as(u56, bottom) << 16 | top, &.{});

    }

    /// Session only: shows what lies behind Quartz, softened, or draws its tints solid, as the user chose.
    pub fn quartz(self: *Display, translucent: bool) api.ServiceError!void {

        _ = try self.request(.quartz, @intFromBool(translucent), &.{});

    }

    /// Session only: draws the accent as `gui.theme.accents[index]`, as the user chose.
    pub fn accent(self: *Display, index: u8) api.ServiceError!void {

        _ = try self.request(.accent, index, &.{});

    }

    /// Makes the shared pixels `handle`, `width` by `height` premultiplied 0xAARRGGBB, drawable by image commands; again after changing them,
    /// naming the `changed` area when only that did, so less goes to the GPU.
    pub fn image(self: *Display, handle: u64, width: u32, height: u32, changed: ?Area) api.ServiceError!void {

        try self.share(handle);

        const area = changed orelse Area{

            .width = @intCast(width),
            .height = @intCast(height),

        };

        var dimensions = [6]u32{ width, height, @bitCast(area.x), @bitCast(area.y), @bitCast(area.width), @bitCast(area.height) };

        _ = try self.request(.image, @intCast(handle), std.mem.asBytes(&dimensions));

    }

    /// Lets go of image `handle`.
    pub fn forget(self: *Display, handle: u64) void {

        _ = self.request(.forget, @intCast(handle), &.{}) catch {

        };

    }

    /// Session only: copies the whole screen into `out`, 0x00RRGGBB row after row, which must hold it; returns its size.
    pub fn capture(self: *Display, out: []u32) api.ServiceError!Area {

        const value = try self.request(.capture, 0, std.mem.sliceAsBytes(out));

        return .{

            .width = @intCast(value & 0xffff),
            .height = @intCast(value >> 16 & 0xffff),

        };

    }

    /// Replaces the clipboard with `bytes`.
    pub fn copy(self: *Display, bytes: []const u8) api.ServiceError!void {

        _ = try self.request(.clipboard, 1, @constCast(bytes));

    }

    /// Reads the clipboard into `out`.
    pub fn paste(self: *Display, out: []u8) api.ServiceError![]u8 {

        return out[0..@min(try self.request(.clipboard, 0, out), out.len)];

    }

    fn share(self: *Display, handle: u64) api.ServiceError!void {

        api.lend(handle, try self.peer()) catch |err| {

            self.endpoint = 0;
            return err;

        };

    }

    fn peer(self: *Display) api.ApiError!u64 {

        if (self.endpoint == 0) self.endpoint = try api.lookup(0, .display);

        return self.endpoint;

    }

    fn request(self: *Display, operation: protocol.Operation, value: u56, window: []u8) api.ServiceError!u64 {

        const endpoint = try self.peer();

        const result = api.exchange(endpoint, protocol.pack(operation, value), window) catch |err| {

            self.endpoint = 0;
            return err;

        };

        return switch (result) {

            protocol.invalid => error.Invalid,
            protocol.denied => error.Denied,
            protocol.full => error.Full,
            protocol.missing => error.Missing,
            else => result,

        };

    }

};
