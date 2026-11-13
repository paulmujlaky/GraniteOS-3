pub const version = 1;
pub const invalid = ~@as(u64, 0);
pub const empty = invalid - 1;
pub const missing = invalid - 2;
pub const exists = invalid - 3;
pub const full = invalid - 4;
pub const busy = invalid - 5;
pub const denied = invalid - 6;
pub const timeout = invalid - 7;
pub const refused = invalid - 8;
pub const offline = invalid - 9;

pub const Operation = enum(u8) {

    hello,
    lookup,
    ping,
    crash,
    write,
    read,
    passed,
    failed,
    stall,
    restart,
    relaunch,
    info,
    flush,
    list,
    create,
    directory,
    remove,
    volume,
    change,
    login,
    logout,
    password,
    install,
    power,
    surface,
    present,
    wait,
    input,
    place,
    launch,
    end,
    mode,
    argument,
    windows,
    activate,
    reserve,
    image,
    forget,
    clipboard,
    capture,
    rename,
    reload,
    session,
    notify,
    cursor,
    snip,
    pin,
    quartz,
    connect,
    listen,
    accept,
    close,
    resolve,
    echo,
    roots,
    enable,
    locate,
    scale,
    chime,
    accent,
    _,

};

/// Where the installer could put GraniteOS on a disk.
pub const Placement = enum(u8) {

    /// Its partition table could not be read.
    unreadable,

    /// It holds no partitions, so it may be erased and given to GraniteOS.
    empty,

    /// Only GraniteOS uses it, so it may be erased and installed again.
    granite,

    /// Its EFI system partition and free space take GraniteOS beside what is there.
    beside,

    /// Another system uses it and leaves no room.
    full,

};

/// A disk as the installer's `list` reports it: its size and largest free run in sectors, and what installing there would do.
pub const Survey = extern struct {

    sectors: u64 = 0,
    free: u64 = 0,
    placement: Placement = .unreadable,

    /// Its EFI system partition holds Windows' boot manager.
    windows: bool = false,

    /// Installing takes `share` sectors from the end of a Windows volume, for want of free space.
    shrink: bool = false,

    /// What keeps GraniteOS off a `full` disk.
    obstacle: Obstacle = .none,

    /// It already holds a GraniteOS data partition, which installing again keeps.
    existing: bool = false,

};

/// The size of the data partition the installer makes: 25 GiB, in sectors.
pub const share = (25 << 30) / 512;

/// Why the installer cannot put GraniteOS beside the system on a disk.
pub const Obstacle = enum(u8) {

    none,

    /// Files occupy the volume's last 25 GB.
    used,

    /// Windows is hibernated, or shut down with Fast Startup, and would resume onto the volume as it left it.
    hibernated,

    /// Windows marked the volume for checking, or left changes unfinished in its journal.
    dirty,

    /// BitLocker encrypts the volume.
    encrypted,

    /// Its EFI system partition lacks room for the GraniteOS loader.
    boot,

};

/// How `install` treats the disk it names: the first disk that takes GraniteOS beside another system, that disk only, or
/// that disk erased.
pub const Mode = enum(u8) {

    first,
    beside,
    erase,

};

pub fn pack(kind: Operation, payload: u56) u64 {

    return @as(u64, payload) << 8 | @intFromEnum(kind);

}

pub fn operation(message: u64) Operation {

    return @enumFromInt(@as(u8, @truncate(message)));

}

pub fn value(message: u64) u56 {

    return @intCast(message >> 8);

}
