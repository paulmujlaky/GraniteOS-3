//! The flat monochrome look shared by every surface: graphite surfaces, white text, and light grey for focus and selection.

const std = @import("std");

const style = @import("style.zig");

const Style = style.Style;
const Edges = style.Edges;

/// Behind every window.
pub const desktop = 0x0c0c0c;

pub const background = 0x141414;
pub const raised = 0x1b1b1b;
pub const field = 0x232323;
pub const hover = 0x2a2a2a;
pub const selected = 0x333333;

/// Behind a focused field or button, a step brighter than `hover`.
pub const lit = 0x2f2f2f;
pub const line = 0x2c2c2c;

/// Borders of fields and buttons, a step lighter than `line` so they read against `field`.
pub const edge = 0x383838;

pub const text = 0xe8e8e8;
pub const muted = 0x8c8c8c;
pub const faint = 0x5a5a5a;

/// Focus rings, primary actions, and active indicators. These are keys the display swaps for the user's chosen accent as it draws.
pub const accent = 0xeeeeee;
pub const accent_hover = 0xfdfdfd;
pub const accent_pressed = 0xcbcbcb;

/// An accent people may pick in Settings, as the colours that replace `accent`, `accent_hover`, and `accent_pressed`.
pub const Accent = struct {

    name: []const u8,
    shades: [3]u32,

};

/// The first is the default.
pub const accents = [_]Accent{

    .{ .name = "White", .shades = .{ 0xeeeeee, 0xffffff, 0xcccccc } },
    .{ .name = "Blue", .shades = .{ 0x5b9cff, 0x7cb0ff, 0x4a84db } },
    .{ .name = "Teal", .shades = .{ 0x3fc1ae, 0x5fd0bf, 0x34a294 } },
    .{ .name = "Amber", .shades = .{ 0xe6a94a, 0xefbd6c, 0xc58f3c } },
    .{ .name = "Violet", .shades = .{ 0xa58bff, 0xb9a4ff, 0x8a72dd } },

};

/// The index of the accent called `name`, or the default's.
pub fn accentNamed(name: []const u8) u8 {

    for (accents, 0..) |entry, index| {

        if (std.ascii.eqlIgnoreCase(entry.name, name)) return @intCast(index);

    }

    return 0;

}
pub const danger = 0xe5534b;

/// Code and Markdown colours, the one place the look strays from grey: soft hues about as light as the text, so highlighting
/// reads without shouting.
pub const syntax = struct {

    pub const keyword = 0xc6a0f6;
    pub const types = 0x8bd5ca;
    pub const number = 0xf5a97f;
    pub const string = 0xa6da95;
    pub const comment = 0x787878;
    pub const function = 0x8aadf4;
    pub const builtin = 0xeed49f;
    pub const punctuation = 0xa8a8a8;

    /// Behind matches of a search, and around the bracket matching the one at the caret.
    pub const found = 0x4d4122;
    pub const bracket = 0x6a6a6a;

};

/// Graphite tints three quarters opaque over Quartz, which softens what lies behind bars, docks, menus, windows, and tags; the top byte
/// is transparency, as `canvas.shade` makes it. With Quartz switched off they draw solid, as `background` and `raised`.
pub const quartz = 0x40141414;
pub const quartz_raised = 0x401b1b1b;

/// A light tint marking out panes over Quartz, such as toolbars, sidebars, and title bars; over `background` it makes `raised`.
pub const pane = 0xf7ffffff;

/// An area swept out with the pointer, as when selecting: a faint white fill inside a lighter, softly rounded edge.
pub const sweep_fill = 0xe6ffffff;
pub const sweep_edge = 0x73ffffff;
pub const sweep_radius = radius;

/// Corners of everything rounded that is not a circle: controls, cards, pop-ups, and windows.
pub const radius = 12;
pub const corner = radius;
pub const border = 1;
pub const spacing = 12;
pub const gap = 8;

pub const body: f32 = 15;
pub const small: f32 = 13;
pub const heading: f32 = 20;
pub const large: f32 = 30;

/// Height of single-line controls such as fields and buttons.
pub const control = 32;

/// Height of a window's title bar, drawn by the window manager.
pub const title = 34;

/// Base styles for the stock widgets; tweak them per node with `Style.with`.
pub const panel = Style{

    .padding = .all(spacing),
    .gap = spacing,

    .background = pane,
    .radius = corner,

};

pub const button = Style{

    .height = control,
    .padding = .axes(0, 14),

    .background = field,
    .border = edge,
    .border_width = border,
    .radius = radius,
    .text_align = .center,

    .hover = .{

        .background = hover,

    },
    .focus = .{

        .background = lit,

    },
    .pressed = .{

        .background = selected,

    },
    .selected = .{

        .background = selected,
        .border = faint,

    },

};

/// The one action a view most expects, drawn light on dark.
pub const primary = button.with(.{

    .background = accent,
    .border = accent,
    .color = background,

    .hover = .{

        .background = accent_hover,
        .border = accent_hover,

    },
    .focus = .{

        .background = accent_hover,
        .border = accent_hover,

    },
    .pressed = .{

        .background = accent_pressed,
        .border = accent_pressed,

    },

});

/// The action a confirmation asks for when it cannot be undone, such as deleting.
pub const destructive = button.with(.{

    .background = danger,
    .border = danger,
    .color = 0xffffff,

    .hover = .{

        .background = 0xf06a62,
        .border = 0xf06a62,

    },
    .focus = .{

        .background = 0xf06a62,
        .border = 0xf06a62,

    },
    .pressed = .{

        .background = 0xc9463f,
        .border = 0xc9463f,

    },

});

/// The raised, bordered Quartz card of a pop-up list or launcher.
pub const popup = Style{

    .padding = .all(6),
    .gap = 2,

    .background = quartz_raised,
    .quartz = true,
    .border = line,
    .border_width = border,
    .radius = corner,

};

/// A dialog's card, centred over the window it asks for.
pub const card = popup.with(.{

    .width = 400,
    .padding = Edges.all(20),
    .gap = spacing,

});

/// Laid over a window's content while a dialog asks something of it.
pub const dim = 0x80000000;

/// A borderless square button showing an icon, as in toolbars.
pub const tool = Style{

    .width = control,
    .height = control,

    .radius = radius,
    .face = .icons,
    .size = 16,
    .text_align = .center,

    .hover = .{

        .background = hover,

    },
    .focus = .{

        .background = hover,

    },
    .pressed = .{

        .background = selected,

    },
    .selected = .{

        .background = selected,

    },

};

pub const input = Style{

    .height = control,
    .padding = .axes(0, 10),

    .background = field,
    .border = edge,
    .border_width = border,
    .radius = radius,

    .focus = .{

        .background = lit,

    },
    .invalid = .{

        .border = danger,

    },

};

pub const area = input.with(.{

    .height = 5 * control,
    .padding = Edges.all(10),

});

/// A selectable line in a list, such as a file or an account.
pub const item = Style{

    .height = 34,
    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 10,
    .items = .center,

    .radius = radius,

    .hover = .{

        .background = hover,

    },
    .selected = .{

        .background = selected,

    },
    .focus = .{

        .background = hover,

    },

};

/// A row of controls along the top of a view.
pub const bar = Style{

    .height = 44,
    .padding = .axes(6, gap),
    .direction = .row,
    .gap = gap / 2,
    .items = .center,

    .background = pane,

};

/// An icon beside text, such as in list rows.
pub const icon = Style{

    .width = 18,
    .face = .icons,
    .size = 16,
    .text_align = .center,

};

pub const caption = Style{

    .size = small,
    .color = muted,

};

pub const title_text = Style{

    .size = heading,

};

/// A short upright line between groups of tools.
pub const divider = Style{

    .width = border,
    .height = 20,
    .background = line,

};

/// A one-pixel rule between sections.
pub const rule = Style{

    .height = border,
    .background = line,

};

/// Fills the space it is given, pushing its siblings apart.
pub const spring = Style{

    .grow = 1,

};
