const std = @import("std");

const Process = @import("process.zig").Process;
const Lock = @import("lock.zig").Lock;

const List = std.DoublyLinkedList;

/// The longest a call or sleep may wait, in ticks.
pub const longest = 6000;

/// Alarm slots on each processor; more than the longest wait, so a slot only ever holds alarms due on one tick.
pub const slots = 8192;

/// Processor ids are below this.
pub const capacity = 256;

/// What becomes of a processor's process after a kernel entry: it runs on, goes to the back of the queue, waits (queued at once if already woken), or ends.
pub const Outcome = enum {

    keep,
    yield,
    block,
    exit,

};

/// One processor's processes ready to run, and the alarms of those waiting on it with a deadline.
pub const Processor = struct {

    // A cache line each, so no processor contends over its neighbour's.
    lock: Lock align(64) = .{},

    ready: List = .{},
    queued: usize = 0,

    /// A process woke into the queue since this processor last chose one, so the process it runs should give way.
    woken: bool = false,

    /// Live processes homed here.
    homed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    alarms: []List = &.{},

    /// Every slot up to this tick has been emptied; only this processor advances it.
    reached: u64 = 0,

    fn push(self: *Processor, task: *Process) void {

        self.ready.append(&task.link);
        self.queued += 1;

    }

    /// Queues a process that waited ahead of those that used up their time, so input and replies are answered promptly.
    fn hurry(self: *Processor, task: *Process) void {

        self.ready.prepend(&task.link);
        self.queued += 1;
        @atomicStore(bool, &self.woken, true, .release);

    }

    fn take(self: *Processor, id: u32) ?*Process {

        self.lock.acquire();
        defer self.lock.release();

        @atomicStore(bool, &self.woken, false, .release);

        const node = self.ready.popFirst() orelse return null;
        const task = Process.from("link", node);

        self.queued -= 1;
        task.held = true;
        task.state = .running;

        if (task.home != id) {

            _ = self.homed.fetchSub(1, .monotonic);
            _ = processors[id].homed.fetchAdd(1, .monotonic);
            @atomicStore(u32, &task.home, id, .release);

        }

        return task;

    }

    fn disarm(self: *Processor, task: *Process) void {

        if (!task.armed) return;

        self.alarms[task.deadline % slots].remove(&task.alarm);
        task.armed = false;

    }

};

pub const Alarm = struct {

    task: *Process,
    deadline: u64,

};

pub var processors = [_]Processor{.{}} ** capacity;

// Processors in use, in the order they were prepared.
var ids: [capacity]u32 = undefined;
var count: usize = 0;

/// Readies processor `id` to schedule, with `alarms` of empty slots.
pub fn prepare(id: u32, alarms: []List) void {

    processors[id] = .{

        .alarms = alarms,

    };

    if (std.mem.indexOfScalar(u32, ids[0..count], id) == null) {

        ids[count] = id;
        count += 1;

    }

}

/// Queues a new process, which its creator held until now.
pub fn start(task: *Process) void {

    const self = lockHome(task);
    defer self.lock.release();

    task.held = false;
    self.push(task);

}

/// Readies `task` after a wait; the caller holds the lock guarding its state and has written its result.
pub fn wake(task: *Process) void {

    const self = lockHome(task);
    defer self.lock.release();

    self.disarm(task);
    task.deadline = 0;
    task.state = .ready;

    // A process that blocked on a processor still in the kernel is queued by that processor on letting go.
    if (!task.held) self.hurry(task);

}

/// Sets `task`'s alarm for its deadline; the caller holds the lock guarding its state.
pub fn arm(task: *Process) void {

    const self = lockHome(task);
    defer self.lock.release();

    self.alarms[task.deadline % slots].append(&task.alarm);
    task.armed = true;

}

/// Takes the next alarm on processor `id` due by tick `now`; null once every slot up to `now` is empty.
pub fn due(id: u32, now: u64) ?Alarm {

    const self = &processors[id];

    if (self.reached >= now) return null;

    self.lock.acquire();
    defer self.lock.release();

    while (self.reached < now) {

        if (self.alarms[(self.reached + 1) % slots].popFirst()) |node| {

            const task = Process.from("alarm", node);

            task.armed = false;

            return .{

                .task = task,
                .deadline = task.deadline,

            };

        }

        self.reached += 1;

    }

    return null;

}

/// Hands back processor `id`'s process as `outcome` says, returning `exit` when it must end instead.
pub fn release(id: u32, task: *Process, outcome: Outcome) Outcome {

    const self = &processors[id];

    self.lock.acquire();
    defer self.lock.release();

    if (task.doomed or outcome == .exit) return .exit;
    if (outcome == .keep) return .keep;
    if (outcome == .yield) task.state = .ready;

    task.held = false;

    // One woken while still blocking never waited its turn out, unlike one that yields or ran out its time.
    if (task.state == .ready) {

        if (outcome == .block) self.hurry(task) else self.push(task);

    }

    return outcome;

}

/// The process processor `id` runs next: its own oldest ready one, or else one waiting on another processor.
pub fn pick(id: u32) ?*Process {

    if (processors[id].take(id)) |task| return task;

    for (ids[0..count]) |other| {

        if (other == id or @atomicLoad(usize, &processors[other].queued, .monotonic) == 0) continue;
        if (processors[other].take(id)) |task| return task;

    }

    return null;

}

/// Takes `task` off its processor so it can end; false when another processor holds it, which then ends it on letting go.
pub fn claim(task: *Process, holder: bool) bool {

    const self = lockHome(task);
    defer self.lock.release();

    if (task.held and !holder) {

        task.doomed = true;
        return false;

    }

    if (task.state == .ready and !task.held) {

        self.ready.remove(&task.link);
        self.queued -= 1;

    }

    self.disarm(task);
    task.held = false;
    _ = self.homed.fetchSub(1, .monotonic);

    return true;

}

/// Whether a process woke into processor `id`'s queue since it last chose one.
pub fn urgent(id: u32) bool {

    return @atomicLoad(bool, &processors[id].woken, .acquire);

}

/// How many processes are ready but not running.
pub fn waiting() usize {

    var total: usize = 0;

    for (ids[0..count]) |id| total += @atomicLoad(usize, &processors[id].queued, .monotonic);

    return total;

}

/// The processor with the fewest live processes homed on it, so new ones spread across them.
pub fn quietest() u32 {

    var best = ids[0];
    var least: usize = std.math.maxInt(usize);

    for (ids[0..count]) |id| {

        const homed = processors[id].homed.load(.monotonic);

        if (homed < least) {

            least = homed;
            best = id;

        }

    }

    return best;

}

/// Locks the processor `task` is homed on, which only changes while it waits in a ready queue.
fn lockHome(task: *Process) *Processor {

    while (true) {

        const self = &processors[@atomicLoad(u32, &task.home, .acquire)];

        self.lock.acquire();
        if (&processors[task.home] == self) return self;
        self.lock.release();

    }

}
