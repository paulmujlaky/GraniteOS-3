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

pub fn pack(kind: Operation, payload: u56) u64 {

    return @as(u64, payload) << 8 | @intFromEnum(kind);

}

pub fn operation(message: u64) Operation {

    return @enumFromInt(@as(u8, @truncate(message)));

}

pub fn value(message: u64) u56 {

    return @intCast(message >> 8);

}
