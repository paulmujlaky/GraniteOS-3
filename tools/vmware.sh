#!/bin/sh

# Build GraniteOS and boot it in VMware: `run` attaches the COM2 terminal, `show` boots the desktop headless for
# tools/screen.py (VNC port 5901) until interrupted, and `test` runs every acceptance check.

set -eu

fail() {

    printf '%s\n' "$*" >&2
    exit 1

}

usage='Usage: sh tools/vmware.sh run|show|test [--profile target] [--media iso|disk] [--cpus N] [--memory MB] [--usb on|off]
    [--disk sata|nvme] [--serial on|off]'
[ "$#" -ge 1 ] || fail "$usage"

action=$1
media=iso
vnc=$([ "$action" = test ] && echo 5902 || echo 5901)
cpus=2
memory=256
usb=off
disk=sata
com=on
shift

# `--profile target` comes first and shapes the VM like the physical desktop; later options still override it.
if [ "${1:-}" = --profile ]; then

    [ "${2:-}" = target ] || fail "$usage"
    cpus=32
    memory=8192
    usb=on
    disk=nvme
    [ "$action" != show ] || com=off
    shift 2

fi

while [ "$#" -gt 0 ]; do

    [ "$#" -ge 2 ] || fail "$usage"

    case $1 in
        --media) media=$2 ;;
        --cpus) cpus=$2 ;;
        --memory) memory=$2 ;;
        --usb) usb=$2 ;;
        --disk) disk=$2 ;;
        --serial) com=$2 ;;
        *) fail "$usage" ;;
    esac

    shift 2

done

case $action-$media in
    run-iso|run-disk|show-iso|show-disk|test-iso|test-disk) ;;
    *) fail "$usage" ;;
esac

# `--usb on` moves the keyboard and mouse onto an xHCI controller's virtual USB devices, as on the physical desktop.
case $usb in
    on) controllers='pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
usb.present = "TRUE"
usb_xhci.present = "TRUE"
keyboard.vusb.enable = "TRUE"
mouse.vusb.enable = "TRUE"' ;;
    off) controllers='usb.present = "FALSE"' ;;
    *) fail "$usage" ;;
esac

case $cpus-$memory in
    *[!0-9-]*|-*|*-) fail "$usage" ;;
esac

[ "$cpus" -ge 1 ] && [ "$cpus" -le 64 ] && [ "$memory" -ge 128 ] && [ "$memory" -le 32768 ] || fail 'Require 1–64 CPUs and 128–32768 MB'

case $disk-$com in
    sata-on|nvme-on) ;;
    sata-off|nvme-off) [ "$action" = show ] || fail 'Only `show` runs without serial ports, which `run` and `test` talk through' ;;
    *) fail "$usage" ;;
esac

# NVMe disks share one controller; a live CD stays on SATA, as a USB stick would be its own controller.
if [ "$disk" = nvme ]; then

    bus=nvme0
    controllers="$controllers
nvme0.present = \"TRUE\""

else

    bus=sata0

fi

case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) fail 'The VMware terminal pipe requires Windows' ;;
esac

project=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
cd "$project"

python=${PYTHON:-}
for candidate in py python3 python; do

    [ -z "$python" ] || break
    ! "$candidate" --version >/dev/null 2>&1 || python=$candidate

done

[ -n "$python" ] || fail 'Python 3 is required; set PYTHON to its executable path'

vmrun=${VMRUN:-$(command -v vmrun || true)}
for candidate in "/c/Program Files/VMware/VMware Workstation/vmrun.exe" "/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"; do

    [ -n "$vmrun" ] || [ ! -x "$candidate" ] || vmrun=$candidate

done

[ -n "$vmrun" ] || fail 'VMware vmrun is missing; set VMRUN to its path'

command -v zig >/dev/null || fail 'Zig is missing from PATH'
version=$(tr -d '\r\n' < .zigversion)
[ "$(zig version)" = "$version" ] || fail "This project requires Zig $version"

if [ "$action" = test ]; then

    zig build test -Doptimize=ReleaseSafe

fi

zig build -Doptimize=ReleaseSafe "-Dself-test=$([ "$action" = test ] && echo true || echo false)"
"$python" tools/media.py


# Points every per-machine path at zig-out/vm/NAME.
prepare() {

    directory=zig-out/vm/$1
    serial=$directory/serial.log
    vmx=$(cygpath -m "$project/$directory/granite.vmx")
    # MSYS rewrites a leading `\\` in native arguments, so only the short pipe name crosses into Python.
    pipe=GraniteOS-$1
    mkdir -p "$directory"

}

descriptor() {

    sectors=$(( $(wc -c < "$directory/$1.img") / 512 ))
    cat > "$directory/$1.vmdk" <<EOF
# Disk DescriptorFile
version=1
encoding="UTF-8"
CID=fffffffe
parentCID=ffffffff
createType="monolithicFlat"
RW $sectors FLAT "$1.img" 0
ddb.adapterType = "ide"
ddb.geometry.cylinders = "$(( sectors / 1008 ))"
ddb.geometry.heads = "16"
ddb.geometry.sectors = "63"
EOF

}

# Attaches the GraniteOS boot media as the first disk, or as a SATA CD.
live() {

    if [ "$media" = disk ]; then

        cp zig-out/granite.img "$directory/disk.img"
        descriptor disk
        device="$bus:0.present = \"TRUE\"
$bus:0.fileName = \"disk.vmdk\""

    else

        device="sata0:0.present = \"TRUE\"
sata0:0.deviceType = \"cdrom-image\"
sata0:0.fileName = \"$(cygpath -m "$project/zig-out/granite.iso")\"
sata0:0.startConnected = \"TRUE\""

    fi

}

# COM1 carries the kernel log and COM2 the terminal, unless the machine has no serial ports.
ports() {

    if [ "$com" = off ]; then

        printf '%s\n' 'serial0.present = "FALSE"' 'serial1.present = "FALSE"'
        return

    fi

    cat <<PORTS
serial0.present = "TRUE"
serial0.fileType = "file"
serial0.fileName = "$(cygpath -m "$project/$serial")"
serial0.yieldOnMsrRead = "TRUE"
serial0.startConnected = "TRUE"
serial1.present = "TRUE"
serial1.fileType = "pipe"
serial1.fileName = "\\\\.\\pipe\\$pipe"
serial1.pipe.endPoint = "server"
serial1.tryNoRxLoss = "TRUE"
serial1.yieldOnMsrRead = "TRUE"
serial1.startConnected = "TRUE"
PORTS

}

start() {

    : > "$serial"
    cat > "$directory/granite.vmx" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "GraniteOS 3"
guestOS = "other-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memsize = "$memory"
numvcpus = "$cpus"
cpuid.coresPerSocket = "$cpus"
mks.enable3d = "TRUE"
svga.autodetect = "FALSE"
svga.vramSize = "134217728"
svga.maxWidth = "3840"
svga.maxHeight = "2160"
powerType.powerOff = "hard"
powerType.reset = "hard"
sata0.present = "TRUE"
$device
$bus:1.present = "TRUE"
$bus:1.fileName = "data.vmdk"
$(ports)
RemoteDisplay.vnc.enabled = "TRUE"
RemoteDisplay.vnc.port = "$vnc"
floppy0.present = "FALSE"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
ethernet0.present = "TRUE"
ethernet0.virtualDev = "e1000e"
ethernet0.connectionType = "nat"
ethernet0.addressType = "generated"
ethernet0.startConnected = "TRUE"
$controllers
sound.present = "TRUE"
sound.virtualDev = "hdaudio"
sound.fileName = "-1"
sound.autodetect = "TRUE"
sound.startConnected = "TRUE"
msg.autoAnswer = "TRUE"
uuid.action = "create"
EOF

    # `run` shows the VMware window, since the desktop draws there.
    "$vmrun" start "$vmx" "$([ "$action" = run ] && echo gui || echo nogui)"

}

prepare "$action-$media"

# `run` and `show` keep their data disk between sessions; `test` always starts blank.
[ "$action" != test ] && [ -f "$directory/data.img" ] || cp zig-out/data.img "$directory/data.img"
descriptor data
live
start
trap '"$vmrun" stop "$vmx" hard >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM

if [ "$action" = run ]; then

    printf 'Kernel log (COM1): %s\n' "$serial"
    "$python" tools/terminal.py attach "$pipe"
    exit

fi

if [ "$action" = show ]; then

    printf 'Desktop on VNC port %s; kernel log (COM1): %s\n' "$vnc" "$serial"
    while :; do sleep 1; done

fi

markers='boot: firmware released
boot: handoff ready
kernel: memory protected
kernel: page isolation and allocation rollback passed
kernel: all processors online
kernel: IPC and capability checks passed
kernel: fault isolation passed
kernel: process memory reclaimed
kernel: ready
services: ready
services: supervisor recovered; children adopted
services: recovery and application APIs passed
storage: ready
input: ready
audio: VMware HD Audio ready
display: ready'
failure=': error: |Exception Type|services: acceptance failed'

# Waits until the serial log shows `$1` complete boots.
booted() {

    deadline=$(( $(date +%s) + 120 ))

    while :; do

        ! grep -qE "$failure" "$serial" || fail "$(cat "$serial")"

        missing=$(printf '%s\n' "$markers" | while IFS= read -r marker; do [ "$(grep -cF "$marker" "$serial")" -ge "$1" ] || echo "$marker"; done)
        [ -n "$missing" ] || [ "$(grep -c 'kernel: verified cpu = ' "$serial")" -lt $(( cpus * $1 )) ] || break
        [ "$(date +%s)" -lt "$deadline" ] || fail "VMware test timed out. Inspect $serial"
        sleep 0.2

    done

}

# Waits for the guest to power itself off.
halted() {

    deadline=$(( $(date +%s) + 60 ))

    while "$vmrun" list | tr '\\' '/' | grep -qiF "$vmx"; do

        [ "$(date +%s)" -lt "$deadline" ] || fail "The guest did not power off. Inspect $serial"
        sleep 0.5

    done

}

booted 1
"$python" tools/terminal.py smoke "$pipe" "$directory/terminal.log"
grep -q 'files: volume formatted' "$serial" || fail "$(cat "$serial")"

# A full power cycle proves files reached the disk rather than a cache.
"$vmrun" stop "$vmx" hard
mv "$serial" "$directory/first.log"
start
booted 1
"$python" tools/terminal.py persist "$pipe" "$directory/persist.log"
grep -q 'files: volume mounted' "$serial" || fail "$(cat "$serial")"
booted 2
"$python" tools/terminal.py power "$pipe" "$directory/power.log"
halted

! grep -qE "$failure" "$directory/first.log" "$serial" || fail "$(cat "$directory/first.log" "$serial")"
printf 'Accounts, files, reboot, and shutdown passed (%s CPUs, %s MB, %s).\n' "$cpus" "$memory" "$media"

# The live media installs beside a disk another OS already owns, then that disk boots alone.
prepare "$action-$media-install"
cp zig-out/foreign.img "$directory/data.img"
descriptor data
rm -f "$directory/nvram"
live
start
booted 1
"$python" tools/terminal.py install "$pipe" "$directory/install.log"
halted
"$python" tools/media.py verify "$directory/data.img"
mv "$serial" "$directory/live.log"

device="$([ "$media" = disk ] && echo "$bus" || echo sata0):0.present = \"FALSE\""
start
booted 1
"$python" tools/terminal.py installed "$pipe" "$directory/installed.log"
halted

! grep -qE "$failure" "$directory/live.log" "$serial" || fail "$(cat "$directory/live.log" "$serial")"
printf 'VMware test passed (%s CPUs, %s MB, %s).\n' "$cpus" "$memory" "$media"
