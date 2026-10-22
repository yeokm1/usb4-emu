# Roadmap

Status: draft, revised 2026-10-14 after eight Codex review rounds. This repository covers the QEMU
model only. Connection manager drivers for Windows 98 through Windows 7 are developed in
the xhci98 project against this model. Here the model is validated with Linux and with
modern Windows.

The real demo hardware is a ThinkPad P14s Gen 1 with an Intel JHL6240 Alpine Ridge LP
Thunderbolt 3 controller and no USB4 devices, so the Alpine Ridge firmware-CM profile
`tb3-alpine-ridge` comes first. The generic USB4 software-CM profile follows. See
`ARCHITECTURE.md` §2 for the two profiles.

Each item is a checkbox, ticked when done; exits record the date and how they were
verified.

**Order change, 2026-10-14 (maintainer).** No P14s captures were available yet, so
work proceeds M0 (minus captures) -> M1 -> M4 -> the generic-profile half of M5, with the
Windows 11 built-in connection manager as the target. M2, M3's firmware-CM parts and the
capture-dependent M0 items wait for the P14s captures. The M3 tunnel bridge and PCI
integration are built now because M4 and M5 need them.

**Retarget, 2026-10-14 (maintainer).** The first Linux capture showed the P14s has an
Alpine Ridge LP controller (NHI `8086:15bf`), not Titan Ridge as earlier drafts assumed.
The firmware-CM profile is now `tb3-alpine-ridge`, with the Alpine Ridge ICM message set
(`ICM-PROTOCOL.md` §4.9 lists the differences). Titan Ridge moves to "Later, unscheduled".

Each milestone lists an exit criterion. Do not start the next one until the exit criterion
is met and recorded here. Unmodified Linux cannot bind successfully until the CM startup
path of a profile exists, so Linux binding is an exit criterion of M2 and M4, not M1.

## M0. Repository and references

- [x] Reference material fetched per `docs/REFERENCES.md`. Done 2026-10-13.
- [x] Capture from the P14s Gen 1 under Linux (tools in `tools/p14s-capture/`): `lspci`
  for the NHI and bridges; firmware status and outbound mailbox at idle; the driver-ready
  response bytes; `/sys/bus/thunderbolt` contents with a TB3 device attached; config
  space dumps of the host and device routers (debugfs `regs`); device DROM; a
  `thunderbolt` tracing log of driver unload and reload with the device present, unplug,
  plug, approve and unplug. These are the golden data for M2 and M3 and the provenance
  for `docs/ICM-PROTOCOL.md`.
  Done 2026-10-14 (Linux part only): `tests/captures/p14s-gen1/linux-assistOFF_prebootOFF/`,
  Kubuntu 26.04.1 live, CalDigit TS3 Plus dock. A trace of the cold boot itself is not in
  it (driver rebind stands in for it).
- [x] Capture from the P14s Gen 1 under Windows 11 (Intel driver package) and under
  Windows 98 / DOS (no OS driver), with the collectors in `tools/p14s-capture/`.
  Done 2026-10-14: `tests/captures/p14s-gen1/win11-assistOFF_prebootOFF/`, the Windows 98
  BIOS matrix in `win98/` (Assist and pre-boot on/off, plus nothing attached) and a
  Linux Assist-on/pre-boot-on run. Decoded in `docs/ICM-PROTOCOL.md` §9-§12; the ICM
  conversation under Windows stays unreadable (WPP trace without format data).
- [ ] Pin the Intel Thunderbolt driver package version for Windows 11, QEMU commit, Linux
  (partial, 2026-10-14: QEMU v11.1.2, Windows 11 build 26300 ISO
  `Windows11_Client_x64_en-us_26300_9457.iso`; Intel package and Linux image open)
  guest kernel and image, Windows 11 image. Candidate Intel package: the one on the real
  P14s, `tbthostcontroller.inf` 1.41.1353.0 (12/12/2022), per the Windows 11 capture.
  Pinned 2026-10-22 from what is at hand: QEMU upstream v11.1.2 plus the fork at `9b5db6e`
  (`src/patches/0001-usb4-emu.patch`); Windows 11 ISO sha256
  `bd4307df32bc8af33b39ccecb1174aeb345386630f89a2b86c7a4e36b55ea650`; Linux guest
  Kubuntu 26.04.1 desktop amd64 live ISO (`kubuntu-26.04.1-desktop-amd64.iso`, sha256
  `831e4d4bb85098339ba43d3502cd6619b27e76daf37246a084cd68a6413090b8`), kernel
  7.0.0-30, booted with `-kernel`/`-initrd` from the ISO as in `docs/LINUX-TEST.md`.
  Intel package, pinned 2026-10-22 by the maintainer: the Windows Update Catalog DCH
  package 1.41.1379.0 (07/27/2023, `TbtHostController.inf`, matches
  `PCI\VEN_8086&DEV_15BF&CC_0880`; cab
  `12081e68-169e-483b-9180-87f40ecc6904_8aa1088bc7bd88105d5c4e4a504bfb9bdcd01078.cab`,
  sha256 `d01be65779f2e26ea6c07e4db2f4e0b8bb3a99d5f64aabada8828ac0969eb1c6`; local copy
  `E:\xhci98-scratch\p43-33\dl\tbt-dch-1.41.1379.0`). The P14s capture ran 1.41.1353.0
  (12/12/2022), which is not available here; 1.41.1423.0 from the same source no longer
  lists `DEV_15BF`. Windows guest drivers for the S3 leg: virtio-win 0.1.302 stable
  (`virtio-win-0.1.302.iso` from fedorapeople.org `stable-virtio`, sha256
  `303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d`), used only inside guests.
- [x] Create `NOTICE` with the FreeBSD and tbtools notices, ready for the first incorporated
  file.
  Done 2026-10-22: the pinned commits, the copyright lines and licence texts of both,
  and the Linux entry, each with an empty file list (nothing is incorporated yet).
- [x] Write the clean-room description of the Intel host interface MMIO semantics that M1
  implements (interrupt clearing, DMA misc auto-clear bit, mailbox) with observed and
  inferred tags, as the first part of `docs/ICM-PROTOCOL.md`.
  Done 2026-10-14: `docs/ICM-PROTOCOL.md` §2, from the Linux capture and a clean-room
  reading; awaiting review.
- [ ] Confirm the pinned QEMU's `nvme` device boots the pinned Linux image from a qcow2 disk
  on a plain `pci-bridge`, which is the endpoint the tunnel will expose.
- [ ] Exit: a clean QEMU build from the fork boots the pinned Linux and Windows 11 images,
  the hardware captures are checked in under `tests/captures/` with a README noting the
  DMA-port adapter deviation, `NOTICE` exists, and the M1 MMIO description is reviewed.

## M1. Host interface rings, tested in isolation

- [x] `usb4-host` PCI device, BAR0 register file, TX and RX rings, single-vector MSI and INTx,
  `REG_FW_STS` and NHI mailbox registers, interrupt clearing per profile and control bit
  state as in `ARCHITECTURE.md` §4.1.
  Done 2026-10-14 for the generic profile (qtest `usb4-host-test`, 17 cases). Intel clear-on-delivery mode, FW_STS and mailbox remain for M2.
- [x] Control packet CRC32C and framing, verified against Spec Appendix A.2 vectors here,
  before any guest sends a control packet.
  Done 2026-10-14: both Appendix A.2 vectors in `tests/usb4/fabric-test.c`.
- [x] Exit: qtests pass for wraparound, RX exhaustion, completion ordering, reset, the
  mailbox request and error bits, and clearing behaviour in every configuration:
  Intel read-to-clear with and without the auto-clear control bit, USB4 with and without
  Disable ISR Auto-Clear, and the exact single-MSI initialisation sequence Linux uses. A
  ring-level test driver exercises the rings over MSI, INTx and pure polling in each
  configuration. No Linux binding is claimed at this milestone.
  Done 2026-10-22 (QEMU `5bb712d`): `usb4-host-test` `/usb4-host/matrix/<cfg>/<dlv>`, 16
  cases, runs wraparound, completion ordering, RX exhaustion with refill, a masked
  completion and a host interface reset (status cleared, INTx dropped, a waiting frame
  cancelled) for each of `usb4-generic` with and without Disable ISR Auto-Clear and
  `tb3-alpine-ridge` with and without the Intel auto-clear bit, over pure polling, INTx,
  single MSI and MSI-X, checking the delivery and the clearing rule after every
  completion; `/usb4-host/linux-single-msi-ar` is the Linux single-MSI sequence on Alpine
  Ridge (`nhi.c` and `pci.c` under `QUIRK_AUTO_CLEAR_INT`). The mailbox request and error
  bits are `usb4-icm-test` `/usb4-icm/identity`. `usb4-host-test` 40 cases.

## M2. Alpine Ridge profile: ICM startup and TB3 enumeration

- [x] Write `docs/ICM-PROTOCOL.md` first, per the clean-room rule in `AGENTS.md`: field tables,
  startup sequence, event lifecycle, error statuses, with every statement tagged as
  observed on the P14s or inferred from the Linux client.
  Done 2026-10-14 from the Linux capture; Windows open questions in its §9.
- [x] Rename the code stub's `tb3-titan-ridge` profile to `tb3-alpine-ridge`. Alpine Ridge
  LP PCI identity (`ICM-PROTOCOL.md` R1), firmware-running reset state (R2), mailbox
  mode and commands (R3), driver-ready response with the advertised values from
  `ARCHITECTURE.md` §4.2b (R8).
  Done 2026-10-14 (QEMU `usb4-icm` 64154b6; `tb3-titan-ridge` kept as a deprecated alias).
- [x] `tb3` dialect host router at route 0 and `tb3` dialect device router, serving the full
  read checklist in `ARCHITECTURE.md` §4.2: headers, adapter capability chains, link
  controller fuse UUID, EEPROM bit-bang DROM on the device, UID-only on the host, and no
  NHI-typed adapter at 3, 5 or 7 so the DMA-port probe fails (R17-R19, R21).
  Done 2026-10-22: `tests/usb4/run-ar-conformance.sh` (QEMU `9b5db6e`) replays the P14s
  Linux trace against the fabric with the emulated firmware CM, details in
  `ICM-PROTOCOL.md` §5.6. With the client's own traffic (`--exclude-comm cat`): every
  read of both routers answered, all 15 ICM responses and all 4 device events as
  captured; dock 2,265 of 2,514 read dwords as captured (90.1%), host 199 of 294
  (67.7%), writes 4,172 of 4,181. The differences are the DROM and host UID contents
  (emulator identity), the DMA port (deliberately absent, R20), two counter dwords and
  the Adapter Num of Router CS write replies (owed, §5.6). The replay found and fixed
  the EEPROM control dword read-back while bit-banging (§5.4). Also: qtests
  `usb4-icm-test`, `usb4-tb3dev-test` and the fabric harness `test_tb3_*`; the M2 Linux
  exit.
- [x] Device-connected and device-disconnected events and get route with the lifecycle
  rules, including announcing boot-present devices after driver-ready and after
  driver-unloads plus driver-ready (R9, R11-R13).
  Done 2026-10-14 (`hw/usb4/usb4-icm.c`, qtest `usb4-icm-test`).
- [x] Approve accepted and recorded (the fabric write is stubbed until M3); boot ACL
  store; `security=none` auto-approval with the approved flag in events; the remaining
  commands per the support matrix return the ICM error flag (R10, R14-R16).
  Done 2026-10-14 without a stub: approve programs the PCIe paths and Path Enable through
  the fabric config API, so the shared evaluator brings the tunnel up (R22).
- [x] NHI class code `0x088000` (R23, needed by the Windows INF) and, on q35, an optional
  Device Serial Number capability (R29).
  Class code done 2026-10-14 (R1). Device Serial Number done 2026-10-22 (QEMU `9b5db6e`):
  the NHI's first extended capability on q35, `usb4-host` `dsn` (default on for the tb3
  profiles) and `dsn-value` (default derived from `uuid`); the switch port types
  `usb4-tb3-*`/`usb4-tr-*` (usp, dsp, tunnel-dsp) take the same `dsn-value`, as the
  captured functions all report one serial; `scripts/run-linux.sh DSN=`. qtest
  `usb4-icm-test` `/usb4-icm/dsn`. The tunnelled dock's own switch DSN is not modelled.
- [x] Exit: unmodified Linux binds with MSI, reports the firmware CM, lists the device under
  `/sys/bus/thunderbolt/devices` with the captured name, vendor and UUID, and no NVM
  attributes. Boot-present, hot-added, `device_del` plus re-`device_add`, and driver
  unload plus reload all converge. The same sequence works with the ring-level test
  driver over pure polling.
  Met 2026-10-14 (QEMU `usb4-icm` 5ee4f7e on usb4-emu 8a9a8ac). Kubuntu 26.04.1 live,
  kernel 7.0.0-30, `scripts/run-linux.sh` with `PROFILE=tb3-alpine-ridge`: "using firmware
  connection manager"; with `msix=off` it binds with one MSI vector. `0-1` shows vendor
  `CalDigit, Inc.`, device `TS3 Plus` (names given as device properties), `unique_id` in
  the captured layout (DROM UID, then eight `ff` bytes; the value is emulator-derived),
  no NVM attributes, `authorized` 0; authorising gives `/dev/nvme0n1` with matching 64 MiB
  O_DIRECT write/read checksums. Boot-present, `device_del` plus `device_add`, driver
  unbind plus bind (tunnel kept, re-announced authorised) and `security=none` (authorised
  and tunnelled at boot) all converge. Polling-only ring driver: qtest `usb4-icm-test`
  (6 cases). Details in `docs/LINUX-TEST.md`.

## M3. PCIe tunnel integration and Windows AR smoke gate

- [x] Tunnel evaluator per `ARCHITECTURE.md` §4.3, driven in this milestone by the emulated
  ICM's path programming on approve (replacing the M2 stub), torn down by mailbox
  disconnect-PCIe-paths and by a QMP force-teardown command.
  Done 2026-10-14, driven by guest-programmed paths (generic profile). ICM-driven approve and mailbox disconnect wait for M2.
- [x] Tunnel bridge subclasses `usb4-tunnel-bridge` (from `pci-bridge`) and
  `usb4-tunnel-port` (from `pcie-root-port`), names provisional, with the secondary-bus
  gate address space and window gating per `ARCHITECTURE.md` §4.4. Before anything else
  in M3, confirm in the pinned QEMU that an endpoint behind the subclass resolves its DMA
  address space to the gate, and choose the config-space gating mechanism.
  Done 2026-10-14: `usb4-tunnel-port` and `usb4-tunnel-bridge`, gate address space verified with `info mtree`.
- [x] PCI integration layer per `ARCHITECTURE.md` §4.4: synchronous gate, then quiesce,
  notify and remove from a bottom half, with generation-checked emulator work, forced
  removal of a pending endpoint before a reconnect, and replacement insertion only after
  the guest acknowledges the empty slot or a settle timeout. The endpoint is QEMU's `nvme` device
  per `ARCHITECTURE.md` §4.5.
  Done 2026-10-14 (qtest `usb4-tunnel-test`; Windows 11 forced and CM-driven up, surprise and re-plug). Admin-down defaults to surprise removal because Windows never completes an eject for a gated endpoint with a mounted volume; see `docs/USAGE-tunnel.md`.
- [x] Test hooks: a test-only property that holds the bottom half so the interval between
  the gate and the deferred stages can be probed, and the QMP cutoff event.
  Done 2026-10-14 (held bottom half and cutoff event in `usb4-tunnel-test`).
- [x] Both machine profiles: `usb4-tunnel-port` on q35 and `usb4-tunnel-bridge` on i440FX.
  Built 2026-10-14; i440FX only checked with SeaBIOS enumeration and qtests, no legacy guest.
- [ ] Pre-boot mode (`ICM-PROTOCOL.md` R25, R26): with `preboot=on`, boot-ACL devices are
  approved and tunnelled at emulator power-on, before guest firmware enumerates PCI, and
  are announced with the approved and boot bits; verified by a driverless guest
  (SeaBIOS / Windows 98 DOS mode) seeing the NVMe behind the tunnel, and by Linux
  reporting `boot` = 1. This is the zero-driver path for legacy guests the captures show
  (Windows 98 `OFF_ON`, `ON_ON`).
  Done (recorded 2026-10-22; built 2026-10-14 to -16): `preboot=on`, `boot-acl=`,
  `preboot-acl-only` (R25, R26; since 2026-10-15 every attached device is approved, as
  the ORICO capture shows, `ICM-PROTOCOL.md` §13.2). Driverless guest: SeaBIOS maps the
  NVMe behind the pre-boot tunnel as INT 13h drive 0x81 and DOS / Windows 98 use it as
  D: with `BIOS=OFF_ON` (`NVME-DRIVER-EVAL.md`, `WIN98-TEST.md` "SMM hang at the boot
  logo" table and "P14s BIOS matrix"). Linux `boot` 1: `BIOS=ON_ON` with the dock
  (`WIN98-TEST.md`, Linux paragraph), the ORICO cells of `ICM-PROTOCOL.md` §13.7 and
  Titan Ridge (`LINUX-TEST.md`). qtests `usb4-icm-test` `/usb4-icm/preboot`,
  `preboot-order`, `preboot-reset`, `usb4-icm-tr-test` `/usb4-icm-tr/preboot`.
- [x] Before the Windows smoke gate: MSI-X with 16 vectors and the auto-clear bit (R7,
  R24). Windows 11 logs the host and device NVM versions, which on Alpine Ridge come only
  from the DMA port, so expect to need the read-only DMA port (R20) for it.
  Done (MSI-X and auto-clear since 2026-10-14; checked 2026-10-22, QEMU `9b5db6e`): the
  captured layout (capability 0xa0, 16 entries, table at BAR1 + 0, PBA at BAR1 + 0xfa0,
  BAR1 4 KiB), each of the 16 vectors reachable through the vector allocation registers
  with auto-clear on delivery and on unmasking, two causes on two vectors at once:
  qtests `/usb4-icm/msix-vectors`, `/usb4-icm/msix-autoclear`, and the
  `usb4-host-test` M1 matrix. The read-only DMA port on the `tb3-*` profiles stays open
  until the smoke gate shows Windows needs it.
- [ ] Windows AR smoke gate: Windows 11 with the pinned Intel Thunderbolt driver package
  (pinned: 1.41.1379.0, M0; the capture ran `tbthostcontroller.inf` 1.41.1353.0).
- [ ] Optional, unscheduled: "nothing attached means powered down" model and ACPI force
  power (R27, R28), for testing a driver's force-power path.
- [ ] Exit, Linux, `security=user`: writing `1` to `authorized` exposes `/dev/nvme0n1` and
  I/O succeeds; unapproved devices never expose the endpoint; physical removal during
  idle removes it cleanly and reconnection plus re-approval works; QMP force-teardown
  blocks MMIO, config writes, DMA and interrupts immediately, checked while the bottom
  half is held, and the device disappears after the timeout when the guest ignores the
  eject. An NVMe read in flight at teardown, slowed with a throttled block backend, may
  land data before the cutoff event but guest memory is unchanged after it, and no
  completion or interrupt for it is ever delivered. A reconnect issued before the old
  eject completes yields one fresh endpoint; a stale removal timeout does not affect it;
  a slot power-off register write delivered after the forced removal but before the
  guest acknowledged the empty slot removes nothing, the replacement is inserted after
  the acknowledgement, starts unpowered because the power-off state persisted, and
  serves I/O once the guest powers the slot on. On both bridge types, MMIO, config
  writes, DMA and interrupts are checked blocked before the guest enables the slot and
  working after; on `usb4-tunnel-bridge` this exercises the subclass's SHPC enforcement
  in the Disabled and Power-only states. Separately, with no acknowledgement the
  replacement is inserted when the settle timeout expires. NVMe DMA and MSI are confirmed blocked by the gate address
  space, not merely by the endpoint's own command register. `security=none`: the endpoint appears without
  any `authorized` write, for boot-present and hot-added devices. Verified on both
  machine profiles. Exit, Windows: the Intel driver binds to
  the NHI, reaches driver-ready, and shows the attached device; full Windows validation
  stays in M5. If the Intel package rejects the simplified PCI topology, record what it
  needs and decide whether to model the controller's PCIe switch before M4.
  Linux runs 2026-10-22 ([GUEST-EXITS.md](GUEST-EXITS.md) "M3", QEMU `9b5db6e`, TCG):
  - [x] q35: `authorized=1` exposes the NVMe with I/O, unapproved never; idle removal
    and reconnect with re-approval; force teardown with the bottom half held blocks
    MMIO, config writes and I/O; a throttled read in flight fails and leaves the buffer
    unchanged; an ignored eject is removed at the timeout; a reconnect during an ignored
    eject gives one fresh endpoint that outlives the old timeout; the replacement after
    the guest's power-off comes unpowered and serves I/O once pciehp powers the slot on;
    no acknowledgement: inserted at the settle timeout. `security=none` on q35 and
    i440FX, boot-present and hot-added.
  - [x] i440FX: gated in Disabled and Power-only, reachable after the guest enables the
    slot by SHPC writes; removal and replacement with this driverless guest.
  - [ ] Open, owner question: with Linux's pciehp the model treats the guest's slot
    power-off of a present endpoint as an eject and dismisses it, so a reconnect inside
    pciehp's 5 s attention-button window of the old eject loses the new endpoint until
    the next tunnel cycle, and a pciehp rebind on a slot reading powered off removes it
    (`usb4-tunnel-slot.c`, left for after link-retrain).
  - DMA and MSI blocked by the gate address space rather than the Command register stay
    qtest-verified (`usb4-tunnel-test`); the guest only shows that I/O stops.
  - [ ] Windows: owed (the Intel package, now pinned).

- [x] Exit, legacy path on `usb4-tunnel-bridge`: with `shpc-autoenable=on` and a guest that
  never touches SHPC (a ring-level test driver plus a PCI config rescan), approve makes
  the NVMe endpoint reachable. With it off, the same test enables the slot by polled SHPC
  register writes and then reaches the endpoint. With it on, a guest that disables the
  empty slot during a reconnect claims the slot: the replacement, inserted after
  acknowledgement and, in a separate run, after the settle timeout, stays inaccessible
  until the guest enables the slot, and the indicators the guest set are unchanged.
  Met 2026-10-22 (QEMU `9b5db6e`): Kubuntu 26.04.1 on i440FX, whose shpchp cannot take
  SHPC control (no OSHP), the Thunderbolt driver approving and `/sys/bus/pci/rescan`;
  SHPC commands by `setpci` through the config DWORD window. All five cases as worded;
  readings in [GUEST-EXITS.md](GUEST-EXITS.md) "M3".

At this point the xhci98 project has what it needs to start the legacy Windows ICM client.
It should run the tunnel bridge with `shpc-autoenable=on` unless it implements SHPC
slot enabling itself, see `ARCHITECTURE.md` §7.

## M4. Generic USB4 profile: software CM

- [x] Emulator-specific PCI identity, USB4 interrupt clearing mode. `usb4` dialect host
  router: ROUTER_CS and ADP_CS layouts, capability chains, DROM via router operations,
  lock bit on downstream adapters, native hot-plug events with retransmit until
  acknowledged.
  Done 2026-10-14 (1b36:00f4, router 46f4:4040). The host router also carries one USB3 Down adapter per USB4 port, which the Windows CM requires.
- [x] `usb4` dialect device router with one PCIe up adapter, Configuration Valid and Ready
  handshake, and PCIe Tunneling On.
  Done 2026-10-14.
- [x] Guest-programmed paths feed the same tunnel evaluator as M3.
  Done 2026-10-14 (Windows 11 CM).
- [x] Exit: unmodified Linux binds, reports the software CM, enumerates the device router,
  and `authorized=1` gives a working `/dev/nvme0n1` through guest-programmed paths.
  `authorized=0` removes it. Incomplete paths, a missing enable on either adapter, or a
  device router without Configuration Ready or PCIe Tunneling On never expose the
  endpoint. The host router is never gated on those fields. A locked downstream adapter rejects forwarded control packets, tested on its
  own.
  Done 2026-10-14: Kubuntu 26.04.1 live (kernel 7.0.0-30) reports the software CM,
  enumerates 0-1, `authorized=1` gives a working `/dev/nvme0n1` (O_DIRECT and ext4
  hash checks), `authorized=0` and `device_del` remove it, replug works; needs QEMU
  commit 8df9474 (DLLSC on tunnel link loss). Negative cases by the fabric harness.
  See `docs/LINUX-TEST.md`.

## M5. Modern Windows compatibility

- [ ] Alpine Ridge profile: full Windows 11 run with the pinned Intel driver package.
- [x] Generic profile: ACPI `_OSC` native USB4 grant and USB `_OSC` with USB, DP and
  interdomain tunneling permitted, plus `_DSD` port mapping for the tunneled bridge, per
  `docs/references/microsoft/usb4-acpi-requirements.txt`. Minimum advertised adapters
  for the Microsoft CM, found by testing; a stub USB3 adapter and the xHCI bandwidth
  handshake from `usb4-design-details-and-general-requirements.txt` may be needed before
  M7 and are in scope here if so.
  Done 2026-10-14: `\_SB._OSC` grants and the tunnel port `_DSD`; Windows adds `PCI\USB4_MS_CM`. Minimum adapters found by testing: lanes, host interface, PCIe Down and USB3 Down per port; no DP adapters needed. The guest needs test-signing (`docs/WINDOWS-DEBUG.md`).
- [x] Generic half of the exit met 2026-10-14: Windows 11 build 26300 built-in CM, cold
  boot shows the NVMe as a disk, NTFS format and 64 MB write/read-back hash match, data
  persists across reboot, `device_del`/`device_add` of `usb4-device` removes and restores
  the disk. Verified with `scripts/run-cm-test.sh` and `scripts/guest.py`.
- [x] Generic profile with a Thunderbolt 3 device router, 2026-10-16: Windows 11 build
  26300 built-in CM binds `usb4-device dialect=tb3` on `intel-adl` and `minimal` (it
  failed with Code 10 before: no DMA port, then the eGPU flash dword), tunnels PCIe, the
  NVMe passes a write / read-back hash check, `device_del`/`device_add` remove and restore
  it; also with the dock's switch and with the ASM2464 behind the dock. QEMU branch
  `usb4-win11tb3`, in main as of `2a893ea`; `USB4-HOSTS.md` §8.
- [ ] Exit: on both profiles Windows 11 shows the device, the NVMe endpoint appears in Device
  Manager and passes I/O, and removal and reconnection work.

## M6. Failure and reset coverage

- [x] QMP fault injection: drop next reply, delay reply, surprise removal, host reset, ICM
  safe mode reported through the mailbox mode.
  Done 2026-10-22 (`hw/usb4/usb4-fault.c`, [FAULTS.md](FAULTS.md)): `usb4-host`
  `x-reply-faults` drops, delays or duplicates (stale copy) any frame queued for RX ring 0,
  matched by PDF, route, ICM code and count, and can pull or replug a router or reset the
  host at that frame (QMP event `USB4_REPLY_FAULT`); `x-host-reset` (router or interface);
  `x-icm-mode` (0 = safe mode in outbound mailbox bits 11:8); `usb4-device` `x-cable` for
  surprise removal at a chosen moment with the object kept. Surprise removal itself existed
  before as `device_del` and the bridges' `tunnel=surprise` (qtests `usb4-icm-test`,
  `usb4-tunnel-test`) and the harness's `act=surprise` (`usb4-harness-test`). Verified by
  qtest `usb4-fault-test` (9 cases: each fault, unplug during enumeration on both profiles
  and during a held NVMe read, malformed rules); the other ten usb4 qtest suites pass
  unchanged.
- [ ] Exit: unplug during enumeration or during I/O, dropped and stale replies, and guest
  reboot all recover with no stale devices and no stuck interrupts, on Linux and Windows
  11, in both profiles.
  The stimuli exist and are qtest-verified at the device level (above). Guest runs
  2026-10-22 ([GUEST-EXITS.md](GUEST-EXITS.md), QEMU `c8d878e`, TCG):
  - [x] Linux, `usb4-generic` (software CM): unplug during enumeration (first read of the
    router dropped and the router pulled), unplug during an O_DIRECT NVMe read held by the
    tunnel port harness, a dropped read (retried), every read dropped ("no switch found"),
    a stale reply 500 ms late, a stale duplicate, and a guest reboot. After each: no
    router, NVMe or USB device left after the unplug, all back with the same data after
    the replug, idle interrupt deltas 0 on every thunderbolt, nvme and xhci vector, no
    `nobody cared`, hung task, `BUG:` or `WARNING:`, nothing in D state.
  - [x] Linux, `tb3-alpine-ridge` (firmware CM): device-connected event lost with the
    router pulled, event seen with the router pulled, router pulled at the approve, the
    approve reply dropped (resent), 12 s late (past the 10 s timeout), duplicated, unplug
    during a held NVMe read, two guest reboots. Same checks, same result.
  - [x] Windows 11 (the existing test overlay, built-in CM), `usb4-generic`: unplug during
    enumeration, unplug during a raw NVMe read held by the harness (Windows logs disk
    surprise removal, no hang), a dropped read, a read 3 s late, a duplicate, and a guest
    reboot. After each the router, NVMe and USB disk are absent or present as expected
    with `ConfigManagerErrorCode` 0, the NTFS test files on both disks hash the same, and
    while idle (QEMU traces, 20-30 s windows) the NHI and the xHCI raise no interrupt and
    the NVMe 0-36 (Windows' own background I/O, no storm).
  - [ ] Windows 11, `tb3-alpine-ridge`: owed. It needs the Intel Thunderbolt driver
    package bound to the Alpine Ridge NHI, which is the open M3 smoke gate (the Windows
    11 overlays in the kits run the built-in CM on the generic profile).

## M7. USB3 tunneling

- [x] USB3 down adapter on the host router mapped to a QEMU xHCI instance, USB3 up adapter on
  a dock-style device router, in both dialects.
  Done 2026-10-22 ([USB3-TUNNEL.md](USB3-TUNNEL.md)): `usb4-device usb3-dev=` names the
  QEMU USB devices (a `usb-hub` with its subtree included) behind the USB3 Up adapter; they
  are on the `qemu-xhci` only while the tunnel the CM built is up, leave it inside the
  write that takes it down (the gate), and leave on `device_del`, `x-cable=false`, host
  router and system reset; `x-usb3-tunnel` shows the state; `preos-usb3=on` makes the
  pre-OS firmware CM build the tunnel too. USB4 dialect only: a Thunderbolt 3 router has
  no USB3 adapter, so in the TB3 dialect (and under the firmware-CM profiles, which are
  TB3 host routers) USB reaches a dock through the PCIe tunnel to the dock's own xHCI
  (`dock=on usb-drive=`), and `usb3-dev` is refused there. Verified by qtest
  `usb4-usb3-test` (9 cases: setup, data through the tunnel read with bulk-only SCSI by an
  xHCI driver in the test, teardown, surprise unplug, a fault rule combined with it, hub
  subtree, system reset, pre-OS tunnel, refusals, and the TB3 dock's xHCI under the
  Alpine Ridge and Ice Lake firmware CMs); the other eleven usb4 suites pass unchanged.
- [x] Generic profile, Windows 11 half, 2026-10-14: the Windows built-in CM sets USB3
  Tunneling On, programs HopID 8 USB3 paths both ways, enables both USB3 adapters and does
  the bandwidth request/acknowledge handshake in router config space (no xHCI register
  changes needed); the `usb-storage` behind the device router attaches only while the
  USB3 tunnel is up, survives NTFS write/read-back, and leaves and returns with
  `device_del`/`device_add` of the router. Verified with `USB3=1 scripts/run-cm-test.sh`
  together with the dock and port 2. USB3 tunnels are tracked per device router and work
  through a daisy chain in the fabric harness.
- [ ] Exit: a USB device behind the tunnel appears on the xHCI in Linux and Windows 11.
  Suspend and resume keep device relations.
  Windows 11 (built-in CM) was shown on 2026-10-14 (above). Guest runs 2026-10-22
  ([GUEST-EXITS.md](GUEST-EXITS.md), QEMU `c8d878e`, TCG):
  - [x] Linux, software CM on `usb4-generic`: the CM builds the USB3 tunnel during
    enumeration and `usb 2-1` (`USB3EMU01`) connects on the `qemu-xhci` after the path
    activation, not before; `x-cable=false` disconnects it with the router (also with an
    O_DIRECT write running: `dd` gets EIO, nothing hangs), the replug brings it back with
    its data. S3 (`mem`, woken by `system_wakeup`), twice: Linux restarts the USB3 tunnel
    and resets the same USB device (same device number, same data).
  - [x] Windows 11, built-in CM, with this binary: the USB disk is on the xHCI with the
    tunnel up, leaves with `x-cable=false` and returns with its NTFS data.
  - [ ] Windows 11 suspend and resume: owed. The guest offers no S3 ("An internal system
    component has disabled this standby state: Graphics", the basic display adapter on
    `-vga std`) and no S0 low power idle.
  - Finding: across Linux S3 the NVMe in the PCIe tunnel did not keep its device (the
    model replaced the endpoint when Linux bounced the PCIe paths on resume and pciehp
    removed it). Resolved 2026-10-22 by the link retrain (owner decision; ARCHITECTURE.md
    4.4 "Link retrain", `link-retrain` on the PCIe tunnel slots): the NVMe keeps its
    `pci_dev` and data across Linux S3 on `usb4-generic` (GUEST-EXITS.md, "With the link
    retrain"); qtest `usb4-retrain-test`.

## Later, unscheduled

- [x] Dock-style device router (2026-10-14): PCIe switch with NVMe, e1000e and qemu-xhci
  plus a USB device behind one tunnel, `usb4-device dock=on`; `DOCK=1 scripts/run-cm-test.sh`.
- [x] Second host USB4 port with its own tunnel root port (2026-10-14), `tunnel-port2`.

- [x] Titan Ridge firmware-CM variant (2026-10-15), `profile=tb3-titan-ridge` (4C, `ports=1`
  for 2C), from the Linux client only: route-addressed ICM dialect, Titan Ridge IDs and
  host router layout, `usb4-tr-*` switch types, run scripts. Verified by qtest
  `usb4-icm-tr-test` (10 cases), the fabric harness and Kubuntu 26.04.1 live (kernel
  7.0.0-30): firmware CM bound, both ports' device routers enumerated by route, approve,
  NVMe data checks, unplug and re-plug, driver rebind, pre-boot with the switch topology,
  runtime suspend with RTD3. A capture of real Titan Ridge hardware is still needed;
  see `docs/ICM-TITAN-RIDGE.md` and `docs/LINUX-TEST.md`.
- [x] Real USB4 enclosure preset (2026-10-15), `usb4-device device-model=asm2464`: the
  ASMedia ASM2464PD of the maintainer's ORICO AAGM2-U4, generated from the Framework 13
  capture (`tests/captures/framework13-12th/linux-orico`, analysis
  `docs/captures/ORICO-ASM2464.md`). Verified by the replay of the captured Linux CM
  (`run-asm2464-conformance.sh`: 97.1% of 6,773 device-router read dwords, all 115 writes
  with the captured outcome), the fabric harness (`test_asm2464`), qtest
  `usb4-asm2464-test` (4 cases; the other suites unchanged: host 23, tunnel 29, icm 16,
  icm-tr 14, harness 25, asm4242 8), and unmodified Linux (Kubuntu 26.04.1 live,
  `intel-adl` host): the real enclosure's probe lines and `unique_id`, the 0.6 s
  reconnect after "0: resetting", PCIe tunnel through the ASM2464 switch, NVMe data
  check, unplug and re-plug.
- Other Intel ICM generations: Ice Lake, Tiger Lake integrated, Maple Ridge (Titan Ridge message set).
- Stopped-firmware restart path, and the controller's internal PCIe switch topology (captured; deferred by the decision in `ARCHITECTURE.md` §4.4).
- DMA port mailbox at the captured NHI adapter number, NVM version reporting and NVM
  upgrade, which would remove the adapter-type deviation from the captures.
- DisplayPort tunneling as a path-accepting stub adapter.
- Daisy chaining through downstream lane adapters on device routers.
- Inter-domain links.

## Out of scope for this repository

- Connection manager and ICM client drivers for Windows 98 through Windows 7. They live in
  xhci98 and use this model as their test bed. The model keeps them viable by supporting
  INTx and polling, the i440FX machine, and PCI-only guests.
- NVMe endpoint drivers for legacy Windows.
