# Handoff to the xhci98 project

Read this first if you are an agent or developer from
`D:\OneDrive\git-projects\xhci98` who wants to build USB4 / Thunderbolt support for
Windows 98 SE and Windows 2000 against this emulator. Everything below is on this
machine; paths are relative to `D:\OneDrive\git-projects\usb4-emu`.

## 1. What this repository gives you

A QEMU device model of USB4 and Thunderbolt 3 hosts that real, unmodified connection
managers accept (Windows 11's built-in CM, Linux's software CM and firmware-CM client), so
a new legacy-Windows driver can be developed and debugged without hardware:

- **USB4 host (`profile=usb4-generic`)**: software-CM target. Default `host-model=minimal`,
  `intel-adl` (a real Alder Lake host reproduced from a capture, 95.6% read
  conformance) or `asm4242` (the ASMedia ASM4242 of AM5 X870 boards behind its own PCIe
  switch, with its published IDs and vendor quirks; public sources only, nothing
  captured, [USB4-HOSTS.md](USB4-HOSTS.md) §5). Device routers (`usb4-device`) with an
  NVMe behind a PCIe tunnel, docks (PCIe switch + NVMe + NIC + xHCI), daisy chains, a
  second port, USB3 tunnelling, hot-plug, and an optional pre-OS firmware CM
  (`preos-cm=on`). `device-model=asm2464` is a **real** device router: the ASMedia
  ASM2464PD of an ORICO USB4 NVMe enclosure, reproduced from a capture (97.1% replay
  match, [captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md)).
- **Thunderbolt 3 host (`profile=tb3-alpine-ridge`)**: the maintainer's ThinkPad P14s
  Gen 1 controller with its emulated firmware CM (ICM), reproduced from captures, with
  every observed BIOS setting (`BIOS=` / `DEVICE_AT_BOOT=`).
- **Legacy machine support**: i440FX with `usb4-tunnel-bridge` (PCI-only bridge with
  SHPC, `shpc-autoenable=on`), INTx and pure polling, 32-bit DMA. q35 uses
  `usb4-tunnel-port`.
- **`tools/usb4cm/`**: a working C89, OS-free, polling USB4 software CM core (GPL-2.0-only) with a
  DOS front-end built like `xhciqual` (Open Watcom + DOS/32A). In the Windows 98 VM it
  brings up the tunnel and Windows 98 then mounts the NVMe. Lift it.

## 2. Primary and secondary targets

1. **Primary: a USB4 software CM** (real USB4 machines, all vendors). Contract: USB4
   Specification 2.0 and CM Guide 2.0 (`docs/references/usb-if/`), plus this repo's
   [ARCHITECTURE.md](ARCHITECTURE.md) §4-§5 and §7 and [WINDOWS-DEBUG.md](WINDOWS-DEBUG.md)
   ("What the Windows CM required of the model": real CMs expect USB3 Down adapters, etc.).
   Start from `tools/usb4cm/core`. Test on `usb4-generic` with all three host models and
   with `preos-cm=on`. `asm4242` is the CSM-capable desktop case: run it on i440FX with
   the `usb4-asm-*` stand-ins and `usb4-asm-tunnel-bridge` (`shpc-autoenable=on`), and
   keep its quirks on: never wait unboundedly for a path's Pending bit, do not enable E2E
   flow control on data rings, clamp path credits to 7 bits, and find the tunnel ports
   from the host's PCIe Downstream Entry Mapping or the switch, not by device number.
2. **Secondary: a Thunderbolt 3 ICM client** (the P14s demo). Contract:
   [ICM-PROTOCOL.md](ICM-PROTOCOL.md) (requirements R1-R33, Windows 98 BIOS behaviour in
   §12, a USB4 device on this host in §13). With pre-boot on and the device attached at power-on, no Thunderbolt driver is
   needed at all.

The decision table per platform and BIOS setting is [PLATFORM-MATRIX.md](PLATFORM-MATRIX.md).

**Suggested order** (maintainer, 2026-10-14): start with the Thunderbolt 3 ICM client
plus re-enumeration (§6a), because it can be proven on the real P14s; then the USB4
software CM against `usb4-generic` and the Framework capture; then real USB4 devices.
The ORICO capture exists since 2026-10-15: test the USB4 CM against
`device-model=asm2464` on `host-model=intel-adl` too (`DEVICE_MODEL=asm2464
HOST_OPTS=,host-model=intel-adl scripts/run-linux.sh`, or the same `usb4-device`
property in your own command line).

Rough size: host interface core 1.5-2k lines (the `tools/usb4cm/core` code is ~1.3k),
TB3 ICM client 1-2k, USB4 software CM 4-7k, re-enumeration 0.5-1k plus INFs. Little
changes inside xhci98's existing xHCI code: USB3 tunnels appear as ordinary connects on
the host's own xHCI root ports (test with `USB3=1`), and Thunderbolt 3 docks carry their
own xHCI controller behind a PCIe tunnel, which xhci98 itself would drive.

**Write the CM so it does not depend on this model's exact device router.** The real
ASM2464 shows why ([captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md)): its TMU
capability is at `0xc0`, not after ROUTER_CS_26, and three vendor-specific capabilities
follow it; its lane adapters have Max HopID 27 and 66 buffers; Buffer Allocation reports
only PCIe; NVM Sector Size fails with status 2 (treat as "no NVM"); Router Ready rises a
few ms after Enumerated; adapter 4 exists but the DROM marks it unused; its DROM is the
TBT3-compatible revision 1, not the USB4 format; and after a Downstream Port Reset it
takes about 0.6 s to reconnect. So: treat every router operation as possibly "not
supported" or failing and handle that status, discover capabilities and adapter numbers
from the chains, the DROM and the PCIe Downstream Entry Mapping instead of assuming them,
poll RR, CV/CR and other completions with timeouts rather than fixed delays, wait for the
re-plug after a port reset, and test with both device models, all host models and
`preos-cm=on`.

**Which real machines can run the legacy OSes.** Windows 98-XP need a legacy BIOS
(CSM), and Windows 7 needs CSM for boot video unless UEFI workarounds are used. Most
USB4 laptops are UEFI-only (Class 3): the Framework 13 (12th gen) has no CSM, so it is a
reference capture for the software-CM model, not a run target. Realistic real-hardware
targets are Thunderbolt 3 machines with CSM (like the P14s) and desktop boards that still
offer CSM with discrete Thunderbolt 4/5 or ASMedia USB4 controllers. What a USB4/TB4
controller's firmware does for a CSM-booted OS (firmware CM or not) is unknown until such
a machine is captured. See [CONTROLLER-CATALOG.md](CONTROLLER-CATALOG.md).

**Other Thunderbolt 3 hosts.** Any Thunderbolt 3 device works through the same ICM
client (the firmware CM handles device routers). Other Alpine Ridge hosts need only their
platform's force-power method and BIOS quirks; Titan Ridge changes some ICM messages
(route string instead of link/depth plus get route, no connection key, four-word driver
ready). It is modelled from the Linux client as `profile=tb3-titan-ridge`
([ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md)) but not captured (the `tools/p14s-capture`
tools would capture one).

## 3. Licence (applies to your driver too)

Both projects are GPL-2.0-only: this repo was relicensed from MIT on 2026-10-15 to match
xhci98. xhci98 may adapt code directly from this repo (`tools/usb4cm` included) and from
Linux `drivers/thunderbolt` (GPL-2.0-only), as well as FreeBSD `sys/dev/thunderbolt`
(BSD-2) and Intel tbtools data (MIT). Keep the notices of whatever you adapt: the
copyright lines of the source file, its SPDX tag, and an entry in xhci98's provenance
record naming the source file and pinned commit (this repo's pins are in
[REFERENCES.md](REFERENCES.md)). See [AGENTS.md](../AGENTS.md) "Licence rules".

`docs/ICM-PROTOCOL.md` was written clean-room (from hardware captures, reading Linux for
behaviour only) under the old rule; it remains accurate and is still the best place to
start. The observed/inferred tags in it and in the other docs are about accuracy, not
licensing: behaviour seen only in Linux is a hypothesis until a capture confirms it.

Do not move code from this repo or xhci98 into nvme98, which is BSD-3-Clause.

## 4. Build and run

QEMU fork: `src/qemu` (branch `usb4-emu`, QEMU v11.1.2), already built at
`src/qemu/build/qemu-system-x86_64.exe`. Rebuild: `scripts/msys2-shell.sh
"$PWD/src/build-qemu.sh"`. Recreate from scratch: `src/setup-qemu.sh` (applies
`src/patches/0001-usb4-emu.patch`). Toolchain: `toolchain/msys64`
([TOOLCHAIN.md](TOOLCHAIN.md)). Copy the exe before running a VM so rebuilds are not
blocked (the launchers do this).

| Test bed | Command | Notes |
|---|---|---|
| Windows 98 SE, i440FX | `scripts/run-win98.sh` | TCG only (WHPX aborts with any PCI bridge); `-cpu pentium3,-apic`; base snapshot `base-install` in `vms/win98/win98.qcow2`. Make your own overlay (`qemu-img create -b`) instead of changing it. Knobs: `PROFILE`, `BIOS`, `DEVICE_AT_BOOT`, `TUNNEL_UP_AFTER`, `FORCE_TUNNEL`, `NVME` (see the script header and [WIN98-TEST.md](WIN98-TEST.md)) |
| Windows 98 + reference CM | see [tools/usb4cm/README.md](../tools/usb4cm/README.md) "Validation" | `vms/win98-refcm` holds the working overlay |
| Windows 11 (built-in CM) | `scripts/run-cm-test.sh` (+ `DOCK=1`, `USB3=1`, `CHAIN=1`, `PORT2=0`) | Guest needs `bcdedit /set testsigning on` once per overlay ([WINDOWS-DEBUG.md](WINDOWS-DEBUG.md)) |
| Linux (Kubuntu live) | `scripts/run-linux.sh` (`PROFILE`, `BIOS`, `TOPOLOGY`) | [LINUX-TEST.md](LINUX-TEST.md) |
| Windows 2000, XP x64, Windows 7 x64 | local, git-ignored setups in `vms/win2k`, `vms/winxp64`, `vms/win7x64` (each has a `RESULTS-*.md` with its launch line); `tools/reenum-test/run2k.sh` for Windows 2000 | Windows 2000 needs TCG; the Windows 2000 image uses a Dvorak layout; XP x64 does not boot on q35 |

Minimal device lines (i440FX, generic profile):

```
-global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
-device usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1,shpc-autoenable=on,msi=off
-device usb4-host,id=u4,bus=pci.0,addr=0x4,tunnel-port=tb0,msi=off,msix=off
-drive if=none,id=nvme0,file=nvme.qcow2,format=qcow2
-device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01
-trace usb4_* -D usb4-trace.log
```

Each VM uses its own ports; never stop QEMU processes you did not start (other projects
run QEMU on this machine).

## 5. Debugging your driver

- `-trace 'usb4_*'` decodes every ring 0 control packet in both directions, MMIO accesses
  by register name, router operations, hot-plug events, and why a tunnel is or is not up
  (`usb4_tunnel_inputs`, `usb4_tunnel_path`). It is the fastest way to see what your CM
  got wrong.
- Force or inspect tunnels without a CM: `qom-set /machine/peripheral/<bridge> tunnel
  up|down|eject|surprise`; QMP event `USB4_TUNNEL_ENDPOINT`.
- Compare against a known-good CM: run the same scenario with `tools/usb4cm` (DOS),
  Windows 11 or Linux and diff the traces.

## 6. Known behaviours and gotchas

- **Hang at the logo with a disk at POST: a QEMU TCG bug, fixed in main as of QEMU
  `2a893ea` (branch `usb4-posthang`, 2026-10-16).** SeaBIOS serves INT 13h for an NVMe (pre-boot tunnel or
  `FORCE_TUNNEL`) or a USB Bulk-Only disk (`USB_FALLBACK=bot`) through an SMM
  trampoline. QEMU did not flush its TLB on an SMI from real mode, because no
  paging-related CR0/CR4 bit changes. After the
  Windows 98 logo had been drawn in mode 13h, the SMI handler at 0xa8000 was fetched
  from the VGA frame buffer instead of SMRAM, and the CPU looped at SMM `EIP=0x8000`.
  Whether it hits depends on timing, which is probably why your image did not show it
  (inferred, not traced on your image). With the
  fixed build, Windows 98 boots with a pre-boot NVMe or the ORICO at power-on, and the
  disk works. On an older build, the disk must stay out of SeaBIOS's enumeration at
  POST. That means pre-boot off (no `BIOS=*_ON`, no `FORCE_TUNNEL`), or nothing
  attached at power-on, and no Bulk-Only USB fallback (`USB_FALLBACK=bot`; the default
  UAS disk is skipped by SeaBIOS). Your driver then reaches the disk later: the NVMe
  after a tunnel brought up by your CM or `TUNNEL_UP_AFTER` (forced from QMP), the USB
  disk through xhci98. `TUNNEL_UP_AFTER` does not help with `BIOS=OFF_ON`, because
  there the NVMe is already tunnelled at POST. `-machine smm=off` also avoids the hang,
  but it leaves a disk with no protected-mode driver unusable under Windows.
  `BootGUI=0` and `-boot strict=on` do not help. Details: [WIN98-TEST.md](WIN98-TEST.md), "SMM hang at the boot logo".
- **Windows 98 interrupt routing for hot-added devices** goes through the BIOS `$PIR`
  table, swizzling up to a bus 0 slot. SeaBIOS lists only slots 1-6, so
  `scripts/run-win98.sh` now puts the Thunderbolt 3 root bridge at slot 6 (`ROOT_ADDR`;
  `0x1c` reproduces Code 29 "no IRQ"). **Answered for the real P14s (2026-10-15):** its
  BIOS `$PIR` always lists 00:1c (all four pins) and the tunnel port 04:01, and every
  entry is the standard swizzle, so a tunnel your CM brings up after boot gets an IRQ
  there (link 61, IRQ 10). Do not rely on a device's own `$PIR` entry or its BIOS
  Interrupt Line: both exist only for devices present at POST. See
  [WIN98-TEST.md](WIN98-TEST.md) and
  [captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md) §1.
- **ICM client on an Assist-on P14s** (BIOS Assist on): after the last device leaves,
  expect ICM commands to go unanswered and the whole controller to vanish (registers
  all-ones) within 11-35 s; it does not come back on replug without a platform rescan.
  Time out every command, treat all-ones as removal, and never block on the ICM
  (`ICM-PROTOCOL.md` R32, §13.4). With Assist on, driver-ready reports no RTD3 (flags
  `0x22`).
- **USB4 devices on the Thunderbolt 3 ICM** (e.g. an ASMedia NVMe enclosure): approve
  within about 9 s of the device-connected event. An unapproved USB4 device leaves the
  Thunderbolt link (a device-disconnected event without an unplug) and comes back as a
  USB 3 device on the controller's own xHCI (`8086:15c1`), which xhci98 drives anyway.
  With pre-boot off the device is already a USB disk when the OS starts (observed; that
  it fell back during POST is inferred, the boot trace is empty); with Assist on and
  pre-boot off that xHCI has no resources and the NHI is hidden, so neither path works. The event for such a device differs from a TB3 device (flags `0xa8`, UUID
  words in UID-high-first order, different name block); parse it by field, not by
  comparing with the dock's capture (`ICM-PROTOCOL.md` §13).
  **Modelled on branch `usb4-p14s` (2026-10-15, R33), in main as of `b5936c4`:**
  `usb4-device dialect=usb4,device-model=asm2464` behind `tb3-alpine-ridge` is announced
  in the captured USB4 form, falls back after `usb-fallback-ms` (9385) to a SuperSpeed
  USB disk on the TB xHCI named by the host's `xhci=`, and at power-on with pre-boot off
  is already there before your driver loads (the model switches at power-on; the real timing in POST is not captured). Under Assist with pre-boot off the NHI is hidden and the xHCI has no usable
  BAR, as on the P14s. Launchers: `BIOS=<cell> DEVICE_MODEL=asm2464` on
  `scripts/run-linux.sh` and `scripts/run-win98.sh` (the latter booted with OFF_ON and OFF_OFF on 2026-10-16; see [WIN98-TEST.md](WIN98-TEST.md), "SMM hang at the boot logo").
  The real ORICO is a UAS device (Linux binds `uas`). In main as of QEMU `36f6254` the
  USB disk is UAS on every machine type, i440FX included, with the captured identity
  (`174c:2463`, "ASM246X series"), so `xhciuas.sys` binds it (interface class 08/06/62).
  UAS at SuperSpeed needs bulk streams from your xHCI driver; the TB xHCI works with
  INTx and 32-bit addresses. `usb-fallback=bot` (`USB_FALLBACK=bot` on `run-win98.sh`)
  gives a Bulk-Only disk instead for testing without the UAS driver; QEMU's UAS device
  has no Bulk-Only alternate setting, and whether the real ASM246X has one is not
  captured.
- **Pre-boot does not need the boot ACL** (2026-10-15): with pre-boot on, the firmware
  tunnels every device attached at power-on, and every later announcement carries the
  `boot` bit (link info bit 10), approved or not; do not take `boot` = 1 as "already
  tunnelled", check the approved bit. Modelled (R25; `preboot-acl-only=on` restores the
  old ACL-only model).
- **Timing your client must tolerate** (Alpine Ridge, observed): after driver ready
  the host router may not answer config reads for up to 2.8 s under Assist (0.6-0.8 s
  otherwise) while the firmware announces devices; approve answers after about 0.35-0.4
  s with the tunnel link up before that. Modelled as `first-ready-hold-ms` (auto 2770
  under Assist), `ready-hold-ms`, `approve-link-ms` / `approve-resp-ms` (both 0 by
  default; `run-linux.sh` sets 89 / 383 with `DEVICE_MODEL=asm2464` in BIOS mode).
- **Register values at power-on** (R2): outbound mailbox `0x800003f0` (low nibble 5
  only after the NHI's first D3), DMA misc `0x01000012` (auto-clear bit 2 clear until
  you set it). Do not test for `0x800003f5`; test bits 11:8 for the mode.
- **After a tunnel goes down, the endpoint's registers read all-ones** (as a real link
  drop does): `CSTS == 0xFFFFFFFF` is the removal signal NVMe drivers check.
- The Alpine Ridge NHI advertises INTA# but no captured OS used INTx; verify before
  relying on it.
- Assist-on ACPI hot-plug notifications and the controller leaving are in main as of
  QEMU `25fd4eb` (§6d); without `root-hotplug=acpi` a guest must rescan.
- A tunnel forced up with `qom-set ... tunnel up` (or `x-force-tunnel=on`) bypasses the
  CM, so `device_del` of the device router does not take it down. That is by design.
- The tunnel bridges and `usb4-host` are not migratable: `savevm`/`loadvm` are refused
  (offline `qemu-img snapshot` works).

## 6a. Re-enumeration: what your CM must do after a tunnel changes

Measured in [REENUM-EXPERIMENT.md](REENUM-EXPERIMENT.md) (code in `tools/reenum-test/`):
a driver alone can do it, no EXE is needed, but the mechanism differs by OS.

- **Windows 98 SE:** the CM, as the WDM function driver of the NHI, calls CONFIGMG
  `Reenumerate_DevNode` on the tunnel bridge's devnode from a passive-level thread, and
  for a vanished child `Query_Remove_SubTree` then `Remove_SubTree` first. **Never put a
  WDM driver on the bridge devnode**: Windows 98 ignores `UpperFilters` there, and forcing
  NTKERN as its loader breaks the bridge. The CONFIGMG service numbers were taken from
  memory of the Windows 95/98 DDK and confirmed only at run time; check them against real
  DDK headers.
- **Windows 2000 and later:** a small upper filter on the tunnel bridge calls
  `IoInvalidateDeviceRelations(BusRelations)`; pci.sys then adds or removes the endpoint
  itself. Install it per device through an INF; as a System-class filter it must be
  boot-start, or the next boot stops with 0x7B. Every tunnel down shows "Unsafe Removal".
- One binary can serve both, choosing with `IoIsWdmVersionAvailable(1, 0x10)`. A
  CFGMGR32 EXE (`cmreenum.exe`) works on both as a fallback.
- **Windows 7 x64 on q35** handles the tunnel by itself through native PCIe hot-plug
  (`usb4-tunnel-port`), with no helper. On i440FX it does not drive SHPC.

## 6b. NVMe behind the tunnel

Evidence: [NVME-DRIVER-EVAL.md](NVME-DRIVER-EVAL.md).

- **nvme98** (`D:\OneDrive\git-projects\nvme98`, BSD-3-Clause, fork of SweetLow's nvme9x
  with SweetLow's permission) is the driver for Windows 98/ME, 2000, XP, XP x64 and Vista,
  32- and 64-bit. 0.1.0.0 is the unmodified baseline (amd64 test-signed with the nvme98
  project certificate); it shares the inherited bugs: surprise removal with I/O hangs, 4
  KiB-sector drives crash, NSID 1 only. Its reviewed plan (`docs/PLAN.md`) fixes these;
  4 KiB drives will be supported through 512-byte emulation.
- **Windows 7 x64:** use Microsoft's stornvme (KB2990941 + KB3087873). It handles 4 KiB
  sectors and surprise removal behind the tunnel and is signed.
- **What nvme98 needs from your CM** (nvme98 PLAN 0.10, gate G3, decision MD-2): an
  optional notification that a tunnel's PCIe link has gone down, sent only after the
  path is closed and the endpoint's link-down reset has completed; and the rule that a
  tunnel is reopened only to an endpoint that has been reset (a link-down does this).
  The interface is to be agreed; without it nvme98 completes held requests after a
  deadline (decision MD-1). **Real-hardware evidence (ORICO capture,
  [captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md) §11):** after every link loss
  (host port reset at boot and at a driver rebind, unplug and re-plug) the ASM2464 switch
  and the NVMe came back in their reset state: bus numbers 0, BARs unassigned, Command
  register 0, a fresh nvme controller instance. The PCIe link went down 22 ms after the
  CM saw the unplug. After suspend-to-idle the enclosure's router had been reset and
  Linux rebuilt the tunnel; the nvme driver re-initialised the controller. CC/CSTS were
  not captured.
- Safe eject (e.g. NUSB's tool) is not wired: a tunnelled NVMe is not marked removable
  and the CM is not told about an eject. Mark the devnodes removable and tear the
  tunnel down after an eject, or provide your own eject.

## 6c. Fault injection for your tests

The emulator has a test harness (when merged; see [HARNESS.md](HARNESS.md)): faults at
an exact NVMe command, gate overrides, controller timing faults, lost interrupts, a debug
I/O port for stage markers, and namespace layouts (`nvme-nn` stops stornvme's 256
phantom disks).
- Polling: control-packet round trips on real hardware are about 156 µs median (Framework
  capture). Busy-poll while a transaction is outstanding; poll for hot-plug every
  100-250 ms when idle. Data (NVMe, USB) does not go through the CM and uses the
  device's own interrupts.
- The Alpine Ridge NHI advertises INTA# but no captured OS used INTx; verify before
  relying on it.
- Controller surprise removal and the Assist power-off with ACPI or restore: §6d.

## 6d. The whole controller leaving: surprise removal and the Assist power-off

In main as of QEMU `25fd4eb` (`usb4-emu`, `src/patches/0001-usb4-emu.patch`; built on branch
`usb4-hotplug` and merged 2026-10-15). Design: [ARCHITECTURE.md](ARCHITECTURE.md) §4.4a.

The Thunderbolt 3 tree on i440FX (root bridge `tbrp`, switch `tbusp`, NHI, tunnel
bridge, `tbd2` with the TB xHCI `tbxhci`) can disappear under a running guest and come
back:

- **Surprise removal (your request 3):** `qom-set tbrp present false`. Within that same
  QMP command the tree goes dark:
  - the xHCI's and the NHI's MMIO read all-ones;
  - their config space, and the switch's, reads `0xFFFF`;
  - DMA, MSI and INTx stop.

  `present true` brings the tree back. `tbrp` itself stays, like the PCH root port it
  stands for.
- **Assist power-off (your request 4, R32):** with `bios-assist=on`, the controller
  powers off `power-off-delay-ms` after the last device leaves, or
  `power-off-delay-usb4-ms` when a USB4 device left last (from `usb4-p14s`).
  - From then on the registers read all-ones.
  - The removal is signalled `removal-notify-ms` later. The default is 4400 ms, so
    with an 11000 ms power-off the removal comes at 15.4 s, as on the P14s with the
    ORICO.
  - A plug, or force power, powers the controller up again as a fresh arrival.

`root-hotplug` on `tbrp` decides what the guest is told:

| `root-hotplug` | When the tree leaves | When it comes back | Use for |
|---|---|---|---|
| `none` (default) | nothing (all-ones only) | from reset: bus numbers, windows and BARs 0 (the old behaviour) | compatibility |
| `restore` | nothing (all-ones only) | the configuration it had is written back, as platform firmware would: bus numbers, windows, BARs, Command, interrupt line, and the tunnel bridge's SHPC slot state. An NVMe that returns later behind the tunnel (after your CM approves it again) gets its old BAR and Command | **your Windows 98 SE (APM mode) and Windows 2000 (`acpi=off`) images** |
| `acpi` | ACPI Bus Check on bus-0 slot 6 through PIIX4 PCI hot-plug: the guest re-enumerates below `tbrp` and removes the tree | from reset below `tbrp`, plus a second Bus Check: the guest enumerates it as a fresh arrival | ACPI-mode guests only |

QEMU options (`scripts/run-win98.sh` with `BIOS=...` builds the rest of the tree):

```
-global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
-device usb4-tunnel-bridge,id=tbrp,bus=pci.0,addr=0x6,chassis_nr=1,msi=off,root-hotplug=restore
    (or root-hotplug=acpi[,removal-notify-ms=4400])
-device usb4-host,...,profile=tb3-alpine-ridge,bios-assist=on,power-off-delay-ms=11000
```

`scripts/run-win98.sh` knobs (BIOS mode): `HOTPLUG=restore|acpi` sets `root-hotplug=`,
`REMOVAL_NOTIFY_MS` sets `removal-notify-ms`, and `POWER_OFF_MS` sets
`power-off-delay-ms`. Keep `ROOT_ADDR=6`, because SeaBIOS's `$PIR` lists only slots
1-6. Example:

```
QEMU=<usb4-emu build, 25fd4eb or later> HOTPLUG=restore BIOS=OFF_OFF scripts/run-win98.sh
```

QMP:

```
python scripts/qmp.py --port 47400 cmd qom-set '{"path":"/machine/peripheral/tbrp","property":"present","value":false}'
python scripts/qmp.py --port 47400 cmd qom-set '{"path":"/machine/peripheral/tbrp","property":"present","value":true}'
python scripts/qmp.py --port 47400 cmd qom-get '{"path":"/machine/peripheral/tbrp","property":"root-slot"}'
```

`root-slot` reads, for example, `mode=restore domain=1 present=0 powered=1 up=0 hidden=0
gen=1 saved=6 pending=`. Each step emits the QMP event `USB4_TUNNEL_ENDPOINT` on `tbrp`
with one of these stages:

- `root-gated`: synchronous;
- `root-quiesced`: the tree was reset; from here guest memory no longer changes on its
  behalf;
- `root-removal-notified`;
- `root-arrived`;
- `root-arrival-notified`.

Trace: `-trace 'usb4_tb_root*' -trace 'acpi_pci_*'`.

What the guests did (2026-10-15; details in [WIN98-TEST.md](WIN98-TEST.md), "The
controller tree leaving"):

- **Windows 98 SE in APM mode** (your image), `restore`: the GPE is never serviced.
  The tree came back with exactly the configuration it had (`info pci` identical) and
  no devnode changed. In between, xhci98.sys sees all-ones. It must fail the I/O
  itself, and if it wants the devnode gone, remove it with CONFIGMG (§6a).
- **Windows 98 SE in ACPI mode** (an overlay converted by hand, not your image),
  `acpi`: the removal Bus Check removed the switch, NHI and xHCI devnodes with no user
  action, and the arrival brought them back. So Windows 98 SE **does** handle ACPI PCI
  hot-plug on bus 0, but only once its PCI bus is enumerated by ACPI. Converting an
  APM-mode install takes a manual ACPI BIOS install and removing the old PCI bus.
- **Windows 2000 with `acpi=off`** (your launch line): no ACPI, so the guest learns of
  changes only from a rescan.
  - A rescan after the removal gives "Unsafe Removal of Device", the surprise-removal
    path.
  - With `restore`, a rescan after the return brings the tree back.
  - With `acpi` or `none`, Windows 2000 cannot configure the fresh bridges (bus
    numbers left 0, a yellow "!").
- **Linux** (`acpiphp`), `acpi`: removal and fresh arrival are both automatic,
  including the Assist power-off path.

For your test (a USB stick mid-copy on the TB xHCI, then a surprise removal):
- Use `HOTPLUG=restore` on both legacy images.
- Removing the devnode automatically needs an ACPI-mode guest with `HOTPLUG=acpi`.
- Otherwise the removal reaches Windows 2000 when xhci98.sys or the user triggers a
  rescan, or when xhci98.sys reports the device gone itself.

## 7. Status and open items

Roadmap with dated exits: [ROADMAP.md](ROADMAP.md). Done 2026-10-15, all in main as of `b5936c4` (QEMU `usb4-emu`): the real USB4
enclosure preset (`device-model=asm2464`), the ORICO behind the P14s firmware CM (R33)
and the TB3 device router on a USB4 host (§7.1); in main as of `25fd4eb`, the controller tree
leaving and coming back with the ACPI hot-plug notification for Assist mode (§6d). Not done:
Alpine Ridge read-only DMA port (R20, probably needed by Intel's Windows driver) on the
`tb3-*` profiles (the TB3 dock on a USB4 host has it since `usb4-win11tb3`, in main as of QEMU `2a893ea`, §7.1), Device
Serial Number capability (R29), MSVC 6.0
build of `tools/usb4cm` (only gcc C89 and Open Watcom were checked), a custom SeaBIOS
whose `$PIR` lists every slot (optional now that the P14s table is known; `ROOT_ADDR=6`
gives the same outcome), and a
capture of real Titan Ridge hardware to confirm the inferred `tb3-titan-ridge` profile.

### 7.1 TB3 device router on a USB4 host (in main as of `b5936c4`)

Built 2026-10-15 on QEMU branch `usb4-tb3dev`, merged into `usb4-emu`: in main as of `b5936c4`
(`src/patches/0001-usb4-emu.patch`). Details in
[USB4-HOSTS.md](USB4-HOSTS.md) §7 and §8.

- `usb4-device dialect=tb3` on a `usb4-generic` host (`host-model=minimal`, `intel-adl` or
  the new `amd`) is the CalDigit TS3 Plus as the Framework's Linux software CM found it
  [obs]: router `8086:15d3`, Plug Events and link controller vendor capabilities, PCIe Up
  adapter 6, the host lane adapter's PORT_CS_18 with TBT3-Compatible Mode (TCM, bit 9).
- What your software CM must do differently for it (Linux `tb.c`/`switch.c`/`lc.c` do the
  same): no Configuration Valid / Router Ready handshake and no router operations (DROM by
  EEPROM bit-bang through Plug Events + 4, ICM-PROTOCOL.md §5.4, or skip the DROM);
  configure with router dwords 1-4 (Upstream Port Number, depth, route, Configured,
  Notification Timeout); set plug events active (clear bits 6:2 of Plug Events + 1);
  mark the link configured in the link controller (SX_CTRL at link controller + 0x14 +
  0x96: L1C and UPSTREAM for lane adapter 1); find capabilities from the chains (lane
  capability at `0x36`, PCIe capability at `0x39`, long VSEC headers); acknowledge the
  router's own hot plug events (adapters 9, 2, 10 after configuration, adapter 2 unplug
  after bonding), or suppress them with the disable bits of Plug Events + 1 (bit 3 lane
  adapters, bit 4 DP OUT; a suppressed event is not sent later). Bond by setting Target
  Link Width on both TB3 lanes (`0x37` bits 5:4) and LB on the host's lane 0.
- DMA port (QEMU branch `usb4-win11tb3`, 2026-10-16, in main as of `2a893ea`): adapter 5 of the dock is now Host
  Interface typed (`0x01000002`) with the DMA port mailbox of ICM-PROTOCOL.md §5.2, as on
  the real dock [obs: adapter identity, mailbox protocol, the flash size and NVM version
  44.0 reads at `0x44` and `0x08`]. The model supports flash read only; other commands get
  an access error (the emulator's restriction, R20, not a property of the dock). Windows 11's
  built-in CM needs it (it reads the DROM through it at the router dword `0x34` offset and
  an eGPU dword at `0x734`, otherwise Code 10, USB4-HOSTS.md §8). Your CM may read the
  DROM either way; both give the same bytes. Probe adapters 3, 5, 7 for type 2 before
  assuming there is none: Linux and Windows both do.
- Each TB3 dock has its own link controller UUID by default; `lc-uuid=captured` gives one
  dock the real TS3 Plus's UUID. A USB4 device router can be chained behind the dock
  (`downstream-ports=1` on the dock, `parent=enc0` on the child).
- Chained PCIe tunnel (in main as of QEMU `36f6254`; USB4-HOSTS.md §8
  "Chains"): TS3 Plus + ORICO ASM2464 as in the `linux-ts3plus-orico` capture [obs]. Your
  CM configures the chained router at route `0x303` (depth 2) like any USB4 device router,
  bonds the dock's downstream link with LB on the dock's adapter 3 at `0x37` (the dock then
  reports adapter 4 unplugged), and builds the second tunnel 3:7 <-> 303:3 after the first
  (0:9 <-> 3:6): HopID 8 on 303:1, 3:7, 3:3 and 303:3, then Path Enable on 303:3 and 3:7.
  **i440FX supports one tunnel-bridge level**: a dock behind `usb4-tunnel-bridge` gives
  its own NVMe only, and no chained device behind it is reachable on the PCI side.
  Chaining is q35-only for now (`usb4-tunnel-port`, where the dock's switch has a gated
  hot-plug port for adapter 7). On Windows 98 you can still drive the chain's routers and
  paths over ring 0, but the chained NVMe will not appear.
  `root-hotplug=restore` is not validated across a chain (it belongs to the i440FX
  root-bus bridge, which has no chain).
- Router operation 30h (Get PCIe Downstream Entry Mapping) on `intel-adl`: **left
  unanswered** (Not Supported) in main as of `b5936c4`; 20655c3 and earlier answered it with the
  spec-derived mapping. No Framework capture shows the real host
  answering it: Linux never issues it, the traces hold only opcodes 10h, 24h, 25h, 33h.
  `minimal`, `amd` and `asm4242` still answer it.
- `host-model=amd`: AMD router identity `0438:0208` (`host-domain` 0-3 for `0x0208` to
  `0x020b`) on the `minimal` router, PCI identity unchanged; inferred from Linux
  `quirks.c` only.

Acceptance run (Windows 98 SE, i440FX, NVMe behind the TB3 router at port 1), with a
build of main as of `b5936c4` (`src/build-qemu.sh`), adjust paths:

```
qemu-system-x86_64 -name win98-tb3dev -machine pc -accel tcg -cpu pentium3,-apic \
  -smp 1 -m 512 -display none -vga none -device cirrus-vga \
  -vnc 127.0.0.1:<vnc display> -qmp tcp:127.0.0.1:<qmp port>,server=on,wait=off \
  -rtc base=localtime -nic none \
  -drive if=ide,index=0,format=qcow2,file=win98.qcow2 \
  -drive if=ide,index=2,media=cdrom \
  -global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off \
  -drive if=none,id=nvme0,format=qcow2,file=nvme.qcow2 \
  -device usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1,shpc-autoenable=on,msi=off \
  -device usb4-host,id=u4,bus=pci.0,addr=0x4,tunnel-port=tb0,msi=off,msix=off,profile=usb4-generic,host-model=intel-adl \
  -device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,dialect=tb3
```

This is `scripts/run-win98.sh`'s default `USB4=1` setup with two changes: `host-model=`
on `usb4-host` (`minimal`, `intel-adl` or `amd`) and `dialect=tb3` on `usb4-device`. With
the script: `USB4=0 QEMU=<build>/qemu-system-x86_64.exe scripts/run-win98.sh` followed by
the last five `-global`/`-drive`/`-device` lines above as extra arguments. Hot unplug:
QMP `device_del enc0`; re-plug: `device_add` with the same properties. Verified by
`tests/qtest/usb4-tb3dev-test.c` (the same i440FX bridge and host, all three
host models: ring 0 bring-up, NVMe in slot 1 behind the bridge, `device_del`) and an
unmodified Linux guest on q35 (USB4-HOSTS.md §8); not run under Windows 98 here.

