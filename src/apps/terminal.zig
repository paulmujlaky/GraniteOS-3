//! Terminal: runs an OBSIDIAN shell in a window, drawing what it writes and handing it what you type.

const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

const size: f32 = 14;
const margin = 10;

/// Lines kept, and the widest line, in characters.
const kept = 1000;
const widest = 240;

const State = enum {

    normal,
    escape,
    sequence,

};

var window: gui.Window = undefined;
var shell: u64 = 0;

var lines: [kept][widest]u8 = undefined;
var lengths = [_]u16{0} ** kept;

/// Lines written so far, the first line of the screen the shell addresses, and the cursor.
var total: usize = 1;
var screen_top: usize = 0;
var row: usize = 0;
var column: usize = 0;

/// Lines scrolled back from the bottom while reading history.
var back: usize = 0;

var columns: usize = 80;
var rows: usize = 24;
var cell: f32 = 8;
var height: i32 = 16;

var state = State.normal;
var parameters: [4]u16 = undefined;
var count: usize = 0;

/// Bytes typed but not yet read by the shell, and its read waiting for them.
var input: [512]u8 = undefined;
var head: usize = 0;
var queued: usize = 0;
var waiting: ?api.Request = null;
var since: u64 = 0;

var pasted: [4096]u8 = undefined;
var chunk: [4096]u8 = undefined;

var view = gui.custom(&paint, .{

    .grow = 1,

});

var parts = [_]*gui.Node{&view};

var root = gui.box(.{

    .background = 0x0f0f0f,

}, &parts);

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    const face = gui.font.face(.mono);

    cell = face.advance(face.lookup('M')) * size / face.units;
    height = gui.leading(face, size);
    @memset(&lines[0], ' ');

    window = gui.Window.open(&root, .{

        .title = "Terminal",
        .application = .terminal,

        .width = 760,
        .height = 460,

    }) catch api.exit(3);

    measure();

    var home_bytes: [256]u8 = undefined;
    const home = api.argument(&home_bytes);

    shell = api.launch("shell", if (home.len != 0) home else "/") catch {

        feed("Could not start the shell.\n");
        while (true) if (window.next(500)) |event| if (event.kind == .close) window.quit();

    };

    while (true) {

        if (window.next(if (waiting != null or queued != 0) 1 else 5)) |event| {

            if (event.kind == .close) window.quit();
            react(event);

        }

        serve();

        // Once the shell exits, so does its window.
        if (!api.alive(shell)) api.exit(0);

    }

}

/// Answers the shell's writes and reads until it falls quiet for a moment.
fn serve() void {

    var quiet: usize = 0;

    while (quiet < 40) {

        const request = api.receive(false) catch {

            quiet += 1;
            _ = api.raw(.yield, 0, 0, 0);
            continue;

        };

        quiet = 0;
        handle(request);

    }

    // A read the shell has given up on goes back empty, so the next one can wait instead.
    if (waiting) |request| if (api.ticks() - since > 80) {

        api.answer(request, protocol.empty);

        waiting = null;

    };

}

fn handle(request: api.Request) void {

    if (request.first != shell) return api.answer(request, protocol.denied);

    switch (protocol.operation(request.second)) {

        .write => {

            const length = @min(protocol.value(request.second), chunk.len, request.fourth);

            api.fetch(request, 0, chunk[0..length]) catch return api.answer(request, protocol.invalid);
            feed(chunk[0..length]);
            back = 0;
            window.invalidate(&view);

            api.answer(request, 0);

        },
        .read => {

            if (waiting) |old| api.answer(old, protocol.empty);

            waiting = request;
            since = api.ticks();
            deliver();

        },
        else => api.answer(request, protocol.invalid),

    }

}

/// Hands the waiting read the next typed byte.
fn deliver() void {

    const request = waiting orelse return;
    if (queued == 0) return;

    const byte = input[head];

    waiting = null;
    head = (head + 1) % input.len;
    queued -= 1;

    api.answer(request, byte);

}

fn type_bytes(bytes: []const u8) void {

    for (bytes) |byte| {

        if (queued == input.len) break;

        input[(head + queued) % input.len] = byte;
        queued += 1;

    }

    back = 0;
    window.invalidate(&view);
    deliver();

}

fn react(event: api.Event) void {

    switch (event.kind) {

        .resize => measure(),
        .button => if (event.code == 3 or event.code == 4) {

            back = if (event.code == 3) @min(back + 3, total -| rows) else back -| 3;
            window.invalidate(&view);

        },
        .key => if (event.pressed) press(event),
        else => {

        },

    }

}

/// Turns a key press into the bytes a terminal sends.
fn press(event: api.Event) void {

    const held = event.modifiers;

    switch (event.key()) {

        .character => {

            if (held.control and held.shift and event.char | 0x20 == 'v') return paste();

            if (held.control) {

                const letter = event.char | 0x20;
                if (letter >= 'a' and letter <= 'z') type_bytes(&.{@intCast(letter - 'a' + 1)});

                return;

            }

            var bytes: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(event.char, &bytes) catch return;

            type_bytes(bytes[0..length]);

        },
        .enter => type_bytes("\r"),
        .backspace => type_bytes("\x7f"),
        .tab => type_bytes("\t"),
        .escape => type_bytes("\x1b"),
        .up => type_bytes("\x1b[A"),
        .down => type_bytes("\x1b[B"),
        .right => type_bytes("\x1b[C"),
        .left => type_bytes("\x1b[D"),
        .home => type_bytes("\x1b[H"),
        .end => type_bytes("\x1b[F"),
        .delete => type_bytes("\x1b[3~"),
        .page_up, .page_down => {

            back = if (event.key() == .page_up) @min(back + rows / 2, total -| rows) else back -| rows / 2;
            window.invalidate(&view);

        },
        else => {

        },

    }

}

fn paste() void {

    const bytes = gui.display.paste(&pasted) catch return;

    for (bytes) |byte| type_bytes(if (byte == '\n') "\r" else &.{byte});

}

/// Fits the grid to the window.
fn measure() void {

    const area = window.surface.list.bounds();

    columns = std.math.clamp(@as(usize, @intFromFloat(@as(f32, @floatFromInt(area.width - 2 * margin)) / cell)), 10, widest);
    rows = @max(@as(usize, @intCast(@divTrunc(area.height - 2 * margin, height))), 3);
    window.refresh();

}

/// Interprets what the shell wrote: text, a few control characters, and the escape sequences it uses.
fn feed(bytes: []const u8) void {

    for (bytes) |byte| {

        switch (state) {

            .normal => switch (byte) {

                0x1b => state = .escape,
                '\r' => column = 0,
                '\n' => {

                    column = 0;
                    down();

                },
                0x08 => column -|= 1,
                '\t' => column = @min((column / 8 + 1) * 8, columns - 1),
                0x07 => {

                },
                else => if (byte >= 0x20) put(byte),

            },
            .escape => {

                state = if (byte == '[') .sequence else .normal;
                count = 0;
                parameters = .{ 0, 0, 0, 0 };

            },
            .sequence => {

                if (byte >= '0' and byte <= '9') {

                    if (count == 0) count = 1;
                    parameters[count - 1] = parameters[count - 1] *| 10 +| (byte - '0');

                } else if (byte == ';') {

                    count = @min(count + 1, parameters.len);
                    if (count == 1) count = 2;

                } else {

                    state = .normal;
                    act(byte);

                }

            },

        }

    }

}

/// Runs the escape sequence ending in `final`.
fn act(final: u8) void {

    const first: usize = if (count == 0 or parameters[0] == 0) 1 else parameters[0];

    switch (final) {

        'A' => row = @max(row -| first, screen_top),
        'B' => {

            for (0..first) |_| down();

        },
        'C' => column = @min(column + first, columns - 1),
        'D' => column -|= first,
        'H', 'f' => {

            const second: usize = if (count < 2 or parameters[1] == 0) 1 else parameters[1];

            row = screen_top;
            column = @min(second - 1, columns - 1);
            for (1..first) |_| down();

        },
        'K' => lengths[row % kept] = @intCast(@min(lengths[row % kept], column)),
        'J' => if (count != 0 and parameters[0] == 2) {

            // A cleared screen starts fresh below the history, which stays scrollable.
            screen_top = total;
            row = total;
            column = 0;
            grow();

        },
        else => {

        },

    }

}

fn put(byte: u8) void {

    if (column >= columns) {

        column = 0;
        down();

    }

    const line = &lines[row % kept];
    const length = &lengths[row % kept];

    if (length.* < column) @memset(line[length.*..column], ' ');

    line[column] = byte;
    length.* = @intCast(@max(length.*, column + 1));
    column += 1;

}

/// Moves the cursor down a line, adding one at the bottom and scrolling when needed.
fn down() void {

    row += 1;
    if (row >= total) grow();
    if (row >= screen_top + rows) screen_top = row + 1 - rows;

}

fn grow() void {

    lengths[total % kept] = 0;
    total += 1;

}

fn paint(node: *gui.Node, target: *gui.List) void {

    const area = node.rect;
    const bottom = @max(total, screen_top + rows);
    const first = (bottom -| rows) -| back;
    const oldest = total -| kept;

    for (0..rows) |index| {

        const line = first + index;
        if (line < oldest or line >= total) continue;

        const y = area.y + margin + @as(i32, @intCast(index)) * height;
        const text = lines[line % kept][0..lengths[line % kept]];

        if (line == row and back == 0) target.fill(.{

            .x = area.x + margin + @as(i32, @intFromFloat(@as(f32, @floatFromInt(column)) * cell)),
            .y = y,

            .width = @intFromFloat(@ceil(cell)),
            .height = height,

        }, gui.shade(theme.accent, 150));

        target.text(text, .mono, size, area.x + margin, y + gui.ascent(gui.font.face(.mono), size), theme.text);

    }

}
