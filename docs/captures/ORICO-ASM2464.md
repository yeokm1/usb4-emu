# ORICO AAGM2-U4 (ASMedia ASM2464PD) on the Framework 13: a real USB4 device router

Status: 2026-10-15. Licence: GPL-2.0-only, like the rest of this repository.

The first capture of a real USB4 **device** router. It is the reference for the
`usb4-device device-model=asm2464` preset (§12) and for what a USB4 software CM meets
when it talks to a common USB4 NVMe enclosure. Every statement is `observed` in the
capture unless tagged **[inf]** (inferred: what the observations imply but do not show) or
**[spec]** (USB4 Specification 2.0 / CM Guide 2.0 / USB4 DROM Specification, cited by
section). Linux `drivers/thunderbolt` was read for behaviour only (`AGENTS.md`).

## 0. The capture

`tests/captures/framework13-12th/linux-orico/p14s-linux-20261015-121048-fw13-orico.tar.gz`
(see that folder's `README.md`): Framework Laptop 13 (12th gen, Alder Lake-P, two USB4
domains), installed Kubuntu 26.04.1, kernel 7.0.0-38, Linux software CM, boot with
`thunderbolt.dyndbg=+p`, tool options `rebind`, unplug/replug, approve, `--suspend`
(suspend-to-idle), `--watch-mmio 1`. The enclosure was on USB4 port 2 of domain 1 (host
lane adapters 3/4, PCIe Down adapter 9, tunnel root port 00:07.3), through the platform's
on-board retimer `8087:15ee`. Inside: SK hynix Gold P31 NVMe (`1c5c:174a`).

Citation prefixes (paths inside the extracted run folder):

| Prefix | Source |
|---|---|
| `D:n` | `dmesg-live.txt` line n (starts at boot) |
| `T:t` | `trace-thunderbolt.txt`, record at trace time t (seconds; about 55 ms later than the matching `D:` time) |
| `S<n>:path` | `snap-<n>-*/path`, e.g. `S3:debugfs-thunderbolt/1-3/regs` |
| `P:path` | `pci/path` |

The trace starts at the driver rebind (71.2 s): the boot-time trace buffer is empty
because the `trace_event=` boot option ran before the module loaded. The boot itself is
covered by the driver's debug log. Fifteen trace lines hold two interleaved records, the
first of which is truncated; around the resume from suspend (217.4-217.5 s) several of
the CM's requests to the device router are lost this way, and the device router's
suspend writes (202.4 s) are missing entirely.

Timeline (dmesg time): power-on with the enclosure attached; firmware PCIe tunnel, NVMe
probed at 1.96 s; Linux host reset at 2.32 s, device back at 2.96 s, tunnel 5.14 s
(boltd authorised the stored device), NVMe 6.18 s; rebind 71-76 s (same sequence);
unplug 101.28 s; plug 129.45 s, tunnel 130.17 s, NVMe 131.26 s; suspend-to-idle
201.93-218.42 s; unplug 244.50 s.

## 1. Identity

| Item | Value | Source |
|---|---|---|
| Router ID (ROUTER_CS_0) | `174c:2463` (vendor ASMedia `174c`, device `2463`), Revision 0 | `D:1178` "USB4 Switch: 174c:2463 (Revision: 0, TB Version: 32)" |
| USB4 version (ROUTER_CS_4) | `0x20`: USB4 1.0; Notification Timeout 10 ms at reset | `T:75.2346` read `2000000a` |
| Router UID (ROUTER_CS_7/8) | `0x174c608e`, `0x70912700`; Linux prints `0x70912700174c608e` | `D:1189`, `S3:.../1-3/regs` |
| sysfs | `vendor` `0xb8`, `vendor_name` "ASMedia", `device` `0x2463`, `device_name` "246x", `generation` 4, `unique_id` `8e604c17-0027-9170-ffff-ffffffffffff`, 2 lanes x 20 Gb/s | `S6:sys-bus-thunderbolt/1-3/` |
| Adapters | Max Adapter 4, Upstream Adapter 1 | ROUTER_CS_1 `000101c0` |
| ADP_CS_0 of every adapter | `0x00000000` (adapter vendor/device 0:0) | `D:` "Port 1: 0:0 (Revision: 0, TB Version: 1, ...)" |
| ROUTER_CS_6 flags | TBT3 Not Supported 0 (Linux: "TBT3 support: yes"), Internal Host Controller 0 ("xHCI: no") | `D:` "3: TBT3 support: yes, xHCI: no" |
| PCI functions behind the PCIe Upstream adapter | switch upstream port `1b21:2463` and one downstream port `1b21:2463`, both revision 00, subsystem `1b21:2463` (Subsystem ID capability at `0xc0`) | `P:tb-complex-with-device/0000_7d_00.0/lspci.txt`, `.../0000_7e_00.0/` |

## 2. DROM (full decode)

86 bytes, the same in every snapshot (`S*:debugfs-thunderbolt/1-3/drom`). The DROM Read
router operation returns two more bytes past the end (`0x23 0x02`), §6. Field layout per
the USB4 DROM Specification (TBT3-compatible header, §8; entries §6-§8).

| Bytes | Field | Value |
|---|---|---|
| 0 | UID CRC-8 | `0x5e` (valid) |
| 1-8 | UID | bytes `00 27 91 70 8e 60 4c 17`, little-endian `0x174c608e70912700`: the two ROUTER_CS_7/8 dwords in the opposite order to the UID Linux prints from router config space |
| 9-12 | data CRC-32 | `0xdaab4a38` (valid) |
| 13 | DROM revision | 1 (Linux "DROM version: 1"): the TBT3-compatible format, not the USB4 one (3) |
| 14-15 | data length | `0x0049` (73 bytes from byte 13) |
| 16-17 | vendor ID | `0x00b8` (ASMedia's Thunderbolt vendor ID; sysfs `vendor`) |
| 18-19 | model ID | `0x2463` |
| 20, 21 | model revision, EEPROM revision | `0xe3`, `0x02` |

Entries (from byte 22):

| Offset | Bytes | Entry |
|---|---|---|
| 0x16 | `02 c4` | Unused Adapter Entry, adapter 4 (AE and AD set). Linux: "3:4: disabled by eeprom" (`D:1206`) |
| 0x18 | `08 81 80 02 00 00 00 00` | TBT3 Lane Adapter Entry, adapter 1: lane 0, dual-lane capable, second adapter 2 |
| 0x20 | `08 82 90 01 00 00 00 00` | TBT3 Lane Adapter Entry, adapter 2: lane 1, dual-lane capable, second adapter 1 |
| 0x28 | `0b 83 20 00 00 00 00 00 00 00 00` | TBT3 PCIe Upstream Adapter Entry, adapter 3: function 0, device 1 |
| 0x33 | `0a 01 "ASMedia\0"` | ASCII vendor name |
| 0x3d | `07 02 "246x\0"` | ASCII model name |
| 0x44 | `03 08 00` | TMU Minimum Requested Mode: Off |
| 0x47 | `0f 09 10 04 4c 17 63 24 17 54 66 06 00 c0 5a` | Product Descriptor: USB4 version `0x0410` (1.0), VID `174c`, PID `2463`, firmware revision `0x5417`, TID `0xc0000666`, hardware revision `0x5a` |

So adapter 4 exists (ADP_CS_0 reads 0, not an addressing error) but the DROM marks it
unused, and Linux never sets up a USB3 tunnel to this enclosure. That it is a USB3 Gen X
Upstream adapter is [inf] from its number (Spec 5.2.1 ordering); its type register was
never read.

## 3. Router configuration space

Size `0x200` dwords (debugfs dumps up to `0x1ff`). Values at a fresh reset (first reads
after the Downstream Port Reset of the rebind, `T:75.234`-`75.26`):

| Dword | Reset value | Notes |
|---|---|---|
| ROUTER_CS_1 | `0x000101c0` | Next Capability `0xc0`, Upstream Adapter 1, Max Adapter 4, Depth 0, Revision 0. Linux writes `0x001101c0` |
| ROUTER_CS_4 | `0x2000000a` | Linux writes `0x2000100a` (CM USB4 version 1.0) |
| ROUTER_CS_5 | `0` | Linux writes `0x03000000` (PCIe and USB3 Tunneling On) right after enumeration, then `0x83000000` (Configuration Valid) after TMU setup |
| ROUTER_CS_6 | `0` | **Router Ready not set 0.4 ms after Enumerated** (`T:75.2449`); `0x03000000` (RR and Configuration Ready) when read 0.3 ms after the Configuration Valid write (`T:75.6421`). RR comes later than the model's spec-derived router sets it |
| ROUTER_CS_9-26 | `0` after power loss | Router operations leave their Data dwords: the debugfs dump at 94.6 s shows the last DROM read's 6 dwords followed by dwords 6-15 of the previous 16-dword read. After the suspend (238.5 s) all are 0 (§9) |

Capability chain: `0xc0` TMU Router Configuration Capability (26 dwords, `0x43200328`:
Frequency Measurement Window 800, uni-directional capable, next `0x28`), then
vendor-specific capabilities `0x28` (ID 1, 30 dwords), `0x80` (ID 3, 50 dwords), `0xec`
(ID 6, long header, `0x114` dwords to `0x1ff`). The TMU capability sits at `0xc0`, not
right after ROUTER_CS_26: a CM must walk the chain. The vendor-specific capabilities are
almost all zero; non-zero: `0x2c` `00030088`, `0x2f` `0000000f`, `0x34` `00000300`,
`0x18d` `00001000`, `0x196` `00000140`, `0x197` `00040000`, `0x1ad` `00000002`; the
long VSEC repeats its header at `0x10c`. TMU live dwords (`0xc1`-`0xcd`) change with
every read.

## 4. Adapters

| Adapter | Type (ADP_CS_2) | Capability chain (offsets) | Notes |
|---|---|---|---|
| 1 | Lane, lane 0 of the Upstream Facing Port | ADP_CS_1 `00080740` -> `0x40` TMU (8 dwords) -> `0x80` Lane (3) -> `0xc0` USB4 Port (20) | Max HopID 27 in and out; 7 counter sets; ADP_CS_4 `44200000` (Plugged, **66** Total Buffers); path 0 credits 2 |
| 2 | Lane, lane 1 | `0x40` TMU -> `0x80` Lane | as adapter 1; still 66 buffers after bonding |
| 3 | PCIe Upstream (`0x100102`) | ADP_CS_1 `00080109` -> `0x09` PCIe (1 dword) | Max HopID 8; 1 counter set; no credits (ADP_CS_4 0); path HopID 8 resets to `0x00000008` (output HopID 8 preset) |
| 4 | not read beyond ADP_CS_0 (`0`) | | unused per DROM (§2) |

Register details:

- LANE_ADP_CS_0 `0x003c01c0` (lane 1: `0x003c0100`): Gen 2 and Gen 3, x1 and x2, **no
  CL0s, CL1 or CL2 support** (Linux "3:1: CLx: CL0s/CL1 not supported", `D:1235`).
- LANE_ADP_CS_1 `0x4814001c`: CL0, Gen 3, width x1, PM Secondary set, target Gen 3 x1.
  Linux writes target x2 (`0x4814003c`) on both lanes; after the host bonds, `0x4824003c`.
- LANE_ADP_CS_2 (logical layer errors) reads 3 at first, then 0 or 2.
- ADP_CS_7 (invalid HopID errors) counts up on both lanes (`0x467`, `0x750`, `0xc2a`, ...).
- PORT_CS_18 `0x00003110`: cable USB4 version, Bonding Enabled, RS-FEC Gen 3, Router
  Detected; **Cable Gen 3 Support and CLx Protocol Support are 0** although the link runs
  at Gen 3.
- PORT_CS_19 `0x00040006` at reset: RS-FEC Gen 2 and Gen 3 requested and **Enable Wake on
  USB4 Wake already set**. Linux sets Port Configured (`0x0004000e`).
- ADP_PCIE_CS_0 (`0x09`): `0x000e0400` while no tunnel (TX/RX electrical idle **and RST**),
  `0x8c010400` in the tunnel (Path Enable, LTSSM L0, Link).
- Path entries written by Linux read back as written on both lane and protocol adapters,
  credits included (e.g. PCIe Up HopID 8 `0x800e0808 0x037ff301`, read back at
  `T:238.434`).

## 5. Link, bonding, CL states, TMU

- Gen 3 (20 Gb/s per lane). Linux bonds the two lanes: target width x2 on all four lane
  adapters, Lane Bonding on the host side; the host lane 1 reports a hot unplug, the
  device lanes keep 66 buffers (`D:1220`, `T:75.2729`).
- CL states: not supported by the ASM2464 (§4), so Linux leaves CLx disabled although the
  host supports CL0s/CL1 and `clx=Y` (`D:1235`-`D:1236`).
- TMU: the DROM asks for no TMU mode; Linux sets **bi-directional HiFi** on the device
  router (`D:1242`): Time Disruption on, Post Local Time `0xd6`/`0xd7` and Post Time
  `0xd8`/`0xd9` written, TSPacketInterval `0x10` in `0xc3`, Time Disruption off; on the
  device lane, TMU_ADP_CS_3 and TMU_ADP_CS_6 written 0. Register Locking reads of the
  LocalTime dwords work as in the model.
- Configuration Valid: Configuration Ready is set within the next request (0.3 ms).

## 6. Router operations

All complete at once: Operation Valid is already clear at the CM's first poll, 0.2 ms
after the write (`T:75.2466`), unlike the Alder Lake host (about 1 ms).

| Operation | Result |
|---|---|
| Buffer Allocation Request (`0x33`) | Metadata 1, Data[0] `0x00400004`: PCIe 64 buffers, nothing else (Linux "credit allocation parameters: PCIe: 64", `D:1187`). Only Data[0] is written |
| DROM Read (`0x24`) | Works for 1 and 16 dwords; reading dwords `0x10`-`0x15` returns bytes 64-87, of which bytes 86-87 (`0x23 0x02`) lie past the DROM |
| NVM Sector Size (`0x25`) | **Status 2** (error), not Operation Not Supported (ROUTER_CS_26 `0x02000025`); Linux tries three times and then shows no NVM version |
| others | not issued |

## 7. Sideband

- Local SB registers of the Upstream Facing Port (debugfs `sb_regs`): Vendor ID `0x174c`
  and Product ID `0x2463` answered with length 4; Debug Configuration (5) answers with the
  Result Code bit (`T:94.5095` `0x04000005`), which ends the debugfs dump ("read failed").
  Local transactions complete at once.
- Retimers seen from the device side (Linux's scan of `3:1`): index 1 answers (the host's
  on-board retimer, seen from the other end of the link): Query Last Retimer completes
  with Metadata 0; index 2 gets No Response after about 100 ms. Linux therefore registers
  no retimer on the device side (`D:` "3:1: reading NVM authentication status of
  retimers", no "new retimer").
- **No Response format:** PORT_CS_1 `0x02220408`/`0x03220408`: No Response set, **Result
  Code clear, Length kept**. The Alder Lake host shows the same without the length
  (`0x02220008`).

## 8. Hot plug and tunnels

Event order and timing (trace time). Only the host router sends events; the ASM2464
never sends one (it has no downstream port).

| Step | Observed |
|---|---|
| Plug | host plug events on 0:3 and 0:4 within 0.4 ms (`T:129.505`); enumeration of the device starts 1 ms later; bonding at +37 ms, then unplug event on 0:4 (bonded lane 1) |
| Enumeration to tunnel | Router CS read, TMU and vendor capability walk, enumeration write, PTO/UTO, Buffer Allocation, DROM (3 reads), adapter scan, NVM Sector Size x3, bonding, host retimer scan (~360 ms with the 100 ms No Response at index 2), CLx check, TMU HiFi, Configuration Valid, device retimer scan (~210 ms), then the PCIe tunnel: 0.73 s from the plug event |
| PCIe tunnel | Down path 0:9 -> 3:1 (HopID 8) -> 3:3, Up path 3:3 -> 0:3 -> 0:9; lane ingress credits 64, protocol adapter credits 7, weight 1, priority 3; Path Enable on 3:3 then 0:9 (`D:2168`-`D:2196`) |
| After the tunnel | pciehp Link Up 227 ms after path activation; PCI scan of the ASM2464 switch and the NVMe 440 ms later; NVMe ready 1.8 s after the plug event (`D:2200`-`D:2251`) |
| Unplug | host unplug event on 0:3 (`T:101.336`), Linux deactivates both paths 0.5 ms later, pciehp Link Down 22 ms after the event (`D:2027`-`D:2042`); nothing from the NVMe driver |

Round trips (Linux `tb_tx` to `tb_rx`): device router median 230 µs (p10 155, p90 296,
p99 339 µs), the host router 189 µs on the same domain, so one USB4 hop adds about 40 µs.

## 9. Power: suspend-to-idle and runtime PM

- Before suspend Linux enables wakes 0x1f on the device router and the host (`D:2366`-
  `D:2368`); the device-side writes are missing from the trace (§0).
- After resume the link was up ("0:3: is connected, link is up"), but **the ASM2464 had
  been reset**: its router operation Data dwords and ROUTER_CS_26 read 0 (`T:238.471`),
  and Router Ready was clear after the re-enumeration write. Linux restored the router
  ("restoring Switch at 0x3"), redid TMU, then **tore down and rebuilt the PCIe tunnel**
  ("tunnels restarted, sleeping for 100ms") (`D:2422`-`D:2475`). The NVMe was not
  re-enumerated by the PCI core; the nvme driver re-initialised the controller ("16/0/0
  default/read/poll queues", `D:2497`). Whether the NVMe lost power with the ASM2464 is
  [inf] (likely).
- Domain 1's host router runtime-suspended about 19 s after each unplug (`D:2052`,
  `D:2573`) and its host interface went to D3cold (`watch/0000_00_0d.3.tsv`), as in the
  earlier Framework capture; with the enclosure attached it stayed in D0.
- The Alder Lake host routers report a different UID than in the 2026-10-14 capture on
  the same laptop (domain 0 `0xed93d17080876057` instead of `0x98dc0b4080874fb1`, domain 1
  `0xdad933718087b711` instead of `0xea5e6a4180873d1a`): the host router UID is not fixed
  per machine (per boot or per firmware state, [inf]).

## 10. Boot: the firmware's tunnel and Linux's hand-over

- The UEFI firmware runs a CM: the ASM2464's switch and the NVMe were on the PCI bus at
  1.25 s, before the Thunderbolt driver loaded (`D:516`-`D:533`), and the nvme driver
  probed the disk through the firmware's tunnel (`D:934`).
- The host router of domain 1 was enumerated with a Notification Timeout of 254 ms
  ("Enabled: 1, PlugEventsDelay: 254ms", `D:1068`) and its TMU off; the previous Linux
  instance leaves 10 ms (`D:1765`).
- Linux does not adopt the tunnel. "0: resetting" (Downstream Port Reset on both USB4
  ports, `D:1145`) drops the link: unplug event 19 ms later, pciehp Link Down at 43 ms,
  the PCI devices are removed (`D:1145`-`D:1152`). The ASM2464 comes back with a plug
  event 635 ms after the reset (`D:1173`) and is enumerated from its reset state
  ("Enabled: 0, PlugEventsDelay: 10ms", `D:1181`). The tunnel is rebuilt once boltd has
  authorised the stored device (5.14 s) and the PCI core enumerates the switch and the
  NVMe afresh (§11).
- The same reset is seen at the rebind: DPR asserted at `T:74.6272`, released at
  `T:74.6388` (11.6 ms), unplug event 2 ms after the assert, plug event at `T:75.2328`,
  **594 ms after the release**.

## 11. Endpoint reset on link loss (nvme98 decision MD-2)

The question: is the NVMe behind the enclosure reset when the tunnel's link goes down, so
that a re-opened tunnel always leads to a reset endpoint?

Every time the PCIe tunnel came back after a link loss (host Downstream Port Reset at boot
and at the rebind, physical unplug and replug), the PCI core found the ASM2464 switch and
the NVMe in their reset state:

- both bridges reported bus numbers 0 ("bridge configuration invalid ([bus 00-00]),
  reconfiguring", `D:1534`, `D:1954`, `D:2210`),
- the NVMe's BARs were unassigned (`0x00000000`) and its Command register 0 ("nvme
  0000:7f:00.0: enabling device (0000 -> 0002)", `D:1572`, `D:1992`, `D:2248`),
- the bridges' Command registers were 0 ("enabling device (0000 -> 0003)"),
- the nvme driver probed a new controller instance each time.

Command register 0 after Linux had enabled memory and bus mastering before the loss
shows a conventional reset (or power loss) of the endpoint, not just a re-scan. The
switch itself was reset with it. The capture has no NVMe controller registers (CC/CSTS
are not read by the tool); the nvme driver resets the controller at probe anyway, so the
logs cannot show CSTS at re-enumeration.

Not covered: a tunnel torn down and rebuilt **without** a link loss (Linux never does
that here except at resume, where the ASM2464 itself had been reset, §9), and a link
loss shorter than the enclosure's reconnect time. The model keeps the MD-2 contract by
construction: every tunnel-up inserts a fresh endpoint (`ARCHITECTURE.md` §4.4).

## 12. Model: `usb4-device device-model=asm2464`

QEMU branch `usb4-orico` (worktree `E:/usb4-emu-wt/wt-orico`), files
`hw/usb4/usb4-router-asm2464.c`, `hw/usb4/usb4-asm2464-data.h` (generated by
`tests/usb4/gen-asm2464-data.py` from the capture), the shared image layer
`hw/usb4/usb4-router-img.c` (also used by `intel-adl` now).

```
-device usb4-device,bus=u4.0,port=1,drive=nvme0,device-model=asm2464[,uid=0x...]
DEVICE_MODEL=asm2464 HOST_OPTS=,host-model=intel-adl scripts/run-linux.sh
```

| Reproduced | How |
|---|---|
| Identity, DROM | captured router ID, UID (per-instance `uid=`; the DROM UID and CRC-8 follow), the 88-byte DROM Read stream |
| Layout and images | adapters 1-4 as captured (4 = USB3 Up without image), captured register and path images, the TMU capability at `0xc0` mapped onto the model's TMU, vendor capabilities as storage, 7 / 1 counter sets |
| Behaviour (§3-§7) | Router Ready 5 ms after Enumerated [inf delay]; Buffer Allocation PCIe 64; NVM Sector Size status 2; RST while the PCIe tunnel is down; no Cable Gen 3 Support; credits kept on protocol adapter paths; Debug Configuration undefined; host retimer at index 1 from the device side (Query Last Retimer 0), No Response without Result Code and with the Length kept; reconnect 590 ms after a link loss (DPR) |
| PCI side | on a q35 tunnel port the ASM2464 switch (`usb4-asm2464-usp`/`-dsp`, `1b21:2463`, subsystem `1b21:2463`, DSP without hot-plug) with the NVMe behind it; on the i440FX tunnel bridge the NVMe alone |
| Shared fixes found here | captured routers answer Router CS writes with Adapter Num 0 (also true of the TB3 dock in the earlier Framework capture); No Response without Result Code on `intel-adl` too |

Not modelled: live TMU time and synchronisation values, error counters (ADP_CS_7,
LANE_ADP_CS_2), vendor-specific capability contents beyond the reset image, the platform
power loss in suspend-to-idle, NVMe identity (the endpoint stays QEMU's `nvme`; QEMU branch
`usb4-orico2` (in main as of `36f6254`) gives it and the switch ports the captured link registers, including the
2.5 GT/s x1 upstream link, `ICM-PROTOCOL.md` §13.7), and the order of the PCIe link-down
and the CM's unplug handling (the model drops the tunnel link at once; the real host saw
Link Down 22 ms after the unplug event).

### 12.1 Conformance check

`tests/usb4/run-asm2464-conformance.sh <extracted capture>` replays domain 1 of the
capture (host router route 0 and device router route 3, 6,773 device-router dwords read)
against an `intel-adl` host (domain 1) with an `asm2464` device on USB4 port 2.
Result (2026-10-15):

| | Requests | Dwords matching |
|---|---|---|
| Device router reads | 1,234 (1,165 fully matching) | 6,574 of 6,773 (**97.1%**) |
| ... USB4-defined registers | | 2,140 of 2,339 (91.5%) |
| ... vendor-specific (captured storage) | | 4,434 of 4,434 (100%) |
| Device router writes | 115 | 115 with the captured outcome |
| Host router reads (domain 1) | 5,065 | 46,390 of 49,270 (94.2%) |

The 199 mismatching USB4-defined device dwords: 139 live TMU time and synchronisation
values (`0xc1`-`0xcd`), 16 live error counters and lane TMU values, about 40 that follow
from requests lost in the merged trace lines around the resume (Configuration Valid,
lane width, path entries, Time Disruption), and 3 sideband polls that see Pending once
more than the real router (1 ms timer granularity). Hot plug events: 6 of 15 matched; the
rest are host-side ordering differences after the replay's start, where the model's link
is not yet bonded as the real one was.

### 12.2 Unmodified Linux on the model

Kubuntu 26.04.1 live (kernel 7.0.0-30), `HOST_OPTS=,host-model=intel-adl
DEVICE_MODEL=asm2464`, enclosure on USB4 port 1 (route 1):

- the same probe lines as the real capture: "USB4 Switch: 174c:2463 (Revision: 0, TB
  Version: 32)", "Max Port Number: 4", "1: link: USB4", "TBT3 support: yes, xHCI: no",
  "credit allocation parameters: PCIe: 64", "DROM version: 1", "uid:
  0x70912700174c608e", "Port 1: 0:0 ... Max hop id 27/27, Max counters: 7, Credits
  66/2", "1:4: disabled by eeprom", "new device found, vendor=0xb8 device=0x2463",
  "ASMedia 246x", "1:1: CLx: CL0s/CL1 not supported", "TMU: mode set to: bi-directional,
  HiFi", a device-side retimer scan of 212 ms (real: 213 ms) with no retimer found;
  sysfs `unique_id` `8e604c17-0027-9170-ffff-ffffffffffff` as on the real enclosure;
- "0: resetting" at boot and at a rebind: unplug event 2.4 ms later, plug event 591 ms
  after the reset (real: 594 ms after the DPR release, 635 ms after "resetting");
- after `authorized=1`: the PCIe tunnel, lspci "ASMedia ASM2464PD USB4 Device Controller
  40G [1b21:2463]" for 01:00.0 and 02:00.0 with the NVMe at 03:00.0, the same "PCI bridge
  to [bus 00]" and "enabling device (0000 -> 0002)" signatures as the real re-enumeration;
  a 32 MiB O_DIRECT write reads back with the same SHA-256;
- `device_del` / `device_add` of the enclosure: unplug, tunnel down, NVMe removed; on the
  replug a fresh endpoint and the data intact.

Linux's device-router traffic, guest versus capture, for the enumeration after the
driver rebind up to the PCIe tunnel (373 real requests, final build): the same request
sequence for 369 of them (98.9%) and 398 answer dwords compared, 390 equal (98.0%); the
differences are TMU live time values and how many sideband polls see Pending before No
Response. An earlier build answered Router CS writes with the Upstream Adapter in the
Adapter Num field; that comparison found it (fixed, §12).
