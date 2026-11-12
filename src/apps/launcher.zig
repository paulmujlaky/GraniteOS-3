//! The app launcher, opened from the dock: a search field over category chips and a grid of the apps the search or the
//! picked category shows.

const std = @import("std");

const catalog = @import("catalog.zig");
const desktop = @import("desktop.zig");
const pins = @import("pins.zig");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
const Category = catalog.Category;

const categories = std.enums.values(Category);

/// Chips along the top: every app, then each category.
const sections = categories.len + 1;

var search_bytes: [64]u8 = undefined;

var search_text = gui.Text{

    .buffer = &search_bytes,
    .placeholder = "Search apps",

};

var search = gui.input(&search_text);

var magnifier = gui.icon(.search, theme.icon.with(.{

    .color = theme.muted,

}));

var magnifier_parts = [_]*gui.Node{&magnifier};

/// The magnifier, laid over the field's left end; it takes no clicks, so they reach the field beneath.
var magnifier_row = gui.box(.{

    .padding = .{

        .left = 10,

    },
    .direction = .row,
    .items = .center,

}, &magnifier_parts);

var search_parts = [_]*gui.Node{ &search, &magnifier_row };

var search_box = gui.box(.{

    .height = theme.control,
    .direction = .stack,

}, &search_parts);
var searched: u64 = 0;

/// The category picked, or null for every app.
var picked: ?Category = null;

/// A category's chip under the search, filled while picked.
const chip = gui.Style{

    .height = 28,
    .padding = .axes(0, 12),

    .radius = 14,
    .size = theme.small,
    .color = theme.muted,
    .text_align = .center,

    .hover = .{

        .background = theme.hover,
        .color = theme.text,

    },
    .focus = .{

        .background = theme.hover,

    },
    .selected = .{

        .background = theme.selected,
        .color = theme.text,

    },

};

/// An app's tile: its icon over its name.
const tile = gui.Style{

    .width = 104,
    .height = 88,
    .direction = .column,
    .gap = 6,
    .justify = .center,
    .items = .center,

    .radius = theme.radius,

    .hover = .{

        .background = theme.hover,

    },
    .focus = .{

        .background = theme.hover,

    },
    .pressed = .{

        .background = theme.selected,

    },

};

const columns = 5;
const lines = (catalog.apps.len + columns - 1) / columns;

var chips: [sections]gui.Node = undefined;
var chip_list: [sections]*gui.Node = undefined;

var chip_row = gui.box(.{

    .direction = .row,
    .gap = 4,
    .justify = .center,

}, &chip_list);

var tiles: [catalog.apps.len]gui.Node = undefined;
var tile_icons: [catalog.apps.len]gui.Node = undefined;
var tile_titles: [catalog.apps.len]gui.Node = undefined;
var tile_parts: [catalog.apps.len][2]*gui.Node = undefined;

/// The tiles the search or category shows, packed in order and cut into rows.
var shown_tiles: [catalog.apps.len]*gui.Node = undefined;
var rows: [lines]gui.Node = undefined;
var row_list: [lines]*gui.Node = undefined;

var grid = gui.box(.{

    .grow = 1,
    .gap = 4,
    .scroll = true,

}, &row_list);

var none = gui.label("No apps match.", theme.caption.with(.{

    .grow = 1,
    .text_align = .center,

}));

var root_parts = [_]*gui.Node{ &search_box, &chip_row, &grid, &none };

var root = gui.box(theme.popup.with(.{

    .padding = gui.Edges.all(theme.spacing),
    .gap = 10,

}), &root_parts);

pub var window: gui.Window = undefined;

/// The launcher's size at 100%: five tiles across and three down.
pub const width = columns * 104 + (columns - 1) * 4 + 2 * theme.spacing;
pub const height = 380;

/// Opens the launcher, hidden, at `area`; see `place`.
pub fn init(area: gui.Rect) void {

    for (0..sections) |index| {

        const category: ?Category = if (index == 0) null else categories[index - 1];

        chips[index] = gui.label(if (category) |which| which.title() else "All", chip);
        chips[index].action = &choose;
        chips[index].data = index;
        chip_list[index] = &chips[index];

    }

    for (catalog.apps, 0..) |app, index| {

        tile_icons[index] = gui.icon(app.icon, theme.icon.with(.{

            .width = 40,
            .height = 32,
            .size = 26,

        }));

        tile_titles[index] = gui.label(app.title, .{

            .size = theme.small,
            .text_align = .center,

        });

        tile_parts[index] = .{ &tile_icons[index], &tile_titles[index] };
        tiles[index] = gui.box(tile, &tile_parts[index]);
        tiles[index].action = &open;
        tiles[index].menu = &offer;
        tiles[index].data = index;

    }

    for (&rows, 0..) |*row, index| {

        row.* = gui.box(.{

            .direction = .row,
            .gap = 4,

        }, &.{});

        row_list[index] = row;

    }

    search.action = &first;
    search.style.padding.left = 36;

    window = gui.Window.open(&root, .{

        .layer = .panel,

        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = area.height,

        .hidden = true,
        .motion = .rise,
        .shadow = true,

    }) catch api.exit(3);

}

/// Where the launcher goes on a `screen`-sized display: centred, just above a dock reaching `reach` up from the bottom.
pub fn spot(screen: gui.Rect, reach: i32) gui.Rect {

    return .{

        .x = @divTrunc(screen.width - gui.px(width), 2),
        .y = screen.height - reach - gui.px(height),
        .width = gui.px(width),
        .height = gui.px(height),

    };

}

pub fn place(area: gui.Rect) void {

    window.move(area);

}

/// Keeps the grid to what the search matches; call it every pass of the event loop.
pub fn tick() void {

    // The search field takes its own keys, so a changed text is how typing shows.
    if (search_text.version != searched) filter();

}

/// Shows every app, with the search empty and focused.
pub fn show() void {

    picked = null;
    search_text.clear();
    filter();
    window.show();
    window.focus(&search);

}

pub fn hide() void {

    if (shown()) window.hide();

}

pub fn shown() bool {

    return !window.surface.hidden;

}

fn filter() void {

    const query = search_text.text();
    // Widened first: the enum's own integer is only as wide as its last value needs.
    const current: usize = if (picked) |which| @as(usize, @intFromEnum(which)) + 1 else 0;
    var count: usize = 0;

    searched = search_text.version;

    for (catalog.apps, 0..) |app, index| {

        const hidden = if (query.len != 0) std.ascii.indexOfIgnoreCase(app.title, query) == null and std.ascii.indexOfIgnoreCase(app.summary, query) == null else picked != null and picked != app.category;

        if (hidden) continue;

        shown_tiles[count] = &tiles[index];
        count += 1;

    }

    for (&rows, 0..) |*row, line| {

        const from = @min(line * columns, count);

        row.content.box = shown_tiles[from..@min(from + columns, count)];
        row.hidden = from == count;

    }

    // A search spans every category, so none shows as picked meanwhile.
    for (&chips, 0..) |*item, index| {

        item.selected = query.len == 0 and index == current;

    }

    grid.hidden = count == 0;
    none.hidden = count != 0;
    grid.offset = 0;
    window.refresh();

}

fn choose(row: *gui.Node) void {

    picked = if (row.data == 0) null else categories[row.data - 1];
    search_text.clear();
    filter();

}

fn open(node: *gui.Node) void {

    desktop.start_app(catalog.apps[node.data].image, desktop.home);

}

/// Launches the first app the grid shows.
fn first(_: *gui.Node) void {

    if (!grid.hidden) open(rows[0].content.box[0]);

}

fn offer(node: *gui.Node, at: gui.Point) void {

    const area = window.surface.spec.area;

    pins.offer(catalog.apps[node.data].image, .{

        .x = area.x + at.x,
        .y = area.y + at.y,

    });

}
