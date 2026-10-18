# Architecture

Status: draft, revised 2026-10-14 after eight Codex review rounds; firmware-CM profile
retargeted from Titan Ridge to Alpine Ridge LP the same day, after the first P14s capture.
"Spec" is the USB4 Specification 2.0 and "Guide" is the USB4 Connection Manager Guide 2.0,
both in `docs/references/usb-if/`. "L" is the Linux `drivers/thunderbolt` tree in
`docs/references/linux-thunderbolt/drivers_thunderbolt/` and "B" is FreeBSD
`sys/dev/thunderbolt` in `docs/references/freebsd-thunderbolt/sys_dev_thunderbolt/`.
Linux function names are cited as behaviour evidence only; see the licence rules in
`AGENTS.md`.

## 1. Goal, hardware reality, non-goals

**Goal.** A QEMU device model of a Thunderbolt 3 / USB4 host that is faithful enough for an
unmodified operating system to run its connection manager (CM) against it, enumerate a
device router, and bring up a PCIe tunnel to an NVMe endpoint. The model exists so that the
xhci98 project can develop CM drivers for Windows 98 through Windows 7 without real
hardware. This repository holds only the QEMU model. It is validated here with Linux and
with modern Windows.

**Hardware reality.** The real demo machine is a ThinkPad P14s Gen 1 with UEFI CSM and a
discrete Intel JHL6240 **Alpine Ridge LP** Thunderbolt 3 controller (NHI `8086:15bf`),
confirmed by the 2026-10-14 capture in `tests/captures/p14s-gen1/`. Earlier drafts assumed
Titan Ridge; the maintainer approved retargeting on 2026-10-14. No USB4 devices are
available. On a PC Alpine Ridge host the connection manager runs in the controller
firmware (Intel "ICM"). The OS driver does not program paths; it sends ICM commands and
NHI mailbox commands and receives device-connected events, and the firmware sets up the
tunnel. The model therefore has two host profiles, below, and the Alpine Ridge one is
what the xhci98 driver must work against first. Titan Ridge, whose ICM message set
differs (`ICM-PROTOCOL.md` §4.9), is an uncaptured later variant, modelled from the Linux
client only as `profile=tb3-titan-ridge` (`ICM-TITAN-RIDGE.md`, all inferred).

**Non-goals for the first two profiles.** Tracked in `ROADMAP.md`:

- USB3 tunneling and an integrated xHCI.
- DisplayPort tunneling.
- Inter-domain (host-to-host) links.
- CL low-power states, and TMU behaviour beyond what guests need to proceed.
- NVM firmware upgrade and NVM version reporting. The DMA port is deliberately not
  discoverable under the firmware CM, see §4.2.
- Restarting stopped ICM firmware (the PCIe-to-fabric mailbox in the vendor-specific
  capability of the controller's PCIe upstream port, `ICM-PROTOCOL.md` §2.7). The model
  always boots with firmware already running and authenticated.

## 2. Host profiles

Both profiles share the host interface rings, the control packet machinery, the fabric,
the tunnel evaluator and the PCI integration. They differ in PCI identity, interrupt
register semantics, who decides tunnels, and the config space dialect. Profile is a
`-device usb4-host,profile=` property.

| | `tb3-alpine-ridge` | `usb4-generic` |
|---|---|---|
| Matches | ThinkPad P14s Gen 1 (JHL6240 Alpine Ridge LP) and other Alpine Ridge PCs | Any USB4 host, future hardware |
| PCI ID | NHI `8086:15bf` rev 01, class `0x088000`, subsystem `17aa:22b0`, as captured (`ICM-PROTOCOL.md` §1) | emulator-specific vendor and device, class `0x0C0340` |
| Connection manager | emulated firmware CM (ICM, Alpine Ridge message set) | guest software CM |
| How a guest picks it | Intel NHI device ID, no ACPI native-USB4 `_OSC` grant, and firmware status showing ICM enabled and NVM authenticated at reset (`ICM-PROTOCOL.md` §2.2) | emulator vendor ID, so no ICM probe matches, and the class-code match takes the software CM |
| Interrupt status semantics | Intel register set: read-to-clear status, optional clear-on-delivery enabled by a control bit, mask by writing the interrupt enable register (`ICM-PROTOCOL.md` §2.5) | USB4 register set: read-to-clear by default, made non-destructive by the Disable ISR Auto-Clear control bit, plus explicit clear and mask-clear registers (Spec §12.6.3.1.4 Table 12-14, §12.6.3.4.1 Table 12-28) |
| Linux path | firmware CM client, Alpine Ridge variant, selected by NHI device ID | `tb.c` software CM via class match |
| Windows path | Intel Thunderbolt driver package installed in the guest | Windows 11 built-in CM via ACPI `_OSC` and `_DSD` |
| Router dialect | `tb3`: Intel vendor-specific capabilities, link controller, EEPROM bit-bang (UID on the host, full DROM on device routers) | `usb4`: ROUTER_CS and ADP_CS layouts, router operations, USB4 DROM |
| Who programs paths | the emulated ICM, on approve | the guest, through config writes |
| Legacy driver work in xhci98 | ICM client: firmware status and mailbox handshakes, driver ready, device-connected events, get route, approve, PCI re-enumerate | full software CM per the Guide |

**Controller variants of the TB3 profile (2026-10-15).** The firmware-CM profile has
one internal profile value and a controller variant in the thin profile layer:
`profile=tb3-alpine-ridge` (Alpine Ridge LP, captured) or `profile=tb3-titan-ridge`
(Titan Ridge 4C, NHI `8086:15eb`, router `8086:15ea`, two Thunderbolt ports; `ports=1`
gives 2C, `15e8` / `15e7`). The variant selects only the PCI identity, the host router
layout (Titan Ridge: PCIe Down 8 / 9, NHI 5) and the ICM message dialect
(route-addressed events and approve, four-word driver ready). Register set, interrupt
rules, mailbox, `tb3` config dialect, pre-boot, boot ACL, BIOS Assist power and the
ICM's path programming are shared, so no shared part is forked. A separate profile
would have duplicated every Alpine Ridge profile check for no difference in behaviour.
Contract: `ICM-TITAN-RIDGE.md`. Until 2026-10-14 `tb3-titan-ridge` was the name of the
code stub, then a deprecated alias of `tb3-alpine-ridge`; it now means the Titan Ridge
variant.

The `tb3-alpine-ridge` profile is deliberately an impersonation of an Intel controller,
because that is the only way guests take the firmware CM path. The `usb4-generic` profile
must never use Intel IDs, because those select quirks and ICM probing.

## 3. Guest-visible contract

| Item | Value | Why |
|---|---|---|
| Register layout | Spec §12 host interface registers | The de-facto NHI layout that B `nhi_reg.h` describes; Alpine Ridge uses the same, with 12 rings (`ICM-PROTOCOL.md` §2.1). |
| Firmware status register | ICM enable, NVM auth done, CIO reset request bits. AR profile resets to the captured `0x800001a1`. | `ICM-PROTOCOL.md` §2.2. |
| NHI mailbox (AR profile) | inbound data and command (request and error bits), outbound with the firmware operating mode; mode 3 (CM), outbound resets to the captured `0x800003f5`. Commands: allow-all-devices, save-devices, disconnect-PCIe-paths, driver-unloads, disconnect-PA, disconnect-PB. | `ICM-PROTOCOL.md` §2.3. |
| Interrupts | MSI (single vector) and INTx; MSI-X optional | Linux has no INTx fallback. On the real P14s Linux used MSI-X (16 vectors) with the Intel auto-clear bit; without MSI-X it falls back to single MSI (`ICM-PROTOCOL.md` §2.5). The xhci98 legacy Windows drivers poll. |
| Tunneled PCIe | one bridge whose secondary bus is gated by tunnel state | q35: `usb4-tunnel-port`, a `pcie-root-port` subclass. i440FX (legacy Windows): `usb4-tunnel-bridge`, a `pci-bridge` subclass with SHPC. Names provisional, see §4.4. |

## 4. Components

```
guest OS
   |  BAR0 MMIO (rings, FW_STS, mailbox), DMA rings, MSI/INTx
   v
[1] host interface  --ring 0 packets-->  [2] fabric (tb3 / usb4 dialect)  <--  [2b] emulated ICM
                                             |  router/adapter/path state        (tb3 profile only)
                                             v
                                        [3] tunnel evaluator
                                             |  up / admin-down / eject / surprise
                                             v
                                        [4] PCI integration  --> QEMU bridge + nvme
```

### 4.1 Host interface

- BAR0 register file: TX and RX ring base, producer, consumer and size, ring options, ring
  interrupt status, mask and clear, interrupt throttling, DMA misc, firmware status,
  mailbox, hop count, reset. Layout per Spec §12.5 and §12.6.
- Descriptor rings in guest memory, 16-byte descriptors: buffer address, length, EOF and
  SOF protocol fields, flags. Ring 0 carries control packets and ICM packets. Other rings
  exist only to satisfy the register map.
- Required ring behaviours: wraparound, completion written before interrupt delivery, RX
  descriptor exhaustion, cancellation on reset.
- Interrupt status clearing is a function of profile **and control-register state**, not
  a fixed profile choice. The shared ring engine raises a status bit; the profile layer
  owns the clearing rules:
  - `tb3-alpine-ridge`: a read of the ring status register clears the bits read. Clearing
    on interrupt delivery happens only while the Intel auto-clear control bit in the DMA
    misc register is set, which Linux sets only for per-ring MSI-X. With single MSI the
    handler reads the status registers to find pending rings, so delivery must not clear
    them.
  - `usb4-generic`: a read clears unless the Disable ISR Auto-Clear bit in Host Interface
    Control is set, in which case reads are non-destructive and the explicit clear
    register is the only software clear. Delivery never clears.
  - Both: a host interface reset clears all status.
  Provenance for the Intel rules is `ICM-PROTOCOL.md` §2.5 (capture plus clean-room
  description); M1 may not implement an Intel-specific MMIO semantic beyond it.
- **Polling truthfulness.** Descriptor completion and the producer and consumer indices are
  visible to the guest as soon as a descriptor completes, independent of interrupt
  delivery or masking. Interrupt status is cleared only by the rules above or by reset. A
  poller must act on a status read when reads clear. Polling tests run in every clearing
  configuration, and the Linux single-MSI initialisation sequence is a qtest.

### 4.2 Fabric

- A tree of routers. Route 0 is the host router. Each router has lane adapters and
  protocol adapters, each with an adapter configuration space, a capability chain and a
  path configuration space. Each router carries a `dialect` of `tb3` or `usb4`.
- Control packets per Spec §6 and Guide §3: read, write, error, event and notify-ack, with
  route string, sequence number, config space selector (path, port, router, counters) and
  CRC32C. Packets with a bad CRC are dropped. Spec Appendix A.2 vectors are the unit
  tests. B `router.c` is the code reference for packet handling.
- Config spaces are stateful. Dialect-specific readiness is normalised into shared fabric
  state (§4.3):
  - `usb4` dialect: router header, capability chains, router operations with completion
    status, Configuration Valid written by the CM on device routers and Configuration Ready
    reported back, PCIe Tunneling On, lock bit on downstream adapters, USB4 DROM via
    router operations. Configuration Valid and Ready do not apply to the host router.
  - `tb3` dialect: router header and adapter headers, the Intel vendor-specific
    capabilities for plug events / EEPROM and link controller, and no Configuration Valid
    handshake (L `tb_switch_configuration_valid()` is a no-op for TB3).
- The lock bit on a downstream adapter rejects control packets forwarded through that
  adapter. It is not a data-path gate and is tested separately from tunnel forwarding.
- Native events: a hot-plug event on ring 0 when a device router is attached or detached,
  resent until acknowledged (Guide §3.1.1 and §4.3). In the AR profile the ICM consumes
  these internally and emits ICM events instead; no native hot-plug packet reaches the
  guest.
- Register bitfield tables are generated from `docs/references/tbtools/registers.json`.

#### What a guest reads under ICM (tb3 dialect checklist)

Linux still walks the fabric with ordinary config reads after an ICM event, so the `tb3`
dialect must serve all of the following for the host router and each device router:

All rows observed on the P14s unless marked; details and register values in
`ICM-PROTOCOL.md` §5.

| Read | Host router (route 0, `8086:15c0`) | Device router (dock: route 1, `8086:15d3`) | Reference |
|---|---|---|---|
| Router header (vendor, device, upstream adapter, highest adapter) | yes; upstream adapter 3, highest 5 | yes; upstream adapter 1, highest 11 | §5.1, §5.3 |
| Router capability chain (TMU, vendor-specific sub-ids 0-6) | yes, walked repeatedly | yes | §5.1 |
| Adapter type, header and capability chain for every enabled adapter | 1-2 lane, 3 NHI, 4 PCIe down, 5 DP in | lane, PCIe up/down, DP out; DROM-disabled ones skipped | §5.1, §5.3 |
| Link controller fuse UUID | yes, source of the host UUID | not read: the UUID comes from the event | §5.1 |
| Plug-events capability and EEPROM bit-bang | UID only (9 bytes) | full DROM (0x70 bytes for the dock) | §5.4 |
| DMA port probe: adapter type of 3, 5, 7 | adapter 3 is NHI-typed; NVM DROM and version read through its mailbox | adapter 5 is NHI-typed; NVM version read | §5.2 |
| Router device ID maps to generation 3 | required | required (any Intel TB3 router ID; generation 1 otherwise) | §5.1 [inf] |
| Link, CLx, TMU, path and hop setup | none under ICM | none | §5.5 |
| Writes | EEPROM control dword and DMA-port mailbox only | same | §5 |

DMA port fidelity trade-off: the real host router exposes its NHI adapter at 3, which is
also its upstream adapter, and the dock's router has an NHI-typed adapter at 5; Linux
uses them as the NVM mailbox and shows NVM versions 23.0 and 44.0. The model by default
reports no NHI-typed adapter at 3, 5 or 7, so the probe fails and NVM support is skipped
without error; this is a deliberate deviation, noted in
`tests/captures/p14s-gen1/README.md`. On the host it also means adapter 3, the upstream
adapter in the router header, reads as a non-NHI type; nothing in the Linux client
depends on that. The capture now specifies the mailbox completely (flash read only,
`ICM-PROTOCOL.md` §5.2, requirement R20), so a read-only DMA port behind a property is a
small, unscheduled follow-up; it becomes necessary if the Windows smoke gate shows the
Intel driver needs it. The TB3 device router on a `usb4-generic` host (software CM) has
the DMA port since `usb4-win11tb3` (2026-10-16, in main as of QEMU `2a893ea`), because Windows 11's built-in CM fails
a TB3 router without it (`USB4-HOSTS.md` §8); the `tb3-*` profiles are unchanged.

Host DROM: with no DMA port the client reads only the UID from the EEPROM by bit-bang,
which it accepts. Device DROM: served byte by byte through the EEPROM bit-bang protocol
in the plug-events capability (a SPI-style read command and 16-bit address, decoded in
`ICM-PROTOCOL.md` §5.4), so the model implements that state machine on every `tb3`
router.

Identity consistency rule: for a device router, the UUID in the ICM device-connected
event (bytes 0-7 equal the DROM UID, bytes 8-15 all ones, as captured), the DROM UID and
the link controller fuse must describe the same device. Linux takes the UUID from the
event and the name and vendor from the DROM.

### 4.2b Emulated ICM (tb3-alpine-ridge profile)

An in-emulator connection manager that owns the fabric when the profile is Alpine Ridge.
Its wire contract is `docs/ICM-PROTOCOL.md`, written from the P14s capture plus a
clean-room reading of the Linux client (the rule before the 2026-10-15 relicensing, see
`AGENTS.md`). Implementers of the ICM code work from that document; its §8 requirements
R1-R30 are the checklist. Linux code may now also be adapted, but behaviour seen only in
Linux stays `inferred` until a capture confirms it.

**Pre-boot mode (`preboot=on`, `ICM-PROTOCOL.md` R25, §12.1).** The real firmware, with
the BIOS "Support in Pre Boot Environment" option on, approves boot-ACL devices and
builds their PCIe tunnels at power-on, so a guest with no Thunderbolt driver at all
(SeaBIOS, DOS, Windows 98) sees the device's PCIe tree, and an OS client later sees the
device as approved and boot-present. The model does the same at emulator cold reset,
before guest firmware enumerates PCI, through the same approve path as step 3. This is
the recommended route for legacy guests that only need the endpoint; the full ICM client
is needed for hot-plug. The powered-down "nothing attached" behaviour and ACPI force
power (R27, R28) stay optional.

**Startup, firmware already running.**

1. At reset the firmware status register reads `0x800001a1` (ICM enabled, NVM
   authentication done) and the outbound mailbox `0x800003f5` (CM operating mode).
2. The guest sends mailbox allow-all-devices; the model completes it by clearing the
   request bit without error.
3. The guest sends driver ready on ring 0. The 2-word response carries ROM and RAM
   version bytes, security level, boot ACL support and entry count, and the RTD3 flag.
   Advertised values are a commitment: security level `user` by default; boot ACL
   supported with 16 entries, as captured, backed by a 16-slot store (R14); RTD3 off by
   default, because the captured "on" makes Linux runtime-suspend the NHI to D3 and
   re-run driver ready every few idle seconds; an `rtd3=on` property reproduces the
   capture. A `security=none` property is also offered: in that mode the ICM programs
   the paths itself before announcing a device, and the device-connected event carries
   the approved flag in its link info, for boot-present, hot-added and reconnected
   devices alike. Linux then creates the device already authorised.
4. After driver ready, the ICM announces every device already attached with a
   device-connected event, in adapter order. This also covers driver reload and resume.
   The real firmware holds config requests until it has done so; the model may answer
   them at once but never drops them.
5. Mailbox driver-unloads makes the ICM forget the driver, but tunnels and approvals
   persist (observed); the next driver ready repeats step 4, and a device that left in
   between is simply not announced.

**Command support matrix.** This is the single source for M2 scope.

| Code | Command | Handling |
|---|---|---|
| 0x03 | driver ready | supported |
| 0x0a | get route | supported: link and depth to route string; the Alpine Ridge client sends it after every new device-connected event |
| 0x04 | approve device (UUID, connection key, connection id) | supported: programs paths and enables in the fabric, replies with the request echoed and no error; duplicate approve of an approved device, including one auto-approved under `security=none`, replies success. In M2 the fabric write is a stub that only records approval; the full behaviour lands with the evaluator in M3 |
| 0x18 | boot ACL read / write | supported: 16-slot store, no effect on approval |
| 0x05, 0x06 | challenge device, add device key | reply with the error flag; not needed at security level `user` or `none` |
| 0x10, 0x11 | inter-domain approve / disconnect | reply with the error flag |
| 0x01, 0x20 | topology query, USB4 router operation | reply with the error flag; not used by Alpine Ridge clients |
| other | unknown | reply with the error flag |

**Events.** Device connected (61 words) with endpoint UUID, connection key and id, link
info (host lane adapter as link, depth, approved bit) and endpoint name block; device
disconnected with link info. There is no route string in Alpine Ridge events, which is
why get route exists. Rules: a fresh connection id per announcement, never reused for a
router still announced; events for one port are ordered; a disconnect is sent only for
an announced device and only while a driver is ready. All ICM messages are single
packets (index 0, count 1).

**Behaviour on approve.** The ICM writes the same fabric state a software CM would: the
path entries in both directions, Path Enable on both PCIe adapters. The tunnel evaluator
therefore sees no difference between profiles. Mailbox disconnect-PCIe-paths tears down
every PCIe tunnel, which is the only deauthorisation the Alpine Ridge client has; there
is no per-device disapprove (Linux reports `deauthorization` 0 on the P14s).

### 4.3 Tunnel evaluator

A pure function of fabric state, identical for both profiles. The fabric exposes a
normalised `ready_for_pcie` flag per router:

- `usb4` dialect device router: Configuration Valid set by the CM, Configuration Ready
  reported, and PCIe Tunneling On set (Spec Table 8-3, `ROUTER_CS_5.CV`, `.PTO`,
  `ROUTER_CS_6.CR`).
- `usb4` dialect host router: ready once enumerated. PCIe Tunneling On, Configuration
  Valid and Configuration Ready do not apply to the host router (Spec Table 8-3; the CM
  must not change them), and Linux's USB4 setup returns early for it.
- `tb3` dialect router: always ready once enumerated.

A PCIe tunnel between the host PCIe down adapter and the device PCIe up adapter is up when
(Guide §5.2 and §5.3):

1. The device router is attached and its lane adapters report link up.
2. Both routers are `ready_for_pcie`.
3. A valid path exists in each direction through every hop, using HopID 8 at the PCIe
   adapters, with credits allocated.
4. Path Enable is set on both PCIe adapters.
5. The device PCIe adapter LTSSM has left Detect, which the model reports once 1 to 4 hold.

Transitions: `up`, `admin-down` (CM cleared a path or an enable, or ICM disconnect-PCIe-
paths), `eject` (orderly unplug), `surprise` (device removed while the tunnel was up). The
evaluator never touches QEMU PCI state. A QMP test command can force `admin-down` so the
teardown path is testable on the AR profile.

### 4.4 PCI integration

- The upstream bridge is always present at boot so firmware and the guest assign bus
  numbers and windows for it.
- **Captured topology and the decision not to mirror it (2026-10-14).** On the P14s the
  controller is its own PCIe switch behind PCH root port 00:1c.4: upstream port 03:00.0
  and downstream ports 04:00.0 (NHI on bus 05), 04:01.0 (the tunnel: hot-plug and
  surprise-removal capable slot, buses 06-2a) and 04:02.0 (the controller's own xHCI
  `8086:15c1` on bus 2b), all `8086:15c0`, subsystem `17aa:22b0` (`ICM-PROTOCOL.md` §1).
  The model keeps one gated tunnel bridge and puts the NHI directly on the machine's bus.
  Reasons: the Linux client never looks at the switch while the firmware runs (it uses
  the upstream port only on the firmware-start path, a non-goal); the i440FX profile for
  Windows 98 cannot have a PCIe switch at all; and the tunnel port 04:01.0 already
  behaves like `usb4-tunnel-port` (a hot-plug PCIe downstream slot whose link follows the
  tunnel). Cost: a guest that walks from the NHI up to an Intel `15c0` upstream port, or
  expects the tunnel port to be a sibling of the NHI, will not find that layout. Whether
  the Intel Windows driver does is the open hypothesis tested by the smoke gate in
  `ROADMAP.md` M3. If it fails there, the q35 fallback is to place the NHI and the
  tunnel port under a QEMU upstream port and downstream ports carrying the captured
  Intel IDs, keeping the gate on the tunnel downstream port; the integrated xHCI stays
  out of scope (USB3 is a non-goal).
- The tunnel bridge is a thin subclass of the stock QEMU bridge types: provisionally
  `usb4-tunnel-bridge` from `pci-bridge` with SHPC on i440FX, and `usb4-tunnel-port`
  from `pcie-root-port` on q35. It keeps their hot-plug and config
  behaviour and adds only the gate below. In QEMU each endpoint gets its own bus-master
  address space, derived when the endpoint is realised from the nearest bus that provides
  a DMA address space, normally system memory. A stock bridge's own bus-master region is
  not on that path, so it cannot gate endpoint DMA. The subclass therefore installs a
  **gate address space** on its secondary bus, using the same per-bus hook a virtual
  IOMMU uses. It is a container holding one enable-able alias of system memory. Every
  endpoint realised behind the bridge inherits it as its DMA target, so endpoint DMA and
  MSI or MSI-X writes, which QEMU sends through the same address space, pass through one
  switch the integration layer controls. Consequence: this profile cannot also place a
  virtual IOMMU above the tunnel bridge. That is acceptable for the first profiles.
- On `up`, the endpoint (QEMU `nvme`) is realised and hot-plugged onto the bridge's
  secondary bus through QEMU's existing hot-plug handlers, after the gate is opened.
- **Access gating is separate from guest-visible removal.** QEMU's SHPC and PCIe
  hot-unplug are requests: the guest may delay or ignore the eject, so unplug alone does
  not block the endpoint. Every down transition therefore runs four stages. Only stage 1
  is synchronous; the rest run from a bottom half, because realisation, reset and removal
  are not safe inside a register write callback.

  1. **Gate, synchronous.** In the same call that changes fabric or ICM state, before
     control returns to the guest or to the emulated ICM, the PCI integration layer closes
     a persistent gate on the tunnel bridge's secondary side:
     - guest MMIO to the bridge's forwarding windows is no longer routed to the endpoint.
       The subclass disables its window aliases and re-applies that state after any guest
       write to the bridge's own config space, which would otherwise rebuild them.
       Reads that the windows would have forwarded return all-ones of the access size
       and writes are dropped, as on a real link drop (completion timeout or
       Unsupported Request, which x86 hosts turn into all-ones), so a removal-aware
       driver sees `CSTS == 0xFFFFFFFF`. The all-ones regions are fallback decoders
       below every real primary-bus decoder, follow the bridge's programmed windows,
       and are rebuilt with the aliases after any reset (bus reset, machine reset, FLR);
     - the gate address space's alias is disabled, so every new DMA translation from any
       endpoint behind the bridge fails, including MSI and MSI-X writes;
     - config reads to the secondary bus return all-ones and config writes are dropped,
       so the guest cannot re-enable BAR decoding or bus mastering while removal is
       pending;
     - INTx from the secondary bus is masked at the bridge and deasserted.
     The tunnel bridges, like `usb4-host`, are not migratable: slot and gate state is
     not serialized, so `savevm`/`loadvm` and migration are refused, and a refused
     `loadvm` leaves disks and machine state untouched. Offline `qemu-img snapshot`
     (used by the run scripts) is unaffected.
     These are memory-region and routing toggles only, with no device reset. This
     matches Guide §5.3.2, where PCIe packet transport is disabled during teardown and a
     physical unplug drops the link. The exact QEMU mechanism for the config-space part
     (per-device power state without reset, or interception at the bridge) is chosen and
     verified at the start of M3.
  2. **Quiesce, bottom half.** The endpoint is reset, which drains its outstanding
     block-backend I/O. Gating does not revoke host pointers that QEMU's DMA helpers
     already mapped for submitted requests, so a backend read submitted before stage 1
     can still land data in guest RAM until the drain finishes. Completion-queue writes
     and interrupts for those commands are blocked by the gate, so the guest never sees
     them complete; it sees them as lost, as after a real link loss, and its NVMe driver's
     timeout handling applies. **The declared cutoff for guest memory is the end of
     stage 2.** A QMP event marks it. After the cutoff, guest memory cannot change on the
     endpoint's behalf.
  3. **Notify, bottom half.** Slot presence change and attention are signalled through
     the bridge's hot-plug machinery. `admin-down` and `eject` raise the orderly request;
     `surprise` marks the slot empty without a request.
  4. **Remove, bottom half.** The device object is unrealised when the guest completes
     the eject, immediately on `surprise`, or after a timeout if the guest never responds.

- **Reconnection while a removal is pending.** An `up` always realises a fresh endpoint,
  never re-opens the old one. Two kinds of late work could otherwise hit the replacement:
  - *Emulator work* (removal timeouts, deferred unrealise). Each endpoint instance has a
    generation number; this work carries the generation it was issued for and does
    nothing if that no longer matches the slot's occupant.
  - *Guest slot commands* (PCIe Slot Control power-off, SHPC slot commands). These carry
    no generation, and the stock handlers act on whatever occupies the slot. The model
    does not try to tag them. Instead it makes them unambiguous in time: if the previous
    endpoint is still waiting for the guest's eject, its removal is forced to completion
    as surprise removal and the slot reports empty with a presence-change event. The
    replacement is not inserted until the guest has acknowledged that event (cleared the
    presence-detect-changed status in Slot Status, or the SHPC equivalent) or a settle
    timeout has passed. Without acknowledgement the timeout path still inserts the
    replacement, but it does not imply the guest observed the empty slot.
  - *Slot state persists across the empty interval.* A slot command that arrives while
    the slot is empty cannot remove the replacement, because there is nothing in the slot
    to remove. Its persistent effects do remain: slot power, power and attention
    indicators and the SHPC slot state are kept by the stock handlers. So if the guest
    powered the slot off while it was empty, the replacement is inserted present but
    unpowered, and becomes reachable only when the guest powers the slot on, as on real
    hardware. Who enforces that differs by bridge type:
    - `usb4-tunnel-port` (PCIe): the stock plug path already applies the retained Slot
      Control power state to a newly plugged device, so no extra work is needed.
    - `usb4-tunnel-bridge` (SHPC): the stock SHPC handlers retain the slot state and
      indicators but do not enforce them on a newly plugged device, and PCI realisation
      leaves the endpoint enabled. The subclass therefore enforces the SHPC slot state
      itself: it observes the slot state after every guest SHPC command and after every
      plug, and folds it into the access gate. In the Disabled and Power-only slot states
      the gate is held closed exactly as for a tunnel down transition, stage 1 only, with
      no quiesce or removal. Only the Enabled state lets the gate open.
    - Stock SHPC starts every empty slot Disabled and plugging does not enable it, so a
      guest without an SHPC controller driver would never reach the endpoint. The
      subclass has a `shpc-autoenable` property for such guests. When off, the default,
      the guest must enable the slot through SHPC as Linux `shpchp` does.
    - **Precedence: explicit guest commands always win.** With `shpc-autoenable=on`,
      the subclass moves the slot to Enabled on insertion only while the slot is
      *unclaimed*, meaning the guest has issued no SHPC slot-state command to it since
      the last bridge reset. Reading SHPC registers does not claim a slot. The first
      slot-state command the guest writes claims the slot, and from then until bridge
      reset autoenable is inactive for it and the persistent-state rules above apply
      unchanged. So a guest that disabled an empty slot keeps the replacement
      inaccessible, whether it was inserted after acknowledgement or after the settle
      timeout, until the guest enables the slot. Autoenable only ever changes the slot
      state; it never touches the power or attention indicators.
  - *Presence, power and the tunnel gate are distinct.* The endpoint is reachable only
    when it is present, its slot is powered (PCIe) or Enabled (SHPC) by the guest, and the
    tunnel is up. The model controls presence and tunnel state; the guest controls slot
    power. On the SHPC bridge both conditions drive the one access gate, which is open
    only when both allow it. A command
    arriving after insertion applies to the replacement, which is also what real hardware
    does with a command issued after the guest saw the slot empty and refilled.
- Toggling PCIe link status bits alone is not enough: QEMU handles slot presence, BAR
  mapping and bus mastering separately, and `pci_set_enabled()` resets the device.

### 4.4a The controller tree leaving and coming back (i440FX)

On the P14s the whole Thunderbolt controller below the PCH root port can go away under
a running OS. With BIOS Assist on, the controller powers off about 11 s after the last
device leaves, and the platform removes it at about 15 s (`ICM-PROTOCOL.md` R32,
§13.4). A real surprise removal of a whole PCI tree is the same thing without the
delay. On i440FX the stand-in for the root port is the root-bus `usb4-tunnel-bridge`
(`tbrp`) that `usb4-host` already uses as its power domain (R27). The same bridge
models both cases with one mechanism (in main as of QEMU `25fd4eb`):

- **Inputs.** `present` (QOM, runtime: `false` is a surprise removal, `true` an
  arrival) and the controller's power (`usb4_tunnel_port_power_domain()`, called by
  `usb4-host` for R27 and R32). The tree is up only when both are.
- **Stage 1, synchronous.** In the call that changed the input, the bridge's access
  gate closes exactly as in §4.4:
  - config reads below return all-ones;
  - the forwarding windows read all-ones (the stand-ins stay at the windows the guest
    programmed);
  - DMA, MSI and INTx stop.

  With `root-hotplug=restore` the configuration of every function below is recorded
  first.
- **Stage 2, bottom half.** The tree is reset, which drains its block I/O, under the
  lifecycle serialization and checked against the transition generation.
- **What the guest is told** depends on `root-hotplug`:
  - `none` (default, the behaviour before this section): nothing. On power-on the tree
    comes back from reset (bus numbers and windows 0).
  - `restore`: nothing. On power-on the recorded configuration is written back, as
    platform firmware would: bus numbers, windows, BARs, cache line, latency timer,
    interrupt line, bridge control and Command. For a gated SHPC tunnel bridge below,
    the slot state, power and attention indicators, event masks and claim tracking are
    restored too. A slot the guest disabled therefore stays disabled, and
    `shpc-autoenable` does not re-arm. This is for guests without ACPI hot-plug: the
    existing devnodes keep working once their drivers re-initialise the reset devices,
    and a rescan finds the tree configured as at boot.
    - Records are keyed by the function's position below the root bridge (devfn on
      each bus level), its device model and, behind a tunnel, what built that tunnel
      (everything the tunnel slot builds the endpoint from: the device router's QOM
      path, drive, serial, namespace backends and count, and the switch and dock
      parameters). They are not keyed by the QEMU
      object. A different device on the port starts from reset, as after a real
      firmware restore.
    - An endpoint whose removal is still pending at the arrival (held, or waiting for
      the guest) neither gives nor consumes a record. Its replacement gets it.
    - The departure's reset removes a tunnelled endpoint. Its replacement is a new
      object, inserted when the tunnel is up again (after the CM's approval). It gets
      the old endpoint's record from the tunnel slot's insertion, before its gate
      opens.
    - A record is used once. When a tunnel slot below loses its occupant after the
      arrival, the records behind it are dropped, so a later endpoint there starts from
      reset, as on real hardware.
  - `acpi`: the guest gets an ACPI **Bus Check** on the bridge's bus-0 slot through
    PIIX4 PCI hot-plug (GPE bit 1, `PCIU`), as the P14s's `WHL_Tbt` GPE handler sends
    a bus check to its root port (`ICM-PROTOCOL.md` §11.1). The guest re-enumerates
    below `tbrp`, finds the switch gone and removes the tree.
    - For a power-off, the notification comes `removal-notify-ms` (default 4400) after
      the power-off. The registers therefore read all-ones from about 11 s and the
      removal comes at about 15.4 s, as on the P14s.
    - `present=false` notifies at once.
    - Power-on is a **fresh arrival** below `tbrp`: everything below comes from reset,
      and a second Bus Check makes the guest enumerate it and assign bus numbers and
      windows.
- **The root bridge itself stays visible** in all modes, like a PCH root port, and
  keeps its bus range and windows. Only a guest eject of its slot (`_EJ0`) makes the
  slot read empty: config all-ones, writes dropped, its own BAR and INTx off. That
  sets `present` to `false`, and the next arrival resets the bridge too. The eject
  acts whatever state the tree is in. If the tree is already down (after an Assist
  power-off, or `present=false`), the slot still goes empty, a pending removal
  notification is cancelled, and the generation moves on.
- **Why the bridge stays realized.** `usb4-host`, the fabric, the device routers and
  the ICM all live inside the tree, and unrealizing it would lose them.
  - QEMU's ACPI PCI hot-plug does not describe a cold-plugged bridge as hot-pluggable.
    So the bridge is an *ACPI slot owner* (`TYPE_ACPI_PCIHP_SLOT_OWNER`, a small
    extension of `hw/acpi/pcihp.c`): its slot gets `_EJ0` and a `DVNT` entry whose
    `PCIU` notification is a Bus Check instead of a Device Check. It raises its own
    notifications and is told about `_EJ0` instead of being unplugged.
  - `device_del tbrp` is still refused.
  - The PIIX4 global `acpi-pci-hotplug-with-bridge-support=off` stays, because it
    keeps SHPC on the tunnel bridges. Root-bus hot-plug is on by default.
  - The AML of machines without a slot owner is unchanged. A slot owner takes part
    only at function 0, which is all the hot-plug description covers; at another
    function it is handled as any cold-plugged device. A participating owner with
    `acpi-index` gets its index from the slot's hot-plug `_DSM` only: the static
    acpi-index `_DSM` is left out, so the device has a single `_DSM`.
- **Late work.** The removal-notification timer and the bottom half act only for the
  generation they were issued for. A plug between the power-off and the notification
  brings the tree back, and the stale notification does nothing. Machine reset applies
  the inputs with no notification and nothing pending.
- **Constraints.**
  - The slot must be on bus 0 inside SeaBIOS's `$PIR` range (slots 1-6, `ROOT_ADDR=6`),
    or Windows 98 cannot route an IRQ to a device that arrives later
    (`WIN98-TEST.md`).
  - `acpi` works only for guests that run in ACPI mode. The xhci98 Windows 98 and
    Windows 2000 images do not (`WIN98-TEST.md`, "The controller tree leaving").
  - q35 is unchanged: there the root port is a `usb4-tunnel-port` whose PCIe slot
    already reports presence.

### 4.5 The NVMe endpoint

The drive behind the tunnel is QEMU's existing NVMe controller model (`hw/nvme`, device
`nvme`), backed by any QEMU block backend such as a qcow2 or raw image. It is a complete
NVMe 1.4 class controller with admin and I/O queues, MSI-X and INTx, namespaces and
optional features, and it already boots Linux and Windows. This repository does not
write an NVMe model; it only controls when that device is reachable. Properties the
tunnel layer passes through: `serial`, `drive`, and anything else `nvme` accepts. Legacy
Windows guests need an NVMe driver from the xhci98 side, as `ROADMAP.md` notes.

## 5. Interrupts and polling

- MSI: one vector covering all ring interrupts. Required by Linux when MSI-X is absent.
- MSI-X (AR profile, optional): 16 vectors in BAR1 as captured, with the vector allocation
  registers and the Intel auto-clear bit (`ICM-PROTOCOL.md` §2.5, R7).
- INTx: level-triggered, asserted while any unmasked ring interrupt status bit is set.
- Polling: the legacy Windows drivers read ring indices and interrupt status in a loop,
  and on the AR profile also drive the MMIO handshakes: read firmware status and the
  outbound mailbox, write inbound data and command, and poll the request bit until it
  clears. Everything the legacy ICM client needs is therefore MMIO accesses plus ring 0,
  with no interrupt dependency.

## 6. QEMU device tree

```
-device usb4-tunnel-bridge,id=br0,chassis_nr=1,...         # i440FX; usb4-tunnel-port on q35 (provisional names)
-device usb4-host,id=u4,profile=tb3-alpine-ridge,bridge=br0 # or profile=usb4-generic
-device usb4-device,id=enc0,host=u4,port=1,dialect=tb3     # device router, one PCIe up adapter
-drive if=none,id=disk0,file=nvme.qcow2
-device nvme,id=nvm0,usb4-device=enc0,drive=disk0,serial=USB4EMU01  # QEMU's own NVMe model, realised on tunnel up
```

Attach and detach at runtime use `device_add` and `device_del` of `usb4-device`. QMP
commands for fault injection and forced tunnel teardown are added per `ROADMAP.md`.

## 7. Legacy Windows constraints that shape the model

The xhci98 drivers target Windows 98 through Windows 7 and are not tested here, but the
model must stay usable for them:

- Windows 98 knows PCI only. The bridge is a plain PCI-to-PCI bridge from its point of view,
  so the i440FX profile with `usb4-tunnel-bridge` (a `pci-bridge` subclass) must keep
  working alongside q35.
- No dependency on MSI, PCIe extended config space or 64-bit DMA addresses.
- Hot-plug of the endpoint behind the bridge is assumed to work on those guests, with the
  driver forcing a re-enumeration of the bridge's bus if the stock enumerator does not
  notice on its own.
- In the Alpine Ridge profile the legacy driver is an ICM client only, driven by polling
  MMIO handshakes and ring 0 as in §5. Its minimum command set is allow-all-devices,
  driver ready, get route and approve (`ICM-PROTOCOL.md` §4); it may skip the DROM and
  use the names in the device-connected event.
- Windows 98 has no SHPC controller driver, and the SHPC slot behind
  `usb4-tunnel-bridge` starts Disabled (§4.4). The xhci98 integration takes one of two
  routes, both polling-compatible: run the bridge with `shpc-autoenable=on`, so approve
  followed by a PCI bus rescan is enough; or have the xhci98 driver enable the slot
  itself by writing the SHPC slot command and polling the command status, then rescan.
  The first is the default recommendation for legacy guests; the second is what real
  SHPC hardware without platform help would need.

## 8. Validation strategy

1. Unit tests and qtests in the QEMU tree for CRC vectors, ring behaviour in both
   clearing modes, mailbox handshakes, ICM message encoding and the tunnel evaluator.
2. Linux guest, `tb3-alpine-ridge` profile: the driver reports the firmware CM, the device
   appears under `/sys/bus/thunderbolt/devices` with name and vendor from the DROM and
   UUID from the event, writing `1` to `authorized` produces `/dev/nvme0n1`, physical
   removal and reconnection are clean. Per-device deauthorisation is not possible on this
   profile and is not an exit criterion.
3. Linux guest, `usb4-generic` profile: the same through the software CM, plus
   deauthorisation via `authorized=0`.
4. Windows 11 guest: pinned Intel Thunderbolt driver package on the AR profile, built-in
   CM on the USB4 profile after ACPI `_OSC` grants (native USB4, USB, with USB, DP and
   interdomain tunneling permitted) and `_DSD` port mapping exist in the QEMU machine.
5. Legacy Windows guests are exercised from the xhci98 project, not here.

## 9. Source layout

QEMU has no stable out-of-tree device API, so the model lives in a QEMU fork on a branch,
under `hw/usb4/`. This repository holds the design docs, the fork as a submodule or a patch
series, guest test scripts and image manifests. See `AGENTS.md`.
