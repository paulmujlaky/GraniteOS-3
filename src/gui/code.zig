//! A code view: edits a `Document` in the monospaced face beside a gutter of line numbers, in syntax colours, with the bracket
//! matching the one at the caret outlined and a search's matches marked. Enter keeps indentation, brackets close and indent
//! themselves, and long lines scroll sideways or wrap.

const std = @import("std");

const canvas = @import("canvas.zig");
const document = @import("document.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const image = @import("image.zig");
const search = @import("search.zig");
const style = @import("style.zig");
const syntax = @import("syntax.zig");
const text = @import("text.zig");
const theme = @import("theme.zig");

const api = @import("api");

const Document = document.Document;
const Selection = document.Selection;
const Node = @import("node.zig").Node;
const Track = @import("node.zig").Track;
const Rect = canvas.Rect;
const Point = canvas.Point;

pub const Error = document.Error;

/// Spans a line is coloured in, at most; the rest of a very long line takes the colour of the last.
const most = 256;

/// Matches marked at once, at most.
const marked = 256;

/// Brackets are matched no further than this many bytes away, so an unmatched one stays cheap.
const reach = 1 << 20;

/// Pixels between the caret line's number and the text, and the caret's width.
const gap = 12;
const bar = 2;

/// What the clipboard pastes, as large as the display keeps.
var pasted: [64 * 1024]u8 = undefined;

pub const Indent = struct {

    /// Indents with tab characters rather than spaces.
    tabs: bool = false,

    /// Columns per level, and between tab stops.
    width: u8 = 4,

    /// Reads which indentation most of `bytes` already uses.
    pub fn detect(bytes: []const u8) Indent {

        var tabbed: usize = 0;
        var spaced: usize = 0;
        var least: usize = 8;
        var lines = std.mem.splitScalar(u8, bytes[0..@min(bytes.len, 256 * 1024)], '\n');

        while (lines.next()) |line| {

            if (line.len == 0) continue;

            if (line[0] == '\t') tabbed += 1;

            const spaces = std.mem.indexOfNone(u8, line, " ") orelse continue;

            if (spaces >= 2) {

                spaced += 1;
                least = @min(least, spaces);

            }

        }

        return .{

            .tabs = tabbed > spaced,
            .width = if (spaced == 0 or least >= 4) 4 else @intCast(least),

        };

    }

};

/// One line's change from `each`: `remove` bytes at `at` give way to `insert`, offsets counting from the line's start.
pub const Splice = struct {

    at: usize = 0,
    remove: usize = 0,
    insert: []const u8 = "",

};

/// Where the last paint put things, for keys and the pointer to work from.
const Frame = struct {

    /// Where text goes, right of the gutter.
    area: Rect = .{},

    cell: f32 = 8,
    height: i32 = 16,
    rows: usize = 1,
    columns: usize = 80,

};

/// A line's rows: the whole line, or as wrapped at `columns`, breaking after a space where it can.
const Rows = struct {

    line: []const u8,
    columns: usize,
    tab: usize,
    index: usize = 0,
    done: bool = false,

    fn next(self: *Rows) ?Range {

        if (self.done) return null;

        const start = self.index;

        if (self.columns != 0) {

            var column: usize = 0;
            var space: ?usize = null;

            for (self.line[start..], start..) |byte, index| {

                const width = cells(byte, column, self.tab);

                if (column + width > self.columns and index > start) {

                    self.index = space orelse index;

                    return .{

                        .start = start,
                        .end = self.index,

                    };

                }

                column += width;
                if (byte == ' ') space = index + 1;

            }

        }

        self.done = true;

        return .{

            .start = start,
            .end = self.line.len,

        };

    }

};

const Range = struct {

    start: usize,
    end: usize,

};

/// A row of the view: a line, and which of its wrapped rows.
const Place = struct {

    line: usize,
    row: usize,

    fn before(self: Place, other: Place) bool {

        return self.line < other.line or (self.line == other.line and self.row < other.row);

    }

};

pub const Code = struct {

    document: Document,
    language: *const syntax.Language = &syntax.plain,
    indent: Indent = .{},

    caret: usize = 0,
    anchor: usize = 0,

    /// The column the caret keeps to as it moves up and down through shorter lines.
    goal: ?usize = null,

    /// The first row shown, and how many columns long lines have scrolled left when they do not wrap.
    top: Place = .{ .line = 0, .row = 0 },
    left: usize = 0,

    wrap: bool = false,

    /// Text size in pixels at 100%.
    size: f32 = 14,

    /// A search whose matches to mark.
    finder: ?*search.Finder = null,

    /// The highlighter's state at the start of each line, right for lines before `valid`.
    states: std.ArrayList(syntax.State) = .empty,
    valid: usize = 0,

    /// Where the caret was when last scrolled into view, so the view stays where the wheel leaves it until the caret moves.
    shown: usize = std.math.maxInt(usize),

    frame: Frame = .{},

    pub fn init(allocator: std.mem.Allocator) Code {

        return .{

            .document = .init(allocator),

        };

    }

    pub fn deinit(self: *Code) void {

        self.states.deinit(self.document.allocator);
        self.document.deinit();

    }

    /// Takes `owned`, allocated by the document's allocator, as the text of a file named `name`, reading its language and indentation.
    pub fn load(self: *Code, owned: []u8, name: []const u8) Error!void {

        try self.document.adopt(owned);
        self.language = syntax.detect(name, self.document.content(0));
        self.indent = Indent.detect(owned);
        self.restart();

    }

    /// Starts over at the top, as after opening a file.
    pub fn restart(self: *Code) void {

        self.caret = 0;
        self.anchor = 0;
        self.goal = null;
        self.top = .{ .line = 0, .row = 0 };
        self.left = 0;
        self.valid = 0;
        self.shown = std.math.maxInt(usize);

    }

    pub fn speak(self: *Code, language: *const syntax.Language) void {

        self.language = language;
        self.valid = 0;

    }

    pub fn bytes(self: *const Code) []const u8 {

        return self.document.text();

    }

    pub fn selection(self: *const Code) Selection {

        return .{

            .anchor = self.anchor,
            .caret = self.caret,

        };

    }

    pub fn selected(self: *const Code) []const u8 {

        const range = self.selection();

        return self.bytes()[range.start()..range.end()];

    }

    /// Selects from `anchor` to `caret`.
    pub fn select(self: *Code, anchor: usize, caret: usize) void {

        self.anchor = @min(anchor, self.document.length());
        self.caret = @min(caret, self.document.length());
        self.goal = null;
        self.document.seal();

    }

    /// Moves the caret to `target`, dragging the selection along when `extend`.
    pub fn move(self: *Code, target: usize, extend: bool) void {

        self.select(if (extend) self.anchor else target, target);

    }

    /// The caret's line and column, counting from one, a tab as far as its stop.
    pub fn position(self: *const Code) struct { usize, usize } {

        const line = self.document.line(self.caret);
        const start = self.document.start(line);

        return .{ line + 1, columns(self.bytes()[start..self.caret], self.indent.width) + 1 };

    }

    /// Scrolls so the caret's line sits mid-view, as after jumping to a match.
    pub fn middle(self: *Code) void {

        const line = self.document.line(self.caret);

        self.top = .{ .line = line -| self.frame.rows / 2, .row = 0 };
        self.left = 0;
        self.shown = std.math.maxInt(usize);

        // Revealing goes no further than putting the caret in view, so the line stays where it was put.
        self.reveal();
        self.shown = self.caret;

    }

    /// Replaces the selection with `string`, leaving the caret after it.
    pub fn insert(self: *Code, string: []const u8, kind: document.Kind) Error!void {

        const range = self.selection();

        try self.change(range.start(), range.end(), string, kind, .at(range.start() + string.len));

    }

    /// Replaces bytes `from` to `to` with `string`, then selects `after`.
    pub fn change(self: *Code, from: usize, to: usize, string: []const u8, kind: document.Kind, after: Selection) Error!void {

        try self.document.replace(from, to, string, self.selection(), kind);
        self.anchor = after.anchor;
        self.caret = after.caret;
        self.goal = null;

    }

    /// Types `char`: an opening bracket closes itself or wraps the selection, a closing one steps over its twin or moves back to
    /// its opener's indentation on an otherwise blank line.
    pub fn typed(self: *Code, char: u21) Error!void {

        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(char, &encoded) catch return;
        const string = encoded[0..length];
        const range = self.selection();
        const all = self.bytes();

        if (self.language.brackets and length == 1) {

            const next = if (range.caret < all.len) all[range.caret] else 0;

            if (twin(string[0])) |close| {

                if (!range.empty()) return self.surround(string, &.{close});

                if (next == 0 or blank(next) or next == '\n' or next == '\r' or opener(next) != null) {

                    return self.change(range.caret, range.caret, &.{ string[0], close }, .typing, .at(range.caret + 1));

                }

            }

            if (opener(string[0]) != null and range.empty()) {

                if (next == string[0]) return self.move(range.caret + 1, false);

                const line = self.document.line(range.caret);
                const start = self.document.start(line);

                if (std.mem.trim(u8, all[start..range.caret], " \t").len == 0) if (partner(all, range.caret, string[0])) |open| {

                    const indentation = leading(self.document.content(self.document.line(open)));
                    var built: [256]u8 = undefined;
                    const used = @min(indentation.len, built.len - 1);

                    @memcpy(built[0..used], indentation[0..used]);
                    built[used] = string[0];

                    return self.change(start, range.caret, built[0 .. used + 1], .typing, .at(start + used + 1));

                };

            }

        }

        try self.insert(string, .typing);

    }

    /// Breaks the line, carrying its indentation on, one level deeper after an opening bracket, and continuing a Markdown list.
    pub fn enter(self: *Code) Error!void {

        const range = self.selection();
        const all = self.bytes();
        const line = self.document.line(range.start());
        const start = self.document.start(line);
        const head = all[start..range.start()];
        const indentation = leading(head);
        var from = range.start();
        var to = range.end();

        // Spaces after the caret would only push the next line's text past its indentation.
        while (to < all.len and blank(all[to])) to += 1;

        var built: std.ArrayList(u8) = .empty;

        defer built.deinit(self.document.allocator);

        const allocator = self.document.allocator;
        const trimmed = std.mem.trimRight(u8, head, " \t");
        const last = if (trimmed.len == 0) 0 else trimmed[trimmed.len - 1];
        const opens = (self.language.brackets and twin(last) != null) or (self.language.colon and last == ':');

        // A line holding only indentation keeps none of it.
        if (trimmed.len == 0) from = start;

        try built.append(allocator, '\n');
        try built.appendSlice(allocator, indentation);

        if (self.language.markdown) if (syntax.bullet(head[indentation.len..])) |width| {

            const marker = head[indentation.len..][0..width];
            const empty = std.mem.trim(u8, head[indentation.len + width ..], " \t").len == 0 and to == self.document.end(line);

            // Enter on an empty item ends the list.
            if (empty) return self.change(start, to, "", .other, .at(start));

            if (std.ascii.isDigit(marker[0])) {

                const digits = std.mem.indexOfNone(u8, marker, "0123456789").?;
                const number = std.fmt.parseInt(u32, marker[0..digits], 10) catch 0;

                try built.print(allocator, "{d}{s}", .{ number +% 1, marker[digits..] });

            } else {

                try built.appendSlice(allocator, marker);

            }

            if (std.mem.startsWith(u8, head[indentation.len + width ..], "[ ] ") or std.mem.startsWith(u8, head[indentation.len + width ..], "[x] ")) {

                try built.appendSlice(allocator, "[ ] ");

            }

        };

        if (opens) try self.level(&built);

        const caret = from + built.items.len;

        if (opens and to < all.len and all[to] == twin(last)) {

            try built.append(allocator, '\n');
            try built.appendSlice(allocator, indentation);

        }

        try self.change(from, to, built.items, .typing, .at(caret));

    }

    /// Indents every line the selection touches a level, or inserts an indent at the caret when nothing is selected.
    pub fn tab(self: *Code) Error!void {

        const range = self.selection();

        if (!range.empty()) {

            const Deeper = struct {

                fn edit(code: *const Code, line: []const u8, _: usize, scratch: []u8) Splice {

                    if (std.mem.trim(u8, line, " \t").len == 0) return .{};

                    return .{

                        .insert = code.unit(scratch),

                    };

                }

            };

            return self.each(@as(*const Code, self), Deeper.edit);

        }

        var scratch: [16]u8 = undefined;
        const line = self.document.line(range.start());
        const column = columns(self.bytes()[self.document.start(line)..range.start()], self.indent.width);
        const width = @min(self.indent.width - column % self.indent.width, scratch.len);

        @memset(scratch[0..width], ' ');
        try self.insert(if (self.indent.tabs) "\t" else scratch[0..width], .typing);

    }

    /// Takes a level of indentation off every line the selection touches.
    pub fn untab(self: *Code) Error!void {

        const Shallower = struct {

            fn edit(code: *const Code, line: []const u8, _: usize, _: []u8) Splice {

                if (line.len != 0 and line[0] == '\t') return .{ .remove = 1 };

                const spaces = std.mem.indexOfNone(u8, line, " ") orelse line.len;

                return .{

                    .remove = @min(spaces, code.indent.width),

                };

            }

        };

        try self.each(@as(*const Code, self), Shallower.edit);

    }

    /// Adds `prefix` to every line the selection touches, after the shallowest indentation, or takes it off if they all have it.
    pub fn toggle(self: *Code, prefix: []const u8) Error!void {

        const bare = std.mem.trimRight(u8, prefix, " ");
        const range = self.lines();
        var least: usize = std.math.maxInt(usize);
        var every = true;

        for (range.first..range.last + 1) |line| {

            const content = self.document.content(line);
            const indentation = leading(content).len;

            if (indentation == content.len) continue;

            least = @min(least, indentation);
            if (!std.mem.startsWith(u8, content[indentation..], bare)) every = false;

        }

        if (least == std.math.maxInt(usize)) least = 0;

        const Marker = struct {

            prefix: []const u8,
            bare: []const u8,
            least: usize,
            every: bool,

            fn edit(marker: *const @This(), line: []const u8, _: usize, _: []u8) Splice {

                const indentation = leading(line).len;

                if (indentation == line.len) return .{};

                if (marker.every) {

                    const after = indentation + marker.bare.len;
                    const extra = marker.prefix.len > marker.bare.len and after < line.len and line[after] == ' ';

                    return .{

                        .at = indentation,
                        .remove = marker.bare.len + @intFromBool(extra),

                    };

                }

                return .{

                    .at = marker.least,
                    .insert = marker.prefix,

                };

            }

        };

        const wanted = Marker{

            .prefix = prefix,
            .bare = bare,
            .least = least,
            .every = every,

        };

        try self.each(&wanted, Marker.edit);

    }

    /// Comments the selected lines out with the language's line comment, or back in.
    pub fn comment(self: *Code) Error!void {

        if (self.language.line_comment.len == 0) return;

        var prefix: [8]u8 = undefined;
        const length = @min(self.language.line_comment.len, prefix.len - 1);

        @memcpy(prefix[0..length], self.language.line_comment[0..length]);
        prefix[length] = ' ';

        try self.toggle(prefix[0 .. length + 1]);

    }

    /// Puts `open` and `close` around the selection, keeping it selected inside them, or takes them away if they are already there.
    pub fn surround(self: *Code, open: []const u8, close: []const u8) Error!void {

        const range = self.selection();
        const all = self.bytes();
        const start = range.start();
        const stop = range.end();

        if (start >= open.len and std.mem.eql(u8, all[start - open.len .. start], open) and std.mem.startsWith(u8, all[stop..], close)) {

            self.document.seal();
            try self.document.replace(stop, stop + close.len, "", range, .joined);
            try self.document.replace(start - open.len, start, "", range, .joined);
            self.select(start - open.len, stop - open.len);

            return;

        }

        var built: std.ArrayList(u8) = .empty;

        defer built.deinit(self.document.allocator);

        try built.ensureTotalCapacity(self.document.allocator, open.len + stop - start + close.len);
        built.appendSliceAssumeCapacity(open);
        built.appendSliceAssumeCapacity(all[start..stop]);
        built.appendSliceAssumeCapacity(close);

        try self.change(start, stop, built.items, .other, .{ .anchor = start + open.len, .caret = stop + open.len });

    }

    /// The first and last lines the selection touches; one ending at a line's very start leaves that line out.
    pub fn lines(self: *const Code) struct { first: usize, last: usize } {

        const range = self.selection();
        const first = self.document.line(range.start());
        var last = self.document.line(range.end());

        if (last > first and range.end() == self.document.start(last)) last -= 1;

        return .{

            .first = first,
            .last = last,

        };

    }

    /// Rewrites each line the selection touches through `edit`, as one step, keeping the selection on the same characters.
    /// `edit` sees each line without its newline, its index among them, and scratch space for what it inserts.
    pub fn each(self: *Code, context: anytype, comptime edit: fn (@TypeOf(context), []const u8, usize, []u8) Splice) Error!void {

        const range = self.lines();
        const from = self.document.start(range.first);
        const to = self.document.end(range.last);
        const all = self.bytes();
        const allocator = self.document.allocator;
        var built: std.ArrayList(u8) = .empty;

        defer built.deinit(allocator);

        try built.ensureTotalCapacity(allocator, to - from + 64);

        var anchor = self.anchor;
        var caret = self.caret;

        for (range.first..range.last + 1) |line| {

            const start = self.document.start(line);
            const content = self.document.content(line);
            var scratch: [64]u8 = undefined;
            var splice = edit(context, content, line - range.first, &scratch);

            splice.at = @min(splice.at, content.len);
            splice.remove = @min(splice.remove, content.len - splice.at);

            const base = from + built.items.len;

            try built.appendSlice(allocator, content[0..splice.at]);
            try built.appendSlice(allocator, splice.insert);
            try built.appendSlice(allocator, content[splice.at + splice.remove ..]);
            if (line != range.last) try built.append(allocator, '\n');

            if (self.anchor >= start and self.anchor <= start + content.len) anchor = base + shifted(self.anchor - start, splice);
            if (self.caret >= start and self.caret <= start + content.len) caret = base + shifted(self.caret - start, splice);

        }

        if (std.mem.eql(u8, built.items, all[from..to])) return;

        // What lies after the rewritten lines moves with them, such as a selection ending at the next line's start.
        if (self.anchor > to) anchor = self.anchor - (to - from) + built.items.len;
        if (self.caret > to) caret = self.caret - (to - from) + built.items.len;

        try self.change(from, to, built.items, .other, .{ .anchor = anchor, .caret = caret });

    }

    /// Deletes the selection, or the character or word before the caret: back to the last tab stop within indentation, and an
    /// empty pair of brackets together.
    pub fn backspace(self: *Code, word: bool) Error!void {

        const range = self.selection();

        if (!range.empty()) return self.insert("", .deleting);
        if (range.caret == 0) return;

        const all = self.bytes();
        const caret = range.caret;
        var from = if (word) text.boundary(all, caret, -1) else text.before(all, caret);
        var to = caret;

        if (!word) {

            const start = self.document.start(self.document.line(caret));
            const head = all[start..caret];

            if (!self.indent.tabs and head.len > 1 and std.mem.indexOfNone(u8, head, " ") == null) {

                const width = self.indent.width;

                from = caret - ((head.len - 1) % width + 1);

            }

            if (self.language.brackets and caret < all.len and twin(all[caret - 1]) == all[caret]) to = caret + 1;

        }

        try self.change(from, to, "", .deleting, .at(from));

    }

    /// Deletes the selection, or the character or word after the caret.
    pub fn delete(self: *Code, word: bool) Error!void {

        const range = self.selection();

        if (!range.empty()) return self.insert("", .deleting);

        const all = self.bytes();

        if (range.caret == all.len) return;

        const to = if (word) text.boundary(all, range.caret, 1) else text.after(all, range.caret);

        try self.change(range.caret, to, "", .deleting, .at(range.caret));

    }

    /// Moves the caret a character or word left (`direction` -1) or right (1); without `extend`, a selection collapses to that edge.
    pub fn horizontal(self: *Code, direction: i8, word: bool, extend: bool) void {

        const range = self.selection();
        const all = self.bytes();

        if (!extend and !range.empty()) return self.move(if (direction < 0) range.start() else range.end(), false);

        const target = if (direction < 0)
            (if (self.caret == 0) 0 else if (word) text.boundary(all, self.caret, -1) else text.before(all, self.caret))
        else
            (if (self.caret == all.len) all.len else if (word) text.boundary(all, self.caret, 1) else text.after(all, self.caret));

        self.move(target, extend);

    }

    /// Moves to the line's first non-blank character, or its very start when already there.
    pub fn home(self: *Code, extend: bool) void {

        const line = self.document.line(self.caret);
        const start = self.document.start(line);
        const first = start + leading(self.document.content(line)).len;

        self.move(if (self.caret == first) start else first, extend);

    }

    pub fn end(self: *Code, extend: bool) void {

        self.move(self.document.end(self.document.line(self.caret)), extend);

    }

    /// Moves the caret `delta` rows up (negative) or down, keeping to its column; past the first or last row it goes to the start or end.
    pub fn vertical(self: *Code, delta: isize, extend: bool) void {

        const here = self.place(self.caret);
        const goal = self.goal orelse here.column;
        var at = here.at;
        const count = self.document.count();
        var steps = @abs(delta);
        var target: ?usize = null;

        while (steps > 0) : (steps -= 1) {

            if (delta < 0) {

                if (at.row > 0) {

                    at.row -= 1;

                } else if (at.line > 0) {

                    at.line -= 1;
                    at.row = self.rowCount(at.line) - 1;

                } else {

                    target = 0;
                    break;

                }

            } else if (at.row + 1 < self.rowCount(at.line)) {

                at.row += 1;

            } else if (at.line + 1 < count) {

                at = .{ .line = at.line + 1, .row = 0 };

            } else {

                target = self.document.length();
                break;

            }

        }

        self.move(target orelse self.offset(at, goal), extend);
        self.goal = goal;

    }

    pub fn undo(self: *Code) Error!bool {

        const before = try self.document.undo() orelse return false;

        self.select(before.anchor, before.caret);

        return true;

    }

    pub fn redo(self: *Code) Error!bool {

        const after = try self.document.redo() orelse return false;

        self.select(after.anchor, after.caret);

        return true;

    }

    /// Selects the next match of `finder` from `from`, or the previous one before it when not `forwards`, wrapping around the
    /// ends; false when there is none.
    pub fn seek(self: *Code, finder: *search.Finder, forwards: bool, from: usize) bool {

        const all = self.bytes();

        const found = if (forwards)
            finder.next(all, from) orelse finder.next(all, 0)
        else
            finder.previous(all, from) orelse finder.previous(all, all.len + 1);

        const match = found orelse return false;

        self.select(match.start, match.end);
        self.middle();

        return true;

    }

    /// Replaces the selection with `replacement` if it is a match of `finder`, then selects the next match; false when there is none.
    pub fn substitute(self: *Code, finder: *search.Finder, replacement: []const u8) Error!bool {

        const range = self.selection();
        const all = self.bytes();

        if (finder.next(all, range.start())) |match| if (match.start == range.start() and match.end == range.end()) {

            var built: std.ArrayList(u8) = .empty;

            defer built.deinit(self.document.allocator);

            try finder.expand(all, match, replacement, &built, self.document.allocator);
            try self.insert(built.items, .other);

        };

        return self.seek(finder, true, self.caret);

    }

    /// Replaces every match of `finder` with `replacement` as one step, returning how many there were.
    pub fn substituteAll(self: *Code, finder: *search.Finder, replacement: []const u8) Error!usize {

        const all = self.bytes();
        const allocator = self.document.allocator;
        var built: std.ArrayList(u8) = .empty;

        defer built.deinit(allocator);

        var first: ?usize = null;
        var last: usize = 0;
        var at: usize = 0;
        var count: usize = 0;

        while (finder.next(all, at)) |match| : (count += 1) {

            if (first == null) {

                first = match.start;
                last = match.start;

            }

            try built.appendSlice(allocator, all[last..match.start]);
            try finder.expand(all, match, replacement, &built, allocator);
            last = match.end;
            at = search.past(all, match);

        }

        const start = first orelse return 0;
        const caret = if (self.caret <= start) self.caret else if (self.caret >= last) self.caret + built.items.len - (last - start) else start;

        try self.change(start, last, built.items, .other, .at(caret));

        return count;

    }

    /// The bracket beside the caret, before it first, and the one matching it; null when neither side is a matched bracket.
    pub fn bracket(self: *const Code) ?[2]usize {

        const all = self.bytes();

        for ([_]usize{ self.caret -| 1, self.caret }, 0..) |at, index| {

            if (index == 0 and self.caret == 0) continue;
            if (at >= all.len) continue;

            const char = all[at];

            if (twin(char) != null or opener(char) != null) if (partner(all, at, char)) |other| return .{ at, other };

        }

        return null;

    }

    /// Applies a key press, typing, moving, deleting, indenting, undoing, or using the clipboard; true when anything changed.
    pub fn key(self: *Code, event: api.Event) bool {

        if (event.kind != .key or !event.pressed) return false;

        return self.press(event) catch false;

    }

    fn press(self: *Code, event: api.Event) Error!bool {

        const control = event.modifiers.control;
        const shift = event.modifiers.shift;

        switch (event.key()) {

            .character => {

                if (control and !event.modifiers.alt) {

                    switch (event.char | 0x20) {

                        'a' => self.select(0, self.document.length()),
                        'c' => return self.copy(),
                        'x' => return self.cut(),
                        'v' => return self.paste(),
                        'z' => return if (shift) self.redo() else self.undo(),
                        'y' => return self.redo(),
                        '/' => try self.comment(),
                        else => return false,

                    }

                    return true;

                }

                if (event.modifiers.alt or event.modifiers.super or event.char < 0x20 or event.char == 0x7f) return false;

                try self.typed(event.char);

            },
            .enter => try self.enter(),
            .tab => {

                if (control) return false;
                if (shift) try self.untab() else try self.tab();

            },
            .backspace => try self.backspace(control),
            .delete => try self.delete(control),
            .left => self.horizontal(-1, control, shift),
            .right => self.horizontal(1, control, shift),
            .up, .down => {

                const direction: isize = if (event.key() == .up) -1 else 1;

                if (control) return self.roll(direction);
                self.vertical(direction, shift);

            },
            .page_up, .page_down => {

                const step: isize = @intCast(@max(self.frame.rows, 2) - 1);

                self.vertical(if (event.key() == .page_up) -step else step, shift);

            },
            .home => if (control) self.move(0, shift) else self.home(shift),
            .end => if (control) self.move(self.document.length(), shift) else self.end(shift),
            else => return false,

        }

        return true;

    }

    /// Copies the selection, or the whole line when nothing is selected.
    pub fn copy(self: *Code) bool {

        const piece = self.clipped();

        if (piece.len == 0) return false;

        image.display.copy(piece) catch {};

        return true;

    }

    pub fn cut(self: *Code) Error!bool {

        if (!self.copy()) return false;

        if (self.selection().empty()) {

            const line = self.document.line(self.caret);
            const start = self.document.start(line);
            const finish = if (line + 1 < self.document.count()) self.document.start(line + 1) else self.document.length();

            try self.change(start, finish, "", .other, .at(start));

        } else {

            try self.insert("", .other);

        }

        return true;

    }

    pub fn paste(self: *Code) Error!bool {

        const piece = image.display.paste(&pasted) catch return false;

        try self.insert(piece, .other);

        return true;

    }

    /// What copying takes: the selection, or the caret's line with its newline.
    fn clipped(self: *const Code) []const u8 {

        if (!self.selection().empty()) return self.selected();

        const line = self.document.line(self.caret);
        const start = self.document.start(line);
        const finish = if (line + 1 < self.document.count()) self.document.start(line + 1) else self.document.length();

        return self.bytes()[start..finish];

    }

    /// A node showing the code view and taking its keys, pointer, and wheel; point its `data` at another view to show that one instead.
    pub fn node(self: *Code, look: style.Style) Node {

        return .{

            .style = look,
            .content = .{

                .custom = &record,

            },
            .track = &follow,
            .open = &pick,
            .scroll = &wheel,
            .typing = true,
            .cursor = .text,
            .data = @intFromPtr(self),

        };

    }

    /// Scrolls `delta` rows, positive downward; false when the view was already at that end.
    pub fn roll(self: *Code, delta: isize) bool {

        const before = self.top;
        const count = self.document.count();
        var steps = @abs(delta);

        while (steps > 0) : (steps -= 1) {

            if (delta < 0) {

                if (self.top.row > 0) {

                    self.top.row -= 1;

                } else if (self.top.line > 0) {

                    self.top.line -= 1;
                    self.top.row = self.rowCount(self.top.line) - 1;

                } else break;

            } else if (self.top.row + 1 < self.rowCount(self.top.line)) {

                self.top.row += 1;

            } else if (self.top.line + 1 < count) {

                self.top = .{ .line = self.top.line + 1, .row = 0 };

            } else break;

        }

        // The caret may now be off the view; it stays there until it moves.
        self.shown = self.caret;

        return !std.meta.eql(before, self.top);

    }

    /// One indentation level, written into `scratch`.
    fn unit(self: *const Code, scratch: []u8) []const u8 {

        if (self.indent.tabs) return "\t";

        const width = @min(self.indent.width, scratch.len);

        @memset(scratch[0..width], ' ');

        return scratch[0..width];

    }

    fn level(self: *const Code, built: *std.ArrayList(u8)) Error!void {

        var scratch: [16]u8 = undefined;

        try built.appendSlice(self.document.allocator, self.unit(&scratch));

    }

    /// Which row `offset` falls on, where that row starts, and the caret's column within it.
    fn place(self: *const Code, target: usize) struct { at: Place, start: usize, column: usize } {

        const line = self.document.line(target);
        const start = self.document.start(line);
        const content = self.document.content(line);
        var rows = self.split(content);
        var row: usize = 0;

        while (rows.next()) |range| : (row += 1) {

            if (target - start < range.end or rows.done) {

                return .{

                    .at = .{ .line = line, .row = row },
                    .start = start + range.start,
                    .column = columns(content[range.start..@max(target - start, range.start)], self.indent.width),

                };

            }

        }

        unreachable;

    }

    /// The offset nearest `column` along row `at`; a wrapped row's end is its last character, as its very end starts the next.
    fn offset(self: *const Code, at: Place, column: usize) usize {

        const start = self.document.start(at.line);
        const range = self.rowOf(at);
        const content = self.document.content(at.line);
        const found = nearest(content, range, column, self.indent.width);

        if (found == range.end and range.end < content.len and found > range.start) return start + text.before(content, found);

        return start + found;

    }

    fn rowOf(self: *const Code, at: Place) Range {

        var rows = self.split(self.document.content(at.line));
        var row: usize = 0;
        var last = Range{ .start = 0, .end = 0 };

        while (rows.next()) |range| : (row += 1) {

            last = range;
            if (row == at.row) break;

        }

        return last;

    }

    fn rowCount(self: *const Code, line: usize) usize {

        if (!self.wrap) return 1;

        var rows = self.split(self.document.content(line));
        var count: usize = 0;

        while (rows.next()) |_| count += 1;

        return count;

    }

    fn split(self: *const Code, content: []const u8) Rows {

        return .{

            .line = content,
            .columns = if (self.wrap) self.frame.columns else 0,
            .tab = self.indent.width,

        };

    }

    /// Scrolls the least that brings the caret into view.
    fn reveal(self: *Code) void {

        const rows = self.frame.rows;
        const here = self.place(self.caret);

        if (!self.wrap) {

            const column = here.column;
            const margin = @min(4, self.frame.columns / 4);

            self.top.row = 0;
            if (here.at.line < self.top.line) self.top.line = here.at.line;
            if (here.at.line >= self.top.line + rows) self.top.line = here.at.line + 1 - rows;
            if (column < self.left + margin) self.left = column -| margin;
            if (column + margin >= self.left + self.frame.columns) self.left = column + margin + 1 -| self.frame.columns;

            return;

        }

        self.left = 0;

        if (here.at.before(self.top)) {

            self.top = here.at;
            return;

        }

        // Count the rows down to the caret's, unless its line is too far down for them to fit anyway.
        var seen: usize = 0;
        var at = self.top;

        if (here.at.line - at.line < rows) {

            while (!std.meta.eql(at, here.at) and seen < rows) : (seen += 1) {

                at = if (at.row + 1 < self.rowCount(at.line)) .{ .line = at.line, .row = at.row + 1 } else .{ .line = at.line + 1, .row = 0 };

            }

            if (seen < rows) return;

        }

        // Put the caret's row at the bottom.
        at = here.at;

        var back = rows - 1;

        while (back > 0) {

            if (at.row >= back) {

                at.row -= back;
                break;

            }

            back -= at.row + 1;
            if (at.line == 0) {

                at.row = 0;
                break;

            }

            at.line -= 1;
            at.row = self.rowCount(at.line) - 1;

        }

        self.top = at;

    }

    /// The highlighter's state at the start of `line`, working it out from the last line known.
    fn state(self: *Code, line: usize) syntax.State {

        const language = self.language;

        if (line == 0 or (language.block_comment == null and language.runs.len == 0 and !language.triple and !language.markdown)) return .normal;

        const allocator = self.document.allocator;

        if (self.valid == 0) {

            self.states.clearRetainingCapacity();
            self.states.append(allocator, .normal) catch return .normal;
            self.valid = 1;

        }

        while (self.valid <= line) {

            const previous = self.valid - 1;
            _, const next = syntax.split(language, self.document.content(previous), self.states.items[previous], &.{});

            if (self.states.items.len > self.valid) {

                self.states.items[self.valid] = next;

            } else {

                self.states.append(allocator, next) catch return .normal;

            }

            self.valid += 1;

        }

        return self.states.items[line];

    }

    /// Catches up with edits made since the last paint: later lines' states go stale, and the view and caret stay inside the text.
    fn settle(self: *Code) void {

        const touched = self.document.touched;

        if (touched != std.math.maxInt(usize)) {

            self.valid = @min(self.valid, touched + 1);
            self.document.touched = std.math.maxInt(usize);

        }

        const length = self.document.length();

        self.caret = @min(self.caret, length);
        self.anchor = @min(self.anchor, length);

        if (self.top.line >= self.document.count()) self.top = .{ .line = self.document.count() - 1, .row = 0 };

    }

    fn paint(self: *Code, owner: *Node, list: *draw.List) void {

        const face = font.face(.mono);
        const size = self.size * style.factor();
        const cell = face.advance(face.lookup('0')) * size / face.units;
        const height = text.leading(face, size) + @as(i32, @intFromFloat(@round(size * 0.3)));
        const baseline = @divTrunc(height - text.leading(face, size), 2) + text.ascent(face, size);
        const inner = owner.inner();
        const count = self.document.count();
        var digits: usize = 3;

        while (std.math.pow(usize, 10, digits) <= count) digits += 1;

        const gutter = @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(digits + 1)) * cell))) + style.px(gap);

        self.settle();

        const area = Rect{

            .x = inner.x + gutter,
            .y = inner.y,
            .width = @max(inner.width - gutter, 1),
            .height = inner.height,

        };

        const rows: usize = @intCast(@max(@divTrunc(area.height, height), 1));

        const frame = Frame{

            .area = area,
            .cell = cell,
            .height = height,
            .rows = rows,
            .columns = @intFromFloat(@max(@floor(@as(f32, @floatFromInt(area.width)) / cell) - 1, 1)),

        };

        // A view resized or rewrapped brings the caret back into it.
        if (frame.rows != self.frame.rows or frame.columns != self.frame.columns) self.shown = std.math.maxInt(usize);

        self.frame = frame;

        if (self.top.row >= self.rowCount(self.top.line)) self.top.row = 0;

        if (self.shown != self.caret) {

            self.reveal();
            self.shown = self.caret;

        }

        const all = self.bytes();
        const range = self.selection();
        const caret_line = self.document.line(self.caret);
        const pair = self.bracket();
        const limit = list.limit;

        defer list.limit = limit;

        var matches: [marked]search.Match = undefined;
        var found: usize = 0;

        if (self.finder) |finder| if (!finder.idle()) {

            const last = @min(count - 1, self.top.line + rows);
            const finish = self.document.end(last);
            var at = self.document.start(self.top.line);

            while (found < marked) : (found += 1) {

                const match = finder.next(all, at) orelse break;

                if (match.start > finish) break;
                matches[found] = match;
                at = search.past(all, match);

            }

        };

        var spans: [most]syntax.Span = undefined;
        var number_bytes: [24]u8 = undefined;
        var y = area.y;
        var line = self.top.line;
        var shown_rows: usize = 0;

        while (line < count and shown_rows < rows) : (line += 1) {

            const start = self.document.start(line);
            const content = self.document.content(line);
            const coloured, _ = syntax.split(self.language, content, self.state(line), &spans);
            var wrapped = self.split(content);
            var row: usize = 0;

            while (wrapped.next()) |piece| : (row += 1) {

                if (line == self.top.line and row < self.top.row) continue;
                if (shown_rows == rows) break;

                const band = Rect{

                    .x = inner.x,
                    .y = y,
                    .width = inner.width,
                    .height = height,

                };

                list.limit = inner.within(limit);

                if (line == caret_line and range.empty() and owner.focused) list.fill(band, theme.raised);

                if (row == 0) {

                    const number = std.fmt.bufPrint(&number_bytes, "{d}", .{line + 1}) catch "";
                    const x = area.x - style.px(gap) - @as(i32, @intFromFloat(@as(f32, @floatFromInt(number.len)) * cell));

                    list.text(number, .mono, size, x, y + baseline, if (line == caret_line) theme.muted else theme.faint);

                }

                list.limit = area.within(limit);

                const row_start = start + piece.start;
                const row_end = start + piece.end;
                const last_row = piece.end == content.len;

                for (matches[0..found]) |match| self.shade(list, content, piece, start, match.start, match.end, y, theme.syntax.found, false);
                if (!range.empty()) self.shade(list, content, piece, start, range.start(), range.end(), y, theme.selected, last_row and range.end() > row_end);

                if (pair) |both| for (both) |at| {

                    if (at < row_start or at >= row_end) continue;

                    const x = self.spot(content, piece, at - start);

                    list.outline(.{ .x = x, .y = y, .width = @intFromFloat(@ceil(cell)), .height = height }, 2, 1, theme.syntax.bracket);

                };

                self.runs(list, content, piece, spans[0..coloured], y + baseline, size);

                if (owner.focused and self.caret >= row_start and self.caret <= row_end and (self.caret < row_end or last_row)) {

                    list.fill(.{ .x = self.spot(content, piece, self.caret - start), .y = y, .width = style.px(bar), .height = height }, theme.accent);

                }

                y += height;
                shown_rows += 1;

            }

        }

        list.limit = inner.within(limit);

        // A thin thumb shows how far through the lines the view is.
        if (count > rows) {

            const span = inner.height;
            const length = @max(@divTrunc(span * @as(i32, @intCast(rows)), @as(i32, @intCast(@min(count, std.math.maxInt(i32))))), style.px(24));
            const fraction = @as(f32, @floatFromInt(self.top.line)) / @as(f32, @floatFromInt(count - 1));

            list.round(.{

                .x = inner.right() - style.px(6),
                .y = inner.y + @as(i32, @intFromFloat(fraction * @as(f32, @floatFromInt(span - length)))),
                .width = style.px(4),
                .height = length,

            }, style.px(2), theme.faint);

        }

    }

    /// The x where byte `at` of `content` sits on row `piece`.
    fn spot(self: *const Code, content: []const u8, piece: Range, at: usize) i32 {

        const column = columns(content[piece.start..@max(at, piece.start)], self.indent.width);
        const shift = @as(f32, @floatFromInt(column)) - @as(f32, @floatFromInt(if (self.wrap) 0 else self.left));

        return self.frame.area.x + @as(i32, @intFromFloat(@round(shift * self.frame.cell)));

    }

    /// Fills behind bytes `from` to `to` where they cross row `piece` of the line starting at `start`; `beyond` reaches past its end
    /// for a selected newline.
    fn shade(self: *const Code, list: *draw.List, content: []const u8, piece: Range, start: usize, from: usize, to: usize, y: i32, color: u32, beyond: bool) void {

        const low = @max(from, start + piece.start);
        const high = @min(to, start + piece.end);

        if (low > high or (low == high and !beyond)) return;

        const left = self.spot(content, piece, low - start);
        const right = self.spot(content, piece, high - start) + if (beyond) @as(i32, @intFromFloat(self.frame.cell / 2)) else 0;

        list.fill(.{ .x = left, .y = y, .width = right - left, .height = self.frame.height }, color);

    }

    /// Draws row `piece` of `content` in its colours, a run per stretch of one kind, skipping tabs and what scrolled off the left.
    fn runs(self: *const Code, list: *draw.List, content: []const u8, piece: Range, coloured: []const syntax.Span, baseline: i32, size: f32) void {

        const skip = if (self.wrap) 0 else self.left;
        const visible = skip + self.frame.columns + 2;
        var column: usize = 0;
        var span: usize = 0;
        var run_start: ?usize = null;
        var run_column: usize = 0;
        var run_kind = syntax.Kind.plain;
        var index = piece.start;

        while (index <= piece.end) : (index += 1) {

            while (span < coloured.len and coloured[span].end <= index) span += 1;

            const done = index == piece.end or column >= visible;
            const byte = if (done) 0 else content[index];
            const kind = if (span < coloured.len) coloured[span].kind else .plain;
            const hidden = byte < 0x20 or byte == 0x7f or column < skip;

            if (run_start) |first| if (done or hidden or kind != run_kind) {

                const x = self.frame.area.x + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(run_column - skip)) * self.frame.cell)));

                list.text(content[first..index], .mono, size, x, baseline, syntax.color(run_kind));
                run_start = null;

            };

            if (done) break;

            // A run starts on a character's first byte, never inside one.
            if (run_start == null and !hidden and byte & 0xc0 != 0x80) {

                run_start = index;
                run_column = column;
                run_kind = kind;

            }

            column += cells(byte, column, self.indent.width);

        }

    }

    fn record(owner: *Node, list: *draw.List) void {

        const self: *Code = @ptrFromInt(owner.data);

        self.paint(owner, list);

    }

    /// The offset under `at`, rows above or below the view counting on past its edges.
    fn locate(self: *const Code, at: Point) usize {

        const frame = self.frame;
        const down = @divFloor(at.y - frame.area.y, frame.height);
        var row = self.top;
        var steps = @abs(down);

        while (steps > 0) : (steps -= 1) {

            if (down < 0) {

                if (row.row > 0) {

                    row.row -= 1;

                } else if (row.line > 0) {

                    row.line -= 1;
                    row.row = self.rowCount(row.line) - 1;

                } else return 0;

            } else if (row.row + 1 < self.rowCount(row.line)) {

                row.row += 1;

            } else if (row.line + 1 < self.document.count()) {

                row = .{ .line = row.line + 1, .row = 0 };

            } else return self.document.length();

        }

        const across = @as(f32, @floatFromInt(at.x - frame.area.x)) / frame.cell;
        const column = @as(usize, @intFromFloat(@max(@round(across), 0))) + if (self.wrap) 0 else self.left;

        return self.offset(row, column);

    }

    fn follow(owner: *Node, motion: Track) void {

        const self: *Code = @ptrFromInt(owner.data);
        const target = self.locate(motion.at);

        switch (motion.phase) {

            .down => self.move(target, motion.shift),
            .move => self.move(target, true),
            .up => {},

        }

    }

    /// Selects the word under the caret, as a double-click does.
    fn pick(owner: *Node) void {

        const self: *Code = @ptrFromInt(owner.data);
        const all = self.bytes();
        var first = self.caret;
        var last = self.caret;

        while (first > 0 and text.wordy(all[first - 1])) first -= 1;
        while (last < all.len and text.wordy(all[last])) last += 1;

        self.select(first, last);

    }

    fn wheel(owner: *Node, delta: i32) bool {

        const self: *Code = @ptrFromInt(owner.data);
        const steps = @divTrunc(delta, @max(self.frame.height, 1));

        return self.roll(if (steps == 0) std.math.sign(delta) else steps);

    }

};

/// How many columns `byte` takes at `column`: a tab reaches the next stop, a character's first byte takes one, and the rest
/// of its bytes and a carriage return none.
fn cells(byte: u8, column: usize, tab: usize) usize {

    if (byte == '\t') return tab - column % tab;
    if (byte == '\r' or byte & 0xc0 == 0x80) return 0;

    return 1;

}

/// The columns `string` spans from a line's start.
fn columns(string: []const u8, tab: usize) usize {

    var column: usize = 0;

    for (string) |byte| column += cells(byte, column, tab);

    return column;

}

/// The offset along row `range` of `line` whose column is nearest `column`, on a character's first byte.
fn nearest(line: []const u8, range: Range, column: usize, tab: usize) usize {

    var at: usize = 0;

    for (line[range.start..range.end], range.start..) |byte, index| {

        const width = cells(byte, at, tab);

        if (width == 0) continue;

        // Left of a character's middle puts the caret before it.
        if (2 * column < 2 * at + width) return index;
        at += width;

    }

    return range.end;

}

/// Where a position `offset` bytes into a line lands after `splice`; inside what it removed, it goes to the end of what it inserted.
fn shifted(offset: usize, splice: Splice) usize {

    if (offset <= splice.at) return offset;
    if (offset >= splice.at + splice.remove) return offset - splice.remove + splice.insert.len;

    return splice.at + splice.insert.len;

}

/// The spaces and tabs starting `line`.
fn leading(line: []const u8) []const u8 {

    return line[0 .. std.mem.indexOfNone(u8, line, " \t") orelse line.len];

}

fn blank(byte: u8) bool {

    return byte == ' ' or byte == '\t';

}

/// The bracket closing `char`, if it opens one.
fn twin(char: u8) ?u8 {

    return switch (char) {

        '(' => ')',
        '[' => ']',
        '{' => '}',
        else => null,

    };

}

/// The bracket opening `char`, if it closes one.
fn opener(char: u8) ?u8 {

    return switch (char) {

        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => null,

    };

}

/// Where the bracket matching `char` lies, scanning from `at` the way it points; `at` may hold `char` or be where it will go.
fn partner(all: []const u8, at: usize, char: u8) ?usize {

    var depth: usize = 0;

    if (twin(char)) |close| {

        var index = at + 1;

        while (index < @min(all.len, at + reach)) : (index += 1) {

            if (all[index] == char) depth += 1;

            if (all[index] == close) {

                if (depth == 0) return index;
                depth -= 1;

            }

        }

        return null;

    }

    const open = opener(char) orelse return null;
    var index = at;

    while (index > at -| reach) {

        index -= 1;

        if (all[index] == char and index != at) depth += 1;

        if (all[index] == open) {

            if (depth == 0) return index;
            depth -= 1;

        }

    }

    return null;

}
