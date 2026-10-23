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
| S3 (`echo mem > /sys/power/state`, `system_wakeup` over QMP), twice | USB relation kept: Linux restarts the USB3 tunnel on resume (`tunnels restarted`), `usb 2-1: reset SuperSpeed USB device number 4` (the same device, not a new one), `sda` reads back the same data. **The NVMe is lost** (QEMU `c8d878e`; kept since the link retrain): see "S3 and the PCIe tunnel" below |

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

## S3 and the PCIe tunnel (finding, not part of the exits; resolved by the link retrain)

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
its `pci_dev`. The owner decided (2026-10-22) that the model keeps the endpoint across
such a bounce: the link retrain of ARCHITECTURE.md 4.4, below.

On `tb3-alpine-ridge` S3 (no exit requires it) the PCIe tunnel goes down at the wakeup
with reason `surprise` (the model's trace), the firmware CM re-announces the router, Linux logs "0-1: runtime resuming timed out" and "0-1:
device disconnected", and the router is announced again unapproved (`authorized=0`),
so the NVMe needs a new authorisation. Real Alpine Ridge firmware behaviour across S3
was not captured then.

**Captured 2026-10-23, model changed (R34).** On the P14s the firmware keeps the tunnel:
the ORICO's NVMe survived s2idle and S3, and after each resume the firmware
re-announced it approved (connection id 0, boot bit clear); after S3 it had rebuilt the
tunnel before Linux's driver ready (captures/P14S-SUSPEND-2026-10-23.md §10). The
emulated ICM now does the same for devices saved by mailbox 0x05: it tunnels them again
within the wakeup reset, so the endpoint never sees the tunnel go down (qtest
`/usb4-icm/save-devices`).

Linux guest leg with R34 (2026-10-23): QEMU efa24f1 (binary sha256 `f404d37af36cd8f7...`),
kit `E:\usb4-emu-vms\ps` (the link-retrain kit's launcher with `PROFILE=tb3-alpine-ridge`,
QMP 49100, serial 49101), Kubuntu 26.04.1 live, kernel 7.0.0-30, q35, TCG, 4 vCPUs; TB3
device router with the NVMe (`serial=USB4EMU01`), security `user`, pre-boot off. The
device was authorised through sysfs and a fresh 32 MiB random pattern written to
`nvme0n1` with O_DIRECT (SHA-256 prefix `fb3ac26bf1a0ab74`); each check reads it back
with O_DIRECT and records the `nvme0` name, `0-1/authorized` and the inode of
`/sys/devices/pci0000:00/0000:00:05.0/0000:01:00.0/config` (31872).

| Leg | Result |
|---|---|
| s2idle (`rtcwake -m freeze -s 20`) | Linux sent mailbox 0x05 then 0x07; on resume, driver ready and the device announced **approved, connection id 0** (model trace). **The NVMe is kept**: same `nvme0`, same config inode, `authorized` 1 (no re-authorisation), the pattern reads back; no pciehp message; the nvme driver re-initialised its queues. Quirk: the RTC alarm did not wake the guest from s2idle under QEMU (it stayed frozen with QEMU status `running`, and a key press did not wake it either); the ACPI power button (`system_powerdown`) did, and the guest did not power off |
| S3 (`echo mem`, QEMU `suspended`, `system_wakeup`) | 0x05, 0x07; at the wakeup reset `ICM port 1: saved device restored`, then driver ready and the device announced approved, id 0. **The NVMe is kept**: same `nvme0`, inode, `authorized` 1, pattern; `PM: suspend entry (deep)`, "Waking up from system sleep state S3"; no pciehp message; one tunnel transition in the whole run (the approve), none at the S3 |
| Control: cold `system_reset` | The tunnel goes down (`surprise`) and the endpoint is removed (`none gen=1 gate=closed`); after the reboot the device is announced unapproved (id 2), `authorized` 0, no NVMe: a cold reset is a power-on without pre-boot, as before |

### With the link retrain (2026-10-22)

QEMU tree of branch `link-retrain` (usb4-emu-wt), `usb4-tunnel-port` with the default
`link-retrain=on`; the Linux kit above (Kubuntu 26.04.1 live, kernel 7.0.0-30, q35, TCG,
4 vCPUs, `usb4-generic` with the USB3 tunnel, host loaded by other agents' guests and
builds). A fresh 32 MiB random pattern written to `nvme0n1` with O_DIRECT before the
first suspend; each check reads it back with O_DIRECT, with `sda` (buffered), the
`nvme0` name and the inode of `/sys/bus/pci/devices/0000:01:00.0/config` (a new
`pci_dev` gets a new inode).

| Leg | Result |
|---|---|
| S3 (`mem`, QEMU status `suspended`, `system_wakeup`), four boots | **The NVMe is kept**: same `nvme0`, same config inode, the pattern reads back (SHA-256 prefixes `c7d72d03`, `5c21b0f7`, `58323035`; the last written in the third boot and read again in the fourth), `sda` too; pciehp logs nothing, the nvme driver re-initialises its queues ("4/0/0 default/read/poll queues"). Model trace: the wakeup reset takes the tunnel down (`surprise`), `link retrain of gen 1: link down`, `cutoff`, `held`; Linux restores the routers and the paths (`tunnels restarted`), the tunnel comes up, `retrained`, gate open, generation 1 throughout |
| Later `echo mem` in the same boot | QEMU never reaches `suspended` and resets nothing (no `usb4_fabric_reset`), yet Linux runs its whole resume path ("Low-level resume complete", `tunnels restarted`): the PCIe paths bounce on routers that kept their configuration, `admin-down` then `up`, which the model also takes as a retrain. NVMe kept in all 6 such cycles that were read back. Twice, in two other boots, the guest's user space stopped answering after such a cycle (serial getty and tty1 silent, all vCPUs idle, the kernel still printing); not seen in the boot with the full kernel log (five cycles), not attributed. Why QEMU skips the second suspend is not investigated (it predates this change: the earlier "S3 twice" leg did not check the run state) |
| `x-cable=false` after the cycles (a real unplug) | pciehp "Link Down", "Card not present", `nvme0` gone, the endpoint removed (`removed`, generation 1); `x-cable=true` and authorisation bring a fresh endpoint (generation 2) with the same pattern |
| `tb3-alpine-ridge`, one S3 (before R34, 2026-10-23) | Unchanged outcome: the endpoint is held for the retrain at the wakeup reset, but the emulated ICM does not rebuild the tunnel (the router comes back unapproved, "runtime resuming timed out", "device disconnected"); pciehp turns the slot off and the guest slot command rule removes the endpoint. The NVMe needs a new authorisation, as before |

#### Windows 7 with xHCI98's connection manager (owner's check of the defaults, 2026-10-23)

Same binary; Windows 7 SP1 x86 (xhci98's `win7.img` on an overlay, `msahci` enabled for
q35), q35, TCG, 2 vCPUs, `usb4-tunnel-port` with the default `link-retrain=on`. The
enclosure is the ASM2464 model with a FAT volume (`E:`, "ORICO"); each check copies a
1 MiB file to it and compares it (`fc /b`).

| Leg | Result |
|---|---|
| xHCI98 3.1.0.0 (test cut of kit p43-45), software CM on `usb4-generic` `host-model=amd`, enclosure plugged over QMP | Approved, PCIe up, `E:` on Stor98, data compares clean |
| XHCITR Safely Remove (tray, unelevated) | Windows stops the device and turns the slot off; the guest slot command rule removes the endpoint (`guest turned the slot off ... remove`, generation 1, `dismissed`). The CM does not tear the path down (the box says it has not confirmed the tunnel closed, the known unelevated-XHCITR case); no retrain is involved |
| `x-cable=false`, `x-cable=true` | Surprise down, then a fresh endpoint (generation 2); `E:` back with its files, a new write compares clean |
| `XHCIINST /eject 1` (elevated) | Windows stops it and turns the slot off; the endpoint is removed as above; then the CM tears the path down (`admin-down`) on the empty slot: nothing to retrain. "The PCIe tunnel was closed", exit 0. Replug: generation 3, data clean |
| The NHI disabled and enabled again (`SetupDi` property change) with the endpoint live | The CM keeps the tunnel up across it (no path teardown, `found at start`); the endpoint stays live, generation 3, data clean |
| `tb3-alpine-ridge` (the AR PCIe tree on q35, `usb4-tb3-tunnel-dsp`), xHCI98 3.1.0.0 release, XHCITR Safely Remove | As on the generic host: Windows turns the slot off and the endpoint is removed; the firmware CM tears nothing down |

So on Windows 7 the retrain default changes nothing for xHCI98's eject: Windows' pciehp
turns the slot off before the CM's teardown, and the guest slot command rule removes the
endpoint as before. xHCI98's CM made no path teardown with the endpoint still live in
these legs, so the retrain path itself was not reached from Windows 7.
