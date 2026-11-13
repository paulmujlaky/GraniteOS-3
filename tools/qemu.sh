#!/bin/sh

# Boot GraniteOS in QEMU under WSL2 with KVM, shaped like the physical desktop by default: NVMe storage, 32 CPUs, no serial
# port, USB-only input, no PIT or HPET, and only the firmware framebuffer. `show` serves the screen over VNC for
# tools/screen.py until the guest powers off; `stop` ends it.

set -eu

fail() {

    printf '%s\n' "$*" >&2
    exit 1

}

usage='Usage: sh tools/qemu.sh show|stop [--name NAME] [--media usb|disk|none] [--data blank|foreign|keep] [--cpus N]
    [--memory MB] [--disk nvme|sata] [--input usb|hub|ps2] [--timers off|on] [--serial off|file] [--apic xapic|x2apic|legacy]
    [--vnc PORT] [--accel kvm|tcg] [--screen WIDTHxHEIGHT]'
[ "$#" -ge 1 ] || fail "$usage"

action=$1
shift

name=target
media=usb
data=keep
cpus=32
memory=8192
disk=nvme
input=usb
timers=off
serial=off
apic=xapic
vnc=5903
accel=kvm
screen=1920x1080

while [ "$#" -gt 0 ]; do

    [ "$#" -ge 2 ] || fail "$usage"

    case $1 in
        --name) name=$2 ;;
        --media) media=$2 ;;
        --data) data=$2 ;;
        --cpus) cpus=$2 ;;
        --memory) memory=$2 ;;
        --disk) disk=$2 ;;
        --input) input=$2 ;;
        --timers) timers=$2 ;;
        --serial) serial=$2 ;;
        --apic) apic=$2 ;;
        --vnc) vnc=$2 ;;
        --accel) accel=$2 ;;
        --screen) screen=$2 ;;
        *) fail "$usage" ;;
    esac

    shift 2

done

case $action-$media-$data-$disk-$input-$timers-$serial-$apic-$accel in
    show-*|stop-*) ;;
    *) fail "$usage" ;;
esac

case $media-$data-$disk-$input-$timers-$serial-$apic-$accel in
    usb-*|disk-*|none-*) ;;
    *) fail "$usage" ;;
esac

case $name-$cpus-$memory-$vnc-$screen in
    *[!a-z0-9x-]*) fail "$usage" ;;
esac

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
cd "$project"

# Runs a command inside WSL, where QEMU has KVM.
inside() {

    MSYS_NO_PATHCONV=1 wsl -e "$@"

}

pidfile=/tmp/granite-qemu-$name.pid

if [ "$action" = stop ]; then

    inside sh -c "[ -f $pidfile ] && kill \$(cat $pidfile) 2>/dev/null; rm -f $pidfile" || true
    exit

fi

inside sh -c 'command -v qemu-system-x86_64 >/dev/null && [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]' ||
    fail 'Install QEMU and OVMF in WSL: sudo apt install qemu-system-x86 ovmf'

directory=zig-out/qemu/$name
mkdir -p "$directory"
linux=$(inside wslpath -a "$(cygpath -m "$project")")
guest=$linux/$directory

[ -f zig-out/granite.img ] || fail 'Build first: zig build -Doptimize=ReleaseSafe -Dself-test=false && py tools/media.py'

case $data in
    blank) cp zig-out/data.img "$directory/data.img" ;;
    foreign) cp zig-out/foreign.img "$directory/data.img" ;;
    keep) [ -f "$directory/data.img" ] || cp zig-out/data.img "$directory/data.img" ;;
    *) fail "$usage" ;;
esac

[ "$data" = keep ] && [ -f "$directory/vars.fd" ] || inside cp /usr/share/OVMF/OVMF_VARS_4M.fd "$guest/vars.fd"

# Live media is a copy, so a run never changes the build output.
[ "$media" = none ] || cp zig-out/granite.img "$directory/boot.img"

set -- -name "GraniteOS ($name)" -no-user-config -nodefaults -pidfile "$pidfile" \
    -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd" \
    -drive "if=pflash,format=raw,file=$guest/vars.fd" \
    -m "$memory" -vnc "127.0.0.1:$(( vnc - 5900 ))" \
    -device "bochs-display,xres=${screen%x*},yres=${screen#*x}" \
    -device e1000e,netdev=net -netdev user,id=net \
    -audiodev none,id=sound -device intel-hda -device hda-duplex,audiodev=sound \
    -device qemu-xhci,id=xhci

# `legacy` hides x2APIC from the processor, leaving only the memory-mapped xAPIC.
model=$([ "$apic" = legacy ] && echo ,-x2apic || true)

case $accel in
    kvm) set -- "$@" -accel kvm -cpu "host$model" ;;
    tcg) set -- "$@" -accel tcg -cpu "max$model" ;;
    *) fail "$usage" ;;
esac

machine=q35,smbus=off

case $timers in
    off) machine=$machine,pit=off,hpet=off ;;
    on) ;;
    *) fail "$usage" ;;
esac

case $input in
    usb) machine=$machine,i8042=off; set -- "$@" -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 ;;
    # The keyboard behind a hub and the tablet behind a second hub on the first, as board and monitor hubs place them.
    hub) machine=$machine,i8042=off; set -- "$@" -device usb-hub,bus=xhci.0,port=1 -device usb-kbd,bus=xhci.0,port=1.2,id=hubkbd \
        -device usb-hub,bus=xhci.0,port=1.3 -device usb-tablet,bus=xhci.0,port=1.3.1 ;;
    ps2) ;;
    *) fail "$usage" ;;
esac

case $disk in
    nvme) machine=$machine,sata=off ;;
    sata) set -- "$@" -device ahci,id=ahci ;;
    *) fail "$usage" ;;
esac

set -- "$@" -machine "$machine"

# Firmware hands over in x2APIC mode once a processor's APIC ID passes 254, so a sparse socket layout forces it.
case $apic in
    xapic|legacy) set -- "$@" -smp "$cpus,sockets=1,cores=$cpus,threads=1" ;;
    x2apic) set -- "$@" -smp "$cpus,sockets=3,cores=128,threads=1,maxcpus=384" -device "host-x86_64-cpu,socket-id=2,core-id=0,thread-id=0" ;;
    *) fail "$usage" ;;
esac

case $serial in
    off) set -- "$@" -serial none ;;
    # COM1 takes the kernel log; COM2 carries the serial shell, which the self-test build needs, and records what it writes.
    file) : > "$directory/serial.log"; set -- "$@" -serial "file:$guest/serial.log" -serial "file:$guest/terminal.log" ;;
    *) fail "$usage" ;;
esac

# Attaches raw image `$1` as storage device number `$2`; NVMe disks get a controller each, as two SSDs would.
attach() {

    set -- "$@" "drive$2"

    if [ "$disk" = nvme ]; then

        printf '%s\n' -drive "if=none,format=raw,id=$3,file=$guest/$1" -device "nvme,drive=$3,serial=granite$2"

    else

        printf '%s\n' -drive "if=none,format=raw,id=$3,file=$guest/$1" -device "ide-hd,drive=$3,bus=ahci.$2"

    fi

}

case $media in
    usb) set -- "$@" -drive "if=none,format=raw,id=stick,file=$guest/boot.img" -device usb-storage,bus=xhci.0,drive=stick,removable=on
         storage=$(attach data.img 0) ;;
    disk) storage=$(attach boot.img 0; attach data.img 1) ;;
    none) storage=$(attach data.img 0) ;;
esac

# Each argument is one line, and none holds a space.
# shellcheck disable=SC2086
set -- "$@" $storage

printf 'GraniteOS (%s) on VNC port %s: %s CPUs, %s MB, %s, %s input, timers %s, serial %s, %s\n' \
    "$name" "$vnc" "$cpus" "$memory" "$disk" "$input" "$timers" "$serial" "$apic"
# QEMU_EXTRA adds raw options, such as tracing.
# shellcheck disable=SC2086
inside qemu-system-x86_64 "$@" ${QEMU_EXTRA:-}
