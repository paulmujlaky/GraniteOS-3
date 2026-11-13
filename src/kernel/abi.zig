pub const Request = extern struct {

    number: u64,
    first: u64 = 0,
    second: u64 = 0,
    third: u64 = 0,
    fourth: u64 = 0,
    fifth: u64 = 0,

};

pub const Call = enum(u64) {

    yield = 0,
    exit = 1,
    send = 2,
    receive = 3,
    write = 4,
    allocate = 5,
    release = 6,
    port = 7,
    map = 8,
    reboot = 9,
    ticks = 10,
    identity = 11,
    call = 12,
    reply = 13,
    spawn = 14,
    inspect = 15,
    connect = 16,
    sleep = 17,
    stop = 18,
    owner = 19,
    dma = 20,
    fetch = 21,
    store = 22,
    shutdown = 23,
    assign = 24,
    variable = 25,
    share = 26,
    lend = 27,
    attach = 28,
    detach = 29,
    alive = 30,
    physical = 31,
    clock = 32,
    stats = 33,

    /// Copies kernel log bytes, oldest kept first, from offset `second` into `first`, at most `third`; returns how many.
    history = 34,
    _,

};

pub const Status = enum(u64) {

    success = 0,
    denied = 1,
    invalid = 2,
    missing = 3,
    deadlock = 4,
    exhausted = 5,
    timeout = 6,
    busy = 7,

};

/// Every program the kernel embeds; each builds from `src/apps/NAME.zig` or `src/services/NAME.zig`.
pub const Image = enum(u64) {

    serial,
    shell,
    helper,
    client,
    storage,
    files,
    accounts,
    install,
    display,
    input,
    usb,
    login,
    explorer,
    editor,
    terminal,
    monitor,
    viewer,
    settings,
    calculator,
    clock,
    calendar,
    drawing,
    screenshots,
    net,
    metrics,
    weather,
    requests,
    audio,
    player,
    radio,

    /// Runs with application permissions rather than as a service.
    pub fn application(self: Image) bool {

        return switch (self) {

            .serial, .helper, .storage, .files, .accounts, .install, .display, .input, .usb, .net, .metrics, .audio => false,
            else => true,

        };

    }

    /// An application granted `network`: the shell's tools, the desktop, Settings, and Monitor, which show its state, and the
    /// apps that work over it.
    pub fn networked(self: Image) bool {

        return switch (self) {

            .shell, .login, .settings, .monitor, .weather, .requests, .radio => true,
            else => false,

        };

    }

    /// The permission a process needs before it may be connected to this service; where the computer is counts too, as an
    /// app on the network could learn it anyway.
    pub fn gate(self: Image) ?Permission {

        return if (self == .net or self == .metrics) .network else null;

    }

    /// A signed-in session may launch it by name.
    pub fn launchable(self: Image) bool {

        return self.application() and self != .client and self != .login;

    }

};

pub const Layer = enum(u64) {

    application,
    service,

};

pub const Permission = enum(u32) {

    ipc,
    memory,
    time,
    ports,
    mmio,
    power,
    diagnostics,
    management,
    dma,
    accounts,
    firmware,
    network,

};

/// Who a process acts for; the kernel attaches the sender's identity to every message as `fifth`.
pub const Identity = packed struct(u64) {

    user: u32,
    admin: bool = false,
    reserved: u31 = 0,

};

pub const system = Identity{

    .user = 0,

};

pub const nobody = Identity{

    .user = 0xffffffff,

};

pub const permission_count = @typeInfo(Permission).@"enum".fields.len;

/// A PCI base address range granted to a driver service.
pub const Bar = extern struct {

    base: u64 = 0,
    size: u64 = 0,
    ports: bool = false,

};

pub const Environment = extern struct {

    version: u64 = 1,
    layer: Layer,
    length: u64,
    permissions: [permission_count]Permission,

    /// The PCI function a driver service was granted, by BAR index; unused entries are empty.
    bars: [6]Bar = [_]Bar{.{}} ** 6,

    /// That function's vendor id, and its device id in the upper half; zero without one.
    device: u32 = 0,

    /// The bit its device's interrupts set in the signals `receive` reports; zero when the driver must poll.
    signal: u64 = 0,

};

/// Where a process stands with the scheduler.
pub const State = enum(u64) {

    ready,
    running,
    sending,
    receiving,
    replying,
    sleeping,
    dead,

};

/// System-wide counters from `stats`; ticks count timer interrupts at 100 Hz.
pub const Summary = extern struct {

    /// Physical pages the kernel allocates from, and how many of those are free.
    pages: u64 = 0,
    free: u64 = 0,

    processors: u64 = 0,
    uptime: u64 = 0,

    /// Ticks, summed over every processor, that found a process running or the processor idle.
    busy: u64 = 0,
    idle: u64 = 0,

    /// Live processes, and how many of them were written to the caller's records.
    processes: u64 = 0,
    records: u64 = 0,

};

/// One live process, as reported by `stats`.
pub const Usage = extern struct {

    id: u64,

    /// The process that started it; zero when the kernel did, as for the supervisor.
    owner: u64,

    /// An `Image` value, or `anonymous`.
    image: u64,

    identity: Identity,
    layer: Layer,
    state: State,

    /// RAM pages mapped into the process: its own, DMA buffers, and every shared region it holds; device memory and page tables are left out.
    pages: u64,

    /// Ticks that found the process running.
    ticks: u64,

    /// The `image` of a process started without one, such as the supervisor.
    pub const anonymous = ~@as(u64, 0);

};
