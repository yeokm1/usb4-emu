# Titan Ridge firmware connection manager: host contract (inferred)

Status: first draft, 2026-10-15. Licence: GPL-2.0-only, like the rest of this
repository. Companion to `ICM-PROTOCOL.md` (Alpine Ridge, captured). It describes the
`profile=tb3-titan-ridge` variant of the TB3 firmware-CM profile.

**Nothing in this document is captured.** There is no Titan Ridge machine in
`tests/captures/`. Every statement is tagged:

- **[inf]** what the Linux ICM client expects or does, read from
  `docs/references/linux-thunderbolt/drivers_thunderbolt/` at the pinned commit
  (`icm.c`, `tb_msgs.h`, `nhi.h`, `switch.c`, `tb.c`, `tb.h`, `quirks.c`, `lc.c`). A
  hypothesis until a capture confirms it.
- **[ext]** public PCI ID or product data outside the pinned references.
- **[emu]** an emulator choice where neither Linux nor a capture fixes a value. The
  model must keep it stable, and a capture may change it.
- **[shared]** behaviour taken over unchanged from the Alpine Ridge contract in
  `ICM-PROTOCOL.md`, whose own tags (mostly [obs]) then apply to Alpine Ridge only.

A Linux capture of a Titan Ridge laptop with the P14s capture tool
(`tools/p14s-capture`) would turn most [inf] and [emu] rows into [obs] or corrections.
`CONTROLLER-CATALOG.md` §7 rank 1 lists what to capture.

## 1. Identity

| Item | 2C (JHL7340, one port) | 4C (JHL7540, two ports) | Tag |
|---|---|---|---|
| NHI PCI ID | `8086:15e8` | `8086:15eb` | [inf] Linux `nhi.h`, `pci.c` match table, `icm.c` probe |
| Host router (bridge) ID, router dword 0 | `8086:15e7` | `8086:15ea` | [inf] Linux `nhi.h`; `switch.c` maps both to generation 3 |
| Integrated xHCI | `8086:15e9` | `8086:15ec` | [ext] not in the Linux thunderbolt driver |
| Revision | 6 on NHI, switch ports and xHCI | same | [ext] |
| NHI class | `0x088000` | same | [ext]; Linux binds by ID only [inf] |
| Subsystem | `17aa:22b0` (the P14s value, kept so the platform is "a P14s with a Titan Ridge") | same | [emu] |
| BAR0 / BAR1 / MSI / MSI-X / INTx | as Alpine Ridge LP | same | [shared] [emu] |

Other Titan Ridge IDs the Linux driver lists: the device-side "DD" bridge `8086:15ef`
(device routers in docks; generation 3, and a CLx quirk keyed on NVM major `0x65` that
only the software CM uses) [inf]. The model has no Titan Ridge device router; the
attached device is the captured Alpine Ridge C dock router (`8086:15d3`), which is what a
TB3 dock on a Titan Ridge laptop can be [emu].

The Linux client selects the Titan Ridge dialect by NHI ID `0x15e8` or `0x15eb`; Maple
Ridge (`0x1134`, `0x1137`) uses the same message set with a different "firmware usable"
check, see `CONTROLLER-CATALOG.md` §2 [inf].

## 2. What is shared with Alpine Ridge

[inf] unless noted; the Linux client uses the same functions for both generations:

- Host interface: ring layout, 12 rings, raw ring 0, ICM framing and header word, frame
  types 10/11/12, CRC-32C trailer, error = flags bit 0 (`ICM-PROTOCOL.md` §2-§3).
- Firmware status (ICM enabled, NVM authenticated) and the operating-mode check of the
  outbound mailbox: the client calls the same "is supported" and "get mode" code for
  both. The model resets to the Alpine Ridge values `0x800001a1` / `0x800003f5` [emu].
- NHI mailbox: allow-all-devices (0x23) on bind, driver-unloads (0x07) on unbind, suspend
  and runtime suspend, disconnect-PCIe-paths (0x06). Titan Ridge has no save-devices
  (0x05) call before suspend; the model still completes it.
- Interrupt rules: Intel auto-clear and read-to-clear (`ICM-PROTOCOL.md` §2.5).
- Boot ACL message (0x18): same 16 entries of two words, same read and write layout.
- Runtime PM of the domain: the RTD3 flag at bit 6 of the driver-ready flags; runtime
  suspend sends driver-unloads, resume sends driver-ready.
- Router config dialect (`tb3`): vendor capabilities, plug-events and EEPROM bit-bang,
  link controller with the host UUID at fuse dword `0x102`, DMA-port probe of adapters
  3, 5, 7. No link, TMU, CLx or path access under the ICM.
- After driver ready the client polls host router dword 0 until it is answered.

## 3. Titan Ridge message set

Header word and codes as `ICM-PROTOCOL.md` §3.1 and §4. Word layouts below are 32-bit
values; byte strings inside are packed as in `ICM-PROTOCOL.md` §0 [shared].

### 3.1 Driver ready (0x03), T2

Request: 1 word, as Alpine Ridge.

Response: 4 words [inf] (`icm_tr_driver_ready`):

| Word | Bits | Field | Model value |
|---|---|---|---|
| 0 | 15:8 | flags; bit 6 = controller supports RTD3 | `0xa2`, `0xe2` with `rtd3=on` (Alpine Ridge value) [emu] |
| 1 | 15:0 | reserved | 0 |
| 1 | 18:16 | security level (3 bits; Alpine Ridge has 4) | 1 (`user`), 0 with `security=none` |
| 1 | 22:20 | ICM protocol version; 3 or more enables USB4 router-operation proxying | 2 [emu] |
| 1 | 28:23 | boot ACL entry count (6 bits); no separate "supported" bit; more than 16 makes Linux disable the boot ACL | 16 |
| 2 | 31:0 | NVM version (not used by Linux) | `0x00500000` [emu] |
| 3 | 15:0 | device ID (not used by Linux) | the NHI device ID [emu] |

Linux retries driver ready up to 10 times with a 250 ms timeout on Titan Ridge (5 s
on Alpine Ridge) [inf]. The model answers at once.

### 3.2 Get route (0x0a), T7

Not sent by the Titan Ridge client: events carry the route string [inf]. The model
answers with the error flag, as for any unsupported code [emu].

### 3.3 Device connected (event 0x03), T4

63 words [inf] (`icm_tr_event_device_connected`, `__icm_tr_device_connected`):

| Word | Bits | Field |
|---|---|---|
| 0 | | header; flags as Alpine Ridge: bits 4:3 security level, bit 5 dual lane, bit 7 20 Gb/s; the model sends `0xb1` [shared] |
| 1-4 | | device UUID |
| 5 | | route string bits 63:32 |
| 6 | | route string bits 31:0 |
| 7 | 7:0 | connection id |
| 7 | 15:8 | reserved, 0 |
| 7 | 31:16 | link info, same bit layout as Alpine Ridge (approved bit 8, rejected bit 9, boot bit 10) [inf]; the model also keeps link, depth and bit 11 [emu] |
| 8-62 | | endpoint name block, 55 words, same entries as Alpine Ridge |

No connection key [inf]. The client ignores a frame whose packet index is not 0
(Linux: an extra QoS packet) [inf]; the model sends one packet, index 0, count 1 [emu].
The frame is 252 bytes plus the trailer, exactly the 256-byte RX buffer the client
posts.

Client handling [inf]: known UUID at the same route with the same approval only
refreshes the connection id; otherwise any router or XDomain at that route is removed
and the router is read and registered under the parent found from the route. There is
no get route and no link/depth lookup.

### 3.4 Device disconnected (event 0x04), T5

3 words [inf]: header (flags 0), route high, route low. The client removes the router at
that route.

### 3.5 Approve device (0x04), T6

8 words [inf] (`icm_tr_pkg_approve_device`): header, UUID (4 words), route high, route
low, connection id in bits 7:0 of word 7. The response repeats the 8 words; flags bit 0
means "PCIe tunnel creation failed" (Linux warns and returns an I/O error to the sysfs
write). Approve timeout 10 s as Alpine Ridge.

Model: the device is found by UUID; a wrong route or a stale connection id gets the
error flag; approving an approved device succeeds; the PCIe tunnel is programmed exactly
as on Alpine Ridge (R10), before the response.

### 3.6 Add key (0x06) and challenge (0x05)

Same addressing as approve (UUID, route, id) followed by 8 key or challenge words; the
challenge response appends 8 response words; flags bit 1 = no key stored [inf]. Only
used at security level `secure`; the model answers with the error flag (R15) [emu].

### 3.7 Inter-domain (XDomain) messages

Host-to-host links are out of scope (`ARCHITECTURE.md` §1). For the record [inf]:
XDomain connected (event 0x06) carries link info, remote and local UUID and both route
strings; XDomain disconnected (0x07) route and remote UUID; approve-XDomain (0x10) is
keyed by route and carries transmit/receive path and ring; teardown is ICM message 0x11
sent twice with stage 1 and 2 (Alpine Ridge uses NHI mailbox 0x10/0x11 instead). The
model answers 0x10 and 0x11 with the error flag and never sends 0x06 / 0x07.

### 3.8 USB4 router-operation proxy (0x20)

Used only if the driver-ready protocol version is 3 or more and only for USB4 routers
[inf]. The model reports version 2 and answers 0x20 with the error flag.

## 4. Host router layout (T8)

The Linux ICM client reads whatever adapters the router reports; it does not hard-code
Titan Ridge adapter numbers [inf]. The only Titan Ridge numbers in Linux are in the
software CM: PCIe Down 8 for the first Thunderbolt port and 9 for the second [inf]
(`tb.c`, host PCIe-down mapping). The model's layout, everything except 8 and 9 being
[emu]:

| Adapter | 4C | 2C |
|---|---|---|
| 1, 2 | lane adapters, port A (route 1) | same |
| 3, 4 | lane adapters, port B (route 3) | absent (config reads answer "invalid config space", Linux marks them not implemented) |
| 5 | NHI and Upstream Adapter (DMA-port slot, see below) | same |
| 6, 7 | absent | absent |
| 8 | PCIe Down, port A | same |
| 9 | PCIe Down, port B | absent |
| 10, 11 | DP IN (11 absent on 2C) | 10 only |

Highest adapter 11 in both. No USB3 adapters: a Thunderbolt 3 router has none; USB
reaches the device through the PCIe tunnel to the dock's own xHCI, and the host's
integrated xHCI (`15e9` / `15ec`) is a PCIe function of the controller's switch.

Register images: every Titan Ridge adapter and the router header reuse the captured
Alpine Ridge LP image of the same kind (lane, NHI, PCIe Down, DP IN), with the router
ID, the adapter number, the Upstream Adapter (5) and the highest adapter (11)
overlaid [emu]. The capability chain, plug-events capability, EEPROM and link
controller UUID location are therefore Alpine Ridge's.

DMA port: the client probes adapters 3, 5 and 7 for an NHI-typed adapter [inf]. As on
Alpine Ridge (`ARCHITECTURE.md` §4.2) the model reports none, so the NVM version and the
host DROM copy are not exposed and Linux reads only the host UID by EEPROM bit-bang. On
4C adapter 3 is a lane adapter, so the probe moves on to 5.

Host DROM (EEPROM): the Alpine Ridge format with Titan Ridge adapter entries (lane pairs,
NHI 5, 6 and 7 disabled, PCIe Down 8 and 9, DP IN 10 and 11; port-B entries marked
disabled on 2C) [emu]. Linux does not parse it for the host.

Link controller: the client reads only the host UUID from it under the ICM [inf]. The
Titan Ridge-specific link-controller writes in Linux (connecting the internal xHCI of a
device router on both ports, the PCIe L1 enable of a first-hop Titan Ridge device, CLx
objection masking, TMU objections) are software-CM paths and never run under the
firmware CM [inf].

## 5. Power, force power and RTD3 (T12)

- Linux has no force-power path for Titan Ridge in the thunderbolt driver: the NHI
  mailbox commands are the same six as on Alpine Ridge (`nhi.h`), and the integrated-host
  force-power register block (`pci.c`, Ice Lake and later) is not attached to discrete
  controllers [inf]. Platforms with discrete Alpine Ridge or Titan Ridge expose force
  power through ACPI WMI (`ICM-PROTOCOL.md` §11.2 on the P14s); Linux reaches that, if at
  all, through the separate Intel WMI Thunderbolt platform driver, not through this
  driver [inf].
- The model keeps the Alpine Ridge power model for both variants: `bios-assist`,
  `power=auto|always`, `force-power` (QOM property standing in for the WMI method), and
  the 35 s power-off delay (R27, R28) [shared] [emu].
- With Assist on, the ICM leaves every command unanswered from the last device's
  departure until the power-off, as observed on the P14s (`ICM-PROTOCOL.md` R32,
  `assist-icm-silence`). For Titan Ridge this is [inf]: the same rule is assumed because
  the platform power model is shared; no Titan Ridge machine was captured.
- Runtime D3 of the NHI follows the driver-ready RTD3 flag, `rtd3=on` [shared].

## 6. BIOS conditions (T10)

Security level, pre-boot (`preboot=on` with `boot-acl=`), BIOS Assist and device-at-boot
work as on Alpine Ridge (R14, R22, R25-R30): the dialect only changes message layouts.
A pre-boot approved device is announced with link-info bits approved and boot set
(`0x0d11` for port A) [shared] [emu]. Whether Titan Ridge firmware treats the boot ACL
the same way is not known.

## 7. Model requirements (`tb3-titan-ridge`)

Each is covered by `tests/qtest/usb4-icm-tr-test.c` in the QEMU tree unless noted.

- **T1** Identity per §1: `profile=tb3-titan-ridge` is 4C (`15eb`/`15ea`, two ports);
  `ports=1` gives 2C (`15e8`/`15e7`). Revision 6, class `0x088000`. BAR0 reset state and
  mailbox as R2, R3.
- **T2** Driver ready: 4 words as §3.1; RTD3 from `rtd3=`, security from `security=`,
  boot ACL count 16, protocol version 2.
- **T3** Announce on driver ready (adapter order, port A before port B) and on hot plug
  while a driver is ready; nothing while unloaded (R12).
- **T4** Device connected, 63 words as §3.3, route string = host lane adapter (1 for
  port A, 3 for port B), fresh connection id per announcement.
- **T5** Device disconnected, 3 words with the route (R13 rules).
- **T6** Approve, 8 words as §3.5; UUID, route and id must match.
- **T7** Get route (0x0a), topology (0x01), keys (0x05, 0x06), XDomain (0x10, 0x11) and
  router operation (0x20): error flag.
- **T8** Host router layout of §4 (fabric harness `test_tb3_tr` and the qtest).
- **T9** Boot ACL as R14 and R26.
- **T10** Pre-boot as R25.
- **T11** Switch types `usb4-tr-usp`, `-dsp`, `-tunnel-dsp`, `-pci-bridge`,
  `-tunnel-bridge` (`8086:15ea`) and `usb4-tr-xhci` (`8086:15ec`), revision 6.
- **T12** Power as R27, R28 with the Titan Ridge switch; command silence before the
  power-off as R32 [inf].

Validation (2026-10-15): the qtest (10 cases, 13 since the full-size refusal, two-port
reset and R32 cases), the fabric harness (`test_tb3_tr`), and an unmodified Linux guest
(Kubuntu 26.04.1, kernel 7.0.0-30; `LINUX-TEST.md`, "Titan Ridge profile"): firmware CM
bound, both ports' routers enumerated from the route in the event with no get route,
approve on both ports, NVMe data checks and ext4, unplug and re-plug, driver rebind,
pre-boot with the Titan Ridge switch topology, runtime suspend with RTD3. The Linux run
checks that the model matches what the Linux client accepts, which is also where every
[inf] above came from; it is not evidence about real Titan Ridge firmware.

## 8. What a capture should answer

1. Driver-ready flags byte, the info half-word (security level, protocol version, ACL
   count), the NVM version word and the device ID word.
2. Device-connected flags, link info bits beyond approved/rejected/boot, whether a
   second (QoS) packet follows, and the name block entries.
3. The host router: header revision, adapter numbering and types (in particular 5, 6, 7
   and whether the NHI is the Upstream Adapter), capability chain, plug-events and link
   controller layout, DROM.
4. Firmware status and outbound mailbox values, unexplained bits included.
5. PCI topology of the controller (DSP numbering for two tunnel ports and the xHCI),
   subsystem IDs, and BIOS Assist / pre-boot behaviour, as for the P14s (§12 of
   `ICM-PROTOCOL.md`).
