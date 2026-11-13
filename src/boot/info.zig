pub const MemoryKind = enum {

    reserved,
    available,
    loader,
    firmware,
    runtime,
    runtime_code,
    acpi,
    persistent,
    mmio,
    unusable,

};

pub const Region = struct {

    base: u64,
    size: u64,
    kind: MemoryKind,

};

pub const Framebuffer = struct {

    base: u64,
    size: u64,
    width: u32,
    height: u32,
    stride: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,

};

/// What a boot chosen from the loader's menu leaves out, to narrow down a failure on new hardware.
pub const Skip = packed struct(u8) {

    processors: bool = false,
    x2apic: bool = false,
    usb: bool = false,
    nvme: bool = false,
    audio: bool = false,
    network: bool = false,
    reserved: u2 = 0,

};

pub const Info = struct {

    version: u32 = 3,
    memory: []const Region,
    image: Region,
    stack: Region,
    framebuffer: ?Framebuffer,
    acpi_rsdp: ?u64,
    trampoline: u64 = 0,
    runtime: u64 = 0,

    /// The loader's own EFI file, kept so the installer can copy it.
    efi: ?Region = null,

    /// The firmware's local time at boot in seconds since 1970-01-01 00:00:00; zero when its clock failed.
    clock: u64 = 0,

    skip: Skip = .{},

};
