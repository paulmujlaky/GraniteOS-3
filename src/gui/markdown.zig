//! Markdown: reads CommonMark-style blocks and inline styles, and lays them out as a rendered preview that follows the source
//! as it is edited: headings, paragraphs, nested and task lists, quotes, fenced code in syntax colours, rules, and tables.

const std = @import("std");

const canvas = @import("canvas.zig");
const document = @import("document.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const style = @import("style.zig");
const syntax = @import("syntax.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node;
const Rect = canvas.Rect;

pub const Align = enum {

    left,
    center,
    right,

};

pub const Block = struct {

    kind: Kind,

    /// A heading's level, or how deeply a list item nests.
    level: u8 = 0,

    /// How many quotes it sits inside.
    quote: u8 = 0,

    /// An ordered item's number; null for a bullet.
    number: ?u32 = null,

    /// A task item's box: ticked or not.
    task: ?bool = null,

    /// Inline text, code lines, or table rows, with quote markers and indentation taken out.
    content: []const u8,

    /// The language a code fence names.
    info: []const u8 = "",

    /// A table's columns, as its delimiter row aligns them.
    columns: []const Align = &.{},

    /// The source line it starts on.
    line: usize,

    pub const Kind = enum {

        paragraph,
        heading,
        item,
        code,
        rule,
        table,

    };

};

/// A block still taking lines, and how a fenced one ends.
const Open = struct {

    block: Block,
    lines: std.ArrayList(u8) = .empty,

    fence: ?struct {

        char: u8,
        length: usize,
        indent: usize,

    } = null,

    /// Indented code rather than fenced.
    indented: bool = false,

};

/// Reads `source` into blocks, their text copied into `allocator`, which an arena suits.
pub fn parse(allocator: Allocator, source: []const u8) Allocator.Error![]Block {

    var blocks: std.ArrayList(Block) = .empty;
    var open: ?Open = null;
    var last: ?Block.Kind = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;

    while (lines.next()) |whole| : (number += 1) {

        var rest = std.mem.trimRight(u8, whole, "\r");
        var quote: u8 = 0;

        while (std.mem.indexOfNone(u8, rest, " ")) |lead| {

            if (lead > 3 or rest[lead] != '>') break;

            quote +|= 1;
            rest = rest[lead + 1 ..];
            if (rest.len != 0 and rest[0] == ' ') rest = rest[1..];

        }

        if (open) |*current| if (current.fence) |fence| {

            const trimmed = std.mem.trimLeft(u8, rest, " ");
            const closes = trimmed.len >= fence.length and std.mem.indexOfNone(u8, trimmed, &.{fence.char}) == null;

            if (closes or quote < current.block.quote) {

                try close(allocator, &blocks, &open, &last);
                if (closes) continue;

            } else {

                const indent = @min(std.mem.indexOfNone(u8, rest, " ") orelse rest.len, fence.indent);

                try current.lines.appendSlice(allocator, rest[indent..]);
                try current.lines.append(allocator, '\n');
                continue;

            }

        };

        const indent = std.mem.indexOfNone(u8, rest, " ") orelse rest.len;
        const content = rest[indent..];

        if (content.len == 0) {

            // A blank line inside indented code belongs to it, unless the code ends there.
            if (open) |*current| if (current.indented) {

                try current.lines.append(allocator, '\n');
                continue;

            };

            try close(allocator, &blocks, &open, &last);
            continue;

        }

        const continuing = if (open) |current| (current.block.kind == .paragraph or current.block.kind == .item) and !current.indented else false;

        if (indent >= 4 and !continuing and last != .item) {

            if (open) |*current| if (current.indented) {

                try current.lines.appendSlice(allocator, rest[4..]);
                try current.lines.append(allocator, '\n');
                continue;

            };

            try close(allocator, &blocks, &open, &last);
            open = .{ .block = .{ .kind = .code, .quote = quote, .content = "", .line = number }, .indented = true };
            try open.?.lines.appendSlice(allocator, rest[4..]);
            try open.?.lines.append(allocator, '\n');
            continue;

        }

        if (open) |current| if (current.indented) try close(allocator, &blocks, &open, &last);

        if (indent < 4 and syntax.fence(content)) {

            const length = std.mem.indexOfNone(u8, content, content[0..1]) orelse content.len;

            try close(allocator, &blocks, &open, &last);

            open = .{

                .block = .{ .kind = .code, .quote = quote, .content = "", .info = std.mem.trim(u8, content[length..], " "), .line = number },
                .fence = .{ .char = content[0], .length = length, .indent = indent },

            };

            continue;

        }

        const level = syntax.heading(content);

        if (indent < 4 and level != 0) {

            try close(allocator, &blocks, &open, &last);

            // Closing hashes are decoration.
            const title = std.mem.trim(u8, std.mem.trimRight(u8, std.mem.trim(u8, content[level..], " "), "#"), " ");

            try blocks.append(allocator, .{ .kind = .heading, .level = @intCast(level), .quote = quote, .content = title, .line = number });
            last = .heading;
            continue;

        }

        // A line of `=` or `-` under a paragraph makes it a heading.
        if (open) |*current| if (indent < 4 and current.block.kind == .paragraph and current.block.quote == quote) {

            const underline = std.mem.trimRight(u8, content, " ");

            if (underline.len != 0 and (underline[0] == '=' or underline[0] == '-') and std.mem.indexOfNone(u8, underline, underline[0..1]) == null) {

                current.block.kind = .heading;
                current.block.level = if (underline[0] == '=') 1 else 2;
                try close(allocator, &blocks, &open, &last);
                continue;

            }

        };

        if (indent < 4 and syntax.rule(content)) {

            try close(allocator, &blocks, &open, &last);
            try blocks.append(allocator, .{ .kind = .rule, .quote = quote, .content = "", .line = number });
            last = .rule;
            continue;

        }

        if (syntax.bullet(content)) |width| {

            try close(allocator, &blocks, &open, &last);

            const marker = content[0..width];
            var body = content[width..];
            var task: ?bool = null;

            if (body.len >= 3 and body[0] == '[' and body[2] == ']' and (body.len == 3 or body[3] == ' ') and std.mem.indexOfScalar(u8, " xX", body[1]) != null) {

                task = body[1] != ' ';
                body = std.mem.trimLeft(u8, body[3..], " ");

            }

            const digits = std.mem.indexOfNone(u8, marker, "0123456789") orelse 0;

            open = .{

                .block = .{

                    .kind = .item,
                    .level = @intCast(@min(indent / 2, 8)),
                    .quote = quote,
                    .number = if (digits != 0) std.fmt.parseInt(u32, marker[0..digits], 10) catch 1 else null,
                    .task = task,
                    .content = "",
                    .line = number,

                },

            };

            try open.?.lines.appendSlice(allocator, body);
            continue;

        }

        if (open) |*current| {

            if (current.block.kind == .table and current.block.quote == quote and std.mem.indexOfScalar(u8, content, '|') != null) {

                try current.lines.append(allocator, '\n');
                try current.lines.appendSlice(allocator, content);
                continue;

            }

            const header = current.block.kind == .paragraph and std.mem.indexOfScalar(u8, current.lines.items, '\n') == null;

            if (header and std.mem.indexOfScalar(u8, current.lines.items, '|') != null) if (try delimiters(allocator, content)) |aligns| {

                current.block.kind = .table;
                current.block.columns = aligns;
                continue;

            };

            // A line with fewer quote markers carries on lazily; one with more starts a deeper quote.
            if ((current.block.kind == .paragraph or current.block.kind == .item) and quote <= current.block.quote) {

                try current.lines.append(allocator, '\n');
                try current.lines.appendSlice(allocator, content);
                continue;

            }

        }

        try close(allocator, &blocks, &open, &last);
        open = .{ .block = .{ .kind = .paragraph, .quote = quote, .content = "", .line = number } };
        try open.?.lines.appendSlice(allocator, content);

    }

    try close(allocator, &blocks, &open, &last);

    return blocks.items;

}

fn close(allocator: Allocator, blocks: *std.ArrayList(Block), open: *?Open, last: *?Block.Kind) Allocator.Error!void {

    const current = open.* orelse return;
    var block = current.block;

    block.content = current.lines.items;

    // Indented code keeps no blank lines at its end.
    if (current.indented) block.content = std.mem.trimRight(u8, block.content, "\n");

    try blocks.append(allocator, block);
    last.* = block.kind;
    open.* = null;

}

/// A table's delimiter row, such as `| :-- | :-: |`, read as how its columns align; null when `line` is none.
fn delimiters(allocator: Allocator, line: []const u8) Allocator.Error!?[]const Align {

    var aligns: std.ArrayList(Align) = .empty;
    var cells = Cells.init(line);

    while (cells.next()) |cell| {

        const trimmed = std.mem.trim(u8, cell, " ");
        const inner = std.mem.trim(u8, trimmed, ":");

        if (inner.len == 0 or std.mem.indexOfNone(u8, inner, "-") != null) return null;

        const left = trimmed[0] == ':';
        const right = trimmed[trimmed.len - 1] == ':';

        try aligns.append(allocator, if (left and right) .center else if (right) .right else .left);

    }

    return if (aligns.items.len == 0) null else aligns.items;

}

/// The cells of a table row, between its pipes; a backslash keeps a pipe in a cell.
pub const Cells = struct {

    row: []const u8,
    index: usize = 0,

    pub fn init(row: []const u8) Cells {

        var trimmed = std.mem.trim(u8, row, " ");

        if (trimmed.len != 0 and trimmed[0] == '|') trimmed = trimmed[1..];
        if (trimmed.len != 0 and trimmed[trimmed.len - 1] == '|' and !(trimmed.len > 1 and trimmed[trimmed.len - 2] == '\\')) trimmed = trimmed[0 .. trimmed.len - 1];

        return .{

            .row = trimmed,

        };

    }

    pub fn next(self: *Cells) ?[]const u8 {

        if (self.index > self.row.len) return null;

        const start = self.index;
        var at = start;

        while (at < self.row.len) : (at += 1) {

            if (self.row[at] == '\\') {

                at += 1;
                continue;

            }

            if (self.row[at] == '|') break;

        }

        self.index = at + 1;

        return std.mem.trim(u8, self.row[start..@min(at, self.row.len)], " ");

    }

};

/// How a run of inline text looks.
pub const Look = packed struct(u8) {

    strong: bool = false,
    emphasis: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,

    /// An image's description, shown in its place after an icon.
    image: bool = false,
    icon: bool = false,

    _: u1 = 0,

};

pub const Piece = struct {

    content: []const u8,
    look: Look,

    kind: enum {

        words,

        /// A line break inside a paragraph, read as a space.
        space,

        /// A hard line break: two spaces or a backslash ending a line.
        line,

    } = .words,

};

/// Splits a block's inline text into runs of one look: emphasis and strong emphasis, code spans, struck text, links, and
/// images, with backslash escapes taken out.
pub const Pieces = struct {

    source: []const u8,
    index: usize = 0,
    look: Look = .{},

    /// Which delimiter opened emphasis and strong emphasis, or zero.
    emphasis: u8 = 0,
    strong: u8 = 0,

    /// Where a link's text ends, and where its target does, to carry on from.
    label: ?usize = null,
    after: usize = 0,

    pub fn init(source: []const u8) Pieces {

        return .{

            .source = source,

        };

    }

    pub fn next(self: *Pieces) ?Piece {

        const all = self.source;

        while (self.index < all.len) {

            const start = self.index;
            var at = start;

            while (at < all.len) {

                const char = all[at];

                if (self.label) |end| if (at == end) {

                    if (at > start) return self.cut(start, at);

                    self.look.link = false;
                    self.label = null;
                    self.index = self.after;
                    break;

                };

                switch (char) {

                    '\\' => if (at + 1 < all.len and (punctuation(all[at + 1]) or all[at + 1] == '\n')) {

                        if (at > start) return self.cut(start, at);

                        self.index = at + 2;

                        if (all[at + 1] == '\n') return .{ .content = "", .look = self.look, .kind = .line };

                        return .{ .content = all[at + 1 .. at + 2], .look = self.look };

                    },
                    '\n' => {

                        if (at > start) return self.cut(start, at);

                        const hard = at >= 2 and all[at - 1] == ' ' and all[at - 2] == ' ';

                        self.index = at + 1;

                        return .{ .content = "", .look = self.look, .kind = if (hard) .line else .space };

                    },
                    '`' => {

                        const count = run(all, at, '`');

                        if (closer(all, at + count, '`', count, false)) |end| {

                            if (at > start) return self.cut(start, at);

                            var inner = all[at + count .. end];

                            if (inner.len > 2 and inner[0] == ' ' and inner[inner.len - 1] == ' ') inner = inner[1 .. inner.len - 1];
                            self.index = end + count;

                            var look = self.look;

                            look.code = true;

                            return .{ .content = inner, .look = look };

                        }

                        at += count;
                        continue;

                    },
                    '*', '_', '~' => {

                        // Text before the run goes out first, in the look it had.
                        if (at > start) return self.cut(start, at);

                        if (self.delimit(at)) |width| {

                            self.index = at + width;
                            break;

                        }

                        at += run(all, at, char);
                        continue;

                    },
                    '[' => if (self.label == null) if (target(all, at)) |link| {

                        if (at > start) return self.cut(start, at);

                        self.look.link = true;
                        self.label = link[0];
                        self.after = link[1];
                        self.index = at + 1;
                        break;

                    },
                    '!' => if (at + 1 < all.len and all[at + 1] == '[') if (target(all, at + 1)) |link| {

                        if (at > start) return self.cut(start, at);

                        var look = self.look;

                        look.image = true;
                        self.index = link[1];

                        return .{ .content = all[at + 2 .. link[0]], .look = look };

                    },
                    '<' => if (autolink(all, at)) |end| {

                        if (at > start) return self.cut(start, at);

                        var look = self.look;

                        look.link = true;
                        self.index = end + 1;

                        return .{ .content = all[at + 1 .. end], .look = look };

                    },
                    else => {},

                }

                at += 1;

            } else {

                return self.cut(start, all.len);

            }

        }

        return null;

    }

    fn cut(self: *Pieces, start: usize, end: usize) Piece {

        self.index = end;

        return .{

            .content = self.source[start..end],
            .look = self.look,

        };

    }

    /// Opens or closes emphasis, strong emphasis, or a strikethrough at a run of `*`, `_`, or `~`; how many delimiters it took,
    /// or null when they are only text.
    fn delimit(self: *Pieces, at: usize) ?usize {

        const all = self.source;
        const char = all[at];
        const count = run(all, at, char);
        const before = if (at > 0) all[at - 1] else ' ';
        const after = if (at + count < all.len) all[at + count] else ' ';
        const intraword = char == '_' and std.ascii.isAlphanumeric(before) and std.ascii.isAlphanumeric(after);

        if (intraword) return null;

        if (char == '~') {

            if (count != 2) return null;

            if (self.look.strike and !space(before)) {

                self.look.strike = false;
                return 2;

            }

            if (!space(after) and closer(all, at + 2, '~', 2, false) != null) {

                self.look.strike = true;
                return 2;

            }

            return null;

        }

        // Closing first, strong before plain, so `***both***` unwinds as it opened.
        if (!space(before)) {

            if (count >= 2 and self.strong == char) {

                self.strong = 0;
                self.look.strong = false;
                return 2;

            }

            if (self.emphasis == char) {

                self.emphasis = 0;
                self.look.emphasis = false;
                return 1;

            }

        }

        if (space(after)) return null;

        if (count >= 2 and self.strong == 0 and closer(all, at + count, char, 2, true) != null) {

            self.strong = char;
            self.look.strong = true;
            return 2;

        }

        if (self.emphasis == 0 and closer(all, at + count, char, 1, true) != null) {

            self.emphasis = char;
            self.look.emphasis = true;
            return 1;

        }

        return null;

    }

};

/// Where a run of `count` `char` that could close one opened before `from` starts; `loose` lets it be part of a longer run.
fn closer(all: []const u8, from: usize, char: u8, count: usize, loose: bool) ?usize {

    var at = from;

    while (std.mem.indexOfScalarPos(u8, all, at, char)) |found| {

        const length = run(all, found, char);

        if (found > 0 and !space(all[found - 1]) and (if (loose) length >= count else length == count)) return found;
        at = found + length;

    }

    return null;

}

/// Where `[text](target)` at `at` has its `]`, and where it ends; null when it is not a link.
fn target(all: []const u8, at: usize) ?[2]usize {

    var depth: usize = 0;
    var index = at;

    const label = while (index < all.len) : (index += 1) {

        switch (all[index]) {

            '[' => depth += 1,
            ']' => {

                depth -= 1;
                if (depth == 0) break index;

            },
            '\\' => index += 1,
            '\n' => if (index + 1 < all.len and all[index + 1] == '\n') return null,
            else => {},

        }

    } else return null;

    if (label + 1 >= all.len or all[label + 1] != '(') return null;

    const end = std.mem.indexOfScalarPos(u8, all, label + 2, ')') orelse return null;

    return .{ label, end + 1 };

}

/// Where `<https://…>` at `at` closes; null when it is not an autolink.
fn autolink(all: []const u8, at: usize) ?usize {

    const rest = all[at + 1 ..];

    if (!std.mem.startsWith(u8, rest, "http://") and !std.mem.startsWith(u8, rest, "https://") and !std.mem.startsWith(u8, rest, "mailto:")) return null;

    const end = std.mem.indexOfAny(u8, rest, "> \n") orelse return null;

    return if (rest[end] == '>') at + 1 + end else null;

}

fn run(all: []const u8, at: usize, char: u8) usize {

    var end = at;

    while (end < all.len and all[end] == char) end += 1;

    return end - at;

}

fn space(char: u8) bool {

    return char == ' ' or char == '\t' or char == '\n';

}

/// What the preview draws, placed relative to the top-left of its content.
const Item = struct {

    kind: enum {

        words,
        fill,
        outline,

        /// Text centred in its area, such as an icon.
        label,

    },

    area: Rect,
    baseline: i32 = 0,
    string: []const u8 = "",
    face: font.Face = .sans,
    size: f32 = 0,
    color: u32,
    radius: i32 = 0,

    /// Drawing outside this is cut off, as for a long line in a code block.
    clip: ?Rect = null,

};

/// Where a source line's block begins in the preview.
const Anchor = struct {

    line: usize,
    y: i32,

};

/// Lays out flowing text between two edges, wrapping between words and joining words of one look into one run.
const Flow = struct {

    preview: *Preview,
    left: i32,
    right: i32,
    top: i32,
    height: i32,
    baseline: i32,

    /// Where the next word goes, kept fractional so a line of runs measures as the renderer draws it.
    x: f32,

    /// Plain text's face, size, and colour here, such as a heading's.
    face: font.Face,
    size: f32,
    color: u32,

    run: ?Run = null,

    const Run = struct {

        string: []const u8,
        x: f32,
        end: f32,
        look: Look,

    };

    fn init(preview: *Preview, left: i32, right: i32, top: i32, face: font.Face, size: f32, color: u32) Flow {

        const height: i32 = @intFromFloat(@ceil(size * 1.5));
        const sans = font.face(face);

        return .{

            .preview = preview,
            .left = left,
            .right = @max(right, left + 1),
            .x = @floatFromInt(left),
            .top = top,
            .height = height,
            .baseline = @divTrunc(height - text.leading(sans, size), 2) + text.ascent(sans, size),
            .face = face,
            .size = size,
            .color = color,

        };

    }

    fn pieces(self: *Flow, source: []const u8) Allocator.Error!void {

        var all = Pieces.init(source);

        while (all.next()) |part| try self.piece(part);

    }

    fn piece(self: *Flow, part: Piece) Allocator.Error!void {

        switch (part.kind) {

            .space => {

                try self.flush();
                if (self.x > self.edge()) self.x += self.measure(" ", .{});

            },
            .line => try self.newline(),
            .words => {

                if (part.look.image) try self.place(font.Icon.image.text(), " ", .{ .icon = true });

                var index: usize = 0;
                const string = part.content;

                while (index < string.len) {

                    const stop = std.mem.indexOfScalarPos(u8, string, index, ' ') orelse string.len;
                    const after = std.mem.indexOfNonePos(u8, string, stop, " ") orelse string.len;

                    try self.place(string[index..stop], string[stop..after], part.look);
                    index = after;

                }

            },

        }

    }

    /// Places `word` then the `gap` of spaces after it, wrapping first if the word would run past the right edge.
    fn place(self: *Flow, word: []const u8, gap: []const u8, look: Look) Allocator.Error!void {

        const face, const size = self.lettering(look);
        const scale = size / font.face(face).units;
        const right: f32 = @floatFromInt(self.right);
        var rest = word;

        while (rest.len != 0) {

            var span = font.face(face).measure(rest, scale);

            if (self.x + span > right and self.x > self.edge()) try self.newline();

            var length = rest.len;

            // A word wider than a whole line breaks wherever it must.
            if (span > right - self.edge()) {

                var characters = font.decode(rest);
                var reached: f32 = 0;

                length = 0;

                while (characters.next()) |char| {

                    const advance = font.face(face).advance(font.face(face).lookup(char)) * scale;

                    if (self.x + reached + advance > right and length > 0) break;

                    reached += advance;
                    length = characters.index;

                }

                span = reached;

            }

            const chunk = rest[0..length];

            if (self.joins(chunk, look)) {

                const current = &self.run.?;

                current.string = current.string.ptr[0 .. @intFromPtr(chunk.ptr) + chunk.len - @intFromPtr(current.string.ptr)];

            } else {

                try self.flush();
                self.run = .{ .string = chunk, .x = self.x, .end = self.x, .look = look };

            }

            self.x += span;
            self.run.?.end = self.x;
            rest = rest[length..];

            if (rest.len != 0) try self.newline();

        }

        if (gap.len != 0 and self.x > self.edge()) self.x += font.face(face).measure(gap, scale);

    }

    /// Whether `chunk` carries on the run being gathered: the same look, and only spaces between them in the source.
    fn joins(self: *const Flow, chunk: []const u8, look: Look) bool {

        const current = self.run orelse return false;
        const end = @intFromPtr(current.string.ptr) + current.string.len;
        const begin = @intFromPtr(chunk.ptr);

        if (!std.meta.eql(current.look, look) or begin < end or begin - end > 16) return false;

        return std.mem.indexOfNone(u8, current.string.ptr[current.string.len..][0 .. begin - end], " ") == null;

    }

    fn edge(self: *const Flow) f32 {

        return @floatFromInt(self.left);

    }

    fn measure(self: *const Flow, string: []const u8, look: Look) f32 {

        const face, const size = self.lettering(look);

        return font.face(face).measure(string, size / font.face(face).units);

    }

    fn width(self: *const Flow, string: []const u8, look: Look) i32 {

        return @intFromFloat(@ceil(self.measure(string, look)));

    }

    /// The face and size text of `look` takes here.
    fn lettering(self: *const Flow, look: Look) struct { font.Face, f32 } {

        if (look.code) return .{ .mono, self.size * 0.88 };
        if (look.icon) return .{ .icons, self.size };
        if (look.image) return .{ .italic, self.size };

        const bold = look.strong or self.face == .bold;

        if (bold and look.emphasis) return .{ .bold_italic, self.size };
        if (bold) return .{ .bold, self.size };
        if (look.emphasis) return .{ .italic, self.size };

        return .{ self.face, self.size };

    }

    fn flush(self: *Flow) Allocator.Error!void {

        const current = self.run orelse return;
        const face, const size = self.lettering(current.look);
        const preview = self.preview;
        const x: i32 = @intFromFloat(@round(current.x));
        const span: i32 = @intFromFloat(@round(current.end - current.x));

        self.run = null;

        if (current.look.code) {

            try preview.add(.{

                .kind = .fill,
                .area = .{ .x = x - 3, .y = self.top + 2, .width = span + 6, .height = self.height - 4 },
                .color = theme.field,
                .radius = 4,

            });

        }

        const color = if (current.look.link) theme.syntax.function else if (current.look.image or current.look.icon) theme.muted else self.color;

        try preview.add(.{

            .kind = .words,
            .area = .{ .x = x, .y = self.top, .width = span, .height = self.height },
            .baseline = self.top + self.baseline,
            .string = current.string,
            .face = face,
            .size = size,
            .color = color,

        });

        if (current.look.link or current.look.strike) {

            const y = if (current.look.link) self.top + self.baseline + 2 else self.top + self.baseline - @as(i32, @intFromFloat(size * 0.3));

            try preview.add(.{

                .kind = .fill,
                .area = .{ .x = x, .y = y, .width = span, .height = 1 },
                .color = color,

            });

        }

    }

    fn newline(self: *Flow) Allocator.Error!void {

        try self.flush();
        self.top += self.height;
        self.x = self.edge();

    }

    /// Ends the text, returning where the last line ends.
    fn finish(self: *Flow) Allocator.Error!i32 {

        try self.flush();

        return self.top + self.height;

    }

};

/// Shows a document's Markdown rendered: it lays the text out again whenever it changes, scrolls with the wheel, and can follow
/// another view to a source line.
pub const Preview = struct {

    arena: std.heap.ArenaAllocator,
    source: ?*const document.Document = null,

    items: std.ArrayList(Item) = .empty,
    anchors: std.ArrayList(Anchor) = .empty,

    /// How tall the laid-out content is, and how far it has scrolled.
    height: i32 = 0,
    offset: i32 = 0,

    /// Body text size in pixels at 100%.
    size: f32 = 15,

    /// The source line to scroll to once laid out.
    wanted: ?usize = null,

    /// What the layout was made for, to tell when it is stale.
    laid: struct {

        version: u64 = std.math.maxInt(u64),
        source: ?*const document.Document = null,
        width: i32 = 0,
        size: f32 = 0,

    } = .{},

    pub fn init(allocator: Allocator) Preview {

        return .{

            .arena = .init(allocator),

        };

    }

    pub fn deinit(self: *Preview) void {

        self.arena.deinit();

    }

    /// A node showing the preview, sized by `look`.
    pub fn node(self: *Preview, look: style.Style) Node {

        return .{

            .style = look,
            .content = .{

                .custom = &record,

            },
            .scroll = &wheel,
            .data = @intFromPtr(self),

        };

    }

    /// Shows `source` from now on, from its top.
    pub fn show(self: *Preview, source: *const document.Document) void {

        if (self.source == source) return;

        self.source = source;
        self.offset = 0;

    }

    /// Scrolls to where source line `line` shows, once laid out.
    pub fn follow(self: *Preview, line: usize) void {

        self.wanted = line;

    }

    /// Lays out `source` `width` pixels wide.
    pub fn layout(self: *Preview, source: []const u8, width: i32) Allocator.Error!void {

        _ = self.arena.reset(.retain_capacity);
        self.items = .empty;
        self.anchors = .empty;
        self.height = 0;

        const allocator = self.arena.allocator();
        const blocks = try parse(allocator, source);
        const body = self.size * style.factor();
        const margin = style.px(20);
        const right = width - margin;
        var y = margin;

        for (blocks, 0..) |block, index| {

            const quote_indent = style.px(18);
            const left = margin + @as(i32, block.quote) * quote_indent + @as(i32, block.level) * style.px(24) * @intFromBool(block.kind == .item);
            const color: u32 = if (block.quote != 0) theme.muted else theme.text;
            const top = y;

            try self.anchors.append(allocator, .{ .line = block.line, .y = top });

            switch (block.kind) {

                .paragraph => {

                    var flow = Flow.init(self, left, right, y, .sans, body, color);

                    try flow.pieces(block.content);
                    y = try flow.finish();

                },
                .heading => {

                    const scales = [_]f32{ 1.9, 1.5, 1.25, 1.1, 1, 0.9 };
                    const size = body * scales[@min(block.level, 6) - 1];

                    if (index != 0) y += @intFromFloat(size * 0.5);

                    var flow = Flow.init(self, left, right, y, .bold, size, if (block.level == 6) theme.muted else color);

                    try flow.pieces(block.content);
                    y = try flow.finish();

                    if (block.level <= 2) {

                        y += style.px(4);
                        try self.add(.{ .kind = .fill, .area = .{ .x = left, .y = y, .width = right - left, .height = 1 }, .color = theme.line });
                        y += style.px(4);

                    }

                },
                .item => y = try self.item(block, left, right, y, body, color),
                .code => y = try self.code(block, left, right, y, body),
                .rule => {

                    y += style.px(8);
                    try self.add(.{ .kind = .fill, .area = .{ .x = left, .y = y, .width = right - left, .height = style.px(2) }, .color = theme.line });
                    y += style.px(10);

                },
                .table => y = try self.table(block, left, right, y, body, color),

            }

            // Items of one list sit close; other blocks get a gap.
            const following = if (index + 1 < blocks.len) blocks[index + 1] else null;
            const tight = block.kind == .item and following != null and following.?.kind == .item;
            const gap: i32 = if (tight) @intFromFloat(body * 0.25) else @intFromFloat(body * 0.75);
            const bottom = y;

            y += gap;

            for (0..block.quote) |depth| {

                const continues = following != null and following.?.quote > depth;

                try self.add(.{

                    .kind = .fill,
                    .area = .{ .x = margin + @as(i32, @intCast(depth)) * quote_indent, .y = top, .width = style.px(3), .height = (if (continues) y else bottom) - top },
                    .color = theme.faint,
                    .radius = 1,

                });

            }

        }

        self.height = y + margin;

    }

    fn add(self: *Preview, shown: Item) Allocator.Error!void {

        try self.items.append(self.arena.allocator(), shown);

    }

    fn item(self: *Preview, block: Block, left: i32, right: i32, y: i32, body: f32, color: u32) Allocator.Error!i32 {

        const marker = style.px(24);
        var flow = Flow.init(self, left + marker, right, y, .sans, body, color);
        const middle = y + flow.baseline - @as(i32, @intFromFloat(body * 0.33));

        if (block.task) |done| {

            const side: i32 = @intFromFloat(body * 0.9);
            const box = Rect{ .x = left, .y = middle - @divTrunc(side, 2), .width = side, .height = side };

            if (done) {

                try self.add(.{ .kind = .fill, .area = box, .color = theme.accent, .radius = 3 });
                try self.add(.{ .kind = .label, .area = box, .string = font.Icon.check.text(), .face = .icons, .size = body * 0.8, .color = theme.background });

            } else {

                try self.add(.{ .kind = .outline, .area = box, .color = theme.muted, .radius = 3 });

            }

        } else if (block.number) |number| {

            const label = try std.fmt.allocPrint(self.arena.allocator(), "{d}.", .{number});

            try self.add(.{ .kind = .words, .area = .{ .x = left, .y = y, .width = marker, .height = flow.height }, .baseline = flow.top + flow.baseline, .string = label, .face = .sans, .size = body, .color = theme.muted });

        } else {

            const dot: i32 = @max(@as(i32, @intFromFloat(body * 0.36)), 4);

            // Deeper bullets are hollow.
            try self.add(.{

                .kind = if (block.level % 2 == 0) .fill else .outline,
                .area = .{ .x = left + style.px(4), .y = middle - @divTrunc(dot, 2), .width = dot, .height = dot },
                .color = theme.muted,
                .radius = @divTrunc(dot, 2),

            });

        }

        try flow.pieces(block.content);

        return flow.finish();

    }

    fn code(self: *Preview, block: Block, left: i32, right: i32, y: i32, body: f32) Allocator.Error!i32 {

        const language = syntax.find(block.info) orelse &syntax.plain;
        const size = body * 0.88;
        const face = font.face(.mono);
        const cell = face.advance(face.lookup('0')) * size / face.units;
        const height: i32 = @intFromFloat(@ceil(size * 1.5));
        const baseline = @divTrunc(height - text.leading(face, size), 2) + text.ascent(face, size);
        const padding = style.px(12);
        const count = std.mem.count(u8, std.mem.trimRight(u8, block.content, "\n"), "\n") + 1;
        const box = Rect{ .x = left, .y = y, .width = right - left, .height = @as(i32, @intCast(count)) * height + 2 * padding };
        var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, block.content, "\n"), '\n');
        var state = syntax.State.normal;
        var spans: [128]syntax.Span = undefined;
        var top = y + padding;

        try self.add(.{ .kind = .fill, .area = box, .color = theme.raised, .radius = style.px(theme.radius) });

        while (lines.next()) |line| : (top += height) {

            const filled, state = syntax.split(language, line, state, &spans);
            var start: usize = 0;
            var column: usize = 0;

            for (spans[0..filled]) |span| {

                // Tabs are drawn as the spaces to their stop, so a span is cut at each.
                var piece_start = start;

                for (line[start..span.end], start..) |byte, offset| {

                    if (byte == '\t') {

                        try self.words(line[piece_start..offset], left + padding, column, cell, top + baseline, size, span.kind, box);
                        column += columnsOf(line[piece_start..offset]);
                        column += 4 - column % 4;
                        piece_start = offset + 1;

                    }

                }

                try self.words(line[piece_start..span.end], left + padding, column, cell, top + baseline, size, span.kind, box);
                column += columnsOf(line[piece_start..span.end]);
                start = span.end;

            }

        }

        return box.bottom();

    }

    fn words(self: *Preview, string: []const u8, left: i32, column: usize, cell: f32, baseline: i32, size: f32, kind: syntax.Kind, box: Rect) Allocator.Error!void {

        if (string.len == 0) return;

        const x = left + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(column)) * cell)));

        try self.add(.{

            .kind = .words,
            .area = .{ .x = x, .y = baseline - @as(i32, @intFromFloat(size)), .width = @intFromFloat(@as(f32, @floatFromInt(columnsOf(string))) * cell), .height = @intFromFloat(size * 1.5) },
            .baseline = baseline,
            .string = string,
            .face = .mono,
            .size = size,
            .color = syntax.color(kind),
            .clip = box.inset(style.px(4)),

        });

    }

    fn table(self: *Preview, block: Block, left: i32, right: i32, y: i32, body: f32, color: u32) Allocator.Error!i32 {

        const allocator = self.arena.allocator();
        const count = block.columns.len;
        const padding = style.px(10);
        const widths = try allocator.alloc(i32, count);
        var rows = std.mem.splitScalar(u8, block.content, '\n');
        var header = true;

        // Natural widths first, a cell's text on one line, the header's in bold as it is drawn.
        @memset(widths, 0);

        while (rows.next()) |row| : (header = false) {

            const probe = Flow.init(self, 0, std.math.maxInt(i32) / 2, 0, if (header) .bold else .sans, body, color);
            var cells = Cells.init(row);

            for (widths) |*column| {

                const cell = cells.next() orelse break;
                var all = Pieces.init(cell);
                var span: f32 = 0;

                while (all.next()) |part| span += probe.measure(if (part.kind == .words) part.content else " ", part.look);
                column.* = @max(column.*, @as(i32, @intFromFloat(@ceil(span))) + 2 * padding + 1);

            }

        }

        const total = sum(widths);
        const room = right - left;

        if (total > room) for (widths) |*column| {

            column.* = @max(@divTrunc(column.* * room, @max(total, 1)), 2 * padding + style.px(24));

        };

        var top = y;
        var index: usize = 0;

        rows = std.mem.splitScalar(u8, block.content, '\n');

        while (rows.next()) |row| : (index += 1) {

            var cells = Cells.init(row);
            const first = self.items.items.len;
            var x = left;
            var bottom = top;

            for (widths, 0..) |column, place| {

                const cell = cells.next() orelse "";
                const before = self.items.items.len;
                var flow = Flow.init(self, x + padding, x + column - padding, top + @divTrunc(padding, 2), if (index == 0) .bold else .sans, body, color);

                try flow.pieces(cell);

                const end = try flow.finish();

                bottom = @max(bottom, end + @divTrunc(padding, 2));

                // A cell that fits on one line moves over as its column aligns.
                if (flow.top == top + @divTrunc(padding, 2) and block.columns[place] != .left) {

                    const used = @as(i32, @intFromFloat(@round(flow.x))) - (x + padding);
                    const spare = column - 2 * padding - used;
                    const shift = if (block.columns[place] == .center) @divTrunc(spare, 2) else spare;

                    for (self.items.items[before..]) |*moved| moved.area.x += shift;

                }

                x += column;

            }

            // The header's shading goes under its text, so it is slotted in before it.
            if (index == 0) try self.items.insert(allocator, first, .{ .kind = .fill, .area = .{ .x = left, .y = top, .width = x - left, .height = bottom - top }, .color = theme.raised });

            try self.add(.{ .kind = .fill, .area = .{ .x = left, .y = bottom, .width = x - left, .height = 1 }, .color = theme.line });
            top = bottom;

        }

        try self.add(.{ .kind = .outline, .area = .{ .x = left, .y = y, .width = sum(widths), .height = top - y + 1 }, .color = theme.line, .radius = 0 });

        return top;

    }

    fn paint(self: *Preview, owner: *Node, list: *draw.List) void {

        const area = owner.inner();
        const source = self.source orelse return;
        const width = area.width;

        if (self.laid.version != source.version or self.laid.source != source or self.laid.width != width or self.laid.size != self.size * style.factor()) {

            self.layout(source.text(), width) catch {};
            self.laid = .{ .version = source.version, .source = source, .width = width, .size = self.size * style.factor() };

        }

        if (self.wanted) |line| {

            self.offset = self.at(line);
            self.wanted = null;

        }

        self.offset = std.math.clamp(self.offset, 0, @max(self.height - area.height, 0));

        const limit = list.limit;

        defer list.limit = limit;

        for (self.items.items) |shown| {

            const y = area.y - self.offset;

            if (shown.area.y + y > area.bottom() or shown.area.bottom() + y < area.y) continue;

            const place = Rect{ .x = shown.area.x + area.x, .y = shown.area.y + y, .width = shown.area.width, .height = shown.area.height };

            list.limit = if (shown.clip) |clip| (Rect{ .x = clip.x + area.x, .y = clip.y + y, .width = clip.width, .height = clip.height }).within(limit) else limit;

            switch (shown.kind) {

                .words => list.text(shown.string, shown.face, shown.size, place.x, shown.baseline + y, shown.color),
                .fill => list.round(place, shown.radius, shown.color),
                .outline => list.outline(place, @floatFromInt(shown.radius), 1, shown.color),
                .label => list.label(shown.string, shown.face, shown.size, place, shown.color, .center),

            }

        }

        list.limit = limit;

        if (self.height > area.height) {

            const length = @max(@divTrunc(area.height * area.height, self.height), style.px(24));
            const start = @divTrunc((area.height - length) * self.offset, @max(self.height - area.height, 1));

            list.round(.{ .x = area.right() - style.px(6), .y = area.y + start, .width = style.px(4), .height = length }, style.px(2), theme.faint);

        }

    }

    /// Where source line `line` lies in the laid-out content, between the blocks before and after it.
    pub fn at(self: *const Preview, line: usize) i32 {

        const anchors = self.anchors.items;

        if (anchors.len == 0) return 0;

        var index: usize = 0;

        while (index + 1 < anchors.len and anchors[index + 1].line <= line) index += 1;

        const here = anchors[index];

        if (index + 1 == anchors.len or line <= here.line) return here.y;

        const next = anchors[index + 1];
        const through = @as(f32, @floatFromInt(line - here.line)) / @as(f32, @floatFromInt(next.line - here.line));

        return here.y + @as(i32, @intFromFloat(through * @as(f32, @floatFromInt(next.y - here.y))));

    }

    fn record(owner: *Node, list: *draw.List) void {

        const self: *Preview = @ptrFromInt(owner.data);

        self.paint(owner, list);

    }

    fn wheel(owner: *Node, delta: i32) bool {

        const self: *Preview = @ptrFromInt(owner.data);
        const moved = std.math.clamp(self.offset + delta, 0, @max(self.height - owner.inner().height, 0));

        if (moved == self.offset) return false;

        self.offset = moved;
        self.wanted = null;

        return true;

    }

};

fn sum(widths: []const i32) i32 {

    var total: i32 = 0;

    for (widths) |width| total += width;

    return total;

}

/// Columns `string` takes in a monospaced face, a column per character.
fn columnsOf(string: []const u8) usize {

    var count: usize = 0;

    for (string) |byte| {

        if (byte & 0xc0 != 0x80) count += 1;

    }

    return count;

}

/// ASCII punctuation, which a backslash makes plain text.
fn punctuation(char: u8) bool {

    return std.ascii.isPrint(char) and !std.ascii.isAlphanumeric(char) and char != ' ';

}
