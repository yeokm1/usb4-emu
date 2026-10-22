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

## M3: Linux `tb3-alpine-ridge`, `security=user`, and the legacy SHPC path (2026-10-22)

QEMU `9b5db6e` (`E:\usb4-emu-wt\bin-9b5db6e`), TCG 4 vCPUs, Kubuntu 26.04.1 live
(kernel 7.0.0-30) booted with `-kernel`/`-initrd`, one guest at a time, kit
`E:\usb4-emu-vm\emu-open` (`launch.sh`: `MACHINE=q35|pc`, ports 49020/49021). Five
boots: q35 `security=user` (a1), q35 `security=none` (b1), i440FX `security=user` with
`shpc-autoenable` off (c1) and on (d1), i440FX `security=none` (e1). Data check each
time: 16 MiB O_DIRECT read of the NVMe, md5 `2f58ad9a...` as written at the start.

q35, `usb4-tunnel-port`, `security=user`:

- Boot: firmware CM, security user, `0-1` `authorized` 0, no NVMe in `lspci`.
  `authorized=1`: NVMe at 01:00.0, 16 MiB written and read back O_DIRECT, same md5.
- `x-cable=false` (idle): pciehp link down, card not present, "0-1: device
  disconnected", no NVMe, no router. `x-cable=true`: `0-1` back with `authorized` 0 and
  no NVMe; `authorized=1` brings it back with the same data.
- Force teardown with the deferred stages held (`x-hold-deferred=on`, `tunnel=down`):
  `endpoint` "doomed gen=2 gate=closed"; from the guest, BAR0 through
  `resource0` reads `ffffffff` (was `0f0107ff`), config dword 0 `ffffffff`, a Command
  write reads back `ffff`, a 4 KiB O_DIRECT read never completes (`timeout` 15 s).
  Released: the endpoint is removed, nvme logs the dead controller, nothing in D state.
- In-flight read at teardown: drive throttled to 64 KiB/s read, a 1 MiB O_DIRECT read
  into a page-cache-free buffer file in `/dev/shm` started, `tunnel=surprise` 3 s later:
  `dd` fails (rc 1), the buffer is unchanged (md5 of the fill pattern), no nvme
  interrupt after the teardown.
- Eject the guest ignores (pcieport unbound from 00:05.0, so pciehp never answers):
  `tunnel=eject` gives "ejecting", the endpoint is removed at the 10 s timeout and the
  slot waits for an acknowledgement ("awaiting-ack").
- Reconnect before an ignored eject completes (pciehp unbound, `tunnel=eject` then at
  once `tunnel=up`): the pending endpoint is removed at once, one fresh endpoint (gen
  10) is inserted at the settle timeout, and it is still there after the old eject's
  10 s timeout.
- Replacement after a guest power-off: after `tunnel=surprise` pciehp powers the slot
  off; on `tunnel=up` the replacement comes with an attention-button event, pciehp
  powers the slot on ("Button press: will power on in 5 sec") and the NVMe serves the
  same data.
- `security=none` (b1): `0-1` `authorized` 1 and the NVMe at boot; `device_del` and
  `device_add` of the router: back without any `authorized` write, same data.
- Idle afterwards: 10 s deltas 0 on every thunderbolt, nvme and pciehp vector, no
  warnings, nothing in D state.

Finding (owner question): the model treats a guest power-off of the slot while an
endpoint is present as the guest ejecting it: it removes the endpoint and keeps the
slot empty ("dismissed") until the tunnel goes down and up again, so the guest cannot
power it on again (`echo 1 > .../slots/1/power`: "No such device"; pciehp then reads
the card as not present). Linux does such a power-off in two places: when pciehp is
rebound on a slot whose power control reads off, and when a reconnect comes inside
pciehp's 5 s attention-button window of an eject of the old endpoint (`tunnel=eject`,
then `tunnel=up` at once with pciehp bound): the old eject's power-off lands on the new
endpoint (gen 8) and removes it. Real hardware would keep the card present and powered
off. The exit's "one fresh endpoint" holds with an ignoring guest, not with this Linux
timing. Changing it is in `usb4-tunnel-slot.c`, which the link-retrain branch is
changing; not touched here.

i440FX, `usb4-tunnel-bridge` (no SHPC driver: Linux's shpchp cannot get control
without ACPI OSHP, "Cannot get control of SHPC hotplug", so this guest never touches
SHPC unless told to; the Thunderbolt driver approves, as a ring-level client would):

- `shpc-autoenable` off (c1): after `authorized=1` the endpoint is live but gated
  ("live gen=1 gate=closed"), slot state Disabled (`0x3f`); a PCI rescan finds nothing.
  Polled SHPC writes through the config DWORD window (capability 0x40): Power-only
  (command `0x0101`) leaves it gated, rescan finds nothing, config reads fail; Enabled
  with the power LED on (`0x0106`) opens the gate: rescan finds 01:01.0, same data,
  nvme interrupts delivered.
- Removal with this guest: `x-cable=false`, config reads `ffffffff`, a read times out,
  no D state; the guest removes the PCI device; `x-cable=true`, `authorized=1`: the
  replacement comes at the settle timeout (no acknowledgement from this guest), the
  slot is still Enabled (guest state persisted), a rescan reaches it, same data.
- `shpc-autoenable=on` (d1): `authorized=1`, the slot enables itself (state Enabled),
  a rescan reaches the NVMe, same data.
- Same, reconnect with the guest claiming the empty slot: guest removes the PCI device,
  `x-cable=false`, guest commands Disabled with power LED off and attention LED blink
  (`0x012f`) and clears the presence latch (the acknowledgement); `x-cable=true`,
  `authorized=1`: the replacement is inserted (gen 2) but stays gated ("gate=closed"),
  a rescan finds nothing, slot register still `...2f` (state and both LEDs as the guest
  set them); the guest enables the slot (`0x0106`): reachable, same data.
- Separate run, no acknowledgement (guest commands Disabled, power LED off, attention
  LED on, `0x011f`, and leaves the latch set): the replacement (gen 3) is inserted at the
  settle timeout, stays gated with the slot register unchanged (`...1f`), and becomes
  reachable when the guest enables the slot.
- `security=none` (e1): `0-1` authorised at boot, the NVMe reached after a rescan;
  `device_del`/`device_add` of the router: authorised again without a write, reached
  after a rescan, same data.
- Idle: deltas 0 on every thunderbolt and nvme vector, no warnings, no D state.

## Windows 11, `tb3-alpine-ridge` with the Intel package (WIP, 2026-10-23)

QEMU `ec6776b` (`bin-ec6776b`), `scripts/run-win11-ar.sh` (bridge topology, DSN
`0x5553423445ab0001`), own overlay on the win11tb3 overlay, TCG 4 vCPUs, Intel DCH
1.41.1379.0 installed with `pnputil` (published `oem1.inf`).

- M3 smoke gate: the NHI binds as "Thunderbolt(TM) Controller - 15BF" (instance
  `...ŭ3423445AB000120`, from the DSN), status OK; the driver sends driver ready
  (`0x03`), boot ACL (`0x18`) and get route; System log `nhi` 9001 "driver is loaded and
  initialized connection to HW", driver 1.41.1379.0, NVM version Unknown, and 9002
  "Thunderbolt device is connected", TS3 Plus, CalDigit, Inc., NVM version Invalid, plus
  9006 "An error was detected" entries (codes 0x19F, 0x1A9, 0x20D, 0xEB, 0x22F, 0x12B,
  0xCE; meaning unknown; the NVM versions need the DMA port, R20). Before QEMU `ec6776b`
  the driver's MSI-X handling (no auto-clear; clears through 0x3780c) met an interrupt
  storm, fixed there.
- `security=user` needs the Thunderbolt Control Center to approve (not in the image); the
  runs below use `security=none`.
- M5 (security=none): NVMe in Device Manager (error 0), NTFS T:, 32 MiB file, SHA-256
  `914E8937...`; `x-cable=false`: 9003, disk gone; `x-cable=true`: 9002, disk back,
  same hash.
- M6, each with a cable cycle and a 20 s idle window (NHI 0, NVMe 0 interrupts): device
  connected event dropped with the router pulled, and seen with the router pulled:
  nothing stale; the first route-1 config reply dropped (resent), 3 s late, duplicated;
  the get-route reply dropped, 12 s late: router, NVMe and hash back each time. Unplug
  during a raw 1 MiB read held by the harness (token 89307): "Disk 1 has been surprise
  removed", 9003, the reader process ends; replug: all back, same hash.
- Owed: guest reboot leg, M7 Windows legs, Windows 11 S3 (virtio-win display driver).

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
is not captured.

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
| `tb3-alpine-ridge`, one S3 | Unchanged outcome: the endpoint is held for the retrain at the wakeup reset, but the emulated ICM does not rebuild the tunnel (the router comes back unapproved, "runtime resuming timed out", "device disconnected"); pciehp turns the slot off and the guest slot command rule removes the endpoint. The NVMe needs a new authorisation, as before |

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
