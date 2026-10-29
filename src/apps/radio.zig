//! Radio: internet stations streamed as MP3 with the song now playing; a few featured, more found in the Radio Browser
//! directory, and favourites kept.

const std = @import("std");

const catalog = @import("catalog.zig");
const stations = @import("stations.zig");

const api = @import("api");
const gui = @import("gui");
const media = @import("media");

const icy = media.icy;
const mp3 = media.mp3;
const theme = gui.theme;
const Station = stations.Station;
pub const panic = api.panic;

/// Stations one search lists at most, and favourites kept.
const found_most = 40;
const kept_most = 16;

/// Ticks to wait on the directory or a station connecting, and on a playing station between its bytes.
const patience = 15 * 100;

/// Seconds of sound the speakers hold, and how many must be in before they play, so the network's hiccups go unheard.
const held = 4;
const ready = 2;

/// Bytes taken from a station at most at once.
const piece = 4096;

const Trouble = api.http.HttpError || error{ Unavailable, Format, Ended, Speechless };

const Tab = enum {

    featured,
    favourites,
    search,

};

/// Where listening stands, as the window shows it.
const State = enum {

    stopped,
    connecting,
    buffering,
    playing,
    failed,

};

/// What a network wait is for, so the window's events end only the waits they concern.
const Wait = enum {

    stream,
    search,

};

/// A station in the sidebar: its icon, name, and what it plays.
const Row = struct {

    icon: gui.Node,
    title: gui.Node,
    detail: gui.Node,
    words: [2]*gui.Node,
    text: gui.Node,
    parts: [2]*gui.Node,
    node: gui.Node,

    fn init(self: *Row, index: usize) void {

        self.icon = gui.icon(.radio, theme.icon.with(.{

            .color = theme.muted,

        }));

        self.title = gui.label("", .{});
        self.detail = gui.label("", theme.caption);
        self.words = .{ &self.title, &self.detail };

        self.text = gui.box(.{

            .grow = 1,
            .gap = 2,

        }, &self.words);

        self.parts = .{ &self.icon, &self.text };

        self.node = gui.box(theme.item.with(.{

            .height = 48,

        }), &self.parts);

        self.node.action = &rowChosen;
        self.node.menu = &rowOffered;
        self.node.data = index;

    }

    /// Shows `station`, marked when it is the one tuned, and as sounding when that one is `on`.
    fn set(self: *Row, station: *const Station, tuned_here: bool, sounding: bool) void {

        const loud = tuned_here and sounding;

        self.icon.content.label = (if (loud) gui.Icon.volume_high else gui.Icon.radio).text();
        self.icon.style.color = if (loud) theme.text else theme.muted;
        self.title.content.label = station.name;
        self.detail.content.label = station.detail;
        self.detail.hidden = station.detail.len == 0;
        self.node.selected = tuned_here;
        self.node.hidden = false;

    }

};

var tab = Tab.featured;

var found: [found_most]Station = undefined;
var found_count: usize = 0;
var found_memory = std.heap.ArenaAllocator.init(api.pages);

var kept: [kept_most]Station = undefined;
var kept_count: usize = 0;
var kept_memory = std.heap.ArenaAllocator.init(api.pages);

/// The station picked, copied out of its list, and whether it should be playing.
var tuned: ?Station = null;
var tuned_bytes: [2048]u8 = undefined;
var on = false;

/// Rises each time what should play changes, which ends listening to the station before.
var generation: u32 = 0;
var listened: u32 = 0;

var state = State.stopped;
var trouble: []const u8 = "";
var trouble_bytes: [128]u8 = undefined;

var waiting = Wait.stream;
var deadline: u64 = 0;
var wanted = false;

/// The station's titles, its sound as it comes and once decoded, and its bitrate.
var demuxer = icy.Demuxer.init(0);
var feed_bytes: [16 * 1024]u8 = undefined;
var feed = mp3.Feed.init(&feed_bytes);
var frames: mp3.Frames = undefined;
var decoded: [1152 * 2]f32 = undefined;
var mixed: [1152 * 2]f32 = undefined;
var kbps: u32 = 0;

var speakers: ?api.audio.Stream = null;
var volume: u8 = 80;
var muted = false;

var preferences = api.Config{};

// Sidebar.
const tab_icons = [_]gui.Icon{ .radio, .star, .search };
const tab_titles = [_][]const u8{ "Featured", "Favourites", "Search" };

var tab_nodes: [tab_titles.len]gui.Node = undefined;
var tab_marks: [tab_titles.len]gui.Node = undefined;
var tab_labels: [tab_titles.len]gui.Node = undefined;
var tab_parts: [tab_titles.len][2]*gui.Node = undefined;
var tab_list: [tab_titles.len]*gui.Node = undefined;

var tabs = gui.box(.{

    .direction = .row,
    .gap = 4,

}, &tab_list);

var search_bytes: [64]u8 = undefined;

var search_text = gui.Text{

    .buffer = &search_bytes,
    .placeholder = "Search stations by name",

};

var search = gui.input(&search_text);

/// How the last search went, and whether a favourite was just refused for want of room; the note under the tabs says.
var searched: []const u8 = "Type a station's name and press Enter.";
var note_bytes: [96]u8 = undefined;
var refused = false;

var note = gui.label("", theme.caption.with(.{

    .padding = gui.Edges.axes(4, 4),

}));

var rows: [found_most]Row = undefined;
var row_list: [found_most]*gui.Node = undefined;

var list = gui.box(.{

    .grow = 1,
    .gap = 2,
    .scroll = true,

}, &row_list);

var side_parts = [_]*gui.Node{ &tabs, &search, &note, &list };

var side = gui.box(.{

    .width = 300,
    .padding = .all(theme.gap),
    .gap = theme.gap,

    .background = theme.raised,

}, &side_parts);

// Now playing.
var art = gui.icon(.radio, theme.icon.with(.{

    .width = null,
    .size = 72,
    .color = theme.faint,
    .text_align = .center,

}));

var song = gui.label("", theme.title_text.with(.{

    .text_align = .center,

}));

var artist = gui.label("", theme.caption.with(.{

    .text_align = .center,

}));

var channel = gui.label("", .{

    .color = theme.muted,
    .text_align = .center,

});

var status_bytes: [96]u8 = undefined;

var status = gui.label("", theme.caption.with(.{

    .color = theme.faint,
    .text_align = .center,

}));

var cover_parts = [_]*gui.Node{ &art, &song, &artist, &channel, &status };

var cover = gui.box(.{

    .grow = 1,
    .padding = gui.Edges.all(theme.spacing * 2),
    .gap = theme.gap,
    .justify = .center,
    .items = .stretch,

}, &cover_parts);

var body_parts = [_]*gui.Node{ &side, &cover };

var body = gui.box(.{

    .grow = 1,
    .direction = .row,

}, &body_parts);

// Controls.
var play_tool = gui.tool(.play, &playChosen);
var star_tool = gui.tool(.star, &starChosen);
var spring = gui.box(theme.spring, &.{});
var loudness_tool = gui.tool(.volume_high, &muteChosen);

var loudness = gui.Slider{

    .value = 0.8,
    .changed = &volumeMoved,

};

var leveler: gui.Node = undefined;
var control_parts = [_]*gui.Node{ &play_tool, &star_tool, &spring, &loudness_tool, &leveler };

var controls = gui.box(.{

    .height = 52,
    .padding = .axes(0, theme.gap),
    .direction = .row,
    .gap = 4,
    .items = .center,

}, &control_parts);

var rule = gui.box(theme.rule, &.{});
var parts = [_]*gui.Node{ &body, &rule, &controls };

var root = gui.box(.{

    .background = theme.background,

}, &parts);

var window: gui.Window = undefined;

var row_menu: gui.Menu(&.{

    .{ .icon = .play, .title = "Play", .hint = "Enter", .run = playPicked },
    .{ .icon = .star, .title = "Add to favourites", .run = keepPicked, .offered = pickedLoose },
    .{ .icon = .close, .title = "Remove from favourites", .run = dropPicked, .offered = pickedKept },

}) = .{};

/// The row a menu acts on.
var picked: usize = 0;

var title_bytes: [160]u8 = undefined;

comptime {

    std.debug.assert(stations.featured.len <= found_most and kept_most <= found_most);

}

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var argument_bytes: [256]u8 = undefined;
    const argument = api.argument(&argument_bytes);

    frames = mp3.Frames.init();
    preferences.open(std.fs.path.basename(catalog.home(argument) orelse ""), "radio");
    load();
    build();

    window = gui.Window.open(&root, .{

        .title = "Radio",
        .application = .radio,

        .width = 900,
        .height = 560,

    }) catch api.exit(3);

    row_menu.init(&window);
    window.react = &shortcut;
    api.net.idle = &idle;
    show();

    while (true) {

        if (wanted) find();
        if (on and listened != generation) listen();

        pump(100);

    }

}

fn build() void {

    for (&tab_nodes, 0..) |*node, index| {

        tab_marks[index] = gui.icon(tab_icons[index], theme.icon);

        tab_labels[index] = gui.label(tab_titles[index], .{

            .size = theme.small,

        });

        tab_parts[index] = .{ &tab_marks[index], &tab_labels[index] };

        node.* = gui.box(theme.item.with(.{

            .grow = 1,
            .height = 32,
            .gap = 6,
            .justify = .center,

        }), &tab_parts[index]);

        node.action = &tabChosen;
        node.data = index;
        tab_list[index] = node;

    }

    for (&rows, 0..) |*row, index| {

        row.init(index);
        row_list[index] = &row.node;

    }

    search.action = &ask;

    leveler = loudness.node(.{

        .width = 100,

    });

    play_tool.style = play_tool.style.with(.{

        .width = 40,
        .height = 40,
        .size = 18,
        .radius = 20,

        .background = theme.accent,
        .color = theme.background,

        .hover = .{

            .background = theme.text,

        },
        .focus = .{

            .background = theme.text,

        },
        .pressed = .{

            .background = theme.muted,

        },

    });

}

/// Waits up to `timeout` ticks for the window's events, and quits once it closes.
fn pump(timeout: u64) void {

    const event = window.next(timeout) orelse return;

    if (event.kind == .close) quit();

}

/// Keeps the window answering while the network is waited on, and ends a station's wait once something else should play.
fn idle() api.net.NetError!void {

    pump(1);

    if (waiting == .stream and (!on or generation != listened)) return error.Cancelled;
    if (api.ticks() >= deadline) return error.Timeout;

}

fn quit() noreturn {

    if (speakers) |*open| open.close();

    window.quit();

}

/// Keys that work wherever the focus is, unless a node took them.
fn shortcut(_: *gui.Window, event: api.Event) bool {

    if (event.kind != .key or !event.pressed) return false;

    if (event.chord(.{ .control = true }, 'f')) {

        choose(.search);
        return true;

    }

    switch (event.key()) {

        .up => setVolume(volume +| 5, true),
        .down => setVolume(volume -| 5, true),
        .character => switch (event.char) {

            ' ', 'k' => playChosen(&play_tool),
            'm' => muteChosen(&loudness_tool),
            's' => starChosen(&star_tool),
            else => return false,

        },
        else => return false,

    }

    return true;

}

/// Plays the tuned station until something else should play, or it fails.
fn listen() void {

    listened = generation;

    const station = tuned orelse return;

    state = .connecting;
    trouble = "";
    kbps = station.bitrate;
    demuxer = .init(0);
    show();

    waiting = .stream;
    deadline = api.ticks() + patience;

    var response: api.http.Response = undefined;

    api.http.open(api.pages, station.url, .{

        .headers = &.{

            .{

                .name = "Icy-MetaData",
                .value = "1",

            },

        },

    }, &response) catch |err| return fail(err);

    defer response.close();

    if (response.status != 200) return fail(error.Unavailable);

    switch (icy.Format.of(response.header("content-type") orelse "")) {

        .aac, .ogg => return fail(error.Format),
        .mpeg, .other => {},

    }

    // Stations write `icy-br` as `128`, or as `128,128` for a bitrate range.
    const rate = response.header("icy-br") orelse "";

    kbps = std.fmt.parseInt(u32, std.mem.trim(u8, rate[0 .. std.mem.indexOfScalar(u8, rate, ',') orelse rate.len], " "), 10) catch kbps;
    demuxer = .init(std.fmt.parseInt(usize, response.header("icy-metaint") orelse "0", 10) catch 0);
    feed = .init(&feed_bytes);
    frames.reset();
    state = .buffering;
    show();

    stream(&response);

    if (speakers) |*open| {

        open.flush();
        open.pause(true);

    }

}

/// Moves the station's sound from the network through the decoder to the speakers.
fn stream(response: *api.http.Response) void {

    var bytes: [piece]u8 = undefined;

    while (on and generation == listened) {

        if (wanted) {

            find();
            waiting = .stream;
            deadline = api.ticks() + patience;

        }

        play();

        if (state == .failed) return;

        // With the speakers full and bytes enough held, the network can wait.
        if (feed.room() < piece) {

            pump(2);
            continue;

        }

        const came = response.body.peekGreedy(1) catch |err| {

            if (err == error.EndOfStream) return fail(error.Ended);

            const why = response.failure();

            if (why != error.Cancelled) fail(why);

            return;

        };

        const count = @min(came.len, piece);
        const changes = demuxer.changes;

        @memcpy(bytes[0..count], came[0..count]);
        response.body.toss(count);
        deadline = api.ticks() + patience;
        feed.keep(demuxer.strip(bytes[0..count]));

        if (demuxer.changes != changes) show();

        // A timeout of zero would wait for input without end.
        pump(1);

    }

}

/// Decodes what the feed holds into the speakers' room, playing once enough is in and holding while it runs out.
fn play() void {

    if (feed.rate == 0) feed.probe();
    if (feed.rate == 0) return;

    const open = speakersFor(feed.rate, feed.channels) orelse return fail(error.Speechless);
    const channels = open.format.channels;

    while (open.room() >= 1152) {

        const bytes = feed.frame() orelse break;
        const header = mp3.Header.parse(std.mem.readInt(u32, bytes[0..4], .big)).?;
        const count = frames.decode(bytes, &decoded) catch continue;

        if (kbps == 0) kbps = header.bitrate;

        mp3.remix(&decoded, header.channels, &mixed, channels, count);
        _ = open.write(f32, mixed[0 .. count * channels]);

    }

    const queued = open.header.capacity - open.room();

    if (state == .buffering and queued >= open.format.rate * ready) {

        open.pause(false);
        state = .playing;
        show();

    } else if (state == .playing and queued == 0) {

        open.pause(true);
        state = .buffering;
        show();

    }

}

/// Speakers for sound of `rate` and `channels`, keeping those open when they suit; held paused until enough is in.
fn speakersFor(rate: u32, channels: u8) ?*api.audio.Stream {

    if (speakers) |*open| {

        if (open.format.rate == rate and open.format.channels == channels) return open;

        open.close();
        speakers = null;

    }

    const format = api.audio.Format{

        .rate = rate,
        .channels = channels,
        .encoding = .f32,

    };

    var open = api.audio.Stream.open(format, rate * held) catch return null;

    open.pause(true);
    speakers = open;
    level();

    return &speakers.?;

}

fn fail(err: Trouble) void {

    state = .failed;
    on = false;

    trouble = switch (err) {

        error.Unavailable => "This station isn't broadcasting right now.",
        error.Format => "This station doesn't send MP3, the one format Radio plays.",
        error.Ended => "The station stopped broadcasting.",
        error.Timeout => "The station stopped answering.",
        error.Speechless => "There's no sound device to play through.",
        else => |other| std.fmt.bufPrint(&trouble_bytes, "Couldn't reach this station: {s}.", .{api.http.reason(other)}) catch "",

    };

    if (speakers) |*open| {

        open.flush();
        open.pause(true);

    }

    show();

}

/// Searches the directory for the stations named in the search field.
fn find() void {

    wanted = false;

    const query = std.mem.trim(u8, search_text.text(), " ");

    if (query.len == 0) return;

    waiting = .search;
    deadline = api.ticks() + patience;
    tab = .search;
    found_count = 0;
    searched = "Searching\u{2026}";
    show();

    _ = found_memory.reset(.retain_capacity);

    found_count = lookup(query) catch |err| {

        searched = std.fmt.bufPrint(&note_bytes, "Couldn't search: {s}.", .{api.http.reason(err)}) catch "";
        return show();

    };

    searched = if (found_count == 0) "No stations found." else "";
    show();

}

fn lookup(query: []const u8) api.http.HttpError!usize {

    const allocator = found_memory.allocator();

    var url: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&url);

    writer.writeAll(stations.directory) catch return error.Malformed;
    api.http.escape(&writer, query) catch return error.Malformed;

    var reply = std.Io.Writer.Allocating.init(allocator);

    if (try api.http.get(api.pages, writer.buffered(), &reply.writer) != 200) return error.Malformed;

    return stations.read(allocator, reply.written(), &found) catch |err| if (err == error.OutOfMemory) error.Exhausted else error.Malformed;

}

/// Plays `station` instead of whatever played.
fn tune(station: *const Station) void {

    var memory = std.heap.FixedBufferAllocator.init(&tuned_bytes);

    tuned = station.copy(memory.allocator()) catch return;
    start();

}

/// Plays the tuned station from now.
fn start() void {

    on = true;
    generation +%= 1;
    state = .connecting;
    trouble = "";
    show();

}

fn stop() void {

    on = false;
    generation +%= 1;
    state = .stopped;
    show();

}

/// The stations the sidebar lists.
fn listing() []const Station {

    return switch (tab) {

        .featured => &stations.featured,
        .favourites => kept[0..kept_count],
        .search => found[0..found_count],

    };

}

/// Where the station at `url` sits among the favourites.
fn keptAt(url: []const u8) ?usize {

    for (kept[0..kept_count], 0..) |station, index| {

        if (std.mem.eql(u8, station.url, url)) return index;

    }

    return null;

}

/// Keeps `station` as a favourite, unless it is one or there is no room.
fn keep(station: *const Station) void {

    refused = false;

    if (keptAt(station.url) != null) return;

    if (kept_count == kept_most) return refuse();

    kept[kept_count] = station.copy(kept_memory.allocator()) catch return refuse();
    kept_count += 1;

    if (!remember()) {

        kept_count -= 1;
        _ = remember();

        return refuse();

    }

    show();

}

fn refuse() void {

    refused = true;
    show();

}

fn drop(url: []const u8) void {

    const index = keptAt(url) orelse return;

    std.mem.copyForwards(Station, kept[index .. kept_count - 1], kept[index + 1 .. kept_count]);
    kept_count -= 1;
    _ = remember();
    show();

}

/// Reads the volume and the favourites.
fn load() void {

    volume = @min(preferences.number(u8, "volume") orelse 80, 100);
    loudness.value = @as(f32, @floatFromInt(volume)) / 100;

    var lines = preferences.all("station");

    while (lines.next()) |line| {

        if (kept_count == kept_most) break;

        const station = Station.parse(line) orelse continue;

        kept[kept_count] = station.copy(kept_memory.allocator()) catch break;
        kept_count += 1;

    }

}

/// Writes the volume and the favourites back; false when the favourites do not all fit.
fn remember() bool {

    var line_bytes: [512]u8 = undefined;
    var fits = preferences.set("volume", volume);

    preferences.erase("station");

    for (kept[0..kept_count]) |*station| {

        const line = station.line(&line_bytes) orelse {

            fits = false;
            continue;

        };

        fits = preferences.add("station", line) and fits;

    }

    preferences.save() catch {

    };

    return fits;

}

/// Shows the tab's stations, what plays, and the controls' states.
fn show() void {

    const shown = listing();
    const url = if (tuned) |station| station.url else "";

    for (&tab_nodes, 0..) |*node, index| node.selected = index == @intFromEnum(tab);

    for (&rows, 0..) |*row, index| {

        row.node.hidden = index >= shown.len;
        if (index < shown.len) row.set(&shown[index], std.mem.eql(u8, shown[index].url, url), on);

    }

    search.hidden = tab != .search;
    note.content.label = if (refused) "There's no room for more favourites." else switch (tab) {

        .featured => "",
        .favourites => if (kept_count == 0) "Stations you star are kept here." else "",
        .search => searched,

    };

    note.hidden = note.content.label.len == 0;
    showCover();

    play_tool.content.label = (if (on) gui.Icon.pause else gui.Icon.play).text();
    star_tool.hidden = tuned == null;
    star_tool.selected = if (tuned) |station| keptAt(station.url) != null else false;
    loudness_tool.content.label = speaker().text();
    window.refresh();

}

/// Shows the station tuned and its song, or how to start.
fn showCover() void {

    const station = tuned orelse {

        song.content.label = "Radio";
        artist.content.label = "Pick a station to listen to.";
        artist.hidden = false;
        channel.hidden = true;
        status.hidden = true;
        art.style.color = theme.faint;
        window.retitle("Radio");

        return;

    };

    const now = icy.Song.of(if (state == .playing or state == .buffering) demuxer.title() else "");
    const titled = now.name.len != 0;

    song.content.label = if (titled) now.name else station.name;
    artist.content.label = if (titled) now.artist else station.detail;
    artist.hidden = artist.content.label.len == 0;
    channel.content.label = station.name;
    channel.hidden = !titled;
    status.content.label = describe();
    status.style.color = if (state == .failed) theme.danger else theme.faint;
    status.hidden = false;
    art.style.color = if (state == .playing) theme.text else theme.faint;

    window.retitle(std.fmt.bufPrint(&title_bytes, "{s} - Radio", .{song.content.label}) catch "Radio");

}

/// Where listening stands in words, such as `MP3 · 128 kbps · 44.1 kHz · Stereo`.
fn describe() []const u8 {

    return switch (state) {

        .stopped => "Stopped",
        .connecting => "Connecting\u{2026}",
        .buffering => "Buffering\u{2026}",
        .failed => trouble,
        .playing => std.fmt.bufPrint(&status_bytes, "MP3 \u{00b7} {d} kbps \u{00b7} {d:.1} kHz \u{00b7} {s}", .{

            kbps,
            @as(f64, @floatFromInt(feed.rate)) / 1000,
            if (feed.channels == 1) "Mono" else "Stereo",

        }) catch "",

    };

}

fn choose(which: Tab) void {

    tab = which;
    refused = false;
    show();

    if (which == .search) window.focus(&search);

}

fn tabChosen(node: *gui.Node) void {

    choose(@enumFromInt(node.data));

}

fn ask(_: *gui.Node) void {

    wanted = true;

}

fn rowChosen(node: *gui.Node) void {

    const shown = listing();

    if (node.data < shown.len) tune(&shown[node.data]);

}

fn rowOffered(node: *gui.Node, at: gui.Point) void {

    picked = node.data;
    row_menu.show(at);

}

fn pickedStation() ?*const Station {

    const shown = listing();

    return if (picked < shown.len) &shown[picked] else null;

}

fn playPicked() void {

    if (pickedStation()) |station| tune(station);

}

fn keepPicked() void {

    if (pickedStation()) |station| keep(station);

}

fn dropPicked() void {

    if (pickedStation()) |station| drop(station.url);

}

fn pickedKept() bool {

    const station = pickedStation() orelse return false;

    return keptAt(station.url) != null;

}

fn pickedLoose() bool {

    return !pickedKept();

}

fn playChosen(_: *gui.Node) void {

    if (on) return stop();
    if (tuned != null) return start();

    const shown = listing();

    if (shown.len != 0) tune(&shown[0]);

}

fn starChosen(_: *gui.Node) void {

    const station = tuned orelse return;

    if (keptAt(station.url) != null) drop(station.url) else keep(&station);

}

fn muteChosen(_: *gui.Node) void {

    muted = !muted;
    level();
    show();

}

fn volumeMoved(slider: *gui.Slider, done: bool) void {

    setVolume(@intFromFloat(@round(slider.value * 100)), done);

}

fn setVolume(percent: u8, keep_it: bool) void {

    volume = @min(percent, 100);
    muted = false;
    loudness.value = @as(f32, @floatFromInt(volume)) / 100;
    level();

    if (keep_it) _ = remember();

    loudness_tool.content.label = speaker().text();
    window.invalidate(&controls);

}

/// The volume control's icon for how loud the radio is.
fn speaker() gui.Icon {

    return if (muted or volume == 0) .mute else if (volume < 50) .volume_low else .volume_high;

}

/// Sets the speakers' own volume from the radio's.
fn level() void {

    if (speakers) |*open| open.loudness(if (muted) 0 else volume);

}
