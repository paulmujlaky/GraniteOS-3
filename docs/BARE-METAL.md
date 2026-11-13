# Bare-Metal Bring-Up

For the desktop (i9-13900K, Z790-class board, RTX 4060 Ti, NVMe). The machine has no serial port, so the screen is the log.

## 1. Put GraniteOS on a USB stick

Writing the image erases the whole stick.

1. Build the image:

   ```sh
   zig build -Doptimize=ReleaseSafe -Dself-test=false -j2
   py tools/media.py
   ```

   The result is `zig-out/granite.img` (a GPT disk holding one EFI system partition).
2. Write `zig-out/granite.img` to the stick, raw:
   - Windows: [Rufus](https://rufus.ie). Pick the stick, select the image, and choose **DD Image mode** when asked.
   - Linux or macOS: `dd if=zig-out/granite.img of=/dev/sdX bs=4M conv=fsync`, with `sdX` the stick, not a disk.
3. Check: the stick shows one small FAT partition holding `EFI/BOOT/BOOTX64.EFI`.

## 2. Boot the stick

1. Firmware setup (Del or F2 at power-on):
   - **Secure Boot: off**. The loader is unsigned.
   - **CSM / Legacy boot: off**, so the board boots in UEFI mode only.
   - Leave everything else at its default for the first try, including Above 4G decoding and Resizable BAR.
2. Plug the keyboard and mouse into the board's rear USB ports, not a monitor or front-panel hub, for the first try.
3. Power on, open the one-time boot menu (often F8, F11 or F12), and choose **UEFI: <the stick>**.
4. When the GraniteOS banner says *Press any key for boot options*, wait 1.5 s for a normal boot, or press a key for options (see section 3).
5. Expected result: kernel log text, then an **Install GraniteOS** panel listing every disk. The stick boot cannot sign in on its own, because accounts live on an installed volume.

## Install

You need an installed system to sign in and use `log` (see section 3). The panel lists each disk with its size and state, and says what installing on the picked one does. GraniteOS cannot install to a USB stick.

GraniteOS takes a **25 GB** data partition and leaves the rest of the disk alone. The size is fixed for now.

### Default: beside Windows on the same disk

1. Back up first. In Windows:
   - Turn off **Fast Startup** (Control Panel › Power Options › *Choose what the power buttons do*), then **Shut down** before booting the stick.
   - **BitLocker / Device Encryption** must be off for the Windows volume. GraniteOS cannot read an encrypted volume.
2. Boot the stick, pick the Windows disk, and press **Install**, then **Shrink Windows and install** to confirm.
3. When the panel says *Installed*, remove the stick and restart. Firmware now starts **GraniteOS** first. Create the administrator account.

What happens: if the disk has 25 GB of unallocated space, GraniteOS uses it. Otherwise it shrinks the largest NTFS volume by 25 GB, taking only space at the **end** of that volume that holds no files; nothing is moved. Its loader goes under `EFI\GRANITE` in Windows' EFI system partition. The next Windows start runs a quick disk check (*Scanning and repairing drive*) to finish the shrink; let it complete. Older System Restore points may be lost.

If the disk shows a reason instead of an Install button:

| Label | Fix |
|---|---|
| `end in use` | Files sit in the volume's last 25 GB. In Windows, open Disk Management, **Shrink Volume** by at least 25 GB, and leave the space unallocated. |
| `Fast Startup on` | Windows is hibernated. Turn off Fast Startup and shut down (see step 1). |
| `needs chkdsk` | Run `chkdsk C: /f` in an administrator terminal, restart Windows, then shut it down. |
| `BitLocker on` | Turn off BitLocker or Device Encryption and wait for decryption to finish, or shrink in Disk Management as for `end in use`. |
| `EFI partition full` | The loader needs about 20 MB in Windows' EFI system partition. Use a second disk instead (below). |
| `Full` | No unallocated space and no NTFS volume to shrink. Free 25 GB in Disk Management. |

To start Windows, pick **Windows Boot Manager** in the firmware's one-time boot menu, or move it back to first place in firmware setup.

### Alternative: its own disk (Windows is never touched)

GraniteOS erases a disk only if it shows as **empty** or **GraniteOS**. Disks holding Windows or any other data are never erased.

1. Pick a second internal disk (NVMe or SATA) you can wipe. If it still has partitions, clear it from Windows first. Back up anything on it.
   - Open an administrator terminal and run `diskpart`, then `list disk`.
   - Find the disk by its size, then run `select disk N` and `clean`. Check the number twice, because `clean` wipes the selected disk.
2. Boot the stick. Pick the disk marked **empty**, press **Install**, then press **Erase disk N and install** to confirm.

GraniteOS lays its own partition table on that disk: a 256 MiB EFI system partition and a 25 GB data partition. The rest stays unallocated.

From the serial shell or Terminal, `disks` lists the same information, and `install N erase` or `install N beside` installs. `log` shows why a volume could not be shrunk.

## 3. Capture bugs

Photograph the screen, the whole screen and legible, at every step that fails. Note the time since power-on.

| What happens | What to capture |
|---|---|
| Firmware won't start the stick | Secure Boot and CSM settings, and the boot-menu entry's name. |
| Kernel log text, then **error:** | Photo of the screen. It stays up for 60 s, or until reset if it says *halted*. Then boot the stick again: the banner shows *The last boot failed* with the end of that log for 30 s. Photograph it too. |
| Black screen or freeze, no error | Reset, boot again, press a key at the banner and try options one at a time: `1` one processor, `2` xAPIC, `3` no USB, `4` no NVMe, `5` no audio, `6` no network, or `0` for all the safe ones. Note which option makes it boot. |
| Desktop up, but a device is missing (keyboard, disk, sound) | On an installed system: open Terminal and run `log` (administrators), then photograph each screenful. `services` and `ps` help too. |
| Keyboard or mouse dead at login | Try the other rear ports, then a plain keyboard plugged in directly. Note which ports and devices work. |

Include with each report: board model and BIOS version, the boot option used (if any), the photos, and what you did just before the failure.

To reproduce a failure in a VM, run `sh tools/qemu.sh show` (it is set up like this PC), plus `--serial file` to get a text log in `zig-out/qemu/target/serial.log`.
