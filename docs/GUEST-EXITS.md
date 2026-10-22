# Guest exit runs for M6 (faults) and M7 (USB3 tunnel)

The guest half of the roadmap M6 and M7 exits: the fault stimuli of [FAULTS.md](FAULTS.md)
and the USB3 tunnel of [USB3-TUNNEL.md](USB3-TUNNEL.md), driven from QMP against
unmodified guests (Linux on both profiles, Windows 11 on the generic one), with the guest's own view read back after each leg. Run 2026-10-22.

## Setup

- QEMU: `E:\usb4-emu-wt\bin-c8d878e\qemu-system-x86_64.exe` (QEMU `c8d878e`, the build
  of usb4-emu `dcbdbe1`: fault injection and USB3 tunnel), SHA-256 `1de3f21a...0813da8`.
- Host: TCG (`-accel tcg,thread=multi`), 4 vCPUs, other agents' guests running alongside
  (CPU load 80-97 %). No timing is read from these runs.
- Linux: the Kubuntu 26.04.1 live ISO of [LINUX-TEST.md](LINUX-TEST.md) (kernel
  7.0.0-30-generic, stock `thunderbolt`, `thunderbolt.dyndbg=+p`), booted with
  `-kernel/-initrd`, q35, 3 GB, serial console. Kit `E:\usb4-emu-vms\gx` (`launch.sh`,
  `lib.sh`, `guest-irq.sh`), the same device lines as `scripts/run-linux.sh` plus, on
  `usb4-generic`, the USB3 tunnel lines of `scripts/run-cm-test.sh USB3=1`:

  ```
  -device usb4-tunnel-port,id=tp0,bus=pcie.0,addr=5.0,chassis=1,slot=1
  -device qemu-xhci,id=u4x,bus=pcie.0,addr=7.0
  -device usb-storage,id=ustor0,bus=u4x.0,port=1,drive=ustor,serial=USB3EMU01
  -device usb4-host,id=u4,bus=pcie.0,addr=4.0,tunnel-port=tp0,profile=usb4-generic,usb3-xhci=u4x,usb3-port1=1
  -device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,usb3-dev=ustor0
  ```

  `tb3-alpine-ridge`: `profile=tb3-alpine-ridge` on the host, `dialect=tb3` on the
  router, no xHCI lines (a TB3 router has no USB3 adapter).
- After every leg the guest is read for: `/sys/bus/thunderbolt/devices` and each
  router's `authorized`, `lsusb`, `lsblk` (serials `USB4EMU01` = the NVMe behind the
  PCIe tunnel, `USB3EMU01` = the USB disk behind the USB3 tunnel), `lspci` for the NVMe
  function, `/proc/interrupts` for the thunderbolt, nvme, xhci and PCIe port vectors
  sampled twice 10 s apart while idle ("stuck" = a count still moving), `dmesg` for
  `nobody cared`, hung tasks, `BUG:` and `WARNING:`, and `ps` for tasks left in D state.
  "No stale devices" means none of the router, the NVMe function, `nvme0n1`, the USB
  device or `sda` is left after the unplug, and each is back (the disks with the same
  SHA-256 of the first 32 MiB) after the recovery.

## Linux, `usb4-generic` (software CM)

Baseline: "using software connection manager", `0-1` QEMU USB4 NVMe Enclosure. The
CM builds the USB3 tunnel (`0:8 <-> 1:4 (USB3): activating`) during enumeration, before
any authorisation; `usb 2-1: new SuperSpeed USB device ... SerialNumber: USB3EMU01` follows
it (7.20 s, after the path activation at 6.91 s), and the model's trace has the device
detached from the xHCI until then. `x-usb3-tunnel` `up reason=up ups=2 downs=1
attached=ustor0:1` (the boot-time down is Linux's lane-1 unplug noted in LINUX-TEST.md).
`authorized=1` brings `nvme0n1`.

### M7: USB3 tunnel

| Leg | Result |
|---|---|
| 32 MiB O_DIRECT write to `sda`, read back | SHA-256 match |
| `x-cable=false` | "0:1: switch unplugged", USB3 tunnel deactivated, `usb 2-1: USB disconnect`, `sda` gone, `lsusb` empty, `0-1` and `nvme0n1` gone; `x-usb3-tunnel` `down reason=surprise ... attached=ustor0:0` |
| `x-cable=true` | router re-enumerated, USB3 tunnel rebuilt, USB device back (new device number), `sda` reads back the same SHA-256; re-authorised NVMe back |
| `x-cable=false` with a 64 KiB O_DIRECT write loop to `sda` running | `dd` ends with "Input/output error" (rc 1), no task in D state, `sda` gone; replug brings it back |
| S3 (`echo mem > /sys/power/state`, `system_wakeup` over QMP), twice | USB relation kept: Linux restarts the USB3 tunnel on resume (`tunnels restarted`), `usb 2-1: reset SuperSpeed USB device number 4` (the same device, not a new one), `sda` reads back the same data. **The NVMe is lost**: see "S3 and the PCIe tunnel" below |

### M6: faults

| Leg | Stimulus | Result |
|---|---|---|
| Unplug during enumeration | `x-cable=false`; rule `pdf=read route=1 act=drop+unplug dev=enc0`; `x-cable=true` | first read of the router dropped, router pulled: "0:1: hotplug: no switch found", no `0-1`, no USB device, no NVMe; rule cleared, replug: all back, data match |
| Unplug during NVMe I/O | tunnel port harness `x-faults=at=fetch op=read act=hold`; `dd` O_DIRECT read of `nvme0n1`; `x-release` lists the held token (17129, `dd` in D state); `x-cable=false` | pciehp Link Down / Card not present, "0:1: switch unplugged", `dd` ends with "Input/output error", nothing left in D state, NVMe and USB gone; replug and authorise: back, data match |
| Dropped reply, once | `pdf=read route=1 nth=4 act=drop` on a replug | Linux's control channel times out (100 ms) and retries: the router enumerates normally, USB3 tunnel up |
| Dropped replies, every one | `pdf=read route=1 nth=4 act=drop repeat=on` | "1: timeout reading config space 2 from 0x1b" four times, then "0:1: hotplug: no switch found": no `0-1`, no USB3 tunnel; rule cleared, cable cycled: all back |
| Stale reply | `pdf=read route=1 nth=4 act=delay delay=500` | the retry is answered, the late copy arrives 502 ms after the read (`usb4_fault_deliver ... delayed`) and Linux drops it silently; router, USB device present |
| Stale duplicate | `pdf=read route=1 nth=6 act=dup delay=30` | duplicate ignored; router, USB device present |
| Guest reboot | `systemctl reboot` with the NVMe authorised and the USB disk attached | after reboot: software CM, `0-1` enumerated, USB3 tunnel rebuilt, `sda` present, `authorized=0` until written, then `nvme0n1`; both disks read back the same data |

Every leg: idle interrupt deltas `+0` on all thunderbolt, nvme and xhci vectors,
`warnings=0`, no D-state tasks.

## Linux, `tb3-alpine-ridge` (firmware CM)

Baseline: "using firmware connection manager", "security level set to user", host
8086:15c0, device 8086:15d3, `0-1` `authorized=0`; authorising gives `nvme0n1`.

| Leg | Stimulus | Result |
|---|---|---|
| Unplug during enumeration, event lost | `pdf=icm-event code=3 act=drop+unplug dev=enc0` on a replug | "no switch exists at 1.1, ignoring": no `0-1`, nothing stale |
| Unplug during enumeration, event seen | `pdf=icm-event code=3 act=unplug dev=enc0` | "failed to find route string for switch at 1.1", "no switch exists at 1.1": no `0-1` |
| Unplug during approval | `pdf=icm-resp code=4 act=drop+unplug dev=enc0`, then `echo 1 > authorized` | write fails with EIO, "PCIe tunnel creation failed", "0-1: device disconnected": no `0-1`, no NVMe |
| Dropped approve reply | `pdf=icm-resp code=4 act=drop` | Linux resends the approve (the rule matched twice, fired once); `authorized` write succeeds, pciehp card present, `nvme0n1` |
| Stale approve reply | `pdf=icm-resp code=4 act=delay delay=12000` (past the 10 s approve timeout) | approve retried and answered; the late reply is ignored; `nvme0n1` |
| Stale duplicate | `pdf=icm-resp code=4 act=dup delay=50` | ignored; `nvme0n1` |
| Unplug during NVMe I/O | harness hold as above (token 411, `dd` in D state), `x-cable=false` | pciehp Link Down, "0-1: device disconnected", `dd` "Input/output error", nothing in D state; replug, authorise: back, data match |
| Guest reboot, twice | `systemctl reboot` (once with the NVMe absent, once authorised and present) | firmware CM, `0-1` announced `authorized=0`, authorising brings the NVMe with the same data |

Every leg: idle interrupt deltas `+0`, `warnings=0`, no D-state tasks. A replug costs
about 3100 interrupts on each of the two ring vectors at once (the DROM read by EEPROM
bit-bang through the TB3 router's config space) and then stops; that is a burst, not a
stuck interrupt.

## Windows 11, `usb4-generic` (built-in CM)

Kit `E:\usb4-emu-vms\gx-w11`: a new overlay on the `win11tb3` overlay (test-signing on,
read-only backing), OVMF, TCG, 4 vCPUs, 4 GB (Windows 11's minimum), the guest agent of
`scripts/guest.py` on 127.0.0.1:48782, one USB4 port (`tp0`), the same USB3 lines as the
Linux kit. A fresh 4 GB NVMe disk and the USB disk were formatted NTFS (`N:`, `U:`) with a
32 MiB test file each (SHA-256 `0523319BDDABE255...`). Each leg reads back, through the
agent: the `Win32_PnPEntity` entries of the router (`USB4\VID_46F4&PID_0004`), the NVMe
function and disk, the USB device and `USBSTOR` disk with their `ConfigManagerErrorCode`,
`Win32_DiskDrive`, and the two hashes. Interrupts are read on the QEMU side: the
`usb4_host_irq_notify`, `pci_nvme_irq_msix` and `usb_xhci_irq_*` traces enabled for a
20-30 s idle window. The guest ran Defender and servicing in the background the whole
time (guest CPU 83-100 %, host 90 %), so a state read took about a minute and the first
read after the first unplug (with `Get-Disk`) about 8 minutes; nothing hung.

Baseline: "USB4(TM) Host Router (Microsoft)", "USB4 Root Router (1.0)", "USB4 Router
(1.0), QEMU - USB4 NVMe Enclosure", the NVMe and "QEMU QEMU HARDDISK USB Device"
(`USB3EMU01`), all status OK; `x-usb3-tunnel` `up reason=up ups=1 downs=0
attached=ustor0:1`. (`ACPI\QEMU0002` without a driver is unrelated and was there before.)

| Leg | Stimulus | Result |
|---|---|---|
| M7 cable pull and replug | `x-cable=false`, then `true` | tunnel `down reason=surprise ... attached=ustor0:0`, then `up`, USB disk and NVMe back with both hashes |
| Unplug during enumeration | rule `pdf=read route=1 act=drop+unplug dev=enc0` on a replug | no router, NVMe or USB entry present, only the SATA disk; rule cleared, replug: all back, hashes match |
| Unplug during NVMe I/O | harness `at=fetch op=read act=hold`, a raw 1 MiB read of `\\.\PhysicalDrive2` at 2 GiB, `x-cable=false` within a second of the token (49536) appearing | System log: "Disk 2 has been surprise removed", stornvme 11 and 129 (controller error, reset); the reader process ends, nothing present; replug: all back, hashes match |
| Dropped reply | `pdf=read route=1 nth=4 act=drop` | enumeration completes, tunnel up, all present, hashes match |
| Late reply | `pdf=read route=1 nth=4 act=delay delay=3000` | the same |
| Stale duplicate | `pdf=read route=1 nth=6 act=dup delay=30` | the same |
| Guest reboot | `shutdown /r` | agent back, router, NVMe and USB disk present, error code 0, hashes match, tunnel `ups=10 downs=9` |

Idle interrupt windows after every leg: NHI 0, xHCI 0, NVMe 0-36 (Windows' own
background I/O on the new volumes; a stuck MSI-X would be thousands).

Harness note: held without a cable pull, a read is timed out by stornvme (event 129,
"Reset to device") and the controller reset discards the held command (harness
`rule0=2/1 held=0`), so the cable has to go within seconds of the hold.

Not run on Windows 11:

- `tb3-alpine-ridge`: needs the Intel Thunderbolt driver package bound to the Alpine
  Ridge NHI (the open M3 smoke gate); the Windows 11 overlays in the kits run the built-in
  CM on the generic profile.
- Suspend and resume: `powercfg /a` reports S3 "disabled by an internal system
  component: Graphics" (the basic display adapter on `-vga std`), no S0 low power idle,
  hibernation off. A display device with a sleep-capable driver would be needed first.

## S3 and the PCIe tunnel (finding, not part of the exits)

On `usb4-generic` the NVMe does not survive S3, though the USB disk does. On resume
Linux restarts every tunnel: `tb_tunnel_restart()` deactivates each path before it
activates it again ("deactivating PCIe Down path from 0:6 to 1:3", then "activating
..."). The model takes the PCIe tunnel down on that first write (`admin-down`), gates
and surprise-removes the endpoint (generation 5), and when the paths are back it waits
for the guest to acknowledge the empty slot before it inserts a new endpoint (generation
6), as ARCHITECTURE.md §4.4 requires for a hot plug. Linux's pciehp, resuming in the
same 100 ms, sees "Link Down" and "Card not present", removes `01:00.0`, then powers
the slot off, which the model honours (`guest turned the slot off, gen 6: remove`,
`dismissed=1`). The slot stays empty until the router is deauthorised and authorised
again (`echo 0` then `echo 1`), which brings the same disk back with its data. The USB3
side is unaffected because a USB device detached and re-attached on the same xHCI port
is reset, not re-created, by the USB core.

On real hardware the same NVMe retrains its link behind the restored tunnel and keeps
its `pci_dev`. Fixing it needs a model decision (keep the endpoint across a tunnel
bounce of the same router, or insert without waiting for the empty-slot acknowledge
when the router never left), which is an owner question; it is recorded here and in
the roadmap and not changed.

On `tb3-alpine-ridge` S3 (no exit requires it) the PCIe tunnel goes down at the wakeup
with reason `surprise` (the model's trace), the firmware CM re-announces the router, Linux logs "0-1: runtime resuming timed out" and "0-1:
device disconnected", and the router is announced again unapproved (`authorized=0`),
so the NVMe needs a new authorisation. Real Alpine Ridge firmware behaviour across S3
is not captured.
