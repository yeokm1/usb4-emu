# Windows 98 SE legacy-guest test

This VM checks the legacy (i440FX) platform path for the xhci98 project:
`usb4-host` and the `usb4-tunnel-bridge` (SHPC `pci-bridge`) under Windows 98
SE, with the NVMe endpoint behind the tunnel. It has no USB4 connection
manager. The tunnel is forced from QEMU. Verified 2026-10-14.

## Files

| Path | What |
|---|---|
| `vms/win98/win98.qcow2` | Windows 98 SE system disk (4 GiB, FAT32). Internal snapshot `base-install` holds the clean state after first install. |
| `vms/win98/nvme32.qcow2` | Default disk behind the tunnel (`NVME=` overrides it). 1.5 GiB, MBR with one active primary partition, type 0x0C, starting at LBA 63, FAT32 (255 heads, 63 sectors, 4 KiB clusters), holds `README.TXT`. Made in WSL with `sfdisk` and `mformat -F`, then converted to qcow2. |
| `vms/win98/nvme16.qcow2` | The older disk: 504 MiB, FAT16, produced by QEMU vvfat (`qemu-img convert fat:16:vms/win98/nvme-seed`). `nvme-blank.qcow2` is an empty 1 GiB disk. |
| `vms/win98/drvnew.img`, `dl-nvme9x/` | The downloaded NVMe driver build, and a 32 MiB FAT16 IDE disk carrying it (it appears as D:) |
| `vms/win98/bin/` | Copy of the integrated QEMU build (`qemu-system-x86_64.exe`, `qemu-img.exe`) |
| `vms/win98/qi-usb.img` | Copy of the Windows 98 QuickInstall 1.1.0 USB image used to install. The original in `D:\isos` is untouched. |
| `scripts/run-win98.sh`, `scripts/stop-win98.sh` | Start the VM headless in the background, and stop it |

## Running

```
scripts/run-win98.sh                        # usb4-generic, tunnel down at boot
FORCE_TUNNEL=1 scripts/run-win98.sh         # x-force-tunnel=on: NVMe cold-plugged
PROFILE=tb3-alpine-ridge scripts/run-win98.sh
BIOS=OFF_ON PROFILE=tb3-titan-ridge scripts/run-win98.sh   # Titan Ridge 4C switch, 2 ports
USB4=0 scripts/run-win98.sh                 # plain VM, no USB4 devices
scripts/run-win98.sh -snapshot -trace 'usb4_*' -D 'vms\win98\usb4-trace.log'
```

- QMP runs on 127.0.0.1:47400 and VNC on 127.0.0.1:47401. Use
  `VM_DIR=vms/win98 python scripts/qmp.py ...` for `screendump`, `sendkey`
  and `hmp`.
- The script adds these USB4 arguments:

  ```
  -global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
  -drive if=none,id=nvme0,format=qcow2,file=vms/win98/nvme32.qcow2
  -device usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1,shpc-autoenable=on,msi=off
  -device usb4-host,id=u4,bus=pci.0,addr=0x4,tunnel-port=tb0,msi=off,msix=off
  -device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01
  ```

- The rest of the machine is `-machine pc -accel tcg -cpu pentium3,-apic -smp 1
  -m 512`, with `cirrus-vga`, IDE disk and CD-ROM, and no NIC. A TCG boot to
  the desktop takes about 2 minutes.
- Force the tunnel at runtime:
  `python scripts/qmp.py cmd qom-set '{"path":"/machine/peripheral/tb0","property":"tunnel","value":"up"}'`
  (or `"down"`).
- Stopping: use Start > Shut Down in the guest. Windows 98 powers the VM
  off through APM. `scripts/stop-win98.sh` sends `system_powerdown`, which
  Windows 98 ignores, then QMP `quit`, then kills the process.
- Return to the clean install (shut the VM down first):
  `vms/win98/bin/qemu-img.exe snapshot -a base-install vms/win98/win98.qcow2`.
  The current disk is past that snapshot. It has the PCI-PCI bridge and the QuickInstall
  NVMe driver installed, and "Int 13 unit" is off on the NVMe disk.

## Installation (how the disk was made)

Windows 98 QuickInstall 1.1.0 (`win98qi_v1.1.0_ALL_usb.img`) was attached raw
as IDE disk 0 (`INSTALL_IMG=vms/win98/qi-usb.img`), with the new qcow2 as disk 1.
Steps: boot menu entry 1; variant "Windows 98SE (Patched, Stock Installation,
DirectX 6.1a)"; DISK, `sdb`, new MBR, one 4 GiB FAT32 LBA partition, write;
INSTALL to `sdb1` with default options (MBR plus active, format, boot sector,
skip legacy detection, integrated driver library; CREGFIX off). The image is
pre-activated, so no product key was needed.

**Choose "Reboot" at the end, not QMP `quit`.** If QEMU is quit at the
success screen, the installer's Linux page cache has not been flushed, and
Windows then boots with "registry/configuration error".

First boot was under WHPX with no USB4 devices. It reached the desktop with no
prompts. The VM was shut down and `base-install` was taken. The snapshot boots
with any `-cpu`. The later switch to `pentium3,-apic` raised no new-hardware
prompt.

## Results

### Boot with `usb4-host` (generic) and `usb4-tunnel-bridge`, tunnel down

Boots cleanly under TCG. The model causes no hang and no resource conflict.
The Add New Hardware wizard runs twice on the first boot:

1. **PCI standard PCI-to-PCI bridge**, `PCI\VEN_1B36&DEV_0001&SUBSYS_00000000&REV_00`.
   The inbox driver `MACHINE2.INF` installs without the CD.
2. **PCI Universal Serial Bus**, `PCI\VEN_1B36&DEV_00F4&SUBSYS_11001AF4&REV_01`
   (the USB4 host interface, class 0C03). No driver is found. Finish
   leaves it under "Other devices" with a yellow "?". The status is "The drivers
   for this device are not installed (Code 28)". Resources tab: "Memory Range
   FEA00000 - FEA3FFFF", "No conflicts", plus the usual "resources do not
   match any known configuration" note for a driverless device.

Device Manager by connection: PCI bus > Cirrus Logic 5446 PCI, Intel 82371EB
Power Management Controller, Intel 82371SB PCI Bus Master IDE Controller,
Intel 82371SB PCI to ISA bridge, Intel 82441FX Pentium(r) Pro Processor to PCI
bridge, PCI standard PCI-to-PCI bridge (no children), PCI Universal Serial Bus.

Resources (firmware, from `info pci`; Windows keeps them):

| Device | BDF | INTx | IRQ | Windows shows |
|---|---|---|---|---|
| usb4-host (generic) | 00:04.0 | A | 11 | MEM FEA00000-FEA3FFFF (no IRQ shown, driverless) |
| usb4-tunnel-bridge | 00:05.0 | A | 10 | I/O C000-CFFF, MEM FE800000-FE9FFFFF, MEM FE000000-FE1FFFFF, IRQ 10, no conflicts. SHPC BAR0 is 64-bit at FEA51000. |
| NVMe (tunnel up) | 01:01.0 | A (B at the bridge) | 10 | IRQ 10, MEM FE800000-FE803FFF, no conflicts |

IRQ 10 is shared by the bridge, the NVMe, and the PIIX4 ACPI/SMBus function.
IRQ 10 and 11 are level-triggered (PIC ELCR 0x0c). MSI and MSI-X are off on
both USB4 devices (`msi=off`, `msix=off`), and nothing depends on them.

### Tunnel forced up at runtime, then Device Manager "Refresh"

With Device Manager open, `qom-set ... tunnel up` produced this trace:
`usb4_tp_insert ... cold=0`,
`usb4_tb_autoenable tb0: shpc-autoenable: slot Enabled on insertion`, and
`usb4_tp_gate tb0: access gate closed=0`. Windows 98 has no SHPC driver, so it
shows nothing at this point. Pressing **Refresh** starts the wizard for
**NVMe Storage Controller (Windows 9x)**,
`PCI\VEN_1B36&DEV_0010&SUBSYS_11001AF4&REV_02`. QuickInstall ships
SweetLow's NVMe driver (`C:\DRIVER\NVME9X.INF`) and it installs. Windows assigns
the NVMe its BAR and IRQ 10 itself, under the bridge's windows. The bridge then
has a child, NVMe Storage Controller (Windows 9x), which has a disk child,
**QEMU NVMe Ctrl**. The disk also appears under Disk drives.

QEMU `pci_nvme_*` trace from the driver: CC.EN, admin queue setup, I/O
CQ/SQ creation (`ien=1`), Identify Controller and Identify Namespace 1. Every
command completes with status 0. The DMA buffers land in guest RAM through the
tunnel gate address space, and the INTx pulses arrive on IRQ 10 (`info irq`
shows 259 on IRQ 10).

### `x-force-tunnel=on` at boot

Two problems, so do not use this to get a working disk:

- **Model bug: the cold-plugged NVMe has no namespace.** The trace shows
  `usb4_tp_insert tb0: insert endpoint gen 1 drive=(none) serial=(none) cold=1`,
  although `usb4-device enc0` names `drive=nvme0`. The runtime insertion (`cold=0`)
  does use `drive=nvme0`. The cold insertion apparently happens before the
  `usb4-device` claims its port, so it falls back to the bridge's
  `nvme-drive`, which was unset. The NVMe then has no namespace 1: SeaBIOS
  probes namespaces 1-256 and finds nothing. In a guest memory dump of the
  miniport's device extension, `InitComplete=1` but the namespace size was 0
  and request counters were 0. With namespace size 0, nvme2k returns BUSY to
  every READ and a placeholder for READ CAPACITY, so Windows never gets a
  volume. Reported to the integrator, with no hw/usb4 change.
  `run-win98.sh` works around it: with `FORCE_TUNNEL=1` it also passes
  `nvme-drive=nvme0,nvme-serial=USB4EMU01` to the bridge.
- **With a namespace, Windows 98 hung at the boot logo.** SeaBIOS's built-in
  NVMe driver registers the disk as INT 13h drive 0x81, and real-mode DOS
  reads it: LBA 0 and 0x3F, the MBR and FAT32 boot sector. Windows 98 then
  stopped at the logo with the CPU looping at the SMM entry point (SMM=1,
  EIP=0x8000). The cause was a QEMU TCG bug, not the tunnel, the NVMe model
  or SeaBIOS. It is fixed in main as of QEMU `2a893ea` (branch `usb4-posthang`). See "SMM hang at
  the boot logo" below.

With an older QEMU build, keep the NVMe away from SeaBIOS (no forced tunnel at
power-on) and bring the tunnel up after POST. See "NVMe disk: working procedure" and
the preconditions under "Workaround for older QEMU builds" below.

### NVMe disk: working procedure (verified 2026-10-14)

```
TUNNEL_UP_AFTER=6 scripts/run-win98.sh     # or start normally and qom-set ... tunnel up later
# at the desktop: Device Manager > Refresh
```

On Refresh, Windows configures the NVMe (BAR0 FE800000, IRQ 10), and nvme2k
reads LBA 0, 0x3F, 0x40 and the root directory. Explorer then shows
**"Nvme32 (E:)"** (C: is the system disk, D: the CD-ROM). Screendumps:
`vms/win98/win98-nvme-e-drive.png` and `win98-nvme-readme.png`.

- **Read:** Notepad opens `E:\README.TXT` written on the host.
- **Write:** `copy C:\WINDOWS\WIN.INI E:\FROMW98.TXT` produced
  `pci_nvme_write` commands. After a clean shutdown the host read the file
  from `nvme32.qcow2` with `mtype`. Its MD5 (43094d3d5ea366940d6430e7546a6ce0)
  matches the guest's `WIN.INI`.
- The FAT16 vvfat disk (`NVME=vms/win98/nvme16.qcow2`) also mounts as E:,
  and its README.TXT reads.
- The QuickInstall driver build (17813-byte MPD) was used for these runs.
- Boot without the NVMe at POST takes about 25 s under TCG, instead of
  about 2 minutes. SeaBIOS no longer probes 256 namespaces.
- Windows 98 does not auto-configure an NVMe that appears after POST, even
  when it appears before Windows enumerates PCI, so the Refresh is needed.
  This is the same as the hot-plug case under "Tunnel down, and up again".

### Tunnel down, and up again

- `tunnel down`: the gate closes, then quiesce, surprise removal, and
  `endpoint` = `none gen=1 gate=closed awaiting-ack`. Windows 98 does not
  acknowledge the empty slot, so the settle timeout applies to the
  replacement. Windows stays responsive. After Refresh it still lists the NVMe:
  Win9x does not remove a vanished PCI function on its own.
- `tunnel up` again inserts generation 2 with its BAR unassigned. Refresh alone
  does not reprogram it, because Windows thinks it is the same device. Use
  Device Manager **Remove** on the NVMe controller, then **Refresh**. Windows
  then re-detects it, reinstalls the driver, and assigns BAR0 FE800000 and IRQ
  10 again. A future xhci98 CM driver must do the equivalent: reconfigure the
  child bus after a tunnel comes up.

### Tunnel brought up by a guest CM (`USB4CM.EXE`, 2026-10-14)

No forced tunnel: the polling reference CM in [tools/usb4cm](../tools/usb4cm/README.md),
run from the DOS 7.1 prompt (`BootGUI=0` on an overlay, `vms/win98-refcm`), enumerates
the device router, bonds lanes and programs the PCIe paths; the trace shows
`usb4_tunnel_transition router 0x1 PCIe tunnel up` and the NVMe answers at 01:01.0.
Typing `win` afterwards starts Windows without a reset; the tunnel stays up and
Explorer shows the NVMe volume (F:) with no Device Manager Refresh.

### `profile=tb3-titan-ridge` (historical, 2026-10-13 stub)

This records the pre-M2 code stub, which then carried the name `tb3-titan-ridge`. Since
2026-10-15 that name is the inferred Titan Ridge variant
([ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md), NHI `15EB` revision 6, subsystem `17AA:22B0`);
it has not been run in Windows 98 yet. The stub's only difference was the host's identity. The wizard shows **PCI
Universal Serial Bus**, `PCI\VEN_8086&DEV_15E8&SUBSYS_11001AF4&REV_01`. It has
no driver, the same as the generic profile. Note that the subsystem ID is
QEMU's default 1AF4:1100, not a Lenovo one.

## Issues found

Issues 1 and 2 are not in the usb4 model. Issue 3 had a usb4 model bug as one of its causes.

1. **WHPX aborts with any PCI-PCI bridge on i440FX + Windows 98.** QEMU exits
   with `WHPX: failed to unmap GPA range` during Windows 98 boot. It reproduces
   with a stock `-device pci-bridge,...` and no usb4 devices, with `cirrus-vga`
   or `VGA`. Without a bridge, WHPX boots Windows 98 in under a minute. Use
   TCG (the default).
2. **TCG guest restart hangs with a local APIC.** After Start > Shut Down >
   Restart, the machine resets. IO.SYS then waits forever at the boot logo
   for the BIOS tick (0040:006C). The cause is the local APIC state: LVT LINT0
   is masked and SPIV has the APIC software-disabled, so PIC interrupts are not
   accepted, although IRQ0 is pending and unmasked in the PIC. It reproduces
   without usb4 devices. Workaround: `-cpu pentium3,-apic` (the default in
   `run-win98.sh`). Restart then works, and Windows 98 does not use the APIC.
3. **The NVMe volume got no drive letter.** Root cause: the model bug and
   the SMM hang described under "`x-force-tunnel=on` at boot". The driver,
   the partition format and the tunnel data path were not the cause. See
   "NVMe disk: working procedure".

## SMM hang at the boot logo (QEMU TCG bug, fixed 2026-10-16)

**Symptom.** A disk that SeaBIOS serves from one of its 32-bit drivers, present at
power-on, made Windows 98 SE stop at the boot logo, and sometimes at the
"shutting down" screen. The CPU was in SMM at `EIP=0x8000` (`info registers`:
`SMM=1`, `CS=a000`). Triggers: an NVMe behind a pre-boot tunnel (`BIOS=OFF_ON` or
`ON_ON`, `FORCE_TUNNEL=1`), an NVMe on `pci.0`, or the ORICO's USB fallback disk with
`USB_FALLBACK=bot` (SeaBIOS's USB mass storage on the TB xHCI). The default UAS
fallback did not trigger it. SeaBIOS 1.17 skips SuperSpeed UAS devices ("Superspeed
UAS devices not supported (yet)"), so that disk gets no INT 13h drive. `-boot
strict=on`, and `BootGUI=0` followed by `win`, did not avoid it. The real P14s boots
because no emulator is involved.

**Root cause.** SeaBIOS's NVMe, xHCI and USB mass-storage drivers are 32-bit code.
For each INT 13h call to such a drive, SeaBIOS switches to 32-bit mode through its
SMM trampoline (`call32_smm`): it writes 0xb5 to the APM control port 0xb2, and the
SMI handler at SMBASE + 0x8000 resumes the caller in flat 32-bit mode. SeaBIOS
relocates SMBASE to 0xa0000, so the handler's entry point is at 0xa8000, under the
legacy VGA window.

QEMU's TCG softmmu TLB has no separate SMM index. Each TLB entry keeps the address
space (normal memory or SMRAM) that was in effect when it was filled. On SMM entry and
RSM, QEMU flushes the TLB only when the CR0 or CR4 update changes a paging-related
bit (CR0.PE, PG, WP; CR4 paging bits). An SMI from real mode, and an RSM back to it,
change none of them. Windows 98's IO.SYS draws the logo in VGA mode 13h from real
mode. The frame buffer is at 0xa0000-0xaf9ff, so drawing it leaves a TLB entry for
the page at 0xa8000 that points at the frame buffer. When DOS then reads the NVMe or
USB disk through INT 13h, the SMI's first instruction fetch uses that entry. It runs
logo pixels instead of SeaBIOS's handler and takes `#UD` on every attempt, forever.

The hang needs a real-mode INT 13h to that drive after the logo is drawn and before
anything flushes the TLB, such as a protected-mode switch or a trampoline call that
did not touch 0xa8000. That makes it timing dependent.

**Evidence** (QEMU `usb4-emu` 36f6254, `-m 256 -cpu pentium3,-apic`, cirrus-vga):

- `-d int`: the last `SMM: enter` is the `call32_smm` enter command (EAX=0xb5,
  ECX=0x1234), from real mode with CR0=0x10. It has no `SMM: after RSM`, only an
  endless `check_exception old: 0xffffffff new 0x6`. The 27 SMM entries before it
  returned normally.
- In the hang, the monitor's SMM view of 0xa8000 (`x /4xb 0xa8000`) shows SeaBIOS's
  entry code `8c c8 ea 6e` (`mov ax,cs; ljmp f000:...`). The normal view
  (`xp /4xb 0xa8000`) shows `ff ff ff ff`, which is logo pixels and an invalid
  opcode. SMRAM itself was intact.
- One shutdown hung the same way. The CPU was in SMM at CS=a000, EIP about 0xae5f,
  running the zeroed frame buffer of the black shutdown screen.
- Reproduced with `BIOS=OFF_ON` (TS3 dock NVMe): the logo hang on one boot and the
  shutdown hang on another. Also reproduced with
  `BIOS=OFF_OFF DEVICE_MODEL=asm2464 USB_FALLBACK=bot` (logo hang).

**Fix.** QEMU branch `usb4-posthang` on `usb4-emu` 36f6254, in main as of `2a893ea`: 5748fdd
"target/i386: flush the TLB on SMM entry and RSM", plus test follow-up 0702fa0. `do_smm_enter()` and
`helper_rsm()` in `target/i386/tcg/system/smm_helper.c` now call `tlb_flush()`.
Upstream QEMU master has the same code without the flush.

The qtest `x86-smm-tlb-test` has three cases. It needs TCG, the pc machine and the
VGA device, because something must decode 0xa8000 outside SMRAM.

- `entry-from-real-mode/pentium3` and `/qemu64` (32-bit and 64-bit save-state maps):
  a sector booted by SeaBIOS sets mode 13h, reads 0xa000:0x8000 and raises an SMI.
- `rsm-to-real-mode` uses its own firmware image instead of SeaBIOS, because
  SeaBIOS's handler enters protected mode before RSM, and that switch flushes anyway.
  The firmware relocates SMBASE to 0xa0000. Its SMRAM handler only sets a marker and
  executes RSM in real mode. Afterwards, real mode must read the VGA window at
  0xa8000, not the handler's bytes.

All three pass on the fixed build. On 36f6254 all three fail ("the CPU did not
return from SMM"; "stale TLB entry"). With only the `helper_rsm()` flush removed,
`rsm-to-real-mode` fails and the entry cases pass. `q35-test`, `i440fx-test`,
`usb4-host-test` and `usb4-icm-test` still pass.

**Verified on the fixed build.** All runs used overlays of `win98.qcow2` and
`nvme32.qcow2`, `-m 256` and cirrus-vga. Each run was a fresh QEMU process, ended
with Start > Shut Down, which powered the VM off.

| Run | Setting | Result |
|---|---|---|
| (b) TS3 Plus / NVMe pre-boot | `BIOS=OFF_ON` | Desktop. `copy C:\WINDOWS\WIN.INI D:\POSTHANG.TXT` to the NVMe (D:, "NVME32"). After shutdown, `mtype` on the host gives MD5 43094d3d5ea366940d6430e7546a6ce0, the guest's WIN.INI. Shutdown powers off. |
| (b) at 512 MiB | `BIOS=OFF_ON MEM=512` | Desktop. Shutdown powers off. |
| (a) ORICO, pre-boot | `BIOS=OFF_ON DEVICE_MODEL=asm2464` | The ORICO is tunnelled before POST (`PCIe tunnel up`). Desktop. `copy` and `fc` of SYSTEM.INI on D: report no differences. |
| (a) ORICO, USB fallback (UAS) | `BIOS=OFF_OFF DEVICE_MODEL=asm2464` | Desktop. SeaBIOS does not use the UAS disk, and Windows 98 needs xhci98's drivers for it. |
| (a) ORICO, USB fallback (BOT) | `BIOS=OFF_OFF DEVICE_MODEL=asm2464 USB_FALLBACK=bot` | 36f6254 hung at the logo. The fixed build reaches the desktop. The disk is D: in MS-DOS compatibility mode (INT 13h through SeaBIOS, every call an SMI), and `copy` and `fc` report no differences. |

**Workaround for older QEMU builds.** Passing `-machine smm=off` to `run-win98.sh`
avoids the hang, because SeaBIOS then has no SMM trampoline. It is not the default:
without the trampoline, SeaBIOS cannot serve INT 13h from Windows 98's V86 mode. On
36f6254 with `USB_FALLBACK=bot`, the desktop came up, but `dir D:\` gave "Not ready
reading drive D" and hung the DOS box. A disk with a protected-mode driver (the NVMe
with nvme2k) does not need INT 13h after boot, but that case was not tested.

The other workaround is to keep the disk out of SeaBIOS's enumeration and attach it
after POST. It works only if both of these hold:

- **SeaBIOS must not see the disk at POST.** Pre-boot must be off (no `BIOS=*_ON`,
  no `FORCE_TUNNEL`), or no device may be attached at power-on. With `BIOS=OFF_ON`
  the NVMe is tunnelled before POST, so `TUNNEL_UP_AFTER` does not help. Also, the
  ORICO's USB fallback must not be Bulk-Only (`USB_FALLBACK=bot`). SeaBIOS
  enumerates that disk on the TB xHCI at POST; the default UAS one it skips.
- **The guest needs a driver to reach the disk later.** For the NVMe, that is nvme2k
  after the tunnel comes up (a CM, or `TUNNEL_UP_AFTER`, which forces it from QMP),
  then Device Manager Refresh. For the USB disk, it is xhci98's drivers.

**Why xhci98's image did not hang.** It runs the same model and the same NVMe disk:
their `vm/usb4/win98-pbc` run uses `nvme32.qcow2` as its backing file, with
`BIOS=OFF_ON`. The bug should be the same, with only the timing different.
This is inferred: no run on their image was traced. Differences found by reading
their files:

- Their `win98.img` has the stock IO.SYS (222390 bytes, 1999-04-23). This image has
  QuickInstall 1.1.0's patched IO.SYS (222670 bytes, 2026-09-18).
- Their partition starts at LBA 63; this image's starts at LBA 2048.
- Their launcher uses `-vga std` instead of cirrus-vga.
- Their launcher attaches a VVFAT transfer disk as IDE 1. That disk becomes BIOS
  drive 0x81 and moves the NVMe to 0x82.

The MSDOS.SYS `[Options]` section and the empty CONFIG.SYS and AUTOEXEC.BAT are the
same in both images. Any of these differences can change whether a real-mode INT 13h
to the NVMe falls between the logo drawing and the next TLB flush. Which one matters
was not isolated. With the fix, it no longer matters.

## NVMe driver builds and disk formats (2026-10-14)

The two driver builds:

| | QuickInstall 1.1.0 build (installed now) | Download `nvme9x.zip` (readme: nvme2k 1.0.0.2 port) |
|---|---|---|
| `nvme9x.inf` DriverVer | 11/24/2025,1.0.0.2 | 11/24/2025,1.0.0.2 (same INF, without QI's DriverCopy header and CAB source) |
| `NVME2K.MPD` | 17813 bytes, PE link time 2026-02-18 20:45 | 17589 bytes, PE link time 2025-12-28 20:37 |
| `NVMEVSD.VXD` | 6544 bytes | identical |

QuickInstall's miniport is the newer link. The versions were read offline
with `7z` straight from `win98.qcow2`.

History of the live disk:

1. The downloaded build was installed through Device Manager. Remove the
   controller, Refresh, then "Specify a location" on a FAT disk at D:.
   Before that, QuickInstall's MPD was backed up as `C:\DRIVER\nvme2k.qi`,
   and its INF was renamed and its `INF\OTHER` copy deleted, so Windows would
   not pick it again.
2. QuickInstall's build was then restored by copying `nvme2k.qi` over
   `C:\WINDOWS\SYSTEM\IOSUBSYS\NVME2K.MPD` and QI's INF back over
   `C:\DRIVER\nvme9x.inf` and the `INF\OTHER` copy. The INFs have the same
   DriverVer and registry settings, so this is equivalent to a reinstall.
   Checked offline afterwards: MPD 17813 bytes, both INFs 1569 bytes.

The earlier "no I/O" table (both builds, FAT16 and FAT32) was measured with
`x-force-tunnel=on` without `nvme-drive`, so the controller had no namespace
in every one of those runs. The table compared nothing. With a real
namespace, the QuickInstall build works on both disks. The downloaded build
was not retested after the fix.

## P14s BIOS matrix on the Alpine Ridge profile (2026-10-14)

`scripts/run-win98.sh` with `BIOS=<Assist>_<PreBoot>` runs `tb3-alpine-ridge` behind
the captured switch topology on i440FX: a root bridge (stand-in for the PCH root port
00:1c.4, a gated `usb4-tunnel-bridge` so BIOS Assist can power the controller domain
down: config, windows, DMA and interrupts) at 00:1c.0 (00:06.0 since the IRQ fix below; `ROOT_ADDR`) with the switch at 01:01.0, the switch upstream port `8086:15c0`, downstream ports `8086:15c0`
for the NHI `8086:15bf`, the tunnel (`usb4-tb3-tunnel-bridge`) and the xHCI
`8086:15c1`. Assist sets `bios-assist=on` and leaves the xHCI out; pre-boot sets
`preboot=on` with the device's UUID in `boot-acl`; `DEVICE_AT_BOOT=0` starts with
nothing attached. QEMU `usb4-icm` at 3eb5843.

Method: an overlay of `win98.qcow2` in `vms/win98-icm` set to boot to the DOS prompt
(`MSDOS.SYS` `BootGUI=0`), whose `AUTOEXEC.BAT` runs `D:\PCIDUMP.COM > D:\PCIDUMP.TXT`
from a small FAT16 data disk (a copy of `drvnew.img` with `PCIDUMP.COM` from
`tools/p14s-capture/win98`), read back with mtools after QEMU quits. A blank 256 MiB
NVMe disk keeps SeaBIOS from finding a bootable volume behind the tunnel.

| Run | `BIOS` | Device at boot | Switch + NHI | xHCI 15c1 | Behind the tunnel | Capture |
|---|---|---|---|---|---|---|
| OFF_OFF | OFF_OFF | yes | present | present | absent | same |
| OFF_ON | OFF_ON | yes | present | present | NVMe 04:01.0 | same pattern (dock tree) |
| ON_OFF | ON_OFF | yes | present | absent | absent | same |
| ON_ON | ON_ON | yes | present | absent | NVMe 04:01.0 | same pattern (dock tree) |
| OFF_OFF_N | OFF_OFF | no | present | present | absent | same |
| OFF_ON_N | OFF_ON | no | present | present | absent | same |
| ON_OFF_N | ON_OFF | no | absent | absent | absent | same |
| ON_ON_NO | ON_ON | no | absent | absent | absent | same |

All eight match the presence pattern of `tests/captures/p14s-gen1/win98/` (README
table). Differences that remain: the root bridge is QEMU's `1b36:0001`, not the PCH
root port `8086:02bc`; the device router is a single NVMe, not the dock's switch tree;
bus numbers are SeaBIOS's (01-05) rather than the P14s firmware's (03-2b).
The matrix was repeated on 2026-10-15 with a USB4 device (ORICO AAGM2-U4,
`tests/captures/p14s-gen1/win98-orico/`). It matches the dock pattern except with
Assist on and pre-boot off, where the real firmware hides the NHI and shows its xHCI
unconfigured, because the unapproved USB4 device has fallen back to USB mode
([captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md) §2). The model
does not reproduce that cell yet.

Linux with `BIOS=ON_ON` (`scripts/run-linux.sh`, q35): `PCI0._OSC` grants only LTR and
DPC ("platform retains control of PCIe features", as in the captured Assist-on dmesg),
no xHCI, the device `authorized` 1 with `boot` 1 and the NVMe readable at boot.

Re-run 2026-10-14 after the review fixes (QEMU `usb4-icm` ebbeaa7: whole-domain power
gate, cold re-insertion of firmware tunnels at machine reset): all eight combinations
still match. Linux `BIOS=ON_ON`: Assist `_OSC`, `authorized` 1, `boot` 1, 16 MiB
O_DIRECT write/read compare OK; `BIOS=OFF_OFF`: xHCI present, authorising gives
`/dev/nvme0n1`.

Limitation (lifted in main as of QEMU `25fd4eb`, see "The controller tree leaving"
below): with Assist on, the platform's ACPI hot-plug path (the TB GPE handler that
sends a bus check to the root port) is not modelled. An OS honouring the Assist `_OSC`
only finds a controller that powers up after boot by rescanning, as in the captured
Linux Assist-on run. The Assist `_OSC` is not applied when a `usb4-generic` host shares
the machine.

### Hot-added NVMe gets no IRQ behind 00:1c (fixed 2026-10-14)

Symptom (NVMe evaluation run b2): `BIOS=OFF_OFF`, tunnel forced up at the desktop
(`qom-set tb0 tunnel up`), Device Manager Refresh: "NVMe Storage Controller (Windows
9x)" shows **Code 29** ("the BIOS for the device did not give it an IRQ"), `info pci`
shows IRQ 0 and BAR0 unmapped, nvme9x never starts. Reproduced in `vms/win98-irq`
(QMP 48020) with QEMU `usb4-emu` 02de29c.

Root cause: the SeaBIOS `$PIR` table has no entry the hot-added function can reach.

- Windows 98 runs in APM (non-ACPI) mode. PCI bus > IRQ Steering reports "IRQ Table read
  from MS IRQ Routing Specification", so it routes PCI interrupts from `$PIR` only.
- The `$PIR` SeaBIOS rel-1.17.0 builds for i440FX (read from guest memory at F55A0):
  router 00:01.0 (`8086:122e`), six entries, bus 0 devices 1 to 6 only, links 60-63
  rotated per slot, IRQ bitmap DEF8. Nothing on other buses and nothing at device
  0x1c.
- A function that is present at POST gets its Interrupt Line from SeaBIOS (which
  swizzles to bus 0 itself and does not need `$PIR`), and Windows 98 keeps it. A function
  added after POST has Interrupt Line 0. Windows then swizzles its pin up through the
  bridges (04:01.0 -> 02:01.0 -> 01:01.0 -> 00:1c.0) and looks up the bus 0 slot in
  `$PIR`. There is no entry for 00:1c, so Code 29. On the generic profile the bridge
  sits at 00:05, which is listed, so the same hot-add gets IRQ 10.

Fix: `run-win98.sh` puts the root bridge at 00:06.0 by default (`ROOT_ADDR`, 0x1c
reproduces the failure). After that, the same procedure gives the NVMe IRQ 10 (pin D at
00:06 -> link 60) and BAR0 FE400000 under the tunnel bridge's window. nvme9x enables the
controller, the volume mounts as E:, and `copy` + `fc /b` of `SHELL32.DLL` (1.4 MB) shows
no differences; after shutdown the host's MD5 of the copy matches the original
(435aaf79...). The generic profile was re-checked with the same build: IRQ 10, BAR0
FE800000, copy and compare pass. Moving the root bridge changes the PnP location, so
Windows reinstalls the bridges (inbox driver, no CD) on the first boot.

Separately, the i440FX switch-port stand-ins (`usb4-tb3-pci-bridge`) now report
Interrupt Pin INTA# like the captured 15c0 ports, and SeaBIOS writes an Interrupt Line
for each (QEMU `usb4-irq` eff58b0). This matches the capture and does not affect the
routing above.

Real hardware: the P14s runs Windows 98 with IRQ steering too (its Enum has "IRQ Holder
for PCI Steering" for IRQ 10 and 11), and its BIOS wrote an Interrupt Line for the root
port 00:1c.4 and every 15c0 port. **Its `$PIR` covers the tunnel (answered 2026-10-15,**
[captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md) **§1).** The table
is built at POST (router 00:1f.0 `8086:0284`, links 60-63, IRQ bitmap `0xDC78`), always
has an entry for bus 0 device `0x1c` with all four pins (also with the controller powered
down), plus one for the tunnel DSP 04:01 and each secondary bus populated at POST, and
every entry below bus 0 is the standard swizzle of the bus-0 entry. A device hot-added
behind 04:01.0 therefore resolves to link 61 (IRQ 10 as the BIOS routes it) whether
Windows stops at 04:01 or goes on to 00:1c. `ROOT_ADDR=6` gives the emulator the same
outcome and stays the default. A P14s-shaped table on QEMU would have to keep QEMU's
per-slot link rotation (copying the P14s's unrotated bus-0 links would misroute); if it
is ever wanted, build it with a small SeaBIOS patch that generates `$PIR` after PCI
enumeration (entries for every populated bus-0 slot and secondary bus) and select it
together with `ROOT_ADDR=0x1c`.

## The controller tree leaving: surprise removal, Assist power-off, ACPI hot-plug (2026-10-15)

In main as of QEMU `25fd4eb` (`usb4-emu`, `src/patches/0001-usb4-emu.patch`; built on branch `usb4-hotplug`).
Design: [ARCHITECTURE.md](ARCHITECTURE.md) §4.4a. QMP and options:
[XHCI98-HANDOFF.md](XHCI98-HANDOFF.md) §6d. Topology as `BIOS=OFF_OFF` (root bridge
`tbrp` at 00:06.0, switch, NHI 15BF, tunnel bridge, xHCI 15C1). Every run was on an
overlay under `E:\usb4-emu-vms\hotplug`. TCG, `-cpu pentium3,-apic`.

### Does Windows 98 SE handle ACPI PCI hot-plug on bus 0?

**Yes, but only in ACPI mode, which the xhci98 image does not run.**

- The image in `vms/win98` (and the xhci98 copies) runs Windows 98 in **APM mode**: the
  ACPI tables are present but no ACPI driver is loaded, so the GPE is never serviced.
  Use `root-hotplug=restore` there.
- **Switching to ACPI mode took three steps on an overlay:**
  1. Setting `HKLM\Software\Microsoft\Windows\CurrentVersion\Detect` `ACPIOption=1` and
     running Add New Hardware detection did **not** find ACPI. SeaBIOS's BIOS date is
     06/23/99; QuickInstall skipped legacy detection.
  2. Installing "Advanced Configuration and Power Interface (ACPI) BIOS" by hand
     (Add New Hardware, System devices, `ACPI.SYS` 83,280 bytes is on the image)
     worked. On the next boot, however, ACPI's own PCI bus (`ACPI\*PNP0A03`) failed
     with **Code 2**, "two PCI.VXD bus types": the old root-enumerated PCI bus still
     held every PCI device.
  3. Removing that old "PCI bus" in Device Manager and restarting moved all PCI
     devices under the ACPI PCI bus. Windows reinstalled the bridges and the Cirrus
     driver with no CD.

  After that the disk is a normal ACPI-mode install (`w98acpi.qcow2`).
- **Surprise removal** (`qom-set tbrp present false`, `root-hotplug=acpi`):
  1. The gate closed and the tree was reset.
  2. The Bus Check on slot 6 followed. Windows serviced the GPE (`acpi_pci_up_read 64`)
     and re-read bus 1, where every slot read empty.
  3. Device Manager refreshed by itself: the switch, its three downstream ports, the
     NHI and the xHCI devnodes were gone, and `tbrp` stayed with no children.

  The guest kept running. No user action was needed.
- **Arrival** (`present true`): after the Bus Check, Windows enumerated the fresh tree
  by itself.
  - It programmed bus numbers 1-5, the bridge windows and the switch ports' IRQs. It
    also moved `tbrp`'s window and its SHPC BAR, which it is free to do.
  - The driverless NHI and xHCI got no BAR and no IRQ. Windows 98 assigns resources
    only when a driver loads; with xhci98.sys bound that would differ.
- Not run: the Assist power-off in Windows 98 ACPI mode. It is the same code path,
  only delayed (qtest `r32-timing`, and the Linux run below).

### Windows 98 SE in APM mode, `root-hotplug=restore`

`present false`, then `true` on a fresh overlay of `vms/win98/win98.qcow2`:
- The trace shows `root-gated`, `root-quiesced`, "restored the configuration of 6
  functions" and `root-arrived`.
- `info pci` before the removal and after the return is **identical**: bus numbers,
  windows, NHI BAR0 `FE600000`, xHCI BAR0 `FE200000` and IRQs 10/11.
- The desktop stayed responsive and no devnode changed.

What the driver sees in between is all-ones (qtest `restore`).

### Windows 2000 SP4, `-machine pc,acpi=off` (the xhci98 launch line)

`acpi=off` means no ACPI. `root-hotplug=acpi` then only warns once ("slot 6 has no
ACPI PCI hot-plug") and behaves like `none`. Windows learns of changes only from a
rescan (Device Manager, Scan for hardware changes):

- **Removal, then rescan:** "Unsafe Removal of Device" listed the PCI-to-PCI bridges,
  which is Windows 2000's surprise-removal path. The NHI and xHCI devnodes (driverless,
  under Other devices) disappeared.
- **Fresh arrival (`acpi`/`none`), then rescan:** **broken.** pci.sys gave the switch
  upstream port bus 2 with subordinate 2 and left its three downstream ports at bus 0.
  One "PCI standard PCI-to-PCI bridge" shows a yellow "!", and nothing below it is
  found. Windows 2000 without ACPI cannot configure a hot-added bridge hierarchy.
- **`restore`, then rescan:** the tree came back with its boot-time configuration
  (`info pci` identical), and the NHI and xHCI returned as new devnodes ("Found New
  Hardware").

So **`restore` is the mode for both legacy images**. `acpi` needs an ACPI-mode guest.
Windows 2000 with the ACPI HAL was not tried: switching the existing image's HAL is
unsupported, and xhci98 does not run that way.

### Linux (Kubuntu live 26.04, i440FX, WHPX), `root-hotplug=acpi`

- `acpiphp` registers slot 6.
- **Surprise removal:** the xHCI and NHI drivers are removed and buses 02-05 are
  released. `00:06.0` stays.
- **Arrival:** "bridge configuration invalid ([bus 00-00]), reconfiguring", buses
  02-05, BARs assigned and `xhci_hcd` bound again.
- **Assist** (`bios-assist=on`, `power-off-delay-ms=11000`, `device_del enc0`): power
  0, `root-gated` and `root-quiesced`. The Bus Check followed `removal-notify-ms`
  later and Linux released buses 02-05. `device_add` of the device router powered the
  controller up and the tree arrived again.
- The thunderbolt driver fails with "cannot enable MSI" both at boot and after an
  arrival. This comes from `msi=off,msix=off` on the NHI in this i440FX setup and is
  unrelated to hot-plug.
