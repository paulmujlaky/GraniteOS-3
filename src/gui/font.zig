const std = @import("std");

pub const FontError = error{UnsupportedFont};

/// Anti-aliased coverage for one glyph, valid until the next `render`.
pub const Bitmap = struct {

    left: i32,
    top: i32,

    width: usize,
    height: usize,
    coverage: []const f32,

};

const Point = struct {

    x: i32,
    y: i32,
    flag: u8,

};

const Vector = struct {

    x: f32,
    y: f32,

};

var area: [160 * 160]f32 = undefined;
var points: [512]Point = undefined;

/// The last point of each contour loaded so far.
var stops: [64]usize = undefined;

/// How much of `points` and `stops` a glyph being loaded has filled.
const Shape = struct {

    points: usize = 0,
    contours: usize = 0,

};

/// The embedded typefaces; every one is known to parse.
pub const Face = enum(u8) {

    /// Nimbus Sans, a metric-compatible Helvetica.
    sans,

    /// JetBrains Mono, subset to Latin, punctuation, arrows, and box drawing.
    mono,

    /// Lucide's line icons, subset to those `Icon` names.
    icons,

    /// Nimbus Sans thickened, slanted, or both as it renders, since no bold or italic cut is embedded.
    bold,
    italic,
    bold_italic,

};

const files = [_][]const u8{

    @embedFile("fonts/NimbusSans-Regular.ttf"),
    @embedFile("fonts/JetBrainsMono-Regular.ttf"),
    @embedFile("fonts/Lucide.ttf"),

};

var embedded = [_]?Font{null} ** std.enums.values(Face).len;

pub fn face(which: Face) *const Font {

    const slot = &embedded[@intFromEnum(which)];

    if (slot.* == null) {

        const file: usize = if (@intFromEnum(which) < files.len) @intFromEnum(which) else 0;
        var font = Font.init(files[file]) catch unreachable;

        // Twelve degrees leans as Helvetica Oblique does, and a thirtieth of an em thickens stems about as much as a bold cut.
        if (which == .italic or which == .bold_italic) font.slant = 0.21;
        if (which == .bold or which == .bold_italic) font.weight = 0.035;

        slot.* = font;

    }

    return &slot.*.?;

}

pub fn sans() *const Font {

    return face(.sans);

}

/// Lucide icons by name, as their code points in the subset font; adding one means re-subsetting `Lucide.ttf` with it.
pub const Icon = enum(u21) {

    activity = 0xe038,
    alarm = 0xe03a,
    app = 0xe426,
    back = 0xe048,
    bell = 0xe059,
    bell_ring = 0xe224,
    bold = 0xe05d,
    brush = 0xe2e7,
    calculator = 0xe1bc,
    calendar = 0xe063,
    case = 0xe3d9,
    check = 0xe06c,
    circle = 0xe076,
    clipboard = 0xe085,
    clock = 0xe087,
    close = 0xe1b2,
    cloud = 0xe088,
    cloud_moon = 0xe215,
    cloud_sun = 0xe216,
    code = 0xe093,
    columns = 0xe098,
    copy = 0xe09e,
    cpu = 0xe0a9,
    cut = 0xe14e,
    delete = 0xe0ae,
    disk = 0xe0ed,
    document = 0xe0cc,
    down = 0xe06d,
    drizzle = 0xe08a,
    edit = 0xe172,
    eraser = 0xe28f,
    eye = 0xe0ba,
    fast_forward = 0xe0bd,
    file = 0xe0c0,
    file_audio = 0xe55e,
    file_code = 0xe0c3,
    file_video = 0xe321,
    fill = 0xe2e6,
    flag = 0xe0d1,
    fog = 0xe214,
    folder = 0xe0d7,
    folder_add = 0xe0d9,
    folder_open = 0xe247,
    forward = 0xe049,
    globe = 0xe0e8,
    grid = 0xe0ff,
    headphones = 0xe0f1,
    heading = 0xe384,
    history = 0xe1f5,
    home = 0xe0f5,
    hourglass = 0xe296,
    humidity = 0xe0b5,
    image = 0xe0f6,
    info = 0xe0f9,
    italic = 0xe0fb,
    key = 0xe4a3,
    left = 0xe06e,
    line = 0xe51d,
    link = 0xe102,
    list = 0xe106,
    list_ordered = 0xe1d1,
    location = 0xe123,
    lock = 0xe10b,
    logout = 0xe10e,
    maximize = 0xe167,
    memory = 0xe445,
    minimize = 0xe11c,
    monitor = 0xe11d,
    moon = 0xe11e,
    more = 0xe0b6,
    music = 0xe122,
    mute = 0xe1ac,
    new = 0xe0c9,
    palette = 0xe1dd,
    paste = 0xe3e8,
    pause = 0xe12e,
    pencil = 0xe1f9,
    picker = 0xe13b,
    place = 0xe111,
    play = 0xe13c,
    playlist = 0xe2e0,
    plus = 0xe13d,
    power = 0xe140,
    pressure = 0xe1bf,
    quote = 0xe239,
    radio = 0xe142,
    rain = 0xe08e,
    rectangle = 0xe376,
    redo = 0xe2a0,
    refresh = 0xe145,
    regex = 0xe1fc,
    repeat = 0xe146,
    repeat_one = 0xe1fd,
    replace = 0xe3db,
    restart = 0xe148,
    rewind = 0xe147,
    right = 0xe06f,
    save = 0xe14d,
    search = 0xe151,
    send = 0xe152,
    settings = 0xe154,
    shuffle = 0xe15e,
    skip_back = 0xe15f,
    skip_forward = 0xe160,
    snow = 0xe090,
    star = 0xe176,
    storm = 0xe08c,
    sun = 0xe178,
    sunrise = 0xe179,
    sunset = 0xe17a,
    terminal = 0xe181,
    thermometer = 0xe186,
    timer = 0xe1e0,
    trash = 0xe18e,
    umbrella = 0xe199,
    undo = 0xe2a1,
    up = 0xe04a,
    user = 0xe19f,
    user_add = 0xe1a2,
    users = 0xe1a4,
    video = 0xe1a5,
    volume = 0xe1a9,
    volume_high = 0xe1ab,
    volume_low = 0xe1aa,
    wallpaper = 0xe44b,
    warning = 0xe077,
    wind = 0xe1b0,
    word = 0xe3df,
    wrap = 0xe248,
    zoom_fit = 0xe257,
    zoom_in = 0xe1b6,
    zoom_out = 0xe1b7,

    /// The icon as UTF-8, ready to draw with the `icons` face.
    pub fn text(self: Icon) []const u8 {

        // Encoding every icon at compile time takes a few branches each.
        @setEvalBranchQuota(20000);

        return switch (self) {

            inline else => |which| &comptime std.unicode.utf8EncodeComptime(@intFromEnum(which)),

        };

    }

};

/// A TrueType font with glyph outlines; parses tables in place without allocating.
pub const Font = struct {

    bytes: []const u8,
    units: f32,
    long: bool,
    metrics: u16,
    ascent: i16,
    descent: i16,

    /// How far capitals rise above the baseline; the whole line for fonts without letters, such as icons.
    capital: i16 = 0,

    cmap: usize,
    loca: usize,
    glyf: usize,
    hmtx: usize,

    /// Kerning pairs sorted by glyph pair: left, right, then the adjustment, all big-endian.
    pairs: []const [6]u8 = &.{},

    /// How far outlines lean right per unit of height, for synthetic italics.
    slant: f32 = 0,

    /// How many ems strokes thicken by, rightwards, for synthetic bold; advances widen to match.
    weight: f32 = 0,

    pub fn init(bytes: []const u8) FontError!Font {

        if (bytes.len < 12) return error.UnsupportedFont;

        const head = table(bytes, "head") orelse return error.UnsupportedFont;
        const hhea = table(bytes, "hhea") orelse return error.UnsupportedFont;
        const cmap = table(bytes, "cmap") orelse return error.UnsupportedFont;

        var font = Font{

            .bytes = bytes,
            .units = @floatFromInt(read(u16, bytes, head + 18)),
            .long = read(i16, bytes, head + 50) == 1,
            .metrics = read(u16, bytes, hhea + 34),
            .ascent = read(i16, bytes, hhea + 4),
            .descent = read(i16, bytes, hhea + 6),

            .cmap = 0,
            .loca = table(bytes, "loca") orelse return error.UnsupportedFont,
            .glyf = table(bytes, "glyf") orelse return error.UnsupportedFont,
            .hmtx = table(bytes, "hmtx") orelse return error.UnsupportedFont,

        };

        // Version 2 and later of the OS/2 table give the height of capitals.
        if (table(bytes, "OS/2")) |metrics| if (metrics + 90 <= bytes.len and read(u16, bytes, metrics) >= 2) {

            font.capital = read(i16, bytes, metrics + 88);

        };

        if (font.capital <= 0) font.capital = font.ascent + font.descent;

        for (0..read(u16, bytes, cmap + 2)) |index| {

            const record = cmap + 4 + index * 8;
            const platform = read(u16, bytes, record);
            const encoding = read(u16, bytes, record + 2);
            const subtable = cmap + read(u32, bytes, record + 4);

            if ((platform == 3 and encoding == 1 or platform == 0) and read(u16, bytes, subtable) == 4) font.cmap = subtable;

        }

        if (font.cmap == 0 or font.units == 0 or font.metrics == 0) return error.UnsupportedFont;

        // Only a version 0 table whose first subtable is horizontal format 0 pairs; anything else draws unkerned.
        if (table(bytes, "kern")) |kern| {

            const count: usize = read(u16, bytes, kern + 10);

            if (read(u16, bytes, kern) == 0 and read(u16, bytes, kern + 2) != 0 and read(u16, bytes, kern + 8) & 0xff07 == 1 and kern + 18 + count * 6 <= bytes.len) {

                font.pairs = std.mem.bytesAsSlice([6]u8, bytes[kern + 18 ..][0 .. count * 6]);

            }

        }

        return font;

    }

    /// Maps a Unicode code point to a glyph index; 0 is the missing glyph.
    pub fn lookup(self: *const Font, codepoint: u21) u16 {

        if (codepoint > 0xffff) return 0;

        const code: u16 = @intCast(codepoint);
        const segments = read(u16, self.bytes, self.cmap + 6) / 2;
        const ends = self.cmap + 14;

        for (0..segments) |index| {

            if (code > read(u16, self.bytes, ends + index * 2)) continue;

            const start = read(u16, self.bytes, ends + segments * 2 + 2 + index * 2);
            const delta = read(u16, self.bytes, ends + segments * 4 + 2 + index * 2);
            const range = ends + segments * 6 + 2 + index * 2;
            const offset = read(u16, self.bytes, range);

            if (code < start) return 0;
            if (offset == 0) return code +% delta;

            const glyph = read(u16, self.bytes, range + offset + @as(usize, code - start) * 2);

            return if (glyph == 0) 0 else glyph +% delta;

        }

        return 0;

    }

    /// Horizontal advance in font units.
    pub fn advance(self: *const Font, glyph: u16) f32 {

        return @as(f32, @floatFromInt(read(u16, self.bytes, self.hmtx + @as(usize, @min(glyph, self.metrics - 1)) * 4))) + self.weight * self.units;

    }

    /// Spacing adjustment between `left` and the `right` glyph after it, in font units; negative pulls them together.
    pub fn kerning(self: *const Font, left: u16, right: u16) f32 {

        const index = std.sort.binarySearch([6]u8, self.pairs, @as(u32, left) << 16 | right, order) orelse return 0;

        return @floatFromInt(read(i16, &self.pairs[index], 4));

    }

    /// Width of UTF-8 `string` in pixels at `scale` pixels per unit.
    pub fn measure(self: *const Font, string: []const u8, scale: f32) f32 {

        var total: f32 = 0;
        var previous: u16 = 0;
        var characters = decode(string);

        while (characters.next()) |char| {

            const glyph = self.lookup(char);

            total += (self.kerning(previous, glyph) + self.advance(glyph)) * scale;
            previous = glyph;

        }

        return total;

    }

    /// Rasterizes `glyph` at `scale` pixels per unit, shifted right by `shift` pixels; null when it draws nothing.
    pub fn render(self: *const Font, glyph: u16, scale: f32, shift: f32) ?Bitmap {

        const data = self.outline(glyph) orelse return null;
        var shape = Shape{};

        if (!self.load(glyph, 0, 0, 0, &shape) or shape.contours == 0) return null;

        if (self.slant != 0) for (points[0..shape.points]) |*point| {

            point.x += @intFromFloat(@round(@as(f32, @floatFromInt(point.y)) * self.slant));

        };

        const low: f32 = @floatFromInt(read(i16, data, 4));
        const high: f32 = @floatFromInt(read(i16, data, 8));
        const thicken = self.weight * self.units * scale;

        // A one-pixel margin keeps rounding from reaching outside the buffer.
        const left = @floor((@as(f32, @floatFromInt(read(i16, data, 2))) + low * self.slant) * scale + shift) - 1;
        const top = @floor(-high * scale) - 1;
        const width: usize = @intFromFloat(@ceil((@as(f32, @floatFromInt(read(i16, data, 6))) + high * self.slant) * scale + shift + thicken) - left + 2);
        const height: usize = @intFromFloat(@ceil(-low * scale) - top + 2);

        if (width * height + 2 > area.len) return null;

        var raster = Raster{

            .area = area[0 .. width * height + 2],
            .width = width,
            .height = height,

        };

        @memset(raster.area, 0);

        var first: usize = 0;

        for (stops[0..shape.contours]) |last| {

            raster.outline(points[first .. last + 1], scale, shift - left, -top);
            first = last + 1;

        }

        var sum: f32 = 0;

        for (raster.area[0 .. width * height]) |*cell| {

            sum += cell.*;
            cell.* = @min(@abs(sum), 1);

        }

        if (thicken > 0) embolden(raster.area[0 .. width * height], width, thicken);

        return .{

            .left = @intFromFloat(left),
            .top = @intFromFloat(top),

            .width = width,
            .height = height,
            .coverage = raster.area[0 .. width * height],

        };

    }

    /// The `glyf` entry of `glyph`, or null when it has no outline.
    fn outline(self: *const Font, glyph: u16) ?[]const u8 {

        const start = self.location(glyph);
        const end = self.location(@as(usize, glyph) + 1);

        if (end <= start) return null;

        return self.bytes[self.glyf + start .. self.glyf + end];

    }

    /// Appends the contours of `glyph`, moved by (`dx`, `dy`) font units, to `points` and `stops`; false when they do not fit.
    fn load(self: *const Font, glyph: u16, dx: i32, dy: i32, depth: u8, shape: *Shape) bool {

        const data = self.outline(glyph) orelse return true;
        const contours = read(i16, data, 0);

        if (contours < 0) return depth < 4 and self.components(data, dx, dy, depth, shape);
        if (contours == 0) return true;

        const total: usize = @intCast(contours);
        const count = @as(usize, read(u16, data, 10 + (total - 1) * 2)) + 1;
        const base = shape.points;

        if (base + count > points.len or shape.contours + total > stops.len) return false;

        const list = points[base..][0..count];
        var offset = 12 + total * 2;
        offset += read(u16, data, offset - 2);

        var index: usize = 0;

        while (index < count) {

            const flag = data[offset];
            var repeat: usize = 1;

            offset += 1;

            if (flag & 8 != 0) {

                repeat += data[offset];
                offset += 1;

            }

            for (0..@min(repeat, count - index)) |_| {

                list[index] = .{

                    .x = 0,
                    .y = 0,
                    .flag = flag,

                };

                index += 1;

            }

        }

        offset = coordinates(data, offset, list, .x, 2, 16);
        _ = coordinates(data, offset, list, .y, 4, 32);

        for (list) |*point| {

            point.x += dx;
            point.y += dy;

        }

        var first: usize = 0;

        for (0..total) |contour| {

            const last = read(u16, data, 10 + contour * 2);
            if (last < first or last >= count) return false;

            stops[shape.contours] = base + last;
            shape.contours += 1;
            first = last + 1;

        }

        shape.points = base + count;

        return true;

    }

    /// Loads each part of a composite glyph, such as a letter and its accent.
    fn components(self: *const Font, data: []const u8, dx: i32, dy: i32, depth: u8, shape: *Shape) bool {

        var offset: usize = 10;

        while (true) {

            const flags = read(u16, data, offset);
            const part = read(u16, data, offset + 2);
            var x: i32 = 0;
            var y: i32 = 0;

            offset += 4;

            if (flags & 1 != 0) {

                x = read(i16, data, offset);
                y = read(i16, data, offset + 2);
                offset += 4;

            } else {

                x = @as(i8, @bitCast(data[offset]));
                y = @as(i8, @bitCast(data[offset + 1]));
                offset += 2;

            }

            // ponytail: parts placed by matching points, or scaled, draw unmoved and unscaled; Latin accents use plain offsets.
            if (flags & 2 == 0) {

                x = 0;
                y = 0;

            }

            offset += if (flags & 8 != 0) 2 else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) @as(usize, 8) else 0;

            if (!self.load(part, dx + x, dy + y, depth + 1, shape)) return false;
            if (flags & 0x20 == 0) return true;

        }

    }

    fn location(self: *const Font, glyph: usize) usize {

        if (self.long) return read(u32, self.bytes, self.loca + glyph * 4);

        return @as(usize, read(u16, self.bytes, self.loca + glyph * 2)) * 2;

    }

};

/// Accumulates signed area per cell; a running sum then yields coverage.
const Raster = struct {

    area: []f32,
    width: usize,
    height: usize,

    fn outline(self: *Raster, contour: []const Point, scale: f32, x: f32, y: f32) void {

        const count = contour.len;

        const begin = for (contour, 0..) |point, index| {

            if (point.flag & 1 != 0) break index;

        } else null;

        const first = if (begin) |index| place(contour[index], scale, x, y) else middle(place(contour[count - 1], scale, x, y), place(contour[0], scale, x, y));
        var current = first;
        var control: ?Vector = null;

        for (@intFromBool(begin != null)..count) |step| {

            const point = contour[((begin orelse 0) + step) % count];
            const next = place(point, scale, x, y);

            if (point.flag & 1 != 0) {

                if (control) |bend| self.curve(current, bend, next) else self.line(current, next);
                current = next;
                control = null;

            } else {

                if (control) |bend| {

                    const halfway = middle(bend, next);

                    self.curve(current, bend, halfway);
                    current = halfway;

                }

                control = next;

            }

        }

        if (control) |bend| self.curve(current, bend, first) else self.line(current, first);

    }

    fn curve(self: *Raster, from: Vector, bend: Vector, to: Vector) void {

        const deviation_x = from.x - 2 * bend.x + to.x;
        const deviation_y = from.y - 2 * bend.y + to.y;
        const deviation = deviation_x * deviation_x + deviation_y * deviation_y;

        if (deviation < 0.333) return self.line(from, to);

        const steps: usize = 1 + @as(usize, @intFromFloat(@floor(@sqrt(@sqrt(3 * deviation)))));
        var previous = from;

        for (1..steps) |step| {

            const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
            const next = lerp(lerp(from, bend, t), lerp(bend, to, t), t);

            self.line(previous, next);
            previous = next;

        }

        self.line(previous, to);

    }

    fn line(self: *Raster, from: Vector, to: Vector) void {

        if (from.y == to.y) return;

        const direction: f32 = if (from.y < to.y) 1 else -1;
        const upper = if (from.y < to.y) from else to;
        const lower = if (from.y < to.y) to else from;
        const slope = (lower.x - upper.x) / (lower.y - upper.y);
        const last: usize = @intFromFloat(@min(@as(f32, @floatFromInt(self.height)), @max(@ceil(lower.y), 0)));
        var row: usize = @intFromFloat(@max(upper.y, 0));

        while (row < last) : (row += 1) {

            const y0 = @max(@as(f32, @floatFromInt(row)), upper.y);
            const y1 = @min(@as(f32, @floatFromInt(row + 1)), lower.y);
            const start = upper.x + (y0 - upper.y) * slope;
            const end = upper.x + (y1 - upper.y) * slope;
            const delta = (y1 - y0) * direction;
            const x0 = @min(start, end);
            const x1 = @max(start, end);
            const floor = @floor(x0);
            const ceiling = @ceil(x1);
            const first: usize = @intFromFloat(floor);
            const last_cell: usize = @intFromFloat(ceiling);
            const cells = self.area[row * self.width ..];

            if (last_cell <= first + 1) {

                const center = 0.5 * (start + end) - floor;

                cells[first] += delta - delta * center;
                cells[first + 1] += delta * center;
                continue;

            }

            const inverse = 1 / (x1 - x0);
            const head = x0 - floor;
            const tail = x1 - ceiling + 1;
            const entry = 0.5 * inverse * (1 - head) * (1 - head);
            const exit = 0.5 * inverse * tail * tail;

            cells[first] += delta * entry;

            if (last_cell == first + 2) {

                cells[first + 1] += delta * (1 - entry - exit);

            } else {

                const second = inverse * (1.5 - head);

                cells[first + 1] += delta * (second - entry);
                for (first + 2..last_cell - 1) |cell| cells[cell] += delta * inverse;
                cells[last_cell - 1] += delta * (1 - (second + @as(f32, @floatFromInt(last_cell - first - 3)) * inverse) - exit);

            }

            cells[last_cell] += delta * exit;

        }

    }

};

fn coordinates(data: []const u8, start: usize, list: []Point, comptime axis: enum { x, y }, short: u8, same: u8) usize {

    var offset = start;
    var value: i32 = 0;

    for (list) |*point| {

        if (point.flag & short != 0) {

            const delta: i32 = data[offset];

            value += if (point.flag & same != 0) delta else -delta;
            offset += 1;

        } else if (point.flag & same == 0) {

            value += read(i16, data, offset);
            offset += 2;

        }

        @field(point, @tagName(axis)) = value;

    }

    return offset;

}

/// Reads UTF-8 one code point at a time; each malformed byte reads as U+FFFD.
pub const Characters = struct {

    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *Characters) ?u21 {

        if (self.index >= self.bytes.len) return null;

        const rest = self.bytes[self.index..];
        const length = std.unicode.utf8ByteSequenceLength(rest[0]) catch 0;
        const char = if (length != 0 and length <= rest.len) std.unicode.utf8Decode(rest[0..length]) catch null else null;

        self.index += if (char != null) length else 1;

        return char orelse 0xfffd;

    }

};

pub fn decode(bytes: []const u8) Characters {

    return .{

        .bytes = bytes,

    };

}

fn table(bytes: []const u8, comptime tag: *const [4]u8) ?usize {

    for (0..read(u16, bytes, 4)) |index| {

        const record = 12 + index * 16;

        if (std.mem.eql(u8, bytes[record..][0..4], tag)) return read(u32, bytes, record + 8);

    }

    return null;

}

fn read(comptime T: type, bytes: []const u8, offset: usize) T {

    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);

}

fn order(key: u32, pair: [6]u8) std.math.Order {

    return std.math.order(key, read(u32, &pair, 0));

}

/// Smears each row of `coverage` rightwards by `amount` pixels, thickening every vertical stroke as a bold cut would.
fn embolden(coverage: []f32, width: usize, amount: f32) void {

    const whole: usize = @intFromFloat(@floor(amount));
    const part = amount - @floor(amount);
    var row: usize = 0;

    while (row < coverage.len) : (row += width) {

        const cells = coverage[row..][0..width];
        var x = width;

        // Right to left, so every cell still reads the unsmeared ones to its left.
        while (x > 0) {

            x -= 1;

            var most = cells[x];

            for (1..whole + 1) |back| {

                if (back <= x) most = @max(most, cells[x - back]);

            }

            if (whole + 1 <= x) most = @max(most, cells[x - whole - 1] * part);
            cells[x] = most;

        }

    }

}

fn place(point: Point, scale: f32, x: f32, y: f32) Vector {

    return .{

        .x = @as(f32, @floatFromInt(point.x)) * scale + x,
        .y = y - @as(f32, @floatFromInt(point.y)) * scale,

    };

}

fn middle(a: Vector, b: Vector) Vector {

    return lerp(a, b, 0.5);

}

fn lerp(a: Vector, b: Vector, t: f32) Vector {

    return .{

        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,

    };

}
