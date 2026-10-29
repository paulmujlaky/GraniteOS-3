//! The desktop's apps as people see them, and which app opens which file.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");
const media = @import("media");

const Image = api.abi.Image;

/// The groups the launcher sorts apps into.
pub const Category = enum {

    productivity,
    creative,
    internet,
    system,

    pub fn title(self: Category) []const u8 {

        return switch (self) {

            .productivity => "Productivity",
            .creative => "Creative",
            .internet => "Internet",
            .system => "System",

        };

    }

    pub fn icon(self: Category) gui.Icon {

        return switch (self) {

            .productivity => .document,
            .creative => .palette,
            .internet => .globe,
            .system => .cpu,

        };

    }

};

/// What an app changed, so the desktop reads only that again; sent with `reload`. Settings changes the `desktop` config, and
/// Weather the brief the quick settings show.
pub const Reload = enum(u8) {

    all,
    quartz,
    weather,

};

pub const App = struct {

    image: Image,
    category: Category,
    title: []const u8,
    icon: gui.Icon,
    summary: []const u8,

};

pub const apps = [_]App{

    .{ .image = .explorer, .category = .system, .title = "Files", .icon = .folder, .summary = "Browse and organise your files" },
    .{ .image = .editor, .category = .productivity, .title = "Editor", .icon = .edit, .summary = "Write text and code" },
    .{ .image = .terminal, .category = .system, .title = "Terminal", .icon = .terminal, .summary = "Run OBSIDIAN shell commands" },
    .{ .image = .viewer, .category = .creative, .title = "Viewer", .icon = .image, .summary = "Look at pictures" },
    .{ .image = .player, .category = .creative, .title = "Player", .icon = .music, .summary = "Play music and videos" },
    .{ .image = .drawing, .category = .creative, .title = "Drawing", .icon = .brush, .summary = "Sketch and paint pictures" },
    .{ .image = .calculator, .category = .productivity, .title = "Calculator", .icon = .calculator, .summary = "Work out sums" },
    .{ .image = .clock, .category = .productivity, .title = "Clock", .icon = .clock, .summary = "World time, stopwatch, and timer" },
    .{ .image = .calendar, .category = .productivity, .title = "Calendar", .icon = .calendar, .summary = "Months, weeks, and holidays" },
    .{ .image = .screenshots, .category = .creative, .title = "Screenshots", .icon = .cut, .summary = "Snip the screen and keep your screenshots" },
    .{ .image = .weather, .category = .internet, .title = "Weather", .icon = .cloud_sun, .summary = "Conditions and forecasts where you are" },
    .{ .image = .requests, .category = .internet, .title = "Requests", .icon = .send, .summary = "Send HTTP requests and read the replies" },
    .{ .image = .radio, .category = .internet, .title = "Radio", .icon = .radio, .summary = "Listen to radio stations from around the world" },
    .{ .image = .monitor, .category = .system, .title = "Monitor", .icon = .activity, .summary = "Watch processes, memory, and processors" },
    .{ .image = .settings, .category = .system, .title = "Settings", .icon = .settings, .summary = "Display, appearance, and accounts" },

};

/// The config the desktop keeps its pins in: `dock=` the dock's apps in order, and `item=COLUMN,ROW,TARGET` for each desktop item.
/// A target is an app by image name, or an absolute path ending in `/` for a folder.
pub const pins = "pins";

/// The dock's apps until someone changes them.
pub const docked = "explorer,settings";

/// An item on the desktop, in its grid cell.
pub const Item = struct {

    column: u8,
    row: u8,
    target: []const u8,

    /// Reads `COLUMN,ROW,TARGET` from the pins config.
    pub fn parse(line: []const u8) ?Item {

        var fields = std.mem.splitScalar(u8, line, ',');
        const column = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
        const row = std.fmt.parseInt(u8, fields.next() orelse return null, 10) catch return null;
        const target = fields.rest();

        if (target.len == 0) return null;

        return .{

            .column = column,
            .row = row,
            .target = target,

        };

    }

};

/// Whether `target` is on the desktop of user `owner`.
pub fn placed(owner: []const u8, target: []const u8) bool {

    shelf.open(owner, pins);

    var lines = shelf.all("item");

    while (lines.next()) |line| {

        const item = Item.parse(line) orelse continue;
        if (std.mem.eql(u8, item.target, target)) return true;

    }

    return false;

}

var shelf = api.Config{};

/// The app `target` names, if it names one rather than a path.
pub fn application(target: []const u8) ?*const App {

    return find(std.meta.stringToEnum(Image, target) orelse return null);

}

pub fn folder(target: []const u8) bool {

    return target.len > 1 and target[0] == '/' and target[target.len - 1] == '/';

}

/// What people call `target`: its app's title, or its file or folder name.
pub fn named(target: []const u8) []const u8 {

    if (application(target)) |app| return app.title;

    return std.fs.path.basenamePosix(std.mem.trimRight(u8, target, "/"));

}

pub fn badge(target: []const u8) gui.Icon {

    if (application(target)) |app| return app.icon;

    return symbol(named(target), folder(target));

}

/// Opens `target`: an app on `inside`, a folder in Files, or a file in the app that reads it.
pub fn open(target: []const u8, inside: []const u8) api.ServiceError!void {

    if (application(target)) |app| return start(app.image, inside);
    if (target.len < 2 or target[0] != '/') return error.Invalid;
    if (folder(target)) return start(.explorer, target[0 .. target.len - 1]);

    return start(opener(target), target);

}

/// Launches `image` with `argument`, the pointer showing busy until its window appears.
pub fn start(image: Image, argument: []const u8) api.ServiceError!void {

    gui.cursor.busy();
    _ = try api.launch(@tagName(image), argument);

}

pub fn find(image: Image) ?*const App {

    for (&apps) |*app| {

        if (app.image == image) return app;

    }

    return null;

}

/// The app that opens a file named `name`.
pub fn opener(name: []const u8) Image {

    if (picture(name)) return .viewer;

    return if (media.Kind.named(name) != null) .player else .editor;

}

/// Whether `name` looks like an image the viewer reads.
pub fn picture(name: []const u8) bool {

    return std.ascii.endsWithIgnoreCase(name, ".png");

}

/// The icon for a file named `name`, or a directory.
pub fn symbol(name: []const u8, directory: bool) gui.Icon {

    if (directory) return .folder;
    if (picture(name)) return .image;
    if (media.Kind.named(name)) |kind| return if (kind.moving()) .file_video else .file_audio;

    for ([_][]const u8{ ".zig", ".c", ".h", ".py", ".sh", ".json", ".js", ".rs", ".go" }) |extension| {

        if (std.ascii.endsWithIgnoreCase(name, extension)) return .code;

    }

    return if (std.ascii.endsWithIgnoreCase(name, ".txt") or std.ascii.endsWithIgnoreCase(name, ".md")) .document else .file;

}

/// The folder in each home that screenshots and snips are saved in.
pub const screenshots = "Screenshots";

/// What went wrong with a file, as people read it.
pub fn reason(err: api.ServiceError) []const u8 {

    return switch (err) {

        error.Missing => "Not found.",
        error.Exists => "Something with that name already exists.",
        error.Full => "The volume is full.",
        error.Busy => "Only empty folders can be deleted.",
        error.Denied => "Permission denied.",
        error.Invalid => "That can't be done here.",
        else => "The file service is unavailable.",

    };

}

pub const unnamed = "Names need a character or two, and no slashes.";

/// Whether `name` may name a file or folder.
pub fn valid(name: []const u8) bool {

    return name.len != 0 and name.len <= 200 and std.mem.indexOfScalar(u8, name, '/') == null and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");

}

/// A size in bytes as people read it, such as `4.2 KB`.
pub fn amount(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {

    const units = [_][]const u8{ "bytes", "KB", "MB", "GB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;

    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;

    if (unit == 0) return std.fmt.allocPrint(allocator, "{d} {s}", .{ bytes, units[0] });

    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ value, units[unit] });

}

/// The home directory `/home/NAME` an app was launched with, or what `argument` lies under; null when it names none.
pub fn home(argument: []const u8) ?[]const u8 {

    if (!std.mem.startsWith(u8, argument, "/home/")) return null;

    const end = std.mem.indexOfScalarPos(u8, argument, 6, '/') orelse argument.len;

    return argument[0..end];

}
