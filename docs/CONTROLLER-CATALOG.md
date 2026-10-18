# Controller catalogue: what the Linux driver distinguishes, and what we model

Status: first draft, 2026-10-15. A behaviour description in our own words of every
Thunderbolt / USB4 host and device controller generation that the Linux
`drivers/thunderbolt` driver (pinned commit in `docs/REFERENCES.md`) treats differently,
cross-checked against FreeBSD `sys/dev/thunderbolt`, Intel tbtools and this repository's
hardware captures. No Linux code, structure definitions or header text are reproduced;
field names are our own. Linux file names are given as sources so a reviewer can find the
behaviour. Its purpose is to decide which additional controller models would help the
xhci98 project, and to give a future implementer the per-generation differences.

Tags, as in `docs/ICM-PROTOCOL.md`:

- **[obs]** seen in a capture under `tests/captures/` (P14s Gen 1 = Alpine Ridge LP,
  firmware CM; Framework 13 12th gen = Alder Lake-P, software CM). Citation follows.
- **[inf]** what the Linux driver expects or does; not seen on hardware. A hypothesis
  until a capture confirms it (`AGENTS.md`).
- **[ext]** a fact from outside the pinned references and captures (public PCI ID lists,
  general product knowledge). Must be verified before an implementation relies on it.

Model status uses the profile names of `docs/ARCHITECTURE.md` §2 and
`docs/USB4-HOSTS.md`: `tb3-alpine-ridge`, `usb4-generic` with `host-model=minimal` or
`host-model=intel-adl`.

## 0. How the driver tells controllers apart

Three independent keys, applied at different times [inf] (`pci.c`, `nhi.c`, `icm.c`,
`switch.c`, `tb.h`, `quirks.c`):

1. **PCI identity of the NHI.** The PCI match table lists Intel NHI device IDs one by one
   for the Thunderbolt 1-3 era and for the Intel integrated hosts, and then matches *any*
   function with class code `0x0C0340` (USB4 host interface). Two extra NHI-level choices
   hang off the PCI identity: (a) every Intel-vendor NHI gets the Intel interrupt
   auto-clear treatment, and Falcon Ridge additionally an end-to-end flow-control
   workaround; (b) a set of "integrated host" power operations (force power, firmware
   ready, link-controller mailbox, LTR) is attached to Ice Lake and every later Intel
   integrated NHI.
2. **Which connection manager.** If the platform granted native USB4 control through
   ACPI `_OSC`, the software CM is used, full stop. Otherwise the firmware CM (ICM) client
   is tried; it picks one of six ICM dialects by NHI device ID (Falcon Ridge, Alpine
   Ridge, Titan Ridge, Ice Lake, "Tiger Lake class", Maple Ridge; see §2). A device ID
   with no dialect, or a dialect whose "is the firmware usable" check fails, falls back to
   the software CM.
3. **Router identity in config space.** After a router is read, its vendor and device ID
   in router config dword 0 give it a "generation" (1 = Light Ridge to Redwood Ridge, 2 =
   Falcon Ridge and Win Ridge, 3 = Alpine Ridge, Titan Ridge, Ice Lake, 4 = any router whose
   config space reports a USB4 version). The USB4 major version comes from the version
   byte in router dword 4 (`0x20` = USB4 1.0 [obs] Framework dmesg "TB Version: 32").
   Router-level quirks are keyed on router vendor/device ID and, separately, on the DROM
   vendor/model ID (§4).

On Intel integrated hosts the host router's device ID in config space equals the NHI's PCI
device ID and the router vendor is `8087` [obs] Framework: NHI `8086:463e`, router
`8087:463e`; the quirk table relies on the same convention for Raptor Lake, Meteor Lake and
Barlow Ridge [inf]. On discrete Thunderbolt 3 hosts the host router reports the ID of the
controller's PCIe *bridge* function, not the NHI [obs] P14s: NHI `8086:15bf`, router
`8086:15c0`.

## 1. Host controllers

### 1.1 Summary table

IDs are Intel vendor `8086` unless noted. "NHI" is the PCI device ID of the host interface
function, "router" is the device ID the host router reports in config space.

| Controller | Gen | NHI ID | Router / bridge ID | CM chosen by Linux | ICM dialect | USB4 | Modelled |
|---|---|---|---|---|---|---|---|
| Light Ridge, Eagle Ridge, Light Peak (TB1) | 1 | `0x1513` (Light Ridge, Apple subsystem `2222:1111` only) [ext] | `0x1513`, `0x151a`, `0x151b` [ext] | software (Apple only) | none | no | no |
| Cactus Ridge 2C/4C, Port Ridge, Redwood Ridge (TB1) | 1 | `0x1547` (4C, Apple subsystem only) [ext] | `0x1548`/`0x1547`, `0x1549`, `0x1567`/`0x1569` [ext] | software (Apple only) | none | no | no |
| Falcon Ridge 2C/4C (TB2) | 2 | `0x156a` / `0x156c` [ext] | `0x156b` / `0x156d` [ext] | ICM (non-Apple), else software | Falcon Ridge | no | no |
| Win Ridge 2C (TB2 device-class part) | 2 | `0x157d` | `0x157e` | not bound as host by any dialect | none | no | no |
| Alpine Ridge 2C / 4C (TB3, desktop) | 3 | `0x1575` / `0x1577` [ext] | `0x1576` / `0x1578` (`0x1576` also in FreeBSD) | ICM | Alpine Ridge | no | partly: same dialect as LP, not the IDs or adapter layout |
| Alpine Ridge LP (JHL6240, 1 port) | 3 | `0x15bf` | `0x15c0` | ICM [obs] | Alpine Ridge [obs] | no | **yes, `tb3-alpine-ridge`** |
| Alpine Ridge C 2C / 4C (JHL6340 / JHL6540) | 3 | `0x15d9` / `0x15d2` | `0x15da` / `0x15d3` | ICM | Alpine Ridge | no | device router only (`0x15d3`, captured dock) |
| Alpine Ridge USB-only variants (LP, plain, C) | 3 | `0x15dc`, `0x15dd`, `0x15de` | n/a | bound, but no ICM dialect, so software CM | none | no | no |
| Titan Ridge 2C / 4C (JHL7340 / JHL7540) | 3 | `0x15e8` / `0x15eb` | `0x15e7` / `0x15ea` | ICM | Titan Ridge | no | **yes, `tb3-titan-ridge`** (4C default, `ports=1` for 2C; inferred, `ICM-TITAN-RIDGE.md`) |
| Ice Lake (integrated TB3) | 3 | `0x8a17` (NHI0), `0x8a0d` (NHI1) | same as NHI | ICM unless native | Ice Lake | no (TB3 router) | no |
| Tiger Lake (-UP3/-H) | 4 | `0x9a1b`, `0x9a1d`, `0x9a1f`, `0x9a21` | same as NHI | software if `_OSC` native, else ICM if firmware authenticated | Tiger Lake class | v1 | no |
| Alder Lake-P | 4 | `0x463e`, `0x466d` | `8087:463e`, `8087:466d` [obs] | software [obs] (native `_OSC`) | Tiger Lake class | v1 [obs] | **yes, `usb4-generic` `host-model=intel-adl`** (register images; PCI identity stays emulator-specific) |
| Raptor Lake | 4 | `0xa73e`, `0xa76d` | `8087:` same [inf] | as Alder Lake | Tiger Lake class | v1 | no (would reuse `intel-adl`) |
| Meteor Lake-M / -P | 4 | `0x7eb2`; `0x7ec2`, `0x7ec3` | `8087:` same [inf] | as Alder Lake | Tiger Lake class | v1 | no |
| Lunar Lake | 4 | `0xa833`, `0xa834` | not named | software only (no ICM dialect) | none | not distinguished | no |
| Panther Lake-M / -P | 4 | `0xe333`, `0xe334`; `0xe433`, `0xe434` | not named | software only | none | not distinguished | no |
| Wildcat Lake | 4 | `0x4d33` | not named | software only | none | not distinguished | no |
| Maple Ridge 2C / 4C (JHL8340 / JHL8540, discrete TB4) | 4 | `0x1134` / `0x1137` (class `0x0C0340`, matched by class) | not named | software if native, else ICM | Titan Ridge message set + Tiger Lake check | v1 | no |
| Barlow Ridge host 80G / 40G (discrete TB5) | 4 | `0x5781` / `0x5784` | `8087:5781` / `8087:5784` [inf] | software only | none | v2 [inf, ext] | no |
| AMD USB4 hosts (Yellow Carp / Rembrandt, Pink Sardine / Phoenix, later) | 4 | not listed; class match. PCI IDs e.g. `1022:162e`, `162f`, `1668`, `1669` [ext] | router vendor `0x0438`, devices `0x0208`-`0x020b` (quirk table) | software only | none | v1 | **identity only: `usb4-generic` `host-model=amd`** (branch `usb4-tb3dev`): the `minimal` router with router ID `0438:0208`-`020b` (`host-domain` 0-3), emulator PCI identity; nothing captured, all [inf] (`USB4-HOSTS.md` §7) |
| ASMedia ASM4242 (discrete, AM5 X870 / X870E, add-in cards) | 4 | `1b21:2425` (class `0x0C0340`, matched by class) [pub] | `174c:2428` [lkml] | software only | none | v1 | **yes, `usb4-generic` `host-model=asm4242`** (public sources only, nothing captured; `USB4-HOSTS.md` §5) |
| Any other USB4 host (class `0x0C0340`) | 4 | any | any | software | none | from router | `host-model=minimal` |

Notes on the table:

- Thunderbolt 1 controllers are only matched with Apple's subsystem ID and only driven
  by the software CM; the Falcon Ridge ICM dialect refuses to run on Apple machines, and
  from Alpine Ridge on the ICM can be (re)started on Apple machines only on explicit
  request [inf] (`pci.c`, `icm.c`).
- The Alpine Ridge USB-only NHIs are in the PCI table but in no ICM dialect, so the driver
  goes straight to its software CM [inf]. What the hardware does with that is unknown.
- Barlow Ridge hosts and the Lunar Lake / Panther Lake / Wildcat Lake integrated hosts
  have no ICM dialect at all: Linux can only drive them as USB4 software-CM hosts [inf].

### 1.2 NHI-level behaviour per family

| Item | Falcon/Alpine/Titan Ridge (discrete TB2/TB3) | Ice Lake .. Wildcat Lake (integrated) | Maple Ridge, Barlow Ridge (discrete TB4/TB5) | AMD and other USB4 |
|---|---|---|---|---|
| PCI class | `0x088000` [obs] AR LP; the Intel Windows INF requires it (`ICM-PROTOCOL.md` §10.1) | `0x0C0340` [obs] ADL | `0x0C0340` for Maple Ridge (it is only matched by class) [inf]; Barlow Ridge is listed by ID, class not stated | `0x0C0340` |
| BARs | BAR0 256 KiB 32-bit, MSI-X table in BAR1 [obs] AR LP | BAR0 256 KiB 64-bit, MSI-X in BAR2 [obs] ADL | not captured | not captured |
| Interrupts | MSI 1 vector, MSI-X 16, INTx pin A [obs] AR LP | MSI 1 vector, MSI-X 16, INTx pin A [obs] ADL | not captured | not captured |
| Linux vector use | asks for 6 to 16 MSI-X, falls back to one MSI, never INTx [inf] (`pci.c`) | same | same | same |
| Interrupt status clearing | Intel auto-clear: Linux sets bit 2 of the host-interface control register (`0x39864`) when it uses MSI-X, masks by read-modify-write of the enable register, clears by reading status [inf]; `ICM-PROTOCOL.md` §2.5 | same Intel rule; `0x39864` read `0xff000816` with bit 2 set [obs] ADL | same Intel rule [inf] | non-Intel rule: Linux sets the Spec's Disable ISR Auto-Clear (bit 17 of `0x39864`), clears with the explicit clear register and masks with the mask-clear register [inf] (`nhi.c`) |
| Falcon Ridge only | end-to-end flow control needs an unused HopID trick on RX rings [inf] | | | |
| Host interface version (`0x39640` bits 23:16) | 0 [obs] AR LP | 0 [obs] ADL | Barlow Ridge expected to report the v2 interface value `0x40` [inf] | v1 hosts 0 [inf] |
| Host router reset | none (version 0) | none | if version is `0x40` or more: write the reset bit at `0x39898`, wait 100 ms, poll up to 500 ms; module option can skip it [inf] (`nhi.c`) | as left |
| Force power | none in Linux; platform ACPI WMI method on Lenovo (`ICM-PROTOCOL.md` §11.2) [obs] | through a vendor-specific block in the NHI's own PCI config space: set a force-power bit (and a DMA delay value in the top byte) in dword `0xfc`, then poll a firmware-ready bit (bit 31 of `0xc8`) up to about 1 s; done at probe, resume and runtime resume; cleared at shutdown and when idle with no device [inf] (`pci.c`) | none | none |
| Link-controller mailbox | none | command word at `0xf0` (valid bit 0, command in bits 7:1), completion bit 0 of `0xec`; commands "enter Sx with wake", "enter Sx without wake", "prepare for reset"; only used while the ICM is the CM [inf] | none | none |
| LTR | not touched | copies the maximum LTR value at `0xe4` into both halves of `0xe0` on every power-up [inf] | not touched | not touched |
| Host UUID | link-controller fuse registers in router config [obs] AR LP §5.1 | Ice Lake under ICM: two dwords at `0xcc`/`0xd0` of the NHI config space plus two all-ones dwords [inf]; USB4 routers: router UID registers [obs] ADL | router UID [inf] | router UID |
| Firmware image check | | a platform property `IMR_VALID` = 0 aborts the bind [inf] | | |
| IOMMU DMA protection | Linux sets it when any external-facing PCIe port in the same segment is behind an IOMMU with pre-boot protection [inf]; the P14s root port carries the ExternalFacingPort `_DSD` [obs] `ICM-PROTOCOL.md` §11.1 | same; enabled on ADL [obs] Framework dmesg "IOMMU DMA protection is enabled" | same | same |

Gap for all profiles: the model has no Ice Lake-style NHI config-space block (force
power, firmware ready, LC mailbox, LTR, UUID). Linux on an Intel integrated identity
would time out waiting for firmware ready without it [inf]. `intel-adl` avoids this by
keeping an emulator PCI identity.

## 2. Firmware CM (ICM) dialects

All dialects share the ring 0 framing, the four-byte ICM header (code, flags, packet
index, packet count), error = flags bit 0, the 5 s command timeout with three retries, the
NHI firmware-status register and the host-router polling after driver ready
(`ICM-PROTOCOL.md` §2-§4) [inf]. The Alpine Ridge dialect is fully described, with
captures, in `docs/ICM-PROTOCOL.md`; this section lists only the differences.

### 2.1 Per-dialect behaviour

| Item | Falcon Ridge | Alpine Ridge (reference) | Titan Ridge | Ice Lake | Tiger Lake class (TGL, ADL, RPL, MTL) | Maple Ridge |
|---|---|---|---|---|---|---|
| "Firmware usable" check | not an Apple machine | firmware status ICM-enable bit set (or user opt-in to start it) [obs] AR | as Alpine Ridge | not an Apple machine (always) | NVM-authenticated bit (31) of firmware status seen within 10 ms | as Tiger Lake class |
| Restart stopped firmware | no | upstream-port PCIe-to-fabric mailbox, router dword `0x50` bit 9 | same mailbox, router dword `0x777` bit 1 | no | no | no |
| Operating-mode check and "allow all devices" (mailbox `0x23`) | no | yes [obs] | yes | no | no | yes |
| Physical-port link reset at start (via the upstream-port mailbox, only when restarting) | no | yes | yes | no | no | no |
| Driver-ready response | 2 words; 4-bit security level in the info half-word; no ACL, no RTD3 bit | 2 words, ROM/RAM versions, level, ACL count and supported bit, RTD3 = flags bit 6 [obs] | 4 words: header; info in the upper half of word 1 (level bits 2:0, protocol version bits 6:4, ACL count bits 12:7); NVM version word; device ID in the low half of word 3. RTD3 = flags bit 6 | Titan Ridge layout, only the protocol version is used; RTD3 always on; security level not taken from it | as Ice Lake | Titan Ridge layout and fields |
| Driver-ready timing | 5 s x 3 retries | 5 s x 3 [obs: answered in 6 ms] | 250 ms x 10 retries | 20 s x 3 | 20 s x 3 | 250 ms x 10 |
| Device addressing in events | link + depth; route via 14-packet topology query (code `0x01`) | link + depth; route via get route (`0x0a`) [obs] | route string carried in the event | route string | route string | route string |
| Device-connected event | Alpine Ridge layout (61 words) | 61 words, key + id + link info + name block [obs] | 63 words: header, UUID (4), route high, route low, then a word with connection id (bits 7:0) and link info (bits 31:16), then the 55-word name block. No connection key. Frames with packet index other than 0 (extra QoS packet) are ignored | Titan Ridge layout; device RTD3 forced on | as Ice Lake | Titan Ridge layout |
| Device-disconnected event | link info | link info [obs] | 3 words: header, route high, route low | as Titan Ridge | as Titan Ridge | as Titan Ridge |
| Approve / add key / challenge request | UUID, key, id | UUID, key, id [obs approve] | UUID, route high, route low, id (no key); approve is 8 words | not offered (no approve: the ICL client has no device authorisation) | not offered | as Titan Ridge |
| Boot ACL (code `0x18`) | not offered | 16 entries [obs] | 16 entries, count field 6 bits wide | not offered | not offered | message handler present but Linux disables it (it allows 0 entries) |
| Save devices (mailbox `0x05`) on suspend | yes | yes | no | no | no | no |
| Host-to-host paths | approve `0x10` keyed by link info; teardown by NHI mailbox `0x10`/`0x11` | as Falcon Ridge | approve `0x10` keyed by route; teardown by ICM `0x11` in two stages | as Titan Ridge | as Titan Ridge | as Titan Ridge |
| USB4 router-operation proxy (code `0x20`) | no | no | if protocol version >= 3 | if protocol version >= 3 | if protocol version >= 3 | if protocol version >= 3 |
| RTD3 veto event (`0x0a`) | no | no | no | yes: a non-zero reason word keeps the domain powered | yes | no |
| Runtime suspend of the domain (mailbox `0x07` then D3) | no | yes [obs] | yes | yes (plus the force-power and LC-mailbox steps of §1.2) | yes | yes |
| NVM upgrade of the host | yes | yes, except on Apple | yes, except on Apple | not offered | not offered | yes |

Router-operation proxy message (Titan Ridge layout family) [inf]: request = header,
route high, route low, metadata, a word with the opcode in bits 15:0, data length in bits
19:16 and a "data valid" bit 20, then 16 data words; the response replaces the
length/valid half-word with the operation status and returns metadata and data. The NVM
authenticate operation does not answer at once; its result is collected later.

Falcon Ridge topology query [inf]: 14 response frames, one per router slot. Each holds
the router's route (low word first, then high word, unlike every other message), a
used-flag and upstream-port number, a DROM index, the slot index, two reserved words, 16
port descriptors (bits 23:0 adapter type, bits 31:24 slot index of the router behind it,
`0xff` none) and 16 hop-info words. The client walks it from the host slot along the
given link to the requested depth.

### 2.2 What this means for an emulator

- The model's ICM (`hw/usb4/usb4-icm.c`) speaks the Alpine Ridge dialect and, since
  2026-10-15, the Titan Ridge dialect (`profile=tb3-titan-ridge`, `ICM-TITAN-RIDGE.md`).
  A Titan Ridge or Maple Ridge dialect is a message-layout variant (route-addressed events and approve,
  four-word driver-ready, no get route, no save-devices) plus different router IDs and
  adapter numbering (§3). The approve path (fabric programming as a software CM would)
  is reusable unchanged.
- An Ice Lake / Tiger Lake class dialect is smaller (no approve, no ACL, no mailbox mode)
  but needs the NHI config-space block of §1.2 and a USB4 (TGL+) or TB3-style (ICL) host
  router in config space. The ADL register images already in the model are the natural
  base for a "TGL class under ICM" variant.
- Which security level a TGL-class ICM reports, and whether it tunnels PCIe at all
  without approval, is not visible from Linux (the client never approves on these
  generations) [inf]. On those platforms PCIe tunnels are expected to be created by the
  firmware and protected by the IOMMU [inf].

## 3. Router and adapter behaviour per generation

Only the software CM touches most of this; under any ICM the client reads config space
but never configures links, TMU, CLx or paths [obs] AR LP (`ICM-PROTOCOL.md` §5.5).

| Item | Gen 1 (TB1) | Gen 2 (Falcon Ridge) | Gen 3 TB3 (Alpine Ridge, Titan Ridge, Ice Lake) | USB4 v1 | USB4 v2 |
|---|---|---|---|---|---|
| Capability access | Light Ridge / Eagle Ridge need a TMU-access enable bit in router dword `0x26` / `0x2a` before port space is fully readable; Light Ridge needs a dummy port read after a capability walk (stale next-pointer) [inf] (`cap.c`) | normal | normal | normal | normal |
| Plug events | enabled through the vendor plug-events capability; Alpine Ridge keeps its USB plug event enabled for the internal xHCI [inf] (`switch.c`) | same | same | none (USB4 hot plug) | none |
| Host router reset by the software CM | a dedicated "reset" control packet to the router [inf] | lane adapters get a port reset; protocol adapters are disabled and their path entries cleared one HopID at a time [inf] (`switch.c`) | same | Downstream Port Reset on each USB4 port when the driver starts with reset enabled [obs] ADL dmesg "0: resetting" | host interface reset instead (§1.2) [inf] |
| UUID | from DROM UID | link-controller fuse if present, else UID | link-controller fuse [obs] AR LP host | router UID registers [obs] ADL | same |
| DROM (host) | Apple EFI device property, else NVM copy through the DMA port, else UID only through the EEPROM [inf] (`eeprom.c`); P14s: NVM copy plus EEPROM UID [obs] | same | same | DROM-read router operation [obs] ADL | same |
| DROM (device) | EEPROM bit-bang [obs] TS3 Plus | same | same | DROM-read router operation; DROM revision 3 header without UID CRC [inf] | same |
| NVM (Intel) | not upgradeable | DMA port on the host only; 8 KiB header; CSS header written first | DMA port on host and devices; 16 KiB header [obs] DMA port reads `ICM-PROTOCOL.md` §5.2 | NVM router operations | same |
| Runtime PM of the router | no | yes (has a link controller) | yes | yes | yes |
| Lane bonding | no | only if the upstream port's link controller reports "bonding enabled" | same | USB4 port operations per Spec | adds asymmetric widths at Gen 4 (80 Gb/s) when port and cable support it [inf] |
| CL states | no | no | **Titan Ridge only**: needs objection masking in its low-power registers; disabled on the Titan Ridge device bridge `0x15ef` unless NVM major >= `0x65` | yes, except Tiger Lake (not validated) and quirked parts (§4) | CL2 only if both ends are v2 [inf] (`clx.c`) |
| TMU | | | Titan Ridge needs objections disabled for LowRes / uni-directional HiFi | uni-directional LowRes on the host [obs] ADL dmesg | enhanced uni-directional mode [inf] (`tmu.c`) |
| PCIe down adapter for a host lane (software CM only) | Cactus Ridge: 6 / 7 | Falcon Ridge: 6 / 8 | Alpine Ridge: 6 / 7; Titan Ridge: 8 / 9 (port A / port B) [inf] (`tb.c`) | from the PCIe-down mapping in the router [inf] | same |
| Internal xHCI of a device router (software CM only) | | | Alpine Ridge: connect the xHCI to whichever port reports a USB plug; Titan Ridge: connect both ports, through link-controller registers [inf] (`switch.c`, `lc.c`) | USB3 tunnel instead | same |
| Titan Ridge first-hop device | | | PCIe L1 enable written into two of its PCIe bridges through router config [inf] | | |
| DisplayPort | no bandwidth management | DP capability handshake from gen 2 | Titan Ridge DP adapters are treated as USB4-style; LTTPR non-support forced on Titan Ridge sinks [inf] (`tunnel.c`) | USB4 DP | adds DP power management on paths [inf] |
| PCIe tunnel | | | | | extended encapsulation when both ends are v2 and the link is Gen 4 [inf] |
| Max topology depth | 6 | 6 | 6 | 5 when the host is USB4 | 5 |
| Router-config "CM USB4 version" field (router dword 4) | | | | programmed as v1 [inf] | programmed as v2 so v2 capabilities appear [inf] (`switch.c`) |

## 4. Device routers and quirks the driver special-cases

| Device | Identity used for the match | Behaviour [inf] (`quirks.c` unless noted) | Modelled |
|---|---|---|---|
| Alpine Ridge C 4C device (e.g. CalDigit TS3 Plus) | router `8086:15d3`, DROM vendor `0x3d` model `0x11` [obs] | nothing special beyond gen-3 rules; DMA port at adapter 5 [obs] | yes: tb3 device router in `tb3-alpine-ridge` [obs, P14s]; **and on a USB4 host** (`usb4-device dialect=tb3` on `usb4-generic`, any host model, branch `usb4-tb3dev`) from the Framework capture [obs]: power-on state, plug events, link controller SX_CTRL, LC UUID, bonding, PCIe Up 6, TCM on the host port; no DMA port (R20) (`USB4-HOSTS.md` §8) |
| Titan Ridge device bridge ("DD", docks) | router `8086:15ef` | CL states off unless NVM major >= `0x65` | no |
| Goshen Ridge (Intel TB4 device / hub router) | router `8087:0b26` | NVM 27 and older report too many DP main buffers: when credit allocation is in use and the minimum is 56, use 18 | no |
| Barlow Ridge hub 80G / 40G (TB5 device) | router `8087:5786` / `8087:57a4` | USB3 tunnel bandwidth on USB3 down adapters limited to 16376 Mb/s (software CM only) | no |
| Anker Prime TB5 dock | router `8087:5786` with DROM `01ea:83b5` | CL states off | no |
| Dell WD19TB | DROM vendor `0x00d4`, model `0xb070` / `0xb071` | can authenticate new NVM on unplug: the link controller is force-powered by writing `0xffff` to its power register, and an extra sysfs attribute appears | no |
| ASMedia USB4 device routers (e.g. NVMe enclosures) | router vendor `0x174c` | own NVM layout: version at NVM offset `0x28`, date at `0x1c`, both 24-bit with swapped byte order, fixed 512 KiB, no image validation (`nvm.c`) | **yes, ASM2464PD `174c:2463` [obs]**: `usb4-device device-model=asm2464` from the ORICO AAGM2-U4 capture (`captures/ORICO-ASM2464.md`). [obs]: DROM revision 1 (TBT3-compatible), DROM vendor `0xb8`, "ASMedia" / "246x"; adapters 1-2 lane, 3 PCIe Up, 4 unused in the DROM; 66 lane buffers, Max HopID 27; TMU capability at `0xc0`; no CL states; Buffer Allocation PCIe 64 only; NVM Sector Size status 2, so Linux never reaches the ASMedia NVM layout on this enclosure; PCIe switch `1b21:2463` in front of the NVMe |
| Intel host routers ADL, RPL, MTL, Barlow Ridge host | router `8087:<NHI ID>` | USB3 tunnel bandwidth limited to 16376 Mb/s (software CM only) | `intel-adl` reports the ADL IDs, so the limit applies to it |
| Barlow Ridge host 80G / 40G | router `8087:5781` / `8087:5784` | runtime PM blocked while in DP redrive mode | no |
| AMD Yellow Carp / Pink Sardine hosts | router vendor `0x0438`, devices `0x0208`-`0x020b` | CL states off | identity only: `host-model=amd` reports these IDs, so the quirk applies (no CL states are advertised anyway) |
| On-board retimers | sideband vendor / product ID | enumerated on USB4 ports through sideband; platform `_DSM` (GUID `e0053122-795b-4122-8a5e-57be1d26acb3`) powers them for NVM upgrade when no device is attached (`retimer.c`, `acpi.c`) | `intel-adl`: one retimer `8087:15ee` [obs] |

## 5. Windows and firmware expectations

| Host | What Windows does | Evidence |
|---|---|---|
| Alpine Ridge LP (and other TB3 ICM hosts) | Intel `tbthostcontroller.inf` (TbtBusDrv) matches NHI ID plus class `0x0880`; 16 MSI-X; DSN-based instance IDs; per-device approval stored under the `nhi` service key; ACPI owns hot plug when BIOS Assist is on; Lenovo force power via WMI | [obs] `ICM-PROTOCOL.md` §10-§12 |
| Titan Ridge, Maple Ridge | very probably the same Intel package family [inf]; not captured | |
| Integrated Intel TGL .. MTL | Windows 11 binds the inbox `Usb4HostRouter.sys` when the firmware grants `_OSC` USB4 control (software CM); earlier Windows used Intel's driver against the firmware CM [inf, ext] | the model's Windows 11 runs on `usb4-generic` [obs in emulation] |
| Integrated Intel LNL, PTL, WCL; Barlow Ridge; AMD | inbox Windows USB4 CM only [inf]; requires `_OSC` USB4, `_DSD` "usb4-host-interface" links on tunnel root ports, ExternalFacingPort, retimer `_DSM` (Microsoft USB4 ACPI requirements in `docs/references/microsoft/`) | |
| Any USB4 host booting a legacy OS through CSM | a legacy OS never calls `_OSC`, so whether a firmware CM keeps running, and which dialect it speaks, is per platform | open, `PLATFORM-MATRIX.md` §4. ADL under native control: firmware status `0x000001a1`, i.e. ICM-enable set but NVM-authenticated clear, outbound mailbox 0 [obs] Framework `mmio/0000_00_0d.2-*`; under Linux's rule that state means "no usable ICM" |

## 6. Gap list by model

| Model | Covers | Main gaps |
|---|---|---|
| `tb3-alpine-ridge` | AR LP NHI identity, AR ICM dialect (R1-R31 of `ICM-PROTOCOL.md`), tb3 host and device routers, pre-boot and BIOS Assist power behaviour | AR 2C / 4C / C host identities and their two-port adapter layout; read-only DMA port (R20) optional; DSN capability (R29); ACPI hot-plug path under Assist; firmware restart path; Falcon/Titan/Maple Ridge dialects |
| `usb4-generic` `host-model=minimal` | Spec-derived USB4 v1 host router, non-Intel interrupt rules | no vendor quirks; no v2 features (host interface reset, CMUV v2, CL2, asymmetric links, enhanced TMU); stands in for AMD only generically |
| `usb4-generic` `host-model=intel-adl` | ADL-P host router images, two domains, retimer, router operations (95.7% replay match); TBT3-compatible links to a TB3 device router (`usb4-tb3dev`) | no ICM mode (firmware CM for a non-native OS), no NHI config-space block, emulator PCI identity, no CLx state; Get PCIe Downstream Entry Mapping not answered (not observed) |
| `usb4-generic` `host-model=amd` | AMD router identity (`0438:0208`-`020b`) on the `minimal` router [inf] | everything AMD-specific: no capture (registers, firmware pre-OS state, vendor capabilities, NHI PCI identity) |
| `usb4-device` `dialect=tb3` on `usb4-generic` | TS3 Plus device router under a software CM [obs]: power-on state, writable plug events / link controller / target width, read-only vendor capabilities and Router CS gaps, plug events, bonding, PCIe tunnel (93.3% replay match) | DMA port (R20), live vendor registers, link-training flaps, DP, the dock's own PCIe switch, CalDigit DROM content (the model's DROM) |
| `tb3-titan-ridge` | TR 4C / 2C NHI and router identity, TR ICM dialect (T1-T12 of `ICM-TITAN-RIDGE.md`), inferred two-port host layout, `usb4-tr-*` switch types; everything shared with `tb3-alpine-ridge` | no capture: every value is from the Linux client or an emulator choice; no Titan Ridge device router (`15ef`); same DMA-port and DSN gaps as AR |
| `usb4-generic` `host-model=asm4242` | ASM4242 PCI and router identity, own PCIe switch and xHCI identities, inferred two-port layout with DP IN, NVM version, buffer figures, three vendor quirks as options | no capture: layout, TMU, CLx, vendor capabilities, DROM, padding and INTx are [inf]/[unk]; no xHCI halt quirk |
| `usb4-device` `device-model=asm2464` | ASM2464PD device router [obs]: identity, DROM, layout, register images, router operations, timing quirks, its PCIe switch (97.1% replay match) | live TMU and error counters, USB3 adapter (unused on the captured enclosure), NVM, CL states (unsupported by the part) |
| none | Ice Lake, TGL/RPL/MTL identities, Maple Ridge, Barlow Ridge, LNL/PTL, AMD beyond its router ID, Goshen Ridge, other ASMedia device routers (ASM2464 behind a TB3 host), Titan Ridge device routers | see §7 |

How far the Linux driver's expectations held on the two captured controllers, which of
them the captures contradicted, and which branches still need a capture, is in
`docs/CAPTURE-VS-LINUX.md`.

## 7. Recommendation for xhci98

The xhci98 drivers target real TB3 and USB4 laptops running Windows 98 to 7. Those
guests boot through CSM, never call `_OSC`, and need either an ICM client (TB3) or a full
software CM (USB4). Ranked by how many real machines a model unlocks per unit of effort.
Effort is for the model only, given the existing fabric, tunnel evaluator and ICM
framework.

| Rank | Model | Why | Effort | Capture needed to trust it |
|---|---|---|---|---|
| 1 | **Titan Ridge ICM host** (`tb3-titan-ridge`, NHI `0x15e8`/`0x15eb`, router `0x15e7`/`0x15ea`) | The most common TB3 PC controller (2018-2020 laptops and desktops). An xhci98 ICM client must handle its route-addressed dialect, which differs from Alpine Ridge in every device message (§2.1). | Medium: a dialect switch in the ICM (driver-ready layout, events, approve, ACL count width, no get route), new host-router images and adapter numbering (PCIe down 8/9). About 3-5 days. | **Yes.** Everything here is [inf]: driver-ready flags and versions, event flag bits, name block, router images, whether boot ACL and pre-boot behave as on Alpine Ridge. A Linux capture with the same tool as the P14s is enough. |
| 2 | **Alpine Ridge 2C / 4C / C host identities** | Same dialect as the model; other AR laptops and desktop add-in cards. Mostly identity and a second physical port (lane adapters 3/4, link 2 in events, PCIe down 7). | Low: presets on the existing profile, about 1-2 days. | Recommended for the two-port adapter layout and DROM; the dialect itself is already [obs]. |
| 3 | ~~**ASMedia USB4 device router** (NVMe enclosure)~~ **Done 2026-10-15** (`device-model=asm2464`) | The xhci98 end goal is NVMe; ASMedia enclosures are the common USB4 NVMe device, and work behind both USB4 and TB3 hosts. | Done on the USB4 host. Behind a TB3 ICM host it would need the device-connected event layout for a non-Intel router. | Captured on the Framework; a P14s run (TB3 host) is `CAPTURE-VS-LINUX.md` §5 item 5. |
| 4 | **AMD USB4 host** (`host-model=amd`; identity-only preset since 2026-10-15, branch `usb4-tb3dev`) | Every AMD USB4 laptop needs a software CM; differences from `minimal` are non-Intel interrupt clearing (already modelled), router IDs (now modelled, [inf]), no CLx, vendor capabilities and whatever AMD's firmware leaves configured before the OS. | Medium: like `intel-adl` (register images, replay check), about 4-6 days once a capture exists. Until then `amd` is `minimal` with AMD's router IDs. | **Yes**, including a CSM boot if any AMD USB4 machine offers one. |
| 5 | **Intel TGL-class host under ICM** (TGL / ADL / RPL / MTL identity with the firmware CM) | If these machines keep their firmware CM running for an OS that never calls `_OSC`, a legacy driver faces this dialect, not the software CM. It reuses the ADL router images. | Medium-high: Ice Lake-class ICM dialect, NHI config-space block (force power, firmware ready, LC mailbox), RTD3 veto, Intel PCI identity on the generic fabric. About 5-8 days. | **Yes, and first decide whether it exists.** The one Intel USB4 capture (Framework, native `_OSC`) shows the ICM not authenticated [obs]; behaviour under CSM is unknown (`PLATFORM-MATRIX.md` §4). Do not build before a capture of a TGL-class machine booted without `_OSC`. |
| 6 | **Maple Ridge discrete TB4** | Workstations and desktop TB4 cards; Titan Ridge message set on a USB4 router, so it follows from ranks 1 and 5. | Low after rank 1 (about 2 days). | Yes. |
| 7 | **Ice Lake ICM** | Few machines (2019-2020 Ice Lake laptops); unique TB3-router-with-ICL-dialect combination. | Medium. | Yes. |
| 8 | **Falcon Ridge (TB2)** | Windows 7-era desktops with TB2 cards; topology-query route lookup. Small installed base. | Medium. | Yes. |
| 9 | **USB4 v2 features** (Barlow Ridge, LNL, PTL) | Newest hosts; host interface reset, CMUV v2, CL2, asymmetric links. Legacy Windows on these machines is unlikely (no CSM). | Medium, can be added to `minimal` as an option. | Yes for any vendor detail; the Spec covers the generic part. |

The software-CM work already validated on `usb4-generic` (Windows 11, Linux, the DOS
reference CM) covers the common USB4 v1 path. The biggest open risk is not a missing model
but the platform question in rank 5: what a USB4 laptop's firmware does for a CSM-booted
OS. A capture of that state, on an Intel and on an AMD machine, would decide whether the
xhci98 USB4 driver needs an ICM-client mode on Intel at all.
