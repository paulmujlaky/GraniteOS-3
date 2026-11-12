//! Settings: the display mode, the wallpaper, accent, and Quartz, the network, sound, and accounts.

const std = @import("std");

const catalog = @import("catalog.zig");
const wallpapers = @import("wallpapers.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

const Section = enum {

    display,
    appearance,
    network,
    sound,
    accounts,

};

const Pending = enum {

    none,
    name,
    password,
    current,
    replacement,

};

const modes = [_][2]u16{ .{ 1024, 768 }, .{ 1280, 720 }, .{ 1280, 800 }, .{ 1366, 768 }, .{ 1440, 900 }, .{ 1600, 900 }, .{ 1920, 1080 }, .{ 2560, 1440 }, .{ 3840, 2160 } };

const mode_choices = blk: {

    var choices: [modes.len]gui.Choice = undefined;

    for (modes, 0..) |mode, index| {

        choices[index] = .{

            .title = std.fmt.comptimePrint("{d} × {d}", .{ mode[0], mode[1] }),
            .run = chooseMode(index),

        };

    }

    break :blk choices;

};

/// Interface scales to pick from, in percent.
const scales = [_]u8{ 100, 125, 150, 175, 200 };

const scale_choices = blk: {

    var choices: [scales.len]gui.Choice = undefined;

    for (scales, 0..) |percent, index| {

        choices[index] = .{

            .title = std.fmt.comptimePrint("{d}%", .{percent}),
            .run = chooseScale(index),

        };

    }

    break :blk choices;

};

const wallpaper_choices = blk: {

    var choices: [wallpapers.all.len + 1]gui.Choice = undefined;

    for (wallpapers.all, 0..) |entry, index| {

        choices[index] = .{

            .icon = .wallpaper,
            .title = entry.name,
            .run = chooseWallpaper(index),

        };

    }

    choices[wallpapers.all.len] = .{

        .icon = .image,
        .title = "Picture",
        .run = pickPicture,

    };

    break :blk choices;

};

const sections = [_]struct { title: []const u8, icon: gui.Icon }{

    .{ .title = "Display", .icon = .monitor },
    .{ .title = "Appearance", .icon = .palette },
    .{ .title = "Network", .icon = .globe },
    .{ .title = "Sound", .icon = .volume_high },
    .{ .title = "Accounts", .icon = .users },

};

/// The manual address's fields, in the order `api.net.Setting` keeps them.
const entries = [_][]const u8{ "IP address", "Subnet mask", "Gateway", "DNS server" };

/// How tall the monitor previews draw the screen.
const preview_height = 150;

const page = gui.Style{

    .gap = 16,

};

const heading = gui.Style{

    .size = 26,

};

/// Settings stacked as separate cards, close together.
const group = gui.Style{

    .gap = 4,

};

const card = gui.Style{

    .background = theme.pane,
    .radius = theme.corner,

};

/// The card atop a page about a device, such as the network adapter: its round badge, then what it is and how it is.
const hero = card.with(.{

    .padding = gui.Edges.all(20),
    .direction = .row,
    .gap = 16,
    .items = .center,

});

const badge = theme.icon.with(.{

    .width = 44,
    .height = 44,

    .background = theme.field,
    .radius = 22,

    .size = 20,

});

/// A setting's card: an icon, its name, and its control at the right.
const line = card.with(.{

    .height = 60,
    .padding = gui.Edges.axes(0, 16),
    .direction = .row,
    .gap = 16,
    .items = .center,

});

/// A segmented control's track, holding its choices side by side.
const track = gui.Style{

    .height = theme.control,
    .padding = .all(3),
    .direction = .row,
    .gap = 2,

    .background = theme.field,
    .border = theme.line,
    .border_width = theme.border,
    .radius = theme.radius,

};

const segment = gui.Style{

    .padding = .axes(0, 14),

    // Concentric with the track, inset by its padding.
    .radius = theme.radius - 3,
    .size = theme.small,
    .text_align = .center,

    .hover = .{

        .background = theme.hover,

    },
    .selected = .{

        .background = theme.accent,
        .color = theme.background,

    },

};

const avatar = gui.Style{

    .width = 28,
    .height = 28,

    .background = theme.faint,
    .radius = 14,

    .size = theme.small,
    .text_align = .center,

};

const status = theme.caption.with(.{

    .padding = .{

        .left = 4,

    },

});

/// A caption under a page's cards for what went wrong or was done, hidden until it has something to say.
fn quiet() gui.Node {

    var result = gui.label("", status);

    result.hidden = true;

    return result;

}

fn chooseMode(comptime index: usize) *const fn () void {

    return struct {

        fn run() void {

            setMode(index);

        }

    }.run;

}

fn chooseWallpaper(comptime index: usize) *const fn () void {

    return struct {

        fn run() void {

            useWallpaper(index);

        }

    }.run;

}

fn chooseScale(comptime index: usize) *const fn () void {

    return struct {

        fn run() void {

            setScale(scales[index]);

        }

    }.run;

}

/// A setting's card: an icon, its name, and its control at the right.
const Row = struct {

    icon: gui.Node = undefined,
    name: gui.Node = undefined,
    parts: [3]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn init(self: *Row, which: gui.Icon, name: []const u8, control: *gui.Node) void {

        self.icon = gui.icon(which, theme.icon.with(.{

            .width = 20,
            .size = 18,

        }));

        self.name = gui.label(name, .{

            .grow = 1,

        });

        self.parts = .{ &self.icon, &self.name, control };
        self.node = gui.box(line, &self.parts);

    }

};

/// A button showing the current choice beside a chevron, opening a menu of the others.
const Picker = struct {

    value: gui.Node = gui.label("", .{

        .grow = 1,

    }),

    chevron: gui.Node = gui.icon(.down, theme.icon.with(.{

        .size = 14,
        .color = theme.muted,

    })),

    parts: [2]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn init(self: *Picker, action: *const fn (*gui.Node) void) void {

        self.parts = .{ &self.value, &self.chevron };

        self.node = gui.box(theme.button.with(.{

            .width = 180,
            .padding = gui.Edges.axes(0, 12),
            .direction = .row,
            .gap = theme.gap,
            .items = .center,

        }), &self.parts);

        self.node.action = action;

    }

    /// Where its menu opens: just under it.
    fn below(self: *const Picker) gui.Point {

        return .{

            .x = self.node.rect.x,
            .y = self.node.rect.bottom() + 4,

        };

    }

};

/// An on-off switch with its state written beside it: a knob that slides to the lit end of its track.
const Switch = struct {

    state: gui.Node = gui.label("", .{}),

    knob: gui.Node = gui.box(.{

        .width = 16,
        .height = 16,

        .radius = 8,

    }, &.{}),

    knob_parts: [1]*gui.Node = undefined,
    track: gui.Node = undefined,
    parts: [2]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn init(self: *Switch) void {

        self.knob_parts = .{&self.knob};

        self.track = gui.box(.{

            .width = 40,
            .height = 22,
            .padding = .all(3),
            .direction = .row,
            .items = .center,

            .radius = 11,

        }, &self.knob_parts);

        self.parts = .{ &self.state, &self.track };

        self.node = gui.box(.{

            .direction = .row,
            .gap = theme.spacing,
            .items = .center,

        }, &self.parts);

    }

    fn set(self: *Switch, on: bool) void {

        self.state.content.label = if (on) "On" else "Off";
        self.track.style.background = if (on) theme.accent else theme.selected;
        self.track.style.justify = if (on) .end else .start;
        self.knob.style.background = if (on) theme.background else theme.muted;

    }

};

/// A row of round accent colours; the chosen one is ringed.
const Swatches = struct {

    dots: [theme.accents.len]gui.Node = undefined,
    dot_parts: [theme.accents.len][1]*gui.Node = undefined,
    rings: [theme.accents.len]gui.Node = undefined,
    ring_parts: [theme.accents.len]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn init(self: *Swatches) void {

        inline for (theme.accents, 0..) |entry, index| {

            // One shade off the key, so the display shows each swatch's own colour rather than the chosen accent.
            self.dots[index] = gui.box(.{

                .width = 18,
                .height = 18,

                .background = entry.shades[0] ^ 1,
                .radius = 9,

            }, &.{});

            self.dot_parts[index] = .{&self.dots[index]};

            self.rings[index] = gui.box(.{

                .width = 28,
                .height = 28,
                .padding = .all(5),

                .border_width = 2,
                .radius = 14,

                .hover = .{

                    .border = theme.faint,

                },
                .focus = .{

                    .border = theme.muted,

                },
                .selected = .{

                    .border = theme.text,

                },

            }, &self.dot_parts[index]);

            self.rings[index].action = &struct {

                fn run(_: *gui.Node) void {

                    pickAccent(index);

                }

            }.run;

            self.ring_parts[index] = &self.rings[index];

        }

        self.node = gui.box(.{

            .direction = .row,
            .gap = 4,
            .items = .center,

        }, &self.ring_parts);

    }

    fn set(self: *Swatches, chosen: u8) void {

        for (&self.rings, 0..) |*ring, index| ring.selected = index == chosen;

        window.refresh();

    }

};

/// A small monitor on its stand, showing the wallpaper under a sketch of the desktop in the screen's shape.
const Monitor = struct {

    picture: gui.Node = gui.picture(&preview, .{}),
    sketch: gui.Node = gui.custom(&sketchDesktop, .{}),
    screen_parts: [2]*gui.Node = undefined,
    screen: gui.Node = undefined,
    bezel_parts: [1]*gui.Node = undefined,
    bezel: gui.Node = undefined,

    neck: gui.Node = gui.box(.{

        .width = 36,
        .height = 14,

        .background = theme.line,

    }, &.{}),

    foot: gui.Node = gui.box(.{

        .width = 96,
        .height = 5,

        .background = theme.line,
        .radius = 2,

    }, &.{}),

    parts: [3]*gui.Node = undefined,
    node: gui.Node = undefined,

    fn init(self: *Monitor) void {

        self.screen_parts = .{ &self.picture, &self.sketch };

        self.screen = gui.box(.{

            .width = preview_height * 16 / 9,
            .height = preview_height,
            .direction = .stack,

        }, &self.screen_parts);

        self.bezel_parts = .{&self.screen};

        self.bezel = gui.box(.{

            .padding = .all(5),

            .background = theme.desktop,
            .border = theme.line,
            .border_width = theme.border,
            .radius = theme.radius,

        }, &self.bezel_parts);

        self.parts = .{ &self.bezel, &self.neck, &self.foot };

        self.node = gui.box(.{

            .items = .center,

        }, &self.parts);

    }

    fn shape(self: *Monitor, width: i32, height: i32) void {

        if (width > 0 and height > 0) self.screen.style.width = @divTrunc(preview_height * width, height);

    }

};

var window: gui.Window = undefined;
/// The desktop's config, which keeps the wallpaper.
var preferences = api.Config{};
var accounts = api.Accounts{};
var screen = api.Display{};
var files = api.Files{};

/// The process that launched us, normally the desktop, told when the wallpaper changes.
var session: u64 = 0;
var user: []const u8 = "";
var home: []const u8 = "/";
var home_bytes: [64]u8 = undefined;

var dialog = gui.Dialog{};
var pending = Pending.none;
var draft_name: [32]u8 = undefined;
var draft_length: usize = 0;
var draft_secret: [64]u8 = undefined;
var draft_secret_length: usize = 0;

/// The wallpaper as the monitor previews show it, and what it was made from, so it is only made again when that changes.
var preview: gui.Image = undefined;
var preview_ready = false;
var preview_path: [256]u8 = undefined;
var preview_length: usize = 0;
var preview_size = api.display.Area{};

// Sidebar.
var me_initial: [1]u8 = .{' '};
var me_avatar = gui.label("", avatar.with(.{

    .width = 40,
    .height = 40,

    .radius = 20,

    .size = theme.body,

}));

var me_name = gui.label("", .{});
var me_role = gui.label("", theme.caption);
var me_words_parts = [_]*gui.Node{ &me_name, &me_role };

var me_words = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &me_words_parts);

var me_parts = [_]*gui.Node{ &me_avatar, &me_words };

var me = gui.box(theme.item.with(.{

    .height = 60,
    .padding = gui.Edges.axes(0, 8),
    .gap = theme.spacing,

}), &me_parts);

var tab_pills: [sections.len]gui.Node = undefined;
var tab_icons: [sections.len]gui.Node = undefined;
var tab_labels: [sections.len]gui.Node = undefined;
var tab_parts: [sections.len][3]*gui.Node = undefined;
var tabs: [sections.len]gui.Node = undefined;
var tab_list: [sections.len]*gui.Node = undefined;

var tab_box = gui.box(.{

    .gap = 2,

}, &tab_list);

var sidebar_parts = [_]*gui.Node{ &me, &tab_box };

var sidebar = gui.box(.{

    .width = 210,

    .padding = .all(theme.gap),
    .gap = theme.spacing,

    .background = theme.pane,

}, &sidebar_parts);

// Display.
var display_title = gui.label("Display", heading);
var display_monitor = Monitor{};
var display_hero_parts = [_]*gui.Node{&display_monitor.node};

var display_hero = gui.box(card.with(.{

    .padding = gui.Edges.axes(24, 0),
    .items = .center,

}), &display_hero_parts);

var resolution_bytes: [16]u8 = undefined;
var resolution = Picker{};
var resolution_row = Row{};
var resolution_menu: gui.Menu(&mode_choices) = .{};
var scale_bytes: [8]u8 = undefined;
var scale = Picker{};
var scale_row = Row{};
var scale_menu: gui.Menu(&scale_choices) = .{};
var display_rows = [_]*gui.Node{ &resolution_row.node, &scale_row.node };
var display_group = gui.box(group, &display_rows);
var display_status = quiet();
var display_parts = [_]*gui.Node{ &display_title, &display_hero, &display_group, &display_status };
var display_page = gui.box(page, &display_parts);

// Appearance.
var appearance_title = gui.label("Appearance", heading);
var appearance_monitor = Monitor{};
var appearance_hero_parts = [_]*gui.Node{&appearance_monitor.node};

var appearance_hero = gui.box(card.with(.{

    .padding = gui.Edges.axes(24, 0),
    .items = .center,

}), &appearance_hero_parts);

var wallpaper = Picker{};
var wallpaper_row = Row{};

var wallpaper_menu: gui.Menu(&wallpaper_choices) = .{};

var picture_bytes: [256]u8 = undefined;

var picture_text = gui.Text{

    .buffer = &picture_bytes,
    .placeholder = "/home/you/picture.png",

};

var picture_field = gui.input(&picture_text);
var picture_apply = gui.button("Apply", &usePicture);
var picture_parts = [_]*gui.Node{ &picture_field, &picture_apply };

var picture_row = gui.box(line.with(.{

    .gap = theme.gap,

}), &picture_parts);

var quartz = Switch{};
var quartz_on = false;
var quartz_row = Row{};
var swatches = Swatches{};
var accent_row = Row{};
var appearance_rows = [_]*gui.Node{ &wallpaper_row.node, &picture_row, &accent_row.node, &quartz_row.node };
var appearance_group = gui.box(group, &appearance_rows);
var appearance_status = quiet();
var appearance_parts = [_]*gui.Node{ &appearance_title, &appearance_hero, &appearance_group, &appearance_status };
var appearance_page = gui.box(page, &appearance_parts);

// Network.
var network_title = gui.label("Network", heading);

var link_icon = gui.icon(.globe, badge);

var link_name = gui.label("Ethernet", .{

    .size = 18,

});

var link_state = gui.label("", theme.caption);
var link_words_parts = [_]*gui.Node{ &link_name, &link_state };

var link_words = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &link_words_parts);

var address_bytes: [16]u8 = undefined;

var address_value = gui.label("", .{

    .size = 18,
    .text_align = .right,

});

var address_caption = gui.label("IP address", theme.caption.with(.{

    .text_align = .right,

}));

var address_parts = [_]*gui.Node{ &address_value, &address_caption };

var address_box = gui.box(.{

    .gap = 2,

}, &address_parts);

var link_parts = [_]*gui.Node{ &link_icon, &link_words, &address_box };

var link_hero = gui.box(hero, &link_parts);

var automatic = gui.label("Automatic", segment);
var manual = gui.label("Manual", segment);
var method_parts = [_]*gui.Node{ &automatic, &manual };
var method = gui.box(track, &method_parts);
var method_row = Row{};

/// Whether the Manual segment is picked, which may be ahead of the address in use until applied.
var manual_chosen = false;

var entry_bytes: [entries.len][16]u8 = undefined;
var entry_texts: [entries.len]gui.Text = undefined;
var entry_labels: [entries.len]gui.Node = undefined;
var entry_fields: [entries.len]gui.Node = undefined;
var entry_parts: [entries.len][2]*gui.Node = undefined;
var entry_cells: [entries.len]gui.Node = undefined;
var entry_firsts = [_]*gui.Node{ &entry_cells[0], &entry_cells[1] };
var entry_seconds = [_]*gui.Node{ &entry_cells[2], &entry_cells[3] };

var entry_first = gui.box(.{

    .direction = .row,
    .gap = theme.spacing,

}, &entry_firsts);

var entry_second = gui.box(.{

    .direction = .row,
    .gap = theme.spacing,

}, &entry_seconds);

var manual_apply = gui.button("Apply", &useManual);
var manual_actions_parts = [_]*gui.Node{&manual_apply};

var manual_actions = gui.box(.{

    .direction = .row,
    .justify = .end,

}, &manual_actions_parts);

var manual_parts = [_]*gui.Node{ &entry_first, &entry_second, &manual_actions };

var manual_card = gui.box(card.with(.{

    .padding = gui.Edges.all(16),
    .gap = theme.spacing,

}), &manual_parts);

var network_rows = [_]*gui.Node{ &method_row.node, &manual_card };
var network_group = gui.box(group, &network_rows);
var network_status = quiet();
var network_parts = [_]*gui.Node{ &network_title, &link_hero, &network_group, &network_status };
var network_page = gui.box(page, &network_parts);

// Sound.
var sound_title = gui.label("Sound", heading);
var output_icon = gui.icon(.headphones, badge);
var output_chip: [32]u8 = undefined;

var output_name = gui.label("", .{

    .size = 18,

});

var output_bytes: [64]u8 = undefined;
var output_state = gui.label("", theme.caption);
var output_words_parts = [_]*gui.Node{ &output_name, &output_state };

var output_words = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &output_words_parts);

var output_parts = [_]*gui.Node{ &output_icon, &output_words };
var output_hero = gui.box(hero, &output_parts);

var loudness = gui.Slider{ .changed = &slideVolume };
var loudness_node: gui.Node = undefined;
var loudness_bytes: [8]u8 = undefined;

var loudness_value = gui.label("", .{

    .width = 44,
    .text_align = .right,

});

var loudness_parts = [_]*gui.Node{ &loudness_node, &loudness_value };

var loudness_control = gui.box(.{

    .width = 260,
    .direction = .row,
    .gap = theme.spacing,
    .items = .center,

}, &loudness_parts);

var loudness_row = Row{};
var mute = Switch{};
var mute_row = Row{};
var chimes = Switch{};
var chimes_row = Row{};
var sound_rows = [_]*gui.Node{ &loudness_row.node, &mute_row.node, &chimes_row.node };
var sound_group = gui.box(group, &sound_rows);
var sound_status = quiet();
var sound_parts = [_]*gui.Node{ &sound_title, &output_hero, &sound_group, &sound_status };
var sound_page = gui.box(page, &sound_parts);

// Accounts.
var accounts_title = gui.label("Accounts", heading);
var account_names: [8][32]u8 = undefined;
var account_lengths: [8]usize = undefined;
var account_admins: [8]bool = undefined;
var account_count: usize = 0;
var account_selected: usize = 0;

/// Set once the list first selects the account we run as.
var account_found = false;

var account_initials: [8][1]u8 = undefined;
var account_avatars: [8]gui.Node = undefined;
var account_labels: [8]gui.Node = undefined;
var account_roles: [8]gui.Node = undefined;
var account_words_parts: [8][2]*gui.Node = undefined;
var account_words: [8]gui.Node = undefined;
var account_parts: [8][2]*gui.Node = undefined;
var account_rows: [8]gui.Node = undefined;
var account_list: [8]*gui.Node = undefined;

var account_box = gui.box(.{

    .gap = 2,

}, &account_list);

var list_spring = gui.box(theme.spring, &.{});
var add = gui.button("Add account", &addAccount);
var list_parts = [_]*gui.Node{ &account_box, &list_spring, &add };

var list_card = gui.box(card.with(.{

    .width = 200,
    .padding = gui.Edges.all(6),
    .gap = 6,

}), &list_parts);

/// Whether the account being added will be an administrator.
var adding_admin = false;

var add_menu: gui.Menu(&.{

    .{ .icon = .user, .title = "Standard account", .run = addStandard },
    .{ .icon = .key, .title = "Administrator", .run = addAdministrator },

}) = .{};

var detail_initial: [1]u8 = undefined;

var detail_avatar = gui.label("", avatar.with(.{

    .width = 56,
    .height = 56,

    .radius = 28,

    .size = 22,

}));

var detail_name = gui.label("", .{

    .size = 20,

});

var detail_role = gui.label("", theme.caption);
var detail_words_parts = [_]*gui.Node{ &detail_name, &detail_role };

var detail_words = gui.box(.{

    .grow = 1,
    .gap = 2,

}, &detail_words_parts);

var detail_head_parts = [_]*gui.Node{ &detail_avatar, &detail_words };

var detail_head = gui.box(card.with(.{

    .padding = gui.Edges.all(16),
    .direction = .row,
    .gap = 16,
    .items = .center,

}), &detail_head_parts);

var password = gui.button("Change", &changePassword);
var password_row = Row{};

var kind = gui.label("", .{

    .color = theme.muted,

});

var kind_row = Row{};
var remove = gui.button("Remove", &removeAccount);
var remove_row = Row{};
var detail_parts = [_]*gui.Node{ &detail_head, &kind_row.node, &password_row.node, &remove_row.node };

var detail = gui.box(group.with(.{

    .grow = 1,

}), &detail_parts);

var accounts_body_parts = [_]*gui.Node{ &list_card, &detail };

var accounts_body = gui.box(.{

    .direction = .row,
    .gap = theme.spacing,

}, &accounts_body_parts);

var accounts_status = quiet();
var accounts_parts = [_]*gui.Node{ &accounts_title, &accounts_body, &accounts_status };
var accounts_page = gui.box(page, &accounts_parts);

var pages = [_]*gui.Node{ &display_page, &appearance_page, &network_page, &sound_page, &accounts_page };

var content = gui.box(.{

    .grow = 1,
    .padding = .{

        .top = 20,
        .right = 24,
        .bottom = 24,
        .left = 24,

    },
    .scroll = true,

}, &pages);

var body_parts = [_]*gui.Node{ &sidebar, &content };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

var root_parts = [_]*gui.Node{ &body };
var root = gui.box(.{}, &root_parts);

pub export fn app_main(parent: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    dialog.init();
    session = parent;

    var argument_bytes: [256]u8 = undefined;

    home = std.fmt.bufPrint(&home_bytes, "{s}", .{catalog.home(api.argument(&argument_bytes)) orelse "/"}) catch "/";
    user = std.fs.path.basename(home);

    buildSidebar();
    buildDisplay();
    buildAppearance();
    buildNetwork();
    buildSound();
    buildAccounts();

    window = gui.Window.open(&root, .{

        .title = "Settings",
        .application = .settings,

        .width = 860,
        .height = 580,

    }) catch api.exit(3);

    resolution_menu.init(&window);
    scale_menu.init(&window);
    wallpaper_menu.init(&window);
    add_menu.init(&window);
    loadAccounts();
    show(.display);

    while (true) {

        // The Network and Sound pages keep up with the link and the volume keys while they show.
        const event = window.next(500) orelse {

            if (!network_page.hidden) describeNetwork(false);
            if (!sound_page.hidden) describeSound();
            continue;

        };

        if (event.kind == .close) window.quit();

    }

}

fn buildSidebar() void {

    me.action = &pick;
    me.data = @intFromEnum(Section.accounts);

    for (sections, 0..) |section, index| {

        tab_pills[index] = gui.box(.{

            .width = 3,
            .height = 16,

            .radius = 2,

        }, &.{});

        tab_icons[index] = gui.icon(section.icon, theme.icon);
        tab_labels[index] = gui.label(section.title, .{});
        tab_parts[index] = .{ &tab_pills[index], &tab_icons[index], &tab_labels[index] };

        tabs[index] = gui.box(theme.item.with(.{

            .height = 38,
            .padding = .{

                .right = 10,
                .left = 4,

            },

        }), &tab_parts[index]);

        tabs[index].action = &pick;
        tabs[index].data = index;
        tab_list[index] = &tabs[index];

    }

}

fn buildDisplay() void {

    display_monitor.init();
    resolution.init(&openResolutions);
    resolution_row.init(.monitor, "Display resolution", &resolution.node);
    scale.init(&openScales);
    scale_row.init(.zoom_in, "Scale", &scale.node);

}

fn buildAppearance() void {

    appearance_monitor.init();
    wallpaper.init(&openWallpapers);
    wallpaper_row.init(.wallpaper, "Wallpaper", &wallpaper.node);
    picture_field.style.grow = 1;
    picture_apply.style = theme.primary;

    swatches.init();
    accent_row.init(.palette, "Accent colour", &swatches.node);

    quartz.init();
    quartz_row.init(.brush, "Transparency effects", &quartz.node);
    quartz_row.node.style.hover.background = theme.hover;
    quartz_row.node.action = &toggleQuartz;

}

fn buildNetwork() void {

    automatic.action = &useAutomatic;
    manual.action = &pickManual;
    method_row.init(.settings, "IP assignment", &method);
    manual_apply.style = theme.primary;

    for (entries, 0..) |entry, index| {

        entry_texts[index] = .{

            .buffer = &entry_bytes[index],
            .placeholder = "0.0.0.0",

        };

        entry_labels[index] = gui.label(entry, theme.caption);
        entry_fields[index] = gui.input(&entry_texts[index]);
        entry_parts[index] = .{ &entry_labels[index], &entry_fields[index] };

        entry_cells[index] = gui.box(.{

            .width = 0,
            .grow = 1,
            .gap = 6,

        }, &entry_parts[index]);

    }

}

fn buildSound() void {

    loudness_node = loudness.node(.{

        .grow = 1,

    });

    loudness_row.init(.volume_high, "Volume", &loudness_control);

    mute.init();
    mute_row.init(.mute, "Mute", &mute.node);
    mute_row.node.style.hover.background = theme.hover;
    mute_row.node.action = &toggleMute;

    chimes.init();
    chimes_row.init(.bell, "System sounds", &chimes.node);
    chimes_row.node.style.hover.background = theme.hover;
    chimes_row.node.action = &toggleChimes;

}

fn buildAccounts() void {

    for (0..8) |index| {

        account_avatars[index] = gui.label("", avatar);
        account_labels[index] = gui.label("", .{});
        account_roles[index] = gui.label("", theme.caption);
        account_words_parts[index] = .{ &account_labels[index], &account_roles[index] };

        account_words[index] = gui.box(.{

            .grow = 1,

        }, &account_words_parts[index]);

        account_parts[index] = .{ &account_avatars[index], &account_words[index] };

        account_rows[index] = gui.box(theme.item.with(.{

            .height = 48,

        }), &account_parts[index]);

        account_rows[index].action = &pickAccount;
        account_rows[index].data = index;
        account_list[index] = &account_rows[index];

    }

    password_row.init(.key, "Password", &password);
    kind_row.init(.user, "Account type", &kind);
    remove_row.init(.trash, "Remove account", &remove);
    remove.style.color = theme.danger;

}

fn pick(tab: *gui.Node) void {

    show(@enumFromInt(tab.data));

}

fn show(section: Section) void {

    for (pages, 0..) |each, index| each.hidden = index != @intFromEnum(section);

    for (&tabs, &tab_pills, 0..) |*tab, *pill, index| {

        tab.selected = index == @intFromEnum(section);
        pill.style.background = if (tab.selected) theme.accent else null;

    }

    switch (section) {

        .display => describeDisplay(""),
        .appearance => describeAppearance(),
        .network => describeNetwork(true),
        .sound => describeSound(),
        .accounts => loadAccounts(),

    }

    content.offset = 0;
    dialog.close();
    window.refresh();

}

/// Shows the output device and the volume, or that there is no audio device.
fn describeSound() void {

    const state = api.audio.status() catch {

        output_name.content.label = "No audio device";
        output_state.content.label = "Sound plays once an HD Audio controller is found.";
        sound_group.hidden = true;
        window.refresh();

        return;

    };

    output_name.content.label = state.chip(&output_chip);
    output_state.content.label = std.fmt.bufPrint(&output_bytes, "{s}, {d} output{s}", .{

        state.adapter(),
        state.outputs,
        if (state.outputs == 1) "" else "s",

    }) catch "";

    sound_group.hidden = false;
    loudness.value = @as(f32, @floatFromInt(state.volume)) / 100;
    loudness_value.content.label = std.fmt.bufPrint(&loudness_bytes, "{d}%", .{state.volume}) catch "";
    mute.set(state.muted);
    chimes.set(state.sounds);
    window.refresh();

}

fn unheard() void {

    tell(&sound_status, "The audio service is unavailable.");

}

fn slideVolume(slider: *gui.Slider, done: bool) void {

    api.audio.volume(@intFromFloat(@round(slider.value * 100))) catch return unheard();

    if (done) api.audio.cue(.level);
    describeSound();

}

fn toggleMute(_: *gui.Node) void {

    const state = api.audio.status() catch return unheard();

    api.audio.mute(!state.muted) catch return unheard();
    describeSound();

}

/// Turns the system's short sounds on or off, playing one as they come on.
fn toggleChimes(_: *gui.Node) void {

    const state = api.audio.status() catch return unheard();

    api.audio.sounds(!state.sounds) catch return unheard();
    if (!state.sounds) api.audio.cue(.notice);
    describeSound();

}

/// Shows `message` under a page's cards, or nothing when it is empty.
fn tell(target: *gui.Node, message: []const u8) void {

    target.content.label = message;
    target.hidden = message.len == 0;
    window.refresh();

}

/// Makes the monitor previews show the wallpaper in the screen's shape, unless they already do.
fn describePreview() void {

    const size = screen.size() catch api.display.Area{};

    preferences.open(user, "desktop");

    const path = preferences.get("wallpaper") orelse "";

    display_monitor.shape(size.width, size.height);
    appearance_monitor.shape(size.width, size.height);

    if (preview_ready and std.meta.eql(size, preview_size) and std.mem.eql(u8, path, preview_path[0..preview_length])) return;
    if (size.width <= 0 or size.height <= 0 or path.len > preview_path.len) return;

    var arena = std.heap.ArenaAllocator.init(api.pages);
    defer arena.deinit();

    const tall: u32 = @intCast(gui.px(preview_height));
    const wide: u32 = @intCast(@max(@divTrunc(@as(i64, tall) * size.width, size.height), 1));
    const built_in = wallpapers.find(path) orelse 0;

    var next = gui.Image.open(arena.allocator(), &files, path) catch wallpapers.render(built_in, wide, tall) catch return;

    next.fit = .cover;

    next.publish() catch {

        next.deinit();
        return;

    };

    if (preview_ready) preview.deinit();

    preview = next;
    preview_ready = true;
    preview_size = size;
    @memcpy(preview_path[0..path.len], path);
    preview_length = path.len;
    window.refresh();

}

/// Sketches the desktop over a preview's wallpaper: the top bar, two windows, and the dock.
fn sketchDesktop(node: *gui.Node, list: *gui.List) void {

    const area = node.rect;
    const width = area.width;
    const height = area.height;

    list.fill(.{

        .x = area.x,
        .y = area.y,
        .width = width,
        .height = @max(@divTrunc(height, 26), 3),

    }, 0xe0ffffff);

    const back = gui.Rect{

        .x = area.x + @divTrunc(width * 12, 100),
        .y = area.y + @divTrunc(height * 16, 100),
        .width = @divTrunc(width * 46, 100),
        .height = @divTrunc(height * 50, 100),

    };

    const front = gui.Rect{

        .x = area.x + @divTrunc(width * 42, 100),
        .y = area.y + @divTrunc(height * 30, 100),
        .width = @divTrunc(width * 42, 100),
        .height = @divTrunc(height * 46, 100),

    };

    for ([_]gui.Rect{ back, front }) |each| {

        const bar = @max(@divTrunc(each.height, 9), 4);

        // Like the window manager's: a rounded frame whose title bar meets the content squarely.
        list.shadow(each, 4, 8, 0x80000000);
        list.round(each, 4, theme.line);
        list.round(each.inset(1), 3, theme.selected);

        list.fill(.{

            .x = each.x + 1,
            .y = each.y + 1 + bar,
            .width = each.width - 2,
            .height = each.height - 2 - bar - 3,

        }, theme.raised);

        list.round(.{

            .x = each.x + 1,
            .y = each.bottom() - 1 - 6,
            .width = each.width - 2,
            .height = 6,

        }, 3, theme.raised);

    }

    const dock_width = @divTrunc(width * 16, 100);
    const dock_height = @max(@divTrunc(height, 14), 5);

    list.round(.{

        .x = area.x + @divTrunc(width - dock_width, 2),
        .y = area.bottom() - dock_height - @divTrunc(height, 30),
        .width = dock_width,
        .height = dock_height,

    }, 3, 0xd0ffffff);

}

fn describeDisplay(problem: []const u8) void {

    const size = screen.size() catch api.display.Area{};

    resolution.value.content.label = std.fmt.bufPrint(&resolution_bytes, "{d} × {d}", .{ size.width, size.height }) catch "";
    scale.value.content.label = std.fmt.bufPrint(&scale_bytes, "{d}%", .{screen.scale() catch 100}) catch "";
    describePreview();
    tell(&display_status, problem);

}

fn openResolutions(_: *gui.Node) void {

    resolution_menu.show(resolution.below());

}

fn openScales(_: *gui.Node) void {

    scale_menu.show(scale.below());

}

fn setScale(percent: u8) void {

    screen.rescale(percent) catch return describeDisplay("The display service is unavailable.");

    describeDisplay("");

}

fn setMode(index: usize) void {

    const mode = modes[index];

    screen.mode(mode[0], mode[1]) catch |err| return describeDisplay(switch (err) {

        error.Denied => "Only administrators can change the resolution.",
        error.Invalid => "This screen cannot show that resolution.",
        else => "The display service is unavailable.",

    });

    describeDisplay("");

}

fn describeAppearance() void {

    preferences.open(user, "desktop");

    const current = preferences.get("wallpaper") orelse "";
    const picture = current.len != 0 and wallpapers.find(current) == null;

    if (picture) picture_text.set(current);

    choosePicture(if (picture) null else wallpapers.find(current) orelse 0);
    swatches.set(theme.accentNamed(preferences.get("accent") orelse ""));
    quartz_on = !std.mem.eql(u8, preferences.get("quartz") orelse "", "off");
    quartz.set(quartz_on);
    describePreview();
    tell(&appearance_status, "");

}

/// Shows built-in wallpaper `which` as chosen, or Picture, with a field for its path, when null.
fn choosePicture(which: ?usize) void {

    wallpaper.value.content.label = if (which) |index| wallpapers.all[index].name else "Picture";
    picture_row.hidden = which != null;
    window.refresh();

}

fn openWallpapers(_: *gui.Node) void {

    wallpaper_menu.show(wallpaper.below());

}

/// Saves `value` as `key` in the `desktop` config and asks the desktop to show `what` changed; false, noting why, when it could not.
fn prefer(key: []const u8, value: []const u8, what: catalog.Reload) bool {

    preferences.open(user, "desktop");

    if (!preferences.set(key, value)) {

        note(error.Invalid);
        return false;

    }

    preferences.save() catch |err| {

        note(err);
        return false;

    };

    _ = api.call(session, protocol.pack(.reload, @intFromEnum(what))) catch {

    };

    return true;

}

fn note(err: api.ServiceError) void {

    tell(&appearance_status, if (err == error.Denied) "Permission denied." else "Could not save the choice.");

}

fn toggleQuartz(_: *gui.Node) void {

    if (!prefer("quartz", if (quartz_on) "off" else "on", .quartz)) return;

    quartz_on = !quartz_on;
    quartz.set(quartz_on);
    window.refresh();

}

fn useWallpaper(index: usize) void {

    if (!prefer("wallpaper", wallpapers.all[index].name, .all)) return;

    choosePicture(index);
    describePreview();
    tell(&appearance_status, "");

}

fn pickAccent(index: u8) void {

    if (!prefer("accent", theme.accents[index].name, .accent)) return;

    swatches.set(index);
    tell(&appearance_status, "");

}

fn pickPicture() void {

    choosePicture(null);
    window.focus(&picture_field);

}

fn usePicture(_: *gui.Node) void {

    const choice = picture_text.text();

    if (!catalog.picture(choice)) {

        picture_field.invalid = true;
        return tell(&appearance_status, "Choose a .png file.");

    }

    if (!prefer("wallpaper", choice, .all)) return;

    describePreview();
    tell(&appearance_status, "");

}

/// Shows the link and its address; `fill` also picks the segment for the address in use and puts a manual one in the fields.
fn describeNetwork(fill: bool) void {

    const state = api.net.status() catch api.net.Status{};

    link_state.content.label = if (state.off) "Turned off" else if (state.speed == 0) "Not connected" else if (state.address.empty()) "Connecting…" else "Connected";
    link_icon.style.color = if (state.online()) theme.text else theme.faint;
    address_box.hidden = state.address.empty();
    address_value.content.label = std.fmt.bufPrint(&address_bytes, "{f}", .{state.address}) catch "";

    if (fill) {

        manual_chosen = state.source == .manual;
        if (manual_chosen) fillEntries(state);

    }

    describeMethod();

}

fn describeMethod() void {

    automatic.selected = !manual_chosen;
    manual.selected = manual_chosen;
    manual_card.hidden = !manual_chosen;
    window.refresh();

}

fn fillEntries(state: api.net.Status) void {

    const addresses = [entries.len]api.net.Address{ state.address, state.mask, state.gateway, state.server };

    for (addresses, &entry_texts) |address, *text| {

        var bytes: [16]u8 = undefined;

        text.set(if (address.empty()) "" else std.fmt.bufPrint(&bytes, "{f}", .{address}) catch "");

    }

}

fn pickManual(_: *gui.Node) void {

    if (manual_chosen) return;

    // Starts from the address DHCP gave, the likeliest base for one typed by hand.
    if (entry_texts[0].text().len == 0) fillEntries(api.net.status() catch api.net.Status{});

    manual_chosen = true;
    tell(&network_status, "");
    describeMethod();
    window.focus(&entry_fields[0]);

}

fn useAutomatic(_: *gui.Node) void {

    if (!manual_chosen) return;

    const state = api.net.status() catch api.net.Status{};

    manual_chosen = false;

    if (state.source == .manual) {

        manual_chosen = !configure(.{}, "");

    } else {

        tell(&network_status, "");

    }

    describeMethod();

}

fn useManual(_: *gui.Node) void {

    var addresses: [entries.len]api.net.Address = undefined;

    for (&addresses, entry_texts, 0..) |*address, text, index| {

        const typed = std.mem.trim(u8, text.text(), " ");

        // The gateway and DNS server may stay empty on a network without them.
        address.* = if (typed.len == 0 and index >= 2) .{} else api.net.Address.parse(typed) orelse {

            entry_fields[index].invalid = true;
            return tell(&network_status, "Enter addresses as four numbers, such as 192.168.1.20.");

        };

        entry_fields[index].invalid = false;

    }

    _ = configure(.{

        .manual = 1,
        .address = addresses[0],
        .mask = addresses[1],
        .gateway = addresses[2],
        .server = addresses[3],

    }, "Saved.");

}

/// Applies `setting`, saying `done` or why it failed; false when it failed.
fn configure(setting: api.net.Setting, done: []const u8) bool {

    api.net.configure(setting) catch |err| {

        tell(&network_status, switch (err) {

            error.Denied => "Only administrators can change network settings.",
            error.Invalid => "The IP address and subnet mask are needed.",
            else => "The network service is unavailable.",

        });

        return false;

    };

    tell(&network_status, done);
    describeNetwork(false);

    return true;

}

fn loadAccounts() void {

    account_count = 0;

    while (account_count < account_names.len) {

        const account = (accounts.list(@intCast(account_count)) catch break) orelse break;
        const length = @min(account.name.len, 32);

        @memcpy(account_names[account_count][0..length], account.name[0..length]);
        account_lengths[account_count] = length;
        account_admins[account_count] = account.identity.admin;

        if (std.mem.eql(u8, account_names[account_count][0..length], user)) {

            me_role.content.label = role(account_count);

            if (!account_found) {

                account_selected = account_count;
                account_found = true;

            }

        }

        account_count += 1;

    }

    account_selected = @min(account_selected, account_count -| 1);

    for (0..8) |index| {

        account_rows[index].hidden = index >= account_count;
        account_rows[index].selected = index == account_selected;
        if (index >= account_count) continue;

        account_initials[index] = .{std.ascii.toUpper(account_names[index][0])};
        account_avatars[index].content.label = &account_initials[index];
        account_labels[index].content.label = account_names[index][0..account_lengths[index]];
        account_roles[index].content.label = role(index);

    }

    if (user.len != 0) me_initial = .{std.ascii.toUpper(user[0])};

    me_avatar.content.label = &me_initial;
    me_name.content.label = user;
    detail.hidden = account_count == 0;
    if (account_count != 0) describeAccount();

    window.refresh();

}

fn role(index: usize) []const u8 {

    return if (account_admins[index]) "Administrator" else "Standard";

}

fn describeAccount() void {

    const own = std.mem.eql(u8, selectedName(), user);

    detail_initial = account_initials[account_selected];
    detail_avatar.content.label = &detail_initial;
    detail_name.content.label = selectedName();
    detail_role.content.label = "Signed in";
    detail_role.hidden = !own;
    kind.content.label = role(account_selected);

    // Nobody can remove the account they are using.
    remove_row.node.hidden = own;

}

fn pickAccount(target: *gui.Node) void {

    account_selected = target.data;
    tell(&accounts_status, "");
    loadAccounts();

}

fn selectedName() []const u8 {

    return account_names[account_selected][0..account_lengths[account_selected]];

}

fn addAccount(_: *gui.Node) void {

    add_menu.show(.{

        .x = add.rect.x,
        .y = add.rect.bottom() + 4,

    });

}

fn addStandard() void {

    askName(false);

}

fn addAdministrator() void {

    askName(true);

}

fn askName(admin: bool) void {

    adding_admin = admin;
    pending = .name;
    dialog.edit.secret = false;
    dialog.ask(&window, if (admin) "New administrator's name" else "New account's name", "", "Next", &advance);

}

fn removeAccount(_: *gui.Node) void {

    if (account_count == 0) return;

    var message: [80]u8 = undefined;

    dialog.edit.secret = false;
    dialog.check(&window, std.fmt.bufPrint(&message, "Remove {s}?", .{selectedName()}) catch "Remove it?", "Their files stay in their home folder.", "Remove", &applyRemove);

}

fn applyRemove(_: []const u8) void {

    accounts.remove(selectedName()) catch |err| return tell(&accounts_status, switch (err) {

        error.Busy => "You can't remove the account you're using.",
        error.Denied => "Only administrators can remove accounts.",
        else => "Could not remove that account.",

    });

    tell(&accounts_status, "");
    loadAccounts();

}

fn changePassword(_: *gui.Node) void {

    if (account_count == 0) return;

    const own = std.mem.eql(u8, selectedName(), user);

    pending = if (own) .current else .replacement;
    draft_secret_length = 0;
    dialog.edit.secret = true;
    dialog.ask(&window, if (own) "Current password" else "New password", "", "Next", &advance);

}

/// Steps through the account prompts, which ask one field at a time.
fn advance(value: []const u8) void {

    switch (pending) {

        .name => {

            if (value.len == 0 or value.len > draft_name.len) return dialog.refuse("Names need 1 to 32 characters.");

            @memcpy(draft_name[0..value.len], value);
            draft_length = value.len;
            pending = .password;
            dialog.edit.secret = true;
            dialog.ask(&window, "Their password", "", "Create", &advance);

        },
        .password => {

            pending = .none;
            dialog.edit.secret = false;

            accounts.create(draft_name[0..draft_length], value, adding_admin) catch |err| return tell(&accounts_status, switch (err) {

                error.Exists => "That name is taken.",
                error.Denied => "Only administrators can add accounts.",
                else => "Could not add that account.",

            });

            tell(&accounts_status, "");
            loadAccounts();

        },
        .current => {

            @memcpy(draft_secret[0..@min(value.len, draft_secret.len)], value[0..@min(value.len, draft_secret.len)]);
            draft_secret_length = @min(value.len, draft_secret.len);
            pending = .replacement;
            dialog.ask(&window, "New password", "", "Change", &advance);

        },
        .replacement => {

            defer std.crypto.secureZero(u8, &draft_secret);

            pending = .none;
            dialog.edit.secret = false;
            if (value.len == 0) return tell(&accounts_status, "Passwords can't be empty.");

            accounts.password(selectedName(), value, draft_secret[0..draft_secret_length]) catch |err| return tell(&accounts_status, if (err == error.Denied) "That password was wrong, or you may not change it." else "Could not change the password.");
            tell(&accounts_status, "Password changed.");

        },
        .none => {

        },

    }

}
