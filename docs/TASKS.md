# Tasks

## Milestone 1: Boot

- [x] Fresh Zig project following the established code style in AGENTS.md
- [x] Architecture- and platform-independent foundations.
- [x] x86_64 UEFI boot from removable media.
- [x] Serial diagnostics.
- [x] Boot in VMware (UEFI ISO and GPT/FAT32 disk).
- [ ] Boot on the initial Coffee Lake desktop (physical validation is deferred).

## Milestone 2: Kernel

- [x] Physical and virtual memory management.
- [x] Process isolation and controlled hardware access.
- [x] Preemptive scheduling and multicore execution.
- [x] Interprocess communication.
- [x] Application loading and execution.
- [x] Kernel failure diagnostics and reboot.

## Milestone 3: Services

- [x] Isolated drivers and system helpers.
- [x] Restricted service access to hardware and memory.
- [x] Service startup, supervision, and restart.
- [x] Recovery without interrupting unrelated applications.
- [x] Application-to-service and application-to-application APIs.
- [x] Terminal and shell.

## Milestone 4: Storage and Accounts

- [ ] SATA and VMware storage support.
- [x] Filesystem selection and persistent files/directories.
- [x] File and volume sizes without arbitrary fixed limits.
- [x] Multiple accounts, login, and administrator privileges.
- [x] Private home directories and access permissions.
- [x] Logout and screen locking (terminal and graphical).
- [x] Installed boot alongside an existing OS, preserving its data.
- [x] Shutdown and reboot.

## Milestone 5: Graphics and Desktop

- [x] VMware keyboard/mouse support.
- [x] USB keyboard/mouse support (xHCI and HID; physical validation is deferred).
- [x] VMware display support.
- [ ] Intel UHD 630 display support (detected and read over the firmware framebuffer; driving it awaits physical validation).
- [x] GPU-accelerated rendering wherever supported (VMware done; Intel pending).
- [x] Graphical login and screen locking.
- [x] Window management and a shared widget toolkit.
- [x] Desktop shell and application launching.
- [x] Desktop responsiveness, rendering, and usability improvements over GraniteOS 2.
- [x] File manager, editor, image viewer, settings, and system monitoring.
- [x] Remaining GraniteOS 2 desktop utilities with independently implemented code.

## Milestone 6: Workflows

- [x] Ethernet and VMware networking support (e1000e; the desktop's I219-V awaits physical validation).
- [x] TCP/IP, automatic configuration, DNS, and HTTP/HTTPS transfers.
- [x] Network apps: Weather (with a quick settings card) and Requests, over a shared location service.
- [x] Audio output on supported physical and virtual hardware (VMware HD Audio; the desktop's Realtek codec awaits physical validation).
- [x] Document and code editing (Markdown with a live preview; code with highlighting, find/replace, undo, and tabs).
- [x] Audio/video playback (WAV, FLAC, MP3/MP2, and MPEG-1 video decoded in Zig, in a Player with a queue).
- [x] Internet radio (Shoutcast/Icecast MP3 streams with live titles, Radio Browser search, and favourites).

## Milestone 7: Initial Release

- [ ] Complete-system validation in VMware and on the Coffee Lake desktop.
- [ ] Service-crash isolation and recovery validation.
- [ ] User separation and permission validation.
- [ ] Installation and existing-OS coexistence validation.
- [ ] Idle memory usage below 512 MB.
- [ ] Flexible boot-to-login target below 10 seconds.
- [ ] Completed-system performance and usability assessment.

## Milestone 8: Stretch — Apple Silicon

- [ ] AArch64 kernel and platform support.
- [ ] Apple boot integration.
- [ ] Apple M1 and newer hardware drivers and GPU acceleration.
- [ ] ARM VMware validation on Apple Silicon.
- [ ] Physical Apple Silicon validation.

## Milestone 9: Stretch — Hardware and Reliability

- [ ] NVMe storage and Wi-Fi.
- [ ] IPv6.
- [ ] Bluetooth and battery management.
- [ ] Suspend/resume.
- [ ] Filesystem integrity across unexpected power loss.

## Milestone 10: Stretch — Software Ecosystem

- [ ] SDK, software distribution, and package management.
- [ ] Online communication and collaborative workflows.
- [ ] Browser exploration.
- [ ] Windows application compatibility service.
