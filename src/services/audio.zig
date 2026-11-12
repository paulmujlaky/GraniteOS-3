//! The audio service: drives the HD Audio controller and its codec, mixes every app's stream and the system's short sounds
//! at the volume chosen, and keeps that choice in `/cfgs/system/audio.config`.

const std = @import("std");

const chime = @import("chime.zig");
const codec = @import("codec.zig");
const hda = @import("hda.zig");
const mixer = @import("mixer.zig");

const api = @import("api");

const protocol = api.protocol;
const audio = api.audio;
pub const panic = api.panic;

comptime {

    std.debug.assert(chime.tunes.len == @typeInfo(audio.Sound).@"enum".fields.len);

}

/// Streams at once, requests waiting on them, and short sounds playing together.
const most = 16;
const waiting = 32;
const voices_most = 4;

/// The device frames the mix keeps ahead of the speakers, in buffers: at first, and at most after the device ran dry.
const lead_first = 3;
const lead_most = hda.periods - 4;

const ring_frames = hda.periods * hda.period;

/// Ticks of silence before the device stops, so an idle system takes no interrupts.
const rest = 300;

/// Ticks a waiting request is held before it is answered empty and asks again.
const patience = 50;

/// Ticks after a change before the settings are written, so a run of volume keys writes once.
const settle = 100;

/// Stream 1 of the controller, played as 48 kHz 16-bit stereo.
const tag = 1;
const format = 0x0011;

const volume_first = 70;

const Stream = struct {

    owner: u64 = 0,
    memory: api.Shared = undefined,
    header: *audio.Header = undefined,

    /// The format it was opened with, kept here as the client may scribble over its header.
    rate: u32 = 0,
    capacity: u32 = 0,
    channels: u8 = 0,
    encoding: audio.Encoding = .s16,

    resampler: mixer.Resampler = undefined,

    /// The device frame just past the last one mixed from it, for working out what has played.
    mark: u64 = 0,

    /// Whether it has played anything yet, and whether it ran dry since; running dry only counts against it if it then
    /// plays on, as running dry at the end is just finishing.
    begun: bool = false,
    starved: bool = false,

};

const Wait = struct {

    request: api.Request = undefined,
    stream: usize = 0,
    drain: bool = false,
    until: u64 = 0,
    active: bool = false,

};

var controller: hda.Controller = undefined;
var chip = codec.Codec{};
var address: u4 = 0;
var device: u32 = 0;
var signal: u64 = 0;

var streams = [_]Stream{.{}} ** most;
var waits = [_]Wait{.{}} ** waiting;
var voices = [_]?chime.Voice{null} ** voices_most;

/// The device's place in its ring, the device frame just past the last mixed, and past the last cleared ahead of that.
var cursor = mixer.Cursor{

    .size = hda.ring_bytes,

};

var filled: u64 = 0;
var cleared: u64 = 0;
var lead: u64 = lead_first;
var underruns: u32 = 0;

var running = false;

/// When something last played, in ticks.
var heard: u64 = 0;

var volume: u8 = volume_first;
var muted = false;
var sounds = true;

var configuration = api.Config{};
var save_due: ?u64 = null;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.dma) or api.permits(.ports) or api.permits(.management)) api.exit(2);

    const registers = environment.bars[0];

    device = environment.device;
    signal = environment.signal;

    controller.init(registers.base, registers.size) catch {

        api.log("audio: the HD Audio controller did not start\n");
        api.exit(3);

    };

    choose();

    controller.open(tag, format) catch {

        api.log("audio: the output stream did not start\n");
        api.exit(3);

    };

    chip.start(controller.link(address), tag, format);
    report();

    // The stream has not started, so no interrupt arriving meanwhile needs an answer.
    _ = api.greet(handle);
    load();

    while (true) {

        const now = api.ticks();

        // Without interrupts, the device is polled every tick while it plays; stopped, a stream that may write again is
        // watched closely, since writing and resuming ask nothing of the service.
        const limit = if (running and signal == 0) 1 else if (!running and listening()) 2 else @max(soonest(now) -| now, 1);

        const request = api.within(@min(limit, 100)) catch {

            pump();
            maintain();
            continue;

        };

        if (request.first == 0) {

            if (request.second & signal != 0) controller.acknowledge();
            pump();

        } else if (handle(request)) |result| {

            api.answer(request, result);

        }

        maintain();

    }

}

/// Uses the first codec with an output it can drive, or else the first that answered, so its name still shows.
fn choose() void {

    var first: ?u4 = null;

    for (0..15) |slot| {

        const candidate: u4 = @intCast(slot);
        if (controller.codecs & @as(u15, 1) << candidate == 0) continue;

        var found = codec.Codec{};
        if (!found.probe(controller.link(candidate))) continue;

        found.route(controller.link(candidate));
        if (first == null) first = candidate;

        if (found.outputs != 0) {

            chip = found;
            address = candidate;
            return;

        }

    }

    if (first) |candidate| {

        address = candidate;
        _ = chip.probe(controller.link(candidate));

    }

}

fn report() void {

    var line: [128]u8 = undefined;
    var name: [32]u8 = undefined;
    const state = describe();

    api.log(std.fmt.bufPrint(&line, "audio: {s} ready, {s}, {d} output{s}{s}\n", .{

        state.adapter(),
        state.chip(&name),
        state.outputs,
        if (state.outputs == 1) "" else "s",
        if (signal == 0) ", polled" else "",

    }) catch "audio: ready\n");

}

/// Mixes ahead of the device, noticing when it ran dry, and clears a buffer beyond so a late mix replays silence.
fn pump() void {

    if (!running) return;

    const played = cursor.advance(controller.position());

    if (played > filled) {

        underruns +|= 1;
        lead = @min(lead + 1, lead_most);
        filled = played;

    }

    const target = played + lead * hda.period;
    var sounded = false;

    while (filled < target) {

        const at: usize = @intCast(filled % ring_frames);
        const count = @min(target - filled, hda.period - at % hda.period);
        const buffer = controller.buffer(at / hda.period);

        sounded = render(buffer[at % hda.period * 2 ..][0 .. count * 2], filled) or sounded;
        filled += count;

    }

    if (sounded) heard = api.ticks();

    cleared = @max(cleared, filled);

    while (cleared < filled + hda.period) {

        const at: usize = @intCast(cleared % ring_frames);
        const count = hda.period - at % hda.period;

        @memset(controller.buffer(at / hda.period)[at % hda.period * 2 ..][0 .. count * 2], 0);
        cleared += count;

    }

    for (&streams) |*stream| {

        if (stream.owner != 0) track(stream, played);

    }

}

/// Mixes `out.len / 2` frames for the device, the first of which it plays as frame `start`; true when anything sounded.
fn render(out: []i16, start: u64) bool {

    var frames: [hda.period]mixer.Frame = undefined;
    const mix = frames[0 .. out.len / 2];
    const gain = if (muted) 0 else mixer.loudness(volume);
    var sounded = false;

    @memset(mix, mixer.silence);

    for (&streams) |*stream| {

        if (stream.owner != 0) sounded = blend(stream, mix, gain, start) or sounded;

    }

    for (&voices) |*slot| {

        if (slot.*) |*voice| {

            voice.mix(mix, gain);
            sounded = true;
            if (voice.done()) slot.* = null;

        }

    }

    mixer.quantize(mix, out);

    return sounded;

}

/// Adds what `stream` has ready to `mix` at its volume under `gain`; true when it added anything.
fn blend(stream: *Stream, mix: []mixer.Frame, gain: f32, start: u64) bool {

    const header = stream.header;

    if (@atomicLoad(bool, &header.paused, .acquire)) {

        stream.resampler.gain = 0;
        return false;

    }

    const written = @atomicLoad(u64, &header.written, .acquire);
    const discard = @atomicLoad(u64, &header.discard, .acquire);
    var taken = header.taken;

    // A client that claims more than its ring holds, or less than was taken, is read no further.
    if (written < taken or written - taken > stream.capacity) return false;

    if (discard > taken and discard <= written) {

        taken = discard;
        stream.resampler.reset();
        stream.starved = false;

    }

    const target = gain * mixer.loudness(@atomicLoad(u8, &header.volume, .acquire));

    const produced = switch (stream.encoding) {

        inline .s16, .f32 => |encoding| take(encoding, stream, &taken, written, mix, target),
        _ => 0,

    };

    @atomicStore(u64, &header.taken, taken, .release);

    if (produced == 0) {

        stream.starved = stream.begun;
        return false;

    }

    if (stream.starved) header.underruns +|= 1;

    stream.mark = start + produced;
    stream.begun = true;
    stream.starved = produced < mix.len;

    return true;

}

fn take(comptime encoding: audio.Encoding, stream: *Stream, taken: *u64, written: u64, mix: []mixer.Frame, target: f32) usize {

    const Sample = encoding.Sample();
    const bytes = stream.memory.bytes[audio.Header.data..][0 .. @as(usize, stream.capacity) * stream.channels * @sizeOf(Sample)];

    var source = mixer.Ring(Sample){

        .samples = @alignCast(std.mem.bytesAsSlice(Sample, bytes)),
        .channels = stream.channels,
        .capacity = stream.capacity,
        .taken = taken.*,
        .written = written,

    };

    const produced = stream.resampler.mix(Sample, &source, mix, target);

    taken.* = source.taken;

    return produced;

}

/// Works out the frame of `stream` the speakers are playing, now the device has played `played` frames.
fn track(stream: *Stream, played: u64) void {

    const header = stream.header;
    const taken = header.taken;
    const queued = stream.resampler.span(stream.mark -| played);
    const playing = @max(@atomicLoad(u64, &header.played, .acquire), taken -| queued);

    @atomicStore(u64, &header.played, @min(playing, taken), .release);

}

/// Answers waits that are met or have waited long enough, lets go of streams whose process ended, writes changed settings,
/// and stops the device once it has been quiet a while.
fn maintain() void {

    const now = api.ticks();

    for (&waits) |*wait| {

        if (!wait.active) continue;

        if (met(wait.*)) {

            finish(wait, 0);

        } else if (now >= wait.until) {

            finish(wait, protocol.empty);

        }

    }

    for (&streams) |*stream| {

        if (stream.owner != 0 and !api.alive(stream.owner)) release(stream);

    }

    if (save_due) |due| if (now >= due) save();

    if (running and now >= heard + rest and quiet()) {

        controller.run(false);
        running = false;

    }

    if (!running and !quiet()) wake();

}

/// The tick by which `maintain` next has work.
fn soonest(now: u64) u64 {

    var result = now + 100;

    for (waits) |wait| {

        if (wait.active) result = @min(result, wait.until);

    }

    if (save_due) |due| result = @min(result, due);
    if (running) result = @min(result, heard + rest);

    return result;

}

/// Nothing is left to play: no stream has frames waiting and no short sound rings.
fn quiet() bool {

    for (voices) |voice| {

        if (voice != null) return false;

    }

    for (streams) |stream| {

        if (stream.owner == 0 or stream.header.paused) continue;
        if (@atomicLoad(u64, &stream.header.written, .acquire) != stream.header.taken) return false;

    }

    return true;

}

/// A stream is open and not paused, so it may write frames at any moment.
fn listening() bool {

    for (streams) |stream| {

        if (stream.owner != 0 and !stream.header.paused) return true;

    }

    return false;

}

/// Starts the device if it stopped, mixing first from just ahead of it, as everything it holds is silence.
fn wake() void {

    heard = api.ticks();
    if (running) return;

    const played = cursor.advance(controller.position());

    filled = @min(filled, played + hda.period);
    running = true;
    pump();
    controller.run(true);

}

fn handle(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .crash => api.crash(request),
        .info => inform(request),
        .connect => connect(request, value),
        .wait => hold(request, value),
        .close => close(request, value),
        .change => change(request, value),
        .enable => enable(request, value != 0),
        .chime => ring(value),
        else => protocol.invalid,

    };

}

fn describe() audio.Status {

    var result = audio.Status{

        .device = device,
        .codec = chip.vendor,
        .outputs = chip.outputs,
        .volume = volume,
        .muted = muted,
        .sounds = sounds,
        .rate = mixer.rate,
        .latency = @intCast(lead * hda.period),
        .underruns = underruns,

    };

    for (streams) |stream| {

        if (stream.owner != 0) result.streams += 1;

    }

    return result;

}

fn inform(request: api.Request) u64 {

    const state = describe();

    if (request.fourth < @sizeOf(audio.Status)) return protocol.invalid;
    api.store(request, 0, std.mem.asBytes(&state)) catch return protocol.invalid;

    return 0;

}

/// Attaches the ring a client lent as shared `region` and starts playing it; returns the stream's number.
fn connect(request: api.Request, region: u64) u64 {

    const index = for (streams, 0..) |stream, slot| {

        if (stream.owner == 0) break slot;

    } else return protocol.full;

    const memory = api.attach(region) catch return protocol.denied;
    const header: *audio.Header = @ptrCast(memory.bytes.ptr);

    const shape = audio.Format{

        .rate = header.rate,
        .channels = header.channels,
        .encoding = header.encoding,

    };

    const capacity = header.capacity;

    if (!shape.valid() or capacity < 64 or audio.Header.data + @as(u64, capacity) * shape.frame() > memory.bytes.len) {

        api.detach(memory.handle);
        return protocol.invalid;

    }

    streams[index] = .{

        .owner = request.first,
        .memory = memory,
        .header = header,

        .rate = shape.rate,
        .capacity = capacity,
        .channels = shape.channels,
        .encoding = shape.encoding,

        .resampler = mixer.Resampler.init(shape.rate),
        .mark = filled,

    };

    wake();

    return index;

}

/// The stream numbered `value` if the caller owns it.
fn owned(request: api.Request, value: u64) ?*Stream {

    if (value >= most or streams[value].owner != request.first) return null;

    return &streams[value];

}

/// Holds the request until half the stream's ring is free, or with the drain bit until all it was given has played.
fn hold(request: api.Request, value: u56) ?u64 {

    const index: usize = @intCast(value & 0xffffffff);
    _ = owned(request, index) orelse return protocol.invalid;

    const wait = Wait{

        .request = request,
        .stream = index,
        .drain = value >> 32 & 1 != 0,
        .until = api.ticks() + patience,
        .active = true,

    };

    if (met(wait)) return 0;

    for (&waits) |*slot| {

        if (slot.active) continue;

        slot.* = wait;
        return null;

    }

    return protocol.busy;

}

fn met(wait: Wait) bool {

    const stream = &streams[wait.stream];
    const header = stream.header;
    const written = @atomicLoad(u64, &header.written, .acquire);

    if (stream.owner != wait.request.first) return true;
    if (wait.drain) return @atomicLoad(u64, &header.played, .acquire) >= written or header.paused;

    return written -| header.taken <= stream.capacity / 2;

}

fn finish(wait: *Wait, result: u64) void {

    api.answer(wait.request, result);
    wait.active = false;

}

fn close(request: api.Request, value: u64) u64 {

    release(owned(request, value) orelse return protocol.invalid);

    return 0;

}

fn release(stream: *Stream) void {

    const owner = stream.owner;

    api.detach(stream.memory.handle);
    stream.* = .{};

    for (&waits) |*wait| {

        if (wait.active and wait.request.first == owner and streams[wait.stream].owner == 0) finish(wait, protocol.invalid);

    }

}

/// Sets the volume, or mutes with bit 8 set; any signed-in user may, and the choice is kept.
fn change(request: api.Request, value: u56) u64 {

    if (api.sender(request).user == api.abi.nobody.user) return protocol.denied;

    if (value >> 8 & 1 != 0) {

        muted = value & 1 != 0;

    } else {

        volume = @intCast(@min(value & 0xff, 100));
        muted = false;

    }

    save_due = api.ticks() + settle;

    return 0;

}

fn enable(request: api.Request, on: bool) u64 {

    if (api.sender(request).user == api.abi.nobody.user) return protocol.denied;

    sounds = on;
    save_due = api.ticks() + settle;

    return 0;

}

/// Starts short sound `value`, unless the system's sounds are off; the oldest playing makes way when all are busy.
fn ring(value: u56) u64 {

    if (value >= chime.tunes.len) return protocol.invalid;
    if (!sounds or muted or volume == 0) return 0;

    var slot = &voices[0];

    for (&voices) |*candidate| {

        if (candidate.* == null) {

            slot = candidate;
            break;

        }

        if (candidate.*.?.frame > slot.*.?.frame) slot = candidate;

    }

    slot.* = .{

        .tune = chime.tunes[@intCast(value)],

    };

    wake();

    return 0;

}

fn load() void {

    configuration.open(api.config.system, "audio");
    volume = @min(configuration.number(u8, "volume") orelse volume_first, 100);
    muted = std.mem.eql(u8, configuration.get("muted") orelse "", "on");
    sounds = !std.mem.eql(u8, configuration.get("sounds") orelse "", "off");

}

fn save() void {

    save_due = null;
    configuration.open(api.config.system, "audio");

    _ = configuration.set("volume", volume);
    _ = configuration.set("muted", if (muted) "on" else "off");
    _ = configuration.set("sounds", if (sounds) "on" else "off");

    configuration.save() catch api.log("audio: could not save the settings\n");

}
