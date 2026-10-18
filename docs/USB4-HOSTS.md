# Real USB4 hosts: the `intel-adl` host model, the conformance check and `preos-cm`

The xhci98 project's USB4 software connection manager (CM) for Windows 98 has to work on
real USB4 hosts, not only on the spec-derived minimal host router of the `usb4-generic`
profile. This document covers four additions to the generic profile:

- `host-model=intel-adl`: a host router that reproduces a captured Intel Alder Lake-P
  integrated USB4 host router.
- A real-host conformance check that replays the captured Linux CM's host router
  traffic against the model and compares every answer.
- `preos-cm=on`: emulated platform firmware that runs a CM before the OS, as a USB4 BIOS
  does.
- `host-model=asm4242`: the ASMedia ASM4242 host of AM5 X870 boards, from public sources
  only (§5).
- `usb4-device device-model=asm2464`: a captured real **device** router, the ASMedia
  ASM2464PD of an ORICO AAGM2-U4 NVMe enclosure, with its own replay check (§6).
- `host-model=amd`: an AMD USB4 host router (Yellow Carp / Pink Sardine), public
  sources only (§7).
- `usb4-device dialect=tb3` on a USB4 host: the Thunderbolt 3 device router (CalDigit
  TS3 Plus) as a software CM finds it, from the Framework capture, with its own replay
  check (§8).

§7 and §8 come from QEMU branch `usb4-tb3dev` (2026-10-15), in main as of `b5936c4` (`usb4-emu`).

Source of truth for §1-§4: the Framework Laptop 13 (12th gen) capture,
`tests/captures/framework13-12th/linux-ts3plus/p14s-linux-20261014-143756-framework13.tar.gz`
(see its `README.md`). Every
statement about the real host below is `observed` in that capture unless it says
`inferred`.

## 1. `host-model=intel-adl`

```
-device usb4-host,id=u4,...,host-model=intel-adl[,host-domain=0|1]
```

`minimal` (the default) is the spec-derived host router that the Windows and Linux
regressions were validated on. It is unchanged. `intel-adl` is generic profile only.
`host-domain` selects the identity of NHI #0 (00:0d.2, router 8087:463e) or NHI #1 (00:0d.3,
8087:466d). The PCI identity of the host interface stays QEMU's 1b36:00f4, so guests still
take the software-CM path. The router-level IDs in Router CS and the DROM are the captured
Intel values.

> **Maintainer check.** AGENTS.md says `usb4-generic` must never use Intel IDs. That rule
> is about the PCI identity that steers guests to a firmware CM, and the PCI identity is
> untouched here. The router vendor ID 8087 in ROUTER_CS_0 is an Intel ID, though, and it
> is only used when `intel-adl` is selected explicitly. Please confirm this exception.

### What it reproduces

Register images come from the capture. `tests/usb4/gen-adl-data.py <extracted capture>
hw/usb4/usb4-adl-data.h` generates them (GPL-2.0-only). The base is the debugfs dump of host router
0-0 in `snap-1-initial`, where domain 0 never had a device. Every dword the Linux CM read
before writing it is taken from the trace instead, because that read shows the state after
the host router reset that precedes the trace. Router operation Data/Metadata/Opcode
(ROUTER_CS_9-26) are set to 0, the value seen after a power cycle.

| Item | Captured value / behaviour |
|---|---|
| Adapters | 1-2 lane (USB4 port 1), 3-4 lane (port 2), 5-6 DP IN, 7 host interface (Upstream Adapter, ADP_CS_0 vendor 8086), 8-9 PCIe Down, 10-11 not present (ERR_ADDR), 12-13 USB3 Gen X Down. Max Adapter 13. |
| Router CS | ROUTER_CS_0-26 and the TMU capability at 0x1b-0x34 as in the model. Vendor-specific capabilities follow: 0x3e (VSEC 1), 0x8f (3), 0xc2 (4), 0xd0 (5), 0xff (6, long VSEC chain through 0x600, 0x700, 0x800, 0x1061, 0x1072, 0x10b6). Router CS size 0x10e4 dwords, UUID from ROUTER_CS_7/8 per domain. |
| Adapter capability chains | Lane 0: ADP_CS_1 next 0x0a TMU (8 dwords), then 0x90 USB4 Port (20), then 0x36 Lane (3), then 0x3e VSEC. Lane 1 has the same chain without the port capability. PCIe 0x39 (1 dword) then 0x3a VSEC. USB3 0x0a (5) then 0x10 VSEC. DP IN 0x39 (9) then VSEC. Host interface: VSECs at 0x3e and 0x52. |
| Path CS | Max HopID 19 (lanes), 8 (PCIe, USB3), 9 (DP IN), 11 (host interface: 12 rings, matching HOST_CAPS 0x0000000c in the NHI BAR0 dump). Captured non-zero reset entries (credits and flow control on protocol adapters and the host interface). |
| Counters CS | ADP_CS_1.CCS = 1. 16 counter sets on lanes and the host interface, 2 on the others, 3 dwords each. Reads 0. |
| Router operations | Buffer Allocation Request: USB3 32, DP AUX 1, DP main 0, PCIe 64, HI 14. Only those five Data dwords are written, the rest keep older contents. DROM Read: the captured host DROM ("INTEL", "Gen12"). Query/Allocate/De-allocate DP Resource on adapters 5/6: success. Opcode 0x25: Not Supported. Get PCIe Downstream Entry Mapping (0x30): Not Supported since `usb4-tb3dev` (the shared spec-derived answer before), see below. Get/Set Capabilities (0x31/0x32) and Block/Unblock Sideband (0x34/0x35) still get the shared spec-derived answers, which are not observed either. Other opcodes: Not Supported. Operation Valid stays set for about 1 ms. |
| Hot plug | Setting ROUTER_CS_3.Enumerated sends a plug event for each DP IN adapter every time (domain 0 after each power cycle). |
| Lane adapters | ADP_CS_4 Total Buffers 60 when disconnected, 120 in CL0, 0 on lane 1 of a bonded port. LANE_ADP_CS_1 keeps its last speed and width in CLd. PORT_CS_18 keeps CLx Protocol Support (bit 10). |
| Sideband | Port SB registers from debugfs, product ID per domain. A read answers the register size, except Debug Configuration and Debug (16 bytes) and LRD Tuning (1 byte). A transaction stays Pending about 1-2 ms, or about 100 ms before No Response. |
| Retimer | One on-board retimer at index 1 on each port (8087:15ee, SB registers from `1-0:3.1`), answering RT transactions while a cable is present. Port operations: Query Last Retimer gives Metadata 1, Query Cable Retimer 0, NVM Sector Size 0x1000, NVM Read returns the captured NVM dwords at 0x08 and 0x44-0x4b. Index 2 gets No Response. |
| TMU / CLx | TMU_RTR_CS_0 0x4320033e and the TSPacketInterval and mode writes the CM makes. CLx enable bits in LANE_ADP_CS_1 are stored as written. The model has no real CLx state. |

Not modelled: the live contents of the vendor-specific capabilities (temperatures,
counters, the VSEC 6 window that mirrors port and sideband state), real TMU time values,
DisplayPort, NVM operations on the host router (Windows' NVM Read 0x22 gets Not Supported;
the capture has no answer for it). Thunderbolt 3 (TBT3-compatible) links are modelled
since `usb4-tb3dev` (§8).

**Get PCIe Downstream Entry Mapping (router operation 30h) is not answered.** The USB4
Specification makes it optional for a Host Router (§8.3.1.3). The Framework captures cannot
show the real Alder Lake-P answer: the Linux CM never issues the operation (it maps PCIe
Down adapters to USB4 ports by position, `usb4.c:usb4_switch_map_pcie_down`), and the
traces of both Framework sessions (`linux-ts3plus`, `linux-orico`) hold only opcodes 10h,
24h, 25h and 33h. Until a capture with a CM that issues 30h exists (for example Windows'
inbox CM with an ETW trace that can be decoded), `intel-adl` reports Not Supported, so a
CM cannot come to depend on a made-up mapping. `minimal`, `amd` and `asm4242` answer it
with the spec-derived mapping (inferred).

### Two domains

Alder Lake-P has two host interfaces, each with its own host router and two USB4 ports. The
`_DSD` in SSDT6 maps the USB3 ports SS01/SS02 to `\_SB.PC00.TDM0` and SS03/SS04 to
`\_SB.PC00.TDM1`, with `usb4-port-number` 0, 1, 2 and 3, so the numbering is global and not
per host interface. The tunnel root ports 00:07.0-07.3 use a TUID-dependent `_DSD` that
selects TDM0 or TDM1 (`inferred` from the AML bytes: TUID 0-1 go to TDM0, 2-3 to TDM1).
Domains do not share any state. The model therefore uses one `usb4-host` per domain: give
a second host `host-domain=1` and its own two tunnel ports. One host is enough for CM
development.

## 2. Real-host conformance check

```
# extract the capture tarball to <dir> (PATHMAP.tsv maps FAT-safe names), then
scripts/msys2-shell.sh "<wt>/tests/usb4/run-adl-conformance.sh <dir>"
# ADL_VERBOSE=1: every mismatch; ADL_TOP=n: worst n registers;
# ADL_MIN_MATCH=pct: exit 1 below that share of matching dwords
```

`tests/usb4/adl-replay.py` takes all route-0 traffic of the Linux CM from
`trace-thunderbolt.txt` for both domains: reads with their answers or error codes, writes
with their outcome, the host router's hot plug events and the CM's acknowledgments.
`tests/usb4/adl-conformance.c`, which links the fabric with the fakes from `fabric-test.c`,
creates an `intel-adl` fabric per domain and sends every request in order on a virtual
clock that follows the trace timestamps. It compares each answer dword by dword.

The replay also follows the capture's history:

- A device router is attached where the first ADP_CS_4 read shows Plugged. Cable changes
  in the trace are applied when the capture shows a lane 0 event the model has not
  produced itself.
- Domain 1 was still configured by the previous CM instance (ROUTER_CS_3.Enumerated was
  already set at the first read), so ROUTER_CS_1-4 are seeded from that read.
- An Enter Sleep write followed by a pause of 5 ms or more is a platform power cycle
  (runtime D3cold). The model gets a power-on reset there.

Result (2026-10-14; 2026-10-15 after the sideband No Response fix of §6):

| | Total | Matching |
|---|---|---|
| Read requests | 8428 | 7139 fully matching (7157 since 2026-10-15) |
| Read dwords | 82107 | 78528 (95.6%); 78546 (95.7%) since 2026-10-15 |
| USB4-defined registers | 12813 dwords | 12218 (95.4%); 12236 (95.5%) since 2026-10-15 |
| Vendor-specific (captured storage) | 69294 dwords | 66310 (95.7%) |
| Writes | 530 | 530 with the captured outcome (ack or error) |
| Hot plug events | 29 | 20 matched, 0 extra from the model |

What the remaining differences are:

- Live vendor-specific values.
- TMU LocalTime.
- Sideband Pending timing, which is jittery on the real host.
- The domain 1 state left by the previous CM, and the Thunderbolt 3 dock on domain 1:
  path entries, PCIe LTSSM, bonding and lane 1 events. A model USB4 device router stands
  in for the dock, and route-3 traffic is not replayed.

The first reads of domain 0 seed the image, so they match by construction. The
informative parts are domain 1 and every read after a write, a router operation, a power
cycle or a hot plug.

## 3. `preos-cm=on`: a pre-OS firmware CM

```
-device usb4-host,...,preos-cm=on        (generic profile, any host-model)
```

`hw/usb4/usb4-preos.c` acts as the platform firmware's CM. It runs at every power-on reset,
and when a device router is attached before the OS driver first touches the host
interface's BAR0. It does the following:

1. Enumerates the host router.
2. For each connected device router, down a daisy chain: clears Lock, enumerates the
   router, sets PCIe Tunneling On and Configuration Valid, and bonds the lanes.
3. Programs the PCIe paths (HopID 8/9, as in Guide 5.3.1) and sets Path Enable on both
   PCIe adapters.
4. Consumes its own hot plug events and hands over without cleaning up.

It finds capabilities by walking the chains, so it works on `intel-adl` too. The tunnel
evaluator sees the tunnels up and the NVMe endpoints are cold plugged, so the firmware and
the OS find them on the PCI bus at boot. A power-on reset re-runs the firmware CM while
tunnel evaluation is held, so the tunnels do not flap.

What the OS CMs did with this state:

- **Windows 11 built-in CM** (build 26300, `CHAIN=1 USB3=1`, both host models): it cleans
  up the host router configuration space, as Microsoft's "BIOS to operating system
  handoff" describes. It rewrites ROUTER_CS_1-4 and redoes TMU setup, clears Path Enable on
  the host PCIe Down adapters, resets the lane adapter configuration, and asserts then
  releases Downstream Port Reset on each USB4 port, so the device routers reset. It then
  invalidates the host path entries, enumerates every router again and builds new tunnels.
  The endpoints go away and come back. All three NVMe disks and the USB3 disk end up
  online.

  This exposed a tunnel-port bug, now fixed. A hot insert into a slot the guest still had
  powered reported Attention Button Pressed, which Windows takes as an eject request, so
  it powered the slot off 5 s later.
- **Linux software CM** (Kubuntu 26.04 live, `security=user`): logs `0: resetting` and
  asserts Downstream Port Reset on both ports. The firmware's tunnel goes down (surprise
  removal of the cold-plugged NVMe). It enumerates the device router again and bonds it.
  After `echo 1 > authorized` it builds a new PCIe tunnel, and `/dev/nvme0n1` reads at
  about 450 MB/s.

Neither CM adopts the firmware's tunnels: both tear them down and rebuild them.

## 4. Other runs (2026-10-14)

- Windows 11 CM on `host-model=intel-adl` (`CHAIN=1 USB3=1`): all disks online, no USB4
  problem devices. It issued Buffer Allocation and DROM Read on every router, Query DP
  Resource and then De-allocate DP Resource on adapters 5/6, and NVM Read (0x22) on the
  host router, which got Not Supported. It made no sideband or retimer accesses.
- Linux on `host-model=intel-adl`: `USB4 Switch: 8087:463e`, `new retimer found,
  vendor=0x8087 device=0x15ee` on `0-0:1.1`. It brought up a USB3 tunnel 0:12 <-> 1:4 and,
  after authorization, a PCIe tunnel with a working `/dev/nvme0n1`.

## 5. `host-model=asm4242`: ASMedia ASM4242 (AM5 X870), public sources only

```
-device usb4-host,id=u4,...,host-model=asm4242[,asm-*=...][,intx=off]
HOST_MODEL=asm4242 [TOPOLOGY=switch|bridge] [DEVICE2=1] scripts/run-linux.sh
```

The discrete USB4 host that every AM5 X870 / X870E board carries, and the likeliest real
machine that has both USB4 and a legacy BIOS (CSM). **No such board is available and none
will be**, so unlike `intel-adl` there is no capture, no register image and no
conformance replay. Everything comes from the public material in
[research/AM5-USB4.md](research/AM5-USB4.md) (its §7 lists the model elements M1-M12, its
§8 the unknowns and hedges). Tags below: **[pub]** public hardware dump, **[lkml]**
mailing-list patch, **[vendor]** vendor document, **[inf]** our inference, **[unk]** no
information, in which case the model keeps the `minimal` router's behaviour. Nothing here
is `observed` in this project's sense. Generic profile only; the PCI and router IDs are
ASMedia's, not Intel's.

### What it models

| Element | Model | Source |
|---|---|---|
| Host interface PCI identity | `1b21:2425` rev 01, class `0C0340`, subsystem `1b21:2425` | [pub] lspci, linux-hardware |
| Router identity (ROUTER_CS_0) | `174c:2428`, USB4 version 1.0, host interface version 0 (USB4 v1) | [lkml] quirk patch; v1 [inf] |
| USB4 ports | two, Gen 3 x2 (40 Gb/s) | [vendor] |
| Adapter layout | lanes 1-4; DP IN 5-6, Host Interface 7, PCIe Down 8-9, USB3 Gen X Down 10-11 by default, each block movable (`asm-adp-dp`, `-hi`, `-pcie`, `-usb3`; `asm-adp-dp=0` removes the DP IN adapters). Gaps answer ERR_ADDR, as on the captured Intel host | [inf]: the default follows the captured Intel order without its unused 10-11; the real numbering is [unk] |
| DP IN adapters | type `0E0101h`, DP adapter capability (DP 1.4, HBR3, 4 lanes, MST); Query/Allocate/De-allocate DP Resource succeed; no DP source, no hot plug event | two DP sinks [vendor]; the rest [inf] |
| NVM | NVM Sector Size (4 KiB) and NVM Read, holding only the version dword at `0x28` and the date dword at `0x1c` in the ASMedia byte order; Linux shows `nvm_version` `200011.250708` (`asm-nvm-version`, `asm-nvm-date`; version 0 disables the NVM operations). Write and Authenticate are Not Supported | version [lkml][pub]; offsets [code] Linux `nvm.c` behaviour; sector size [inf] |
| Buffer allocation | USB3 32, DP AUX 1, DP main 18, PCIe 32, baMaxHI 32 | baMaxHI [lkml]; the others [unk], `minimal` values |
| Quirk a, `asm-quirk-pending` (on) | on the Host Interface adapter, Pending Packets (PATH_CS_1 bit 28) is set when a CM clears Valid on a valid path and never clears; it is cleared when the entry is made valid again or by a router reset | [lkml] Fan Ye v3: "never clears"; the clearing points [inf] |
| Quirk b, `asm-quirk-tx-e2e` (on) | a Tx ring other than ring 0 with E2E flow control enabled never completes a descriptor | [lkml] thunderbolt-net patch |
| Quirk c, `asm-quirk-credits` (on) | lane adapters report 174 Total Buffers and the router baMaxHI 32 (off: 120 and 14). A CM that uses the lane figure as a 7-bit path credit value overflows | [lkml] credit-clamp patch |
| Interrupts | MSI (1 vector), MSI-X (16), INTA#; USB4 clearing rules (read-to-clear unless Disable ISR Auto-Clear, explicit clear register), the same as every `usb4-generic` host. `intx=off` (new generic property) removes INTA# so a driver must poll or use MSI | MSI/MSI-X [vendor]; INTx [unk] |
| Pre-OS CM | `preos-cm=off` by default; `preos-cm=on` works unchanged | §8 hedge: no public evidence of a firmware CM or pre-OS tunnels |
| Security | none (software CM, Linux shows `user`) | [pub] |
| Not modelled | TMU and CLx details, vendor capabilities, the real DROM (the host DROM says "QEMU" / "USB4 Host Router (asm4242 preset)"), retimers, Thunderbolt 3 device behaviour, the xHCI's slow-halt quirk (AM5-USB4.md M7), NVM upgrade | [unk] |

Ring count stays 16 (`minimal`), [unk].

### PCI topology

`TOPOLOGY=switch` (the default for `HOST_MODEL=asm4242`) builds the layout that three
independent public dumps show [pub] (device 1 as the second tunnel port is [inf]):

```
pcie-root-port 00:03.0 (bus-reserve=100, mem-reserve=64M)     real: CPU GPP bridge 00:02.2
 └─ usb4-asm-usp           1b21:2421   bus 01
     ├─ usb4-asm-tunnel-dsp 1b21:2423  02:00.0  tunnel, USB4 port 1 (tp0)
     ├─ usb4-asm-tunnel-dsp 1b21:2423  02:01.0  tunnel, USB4 port 2 (tp1)
     ├─ usb4-asm-dsp        1b21:2423  02:02.0 ─ usb4-asm-xhci 1b21:2426 (qemu-xhci, p2=2 p3=2)
     └─ usb4-asm-dsp        1b21:2423  02:03.0 ─ usb4-host host-model=asm4242 (NHI)
```

`TOPOLOGY=bridge` puts the NHI (00:04.0), two `usb4-tunnel-port`s (00:05.0, 00:06.0) and
the xHCI (00:07.0) on `pcie.0`, as for the other host models. On i440FX the same switch
is built from conventional PCI stand-ins (`usb4-asm-pci-usp`, `usb4-asm-pci-bridge`,
`usb4-asm-tunnel-bridge` with SHPC), as the Thunderbolt 3 switch is for Windows 98
(`usb4-asm4242-test` `switch-pc` shows the command line).

**Padding.** The dumps show firmware leaving about 48 bus numbers per tunnel port
[pub/inf]. SeaBIOS and OVMF honour QEMU's bus and window reservation hint only on Red Hat
bridge IDs, so it cannot be put on downstream ports that carry ASMedia IDs. The run script
pads the root port instead (`ASM_BUS_RESERVE`, default 100, giving buses 01-65 as in the
dumps; `ASM_MEM_RESERVE`, default 64M). Each tunnel port then gets one bus and the
firmware's minimum hot-plug window. The real per-port MMIO padding is [unk]; a guest CM
must cope with an endpoint whose BAR does not fit (AM5-USB4.md §8).

**ACPI.** `\_SB._OSC` grants native USB4 as for every generic host. The `_DSD` port
mapping (`usb4-host-interface`, `usb4-port-number`, HotPlugSupportInD3,
ExternalFacingPort) is now also emitted on the tunnel downstream ports of the switch,
referencing the NHI node behind the switch (`\_SB.PCI0.S18.S00.S18.S00`). That the AM5
firmware provides these links is [inf] from Windows' Code 51 reports on the tunnel ports.

### Results (2026-10-15)

QEMU branch `usb4-asm` (worktree `src/wt-asm`).

- Fabric harness (`tests/usb4/fabric-test.c`, `test_asm4242`): identity, default and
  alternative layouts, layout validation, DP IN capability, Buffer Allocation, NVM sector
  size and dwords, DP resource operations, quirks a and c on and off, pre-OS bring-up.
  39,771 checks, 0 failures.
- qtest `usb4-asm4242-test` (7 cases): PCI identity on pc and q35, `intx=off`, layout
  rejected at realize, router ID read over ring 0, USB4 interrupt clearing, quirk b, the
  q35 switch with a pre-OS tunnel to NVMe and Data Link Layer link reporting on the tunnel
  port, and the i440FX stand-in with a pre-OS tunnel through an SHPC tunnel bridge. The
  existing qtests still pass: host 19, tunnel 25, icm 14, icm-tr 10, harness 25.
- Linux (Kubuntu 26.04.1 live, kernel 7.0.0-30, unmodified), `HOST_MODEL=asm4242
  DEVICE2=1`, switch topology: lspci shows the ASM4242 functions under their pci.ids
  names; `using software connection manager`, `created link from 0000:02:00.0` and
  `02:01.0`, `USB4 Switch: 174c:2428`, `Max Port Number: 11`, `Upstream Port Number: 7`,
  `0: NVM version 200011.250708`, credit allocation `DMA: 32`, both device routers
  enumerated and bonded, security `user`. After `authorized=1` on `0-1` and `0-3` both
  NVMe disks appear behind 02:00.0 and 02:01.0 and a 32 MiB O_DIRECT write reads back
  with the same SHA-256. `authorized=0` on `0-1` removes only its disk (pciehp Link Down,
  Card not present); `device_del` / `device_add` of the port-2 router removes it and
  brings back the same data. `TOPOLOGY=bridge`: the same probe and both disks.
  `preos-cm=on`: the NVMe is present from the first PCI scan, Linux resets the host
  router (`0: resetting`), the firmware tunnel goes down and comes back after
  authorisation, as in §3.
- Not run: Windows 11 built-in CM, and any legacy Windows guest (the xhci98 project's
  part).

Model fixes this found, both in shared code and both general:

- Without the `_DSD` on a switch topology Linux warned that the device links to tunneled
  native ports were missing, runtime-suspended the NHI on its own and, on resume, restarted
  the tunnels under an active pciehp, which powered one slot off and lost a disk. The
  ACPI builder now places the NHI path behind bridges and `usb4-tunnel-dsp` emits the
  `_DSD` when it is a host's tunnel port.
- `usb4-tunnel-dsp` advertised no Data Link Layer Link Active Reporting, so Linux pciehp
  (attention button present) never saw a tunnel go down and kept the gated disk. It now
  reports link active and DLLSC like `usb4-tunnel-port`. This also affects the Thunderbolt
  3 switch topologies and daisy-chain ports.

### Legacy guests (CSM boot of Windows 98 to 7)

Works: the i440FX stand-in topology with `usb4-tunnel-bridge` slots
(`shpc-autoenable=on`), INTx, 32-bit BAR0, pure polling, `preos-cm=on` for a boot-time
tunnel. q35 works for Windows 7-class guests.

Not possible or not meaningful here:

- A PCIe switch on i440FX: the stand-ins are PCI-to-PCI bridges with the switch IDs,
  without PCIe capabilities; the topology and IDs match, the port types do not.
- Per-port firmware padding (above) with stock SeaBIOS / OVMF.
- `_OSC` and `_DSD`: legacy Windows never evaluates them, so they make no difference
  there; whether AM5 firmware does anything for the ASM4242 when `_OSC` is never called
  is [unk].
- PCIe extended capabilities (USB4 DVSEC, DSN) exist only on q35.
- Whether AM5 firmware runs a CM before the OS or leaves anything configured at the CSM
  hand-off is [unk]. Test the legacy CM with `preos-cm=off` and `on`.

### What stays uncertain

Everything AM5-USB4.md §8 lists remains: the adapter numbering, which downstream port
carries which tunnel, TMU / CLx / vendor capabilities / DROM, router operations beyond
those above, MMIO padding, INTx, the xHCI port pairing, the exact conditions of the three
quirks, and pre-OS behaviour. Each has an option or a hedge; none is confirmed. A single
public `lspci -xxx` plus a tbtools or debugfs dump of an ASM4242 host would turn most of
it into `observed` data and allow a replay check like §2.

## 6. `device-model=asm2464`: the captured ASMedia ASM2464PD device router

```
-device usb4-device,bus=u4.0,port=1,drive=nvme0,device-model=asm2464[,uid=0x...]
DEVICE_MODEL=asm2464 HOST_OPTS=,host-model=intel-adl scripts/run-linux.sh
scripts/msys2-shell.sh "<wt>/tests/usb4/run-asm2464-conformance.sh <dir>"
```

Source: `tests/captures/framework13-12th/linux-orico` (Framework 13 + ORICO AAGM2-U4,
Linux software CM, rebind, unplug/replug, suspend-to-idle). Everything about the real
router, the model and its checks is in
[captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md); in short:

- Router `174c:2463`, DROM revision 1 (TBT3-compatible) "ASMedia" / "246x" with vendor
  `0xb8`, adapters 1-2 lane, 3 PCIe Up, 4 unused (USB3 Up by number), 66 lane buffers,
  Gen 3 x2, no CL states, TMU capability at `0xc0` behind which three vendor-specific
  capabilities follow; Buffer Allocation reports PCIe 64 only; NVM Sector Size fails
  with status 2 (Linux: no NVM); Router Ready a few ms after Enumerated; reconnect about
  590 ms after a Downstream Port Reset; on q35 its own PCIe switch (`1b21:2463`) in front
  of the NVMe.
- Built on the same image layer as `intel-adl` (`hw/usb4/usb4-router-img.c`, generator
  `tests/usb4/gen-asm2464-data.py`). Any generic host works; `intel-adl` reproduces the
  captured pair, including the device side of the host's on-board retimer.
- Replay check (2026-10-15): device router 97.1% of 6,773 read dwords match (91.5% of the
  USB4-defined ones, the rest live TMU time, error counters and trace loss around the
  resume), 115 of 115 writes with the captured outcome; the `intel-adl` host of domain 1
  94.2% in the same replay.
- Unmodified Linux on `intel-adl` + `asm2464`: the probe lines, sysfs identity and
  `unique_id` of the real enclosure, the 590 ms reconnect after "0: resetting", the
  PCIe tunnel, the ASM2464 switch and a working `/dev/nvme0n1`.

Changes to shared behaviour that came with it (all observed, all limited to the routers
built from a capture): sideband No Response is answered without the Result Code bit
(also `intel-adl`, which raised its replay match to 95.7%), and Router CS write responses
carry the request's Adapter Num (0), not the Upstream Adapter.

The ADL host router's UID is not fixed: the 2026-10-15 capture on the same laptop shows
other UIDs for both domains than the 2026-10-14 one. `intel-adl` keeps the first.

## 7. `host-model=amd`: AMD USB4 host router, public sources only

```
-device usb4-host,id=u4,...,host-model=amd[,host-domain=0..3]
HOST_OPTS=,host-model=amd scripts/run-linux.sh
```

Everything here is `inferred` from public sources. The only public facts about AMD's
integrated USB4 host routers (Yellow Carp / Rembrandt, Pink Sardine / Phoenix) that a
model can use are in the Linux driver: `drivers/thunderbolt/quirks.c` lists router vendor
`0x0438` (AMD's USB-IF vendor ID) with devices `0x0208`, `0x0209`, `0x020a` and `0x020b`,
for which it disables CL states. The NHI PCI IDs (`1022:162e`, `162f`, `1668`, `1669`)
are not in the Linux driver, which binds USB4 host interfaces by class code
(CONTROLLER-CATALOG.md §1.1).

| Item | Model | Source |
|---|---|---|
| Router ID (ROUTER_CS_0, DROM, SB Vendor/Product ID) | `0438:0208`; `host-domain` 0-3 picks `0x0208`-`0x020b` | quirks.c; which ID belongs to which platform and NHI is not public [inf] |
| Layout, registers, router operations, ports | The `minimal` router unchanged (`ports`, default 2) | nothing public [unk] |
| CL states | Not advertised, as on `minimal` (Linux would disable them anyway) | quirks.c |
| Host interface PCI identity | Emulator's `1b36:00f4`, as `intel-adl` | AGENTS.md forbids only Intel PCI IDs on `usb4-generic`, but nothing shows what an AMD NHI ID would change for a guest beyond binding, and guests bind by class |
| DROM model name | "USB4 Host Router (amd preset)" | the real DROM content is [unk] |

So `amd` is `minimal` with AMD's router identity: it lets a CM's vendor checks and quirk
tables be exercised, not AMD-specific behaviour. A capture of an AMD USB4 laptop (Linux,
as for the Framework) would turn it into an image-based preset like `intel-adl`
(CONTROLLER-CATALOG.md §7 item 4). Tests: `tests/qtest/usb4-tb3dev-test.c` (identity,
host-domain range, a TB3 device router and PCIe tunnel on `amd`) and
`tests/usb4/fabric-test.c` (`test_tb3_sw`).

## 8. A Thunderbolt 3 device router on a USB4 host

```
-device usb4-host,id=u4,...,profile=usb4-generic[,host-model=minimal|intel-adl|amd]
-device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,dialect=tb3[,lc-uuid=captured][,uid=0x...]
NO_DEVICE=1 HOST_OPTS=,host-model=intel-adl scripts/run-linux.sh \
    -device usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,dialect=tb3,lc-uuid=captured
scripts/msys2-shell.sh "<wt>/tests/usb4/run-tb3-conformance.sh <dir>"
```

Source: `tests/captures/framework13-12th/linux-ts3plus` (Framework 13 + CalDigit TS3
Plus, an Alpine Ridge C 4C device router `8086:15d3`, Linux software CM). The Linux
behaviour it exercises is listed in [CAPTURE-VS-LINUX.md](CAPTURE-VS-LINUX.md) ADL-38 to
ADL-54. The same `usb4-device dialect=tb3` router serves the `tb3-alpine-ridge` profile,
where it keeps the state the firmware CM leaves (ICM-PROTOCOL.md §5, P14s capture); on a
USB4 host it starts from the dock's power-on state instead. Values below are `observed`
unless tagged otherwise.

| Item | Model |
|---|---|
| Identity | Router `8086:15d3`, revision 6, TB version 2, generation 3 in Linux. Intel's router ID inside router config space, as on the real dock; the PCI side has no Intel ID. Allowed by the second maintainer exception in AGENTS.md ("Two profiles, one fabric", 2026-10-15) |
| Power-on Router CS | `tests/usb4/gen-tb3-sw-data.py` overlays the P14s image with every dword Linux read before writing it after a re-plug (`hw/usb4/usb4-tb3-sw-data.h`): dword 1 `0x0602c005` (Upstream Port Number 0, depth 0), route 0, not configured, dword 4 `0x0200000a`, Plug Events + 1 `0x4e05`, SX_CTRL `0x160` in both link controller port blocks, power-on Path CS entries |
| Writable (as Linux writes them) | Dword 1 Upstream Port Number and depth, dwords 2-3 route and configured, dword 4 Notification Timeout (`0x020000ff`), Plug Events + 1 bits 6:2 (`tb_plug_events_active`: `0x4e01`), EEPROM control, SX_CTRL `0x1a9`/`0x2a9` (L1C/L1D/L2C/L2D, UPSTREAM, wake and sleep bits; `tb_lc_configure_port`: `0x40010160`), lane Target Link Width (dword `0x37` bits 5:4), PCIe Path Enable, Path CS. The bit masks beyond the observed writes follow the Linux `tb_regs.h` definitions [inf] |
| Capability chain | TMU 5, VSEC 0 at 0x20, Plug Events (VSEC 1) 0x28, VSEC 2 0x63, TIME2 (3) 0x79, CP_LP (4) 0xac, VSEC 5 0xcf, link controller (6, long) 0xff, then VSEC 7 0x400, 9 0x6c0, 10 0xff7 (read-only captured values). Link controller descriptor `0x01001402`: port blocks at 0x113 and 0x213, 0x100 dwords each |
| Router CS gaps | 0x1ed-0x212, 0x2ed-0x3ff and 0x402-0x43e are not accessible (Address error), as in the debugfs dump |
| Link controller UUID | Unrelated to the DROM UID, as on the real dock (C3). Default: derived per device from its DROM UID (unique per port position and serial within a host, stable across re-plugs) and a per-host discriminator (a hash of the `usb4-host`'s QOM path and `host-domain`, stable for the same command line) by a mixing function, so two docks never share one, also on two hosts (Linux `unique_id`, bolt's key). `lc-uuid=captured`: the captured fused UUID `000003c6 18879000 30efca23 26d04222` (Linux `unique_id` `c6030000-0090-8718-23ca-ef302242d026`), a fixture for one dock that should look like the real TS3 Plus; the replay check uses it. It is refused on a `tb3-*` host, where no CM reads a device router's link controller UUID. `uid=` replaces dwords 0-1 either way. The ICM event UUID on `tb3-alpine-ridge` stays the DROM UID + ones (R11) |
| Lanes | Two single lanes of 60 credits on link-up (`0x0814001c`, dword 4 `0x03c00000`); after the host bonds them lane 0 `0x0824003c` / `0x07800000`, lane 1 0; unlinked `0x1c18001c` |
| PCIe adapters | Up 6, Down 7 (DFP), capability at `0x39`; `0x012e0400` until a PCIe tunnel to the router first came up, `0x01260400` idle after that, `0xc6210400` with the tunnel up. No Configuration Valid handshake |
| Hot plug events | Plug events for adapters 9, 2 and 10 after the CM configures the router (ADL-39); lane 1 (adapter 2) unplug after bonding (ADL-46). The Plug Events + 1 disable bits suppress them by adapter type: bit 3 lane adapters (also the downstream lanes), bit 4 DP OUT, 5 / 6 low / high DP IN [inf: Linux `tb_regs.h` names; no capture shows a disabled event]. A suppressed event is dropped, not sent later when the bit is cleared, as for ADP_CS_5 Disable Hot Plug Events |
| EEPROM bit-bang | DROM by bit-bang (a TB3 router has no DROM Read router operation); while bit-banging is enabled the control dword reads only the control bits and the data line, low during the command (`0x10`, `0x11`, `0x18`, `0x19`), the idle value `0x0002218a` again once disabled |
| DMA port (adapter 5, since `usb4-win11tb3`, in main as of QEMU `2a893ea`) | Host Interface adapter 5 with the read-only DMA port (ICM-PROTOCOL.md §5.2, R20): dword 0 `0x15788086` (not the router's ID), type `0x01000002`, outbound word `0` at power-on, flash read `0x22000045` -> inbound `0x22000044`, outbound `0x20000020`, data `0xaaaa2b2d 0x0428a804`; NVM version `0x10440000` (44.0) at flash `0x08` (Linux: "NVM version 44.0", ADL-42). Header dwords 1 and 3-5 and the capabilities at `0x3e`/`0x52` are the P14s host NHI adapter's [inf]. The flash is the SPI part the bit-bang reads, so the DROM is at the router dword `0x34` offset (`0x210`) there too [inf]. Flash dword `0x734` reads 0 [inf: Windows driver, below]. Other commands: access error (status 2) [inf]. Only under a software CM; the `tb3-*` profiles keep the port hidden (ARCHITECTURE.md §4.2) |
| Response headers | Router CS write responses carry Adapter Num 0, read responses the Upstream Adapter 1 |
| Host USB4 port | PORT_CS_18 TBT3-Compatible Mode (TCM, bit 9), Cable USB4 Version 01h, no CLx Protocol Support, no Cable Gen 3 Support: `0x00003301` linked on `intel-adl`; the same rule on `minimal` and `amd` [inf]. `intel-adl`: 60 Total Buffers per lane until bonded, then 120 / 0 (ADL-44) |
| Lane bonding | The host's LB on lane 0 bonds when both TB3 lanes have Target Link Width dual at `0x37`. The dock's downstream port bonds the same way: LB (bit 15) on its lane 0 (`0x37` of adapter 3), with Target Link Width dual on adapters 3, 4 and on both lanes of the chained router; the dock then reports adapter 4 unplugged (`linux-ts3plus-orico`: `0x0814803c` on 3:3, then the 3:4 unplug event). LB self-clears: the next read of 3:3 `0x37` gives `0x0824003c` (dual, LB clear; trace lines 8377-8382) |

Not modelled: NVM write and authentication through the DMA port, the live vendor
registers (counters, temperatures, VSEC 2 dword `0x64`, which changes after configuration), the lane 1 plug/unplug flapping during
link training (85.39-86.19 s in the capture), DisplayPort, the internal xHCI connect
(`tb_switch_xhci_connect`: the dock reports no USB plugged, so Linux writes nothing), and
the dock's own PCIe functions (Alpine Ridge bridges `7d:00.0`/`7e:00.0`-`7e:04.0`, two
FL1100 and an ASM1142 xHCI, the I210). Without `downstream-ports` the NVMe sits directly
behind the tunnel, as for the other device routers; with it, see "Chains" below. `preos-cm=on` does not configure TB3 device routers. The DROM is the
model's (names from `vendor-name`/`model-name`), not CalDigit's.

The Intel router ID `8086:15d3` on `usb4-generic` is the second maintainer exception in
AGENTS.md ("Two profiles, one fabric", 2026-10-15): opt-in (`dialect=tb3`), router config
space only, no Intel PCI ID; Linux needs the Intel vendor ID to treat the router as
generation 3 and set up its link controller and Plug Events.

### Chains: a USB4 device router behind the TB3 dock

```
-device usb4-tunnel-port,id=tp0,bus=pcie.0,addr=0x3,chassis=1
-device usb4-host,id=u4,bus=pcie.0,addr=0x4,tunnel-port2=tp0,host-model=intel-adl
-device usb4-device,id=enc0,bus=u4.0,port=2,dialect=tb3,downstream-ports=1,lc-uuid=captured
-device usb4-device,id=enc1,bus=u4.0,parent=enc0,port=1,drive=nvme0,device-model=asm2464
scripts/msys2-shell.sh "<wt>/tests/usb4/run-chain-conformance.sh <dir>"
```

Source: `tests/captures/framework13-12th/linux-ts3plus-orico` (Framework 13, the TS3 Plus
on host adapter 3 of domain 1 as router 3, the ORICO AAGM2-U4's ASM2464PD on the dock's
downstream port as router 303, depth 2). Port 2 of `intel-adl` gives the captured routes.

Fabric (profile-agnostic, unchanged by the chain): a device router's PCIe tunnel runs
from the PCIe Down adapter its parent pairs with the port it is plugged into, to its own
PCIe Up adapter; for the ASM2464 that is the dock's adapter 7. The tunnel evaluator
follows the HopID 8 paths hop by hop and needs the parent's tunnel up first. What a
software CM writes, as Linux did (dmesg 34.65 s) [obs]:

| Tunnel | Paths (HopID 8 in and out) | PCIe enable |
|---|---|---|
| 0:9 <-> 3:6 | 3:1 -> 3:6 (32 credits), 0:9 -> 0:3, 0:3 -> 0:9 (64), 3:6 -> 3:1 | 3:6 `0x39`, 0:9 |
| 3:7 <-> 303:3 | 303:1 -> 303:3 (64), 3:7 -> 3:3, 303:3 -> 303:1, 3:3 -> 3:7 (32) | 303:3 dword 9, then 3:7 `0x39` |

Before that, the CM configures the ASM2464 (route `0x303`, depth 2, ROUTER_CS_5 PTO then
CV, waiting for CR) and bonds the dock-ASM2464 link (above). The dock's PCIe adapter 7
reads `0xc6210400` with the chained tunnel up, as adapter 6 does [inf: no dword 0x39 read
of adapter 7 with that tunnel up is compared yet].

PCI side, q35 only (`usb4-tunnel-port`): when the dock's own tunnel comes up, its tunnel
slot builds the dock's PCIe switch, an XIO3130 upstream port with one downstream port
holding an `nvme` (the dock's `drive=`, none if unset) and one gated hot-plug downstream
port (`usb4-tunnel-dsp`) per downstream USB4 port, standing for PCIe Down adapter 7. The
chained tunnel inserts behind that port: the ASM2464's switch (`1b21:2463` upstream and
downstream port) and the NVMe. That is the minimum: the real dock has an Alpine Ridge
upstream port and five downstream ports (`7d:00.0`, `7e:00.0`-`7e:04.0`, the chained
device behind `7e:04.0`). Each level has its own access gate and generation-checked
bottom half; a chained tunnel going down closes the port's gate only; removing the dock
closes both gates in the same call (leaf first). `usb4_tunnel_slot_identity()` covers
the chain: the tunnel port's identity names the dock and its downstream port count
(`ndfp`), the dock port's identity the chained device, its drive and model. The q35
chain does not exercise `root-hotplug=restore`, which belongs to a root-bus
`usb4-tunnel-bridge` (i440FX): restore across a chain is not validated.

The TS3 Plus's event order when a software CM configures it with a router on its
downstream port, on initial enumeration [obs]: 9, 2, 10 (and an adapter 0 unplug, not
modelled), then the downstream lanes 3 and 4 about 90 ms later (trace lines 2264 and
2388). A later re-plug in the same capture puts 3 and 4 before 10 (line 49240). The model
implements the initial-enumeration order (9, 2, 10, then 3, 4) every time; the delay
between the events is not modelled.

**i440FX supports one tunnel-bridge level.** A dock on `usb4-tunnel-bridge` gets its own
NVMe in slot 1 and nothing else: no PCIe switch, no `usb4-tunnel-dsp`, so no chained
device behind it is reachable (the control-packet side, routes and router configuration,
still works there). Chaining a PCIe tunnel is q35-only for now.

Not modelled for chains: the Plug Events + 1 power-on value with a device on the
downstream port (`0x4c05` in this capture, `0x4e05` in `linux-ts3plus`; the model always
gives `0x4e05`, cause of bit 9 unknown), the dock's adapter 0 unplug events (four, meaning
unknown), DP OUT, suspend, and the bouncy re-plug at 112 s (both PCIe tunnels torn down
before the NVMe was enumerated).

### Results (2026-10-15)

- `tests/usb4/fabric-test.c` `test_tb3_sw` (minimal, intel-adl, amd): power-on header,
  configuration, plug events, SX_CTRL, LC UUID, the gaps, bonding and both lane 1
  unplugs, the PCIe tunnel through adapter 6, admin down and up, surprise removal, power-on
  state again with `uid`.
- `tests/qtest/usb4-tb3dev-test.c` (i440FX, `usb4-tunnel-bridge`, minimal / intel-adl /
  amd): the same steps over ring 0 of the host interface, the NVMe in slot 1 behind the
  bridge, `device_del` closing the gate; Plug Events disables (lane and DP OUT, DP OUT
  only, lane events enabled again before bonding); two default docks with distinct,
  stable link controller UUIDs, also one per host on two hosts; the ASM2464 behind the
  dock (route `0x301`).
  `fabric-test.c` covers the disables and UUIDs as well (review fixes, 2026-10-15).
- Chain (2026-10-15, QEMU branch `usb4-chain`, in main as of `36f6254`): `usb4-tb3dev-test.c` `chain-pcie` and
  `chain-pcie-dock` (q35, `intel-adl`, the dock on port 2, the ASM2464 behind it): ring 0
  enumeration of both routers, bonding of the dock-ASM2464 link (adapter 4 unplug event),
  both tunnels with the captured paths, both slot identities, the NVMe behind the
  ASM2464's switch reached through two gated levels (bus 6, BAR0 read); `device_del` of
  the ASM2464 closes the dock port's gate at once with the dock still reachable, then
  `device_del` of the dock closes the tunnel port's gate; `device_del` of the dock with the
  chain up closes both gates in the same call (stages 2-4 held to check). Suites on that
  branch: tb3dev 11/11, tunnel 29/29, asm2464 4/4, root-hotplug 17/17; `fabric-test.c`
  45,816 checks, 0 failures.
- `run-chain-conformance.sh` (domain 1, routes 0, 3 and 303, `linux-ts3plus-orico`):

  | Router | Read dwords matching | Writes with the captured outcome | Response headers | Hot plug events (captured / matched / from the model / extra) |
  |---|---|---|---|---|
  | 0 (`intel-adl`) | 68,986 of 74,364 (92.8%) | 563 of 563 | 8,499 of 8,499 | 25 / 12 / - / 0 |
  | 3 (TS3 Plus) | 89,847 of 111,453 (80.6%) | 8,110 of 8,125 | 31,229 of 31,229 | 35 / 20 / 21 / 1 |
  | 303 (ASM2464, depth 2) | 11,360 of 12,021 (94.5%) | 195 of 195 | 2,486 of 2,486 | 0 / 0 / 0 / 0 |

  Device router events are matched per router (by domain and route) in order: model
  events passed over to reach a match count as extra, and those left at a cable change,
  a host power cycle or the end count as extra too. Without the chained router attached
  the dock read 80.5%. Route 3's misses: the EEPROM data line (the model's DROM,
  795 reads), Plug Events + 1 (`0x4c05`), router dword 6, live vendor registers (`0x64`,
  `0x23d`, `0xb28`-`0xb2f`). Its unmatched writes: seven writes during suspend that the
  real dock answered with errors (before the DMA port of `usb4-win11tb3` also the eight
  DMA port mailbox writes; route 3 is 89,887 of 111,453 read dwords (80.7%), 8,118 of
  8,125 writes and 31,265 of 31,265 response headers since then, the host and route 303
  unchanged). Unmatched events: the
  adapter 0 unplugs, DP OUT 8, and the re-plug and suspend sequences, which the replay's
  host-level plug logic does not follow (the host's 13 unmatched events are those too).
  Route 303: the TMU dword at `0xc1` (live time, 58 reads). The capture holds no
  complete event record from the ASM2464. Trace line 78094 holds an event record cut off
  before its route, followed by a read request to route 303 on the same line: an event of
  unknown origin, lost.
- `run-tb3-conformance.sh` (domain 1, routes 0 and 3): host router 93.2% of 41,417 read
  dwords (USB4-defined registers 95.8%, against 93.5% with the USB4 stand-in device),
  device router 93.3% of 49,360, 17,319 of 17,319 response headers, 5,955 of 5,963 writes
  with the captured outcome (the others: the DMA port mailbox, and two writes to the state
  the previous CM instance left). With the DMA port (`usb4-win11tb3`, 2026-10-16): device
  router 93.4% (46,089 of 49,360), 17,346 of 17,346 response headers, 5,961 of 5,963
  writes (the two to the previous CM's state); host router unchanged (93.2%, 324 of 324
  writes), `run-adl-conformance.sh` unchanged (95.7%). The one remaining DMA port
  mismatch is the outbound word `0` after the re-plug at 57.3 s, which the replay does not
  follow (the model also reads `0` after a re-plug). The rest is the DROM content (the model's DROM, not
  CalDigit's: 564 EEPROM reads), live vendor registers and replay history.
- Unmodified Linux (Kubuntu 26.04.1 live, q35, `host-model=intel-adl`): "Thunderbolt 3
  Switch: 8086:15d3 (Revision: 6, TB Version: 2)", acks for 1:9, 1:2, 1:10, DROM read by
  EEPROM, "current link width symmetric, single lane", credits 60 -> 120 and 60 -> 0 and
  "link width set to symmetric, dual lanes" after bonding, "TMU: current mode:
  bi-directional, HiFi", `generation` 3, `unique_id`
  `c6030000-0090-8718-23ca-ef302242d026` as on the real dock (that run predates
  `lc-uuid`: the captured UUID was the default then; today pass `lc-uuid=captured`),
  `usb4_port1/link` `tbt`.
  The trace shows Plug Events + 1 `0x4e05 -> 0x4e01`, dword 4 `0x0200000a -> 0x020000ff`,
  SX_CTRL `0x160 -> 0x40010160` and Target Link Width written on both TB3 lanes. After
  `echo 1 > 0-1/authorized`: PCIe Down path 0:8 -> 1:6 and Up path 1:6 -> 0:8, pciehp
  Card present / Link Up, NVMe at 01:00.0, a 32 MiB O_DIRECT write read back with the
  same SHA-256. `device_del enc0`: hot unplug on 0:1, "switch unplugged", both paths
  deactivated, pciehp Link Down, `/dev/nvme0n1` gone. As with the USB4 device routers
  (LINUX-TEST.md "Remaining observation"), Linux logs one "0:1: switch unplugged" during
  boot after its host router reset and enumerates the router again within milliseconds;
  the capture shows no such step.

### Windows 11 built-in CM (2026-10-16, QEMU branch `usb4-win11tb3`: `d99e41b`, `20c8784` on `36f6254`, in main as of `2a893ea`)

Windows 11 build 26300 (`Usb4HostRouter.sys` / `Usb4DeviceRouter.sys` 10.0.26100.9278,
test-signing on, WINDOWS-DEBUG.md) on q35 with `host-model=intel-adl` failed the dock:
"Thunderbolt 3(TM) Router" `USB4\VID_8086&PID_15D3` Code 10, problem status
`0xC000009E`, no DROM name, `DeviceFirmwareVersion` 0 in the rundown, no PCIe tunnel.
Linux accepts the same router because it reads the DROM by EEPROM bit-bang and treats a
missing DMA port as "no NVM support".

What Windows does with a TB3 router, from the `usb4_*` trace and the
TraceLogging rundown of these runs (behaviour seen in emulation; requirements `inferred`, no
Windows capture of a TB3 device on a USB4 host exists):

1. Configures it like Linux (router dwords 1-4, Plug Events + 1 `0x4e01`), reads the
   headers of adapters 1-11 and router dword `0x34` (the DROM offset), then looks for a
   Host Interface adapter to use as the DMA port. It never bit-bangs the EEPROM. With adapter 5 not Host Interface typed it stopped there, retried the whole
   enumeration and gave up with Code 10 (cause 1).
2. With the DMA port: flash reads of `0x08` (NVM version), `0x210` (4 dwords), `0x220`
   (16) and `0x260` (9): the DROM at the `0x34` offset, CRC-checked. Then router dword
   `0x1bb`, the lane capabilities, path 0 of adapter 1, link controller `0x1a0` and SX_CTRL
   (`0x78010160`: also bits 28:27, which the model drops), TMU adapter dword `0x10` = 2,
   Target Link Width on both lanes (bonding, as Linux), TMU "post time" (router dwords
   `0x1b`-`0x1e`, polled at `0x1d` for 0), then flash dword `0x734`
   (DMA port request `0x21000734`).
3. `0x734` is the eGPU configuration: bit 8 means a GPU sits behind the router, and bits
   11:9, the downstream bridge the GPU is behind, must be 0-6 or Windows fails the router
   (it reports an invalid GPU downstream bridge in the NVM). Erased flash (`0xffffffff`)
   failed it: Windows cleared SX_CTRL L1C, re-enumerated and gave up with Code 10 again
   (cause 2). The model answers 0: a dock, no GPU.
4. It then sets up the PCIe tunnel (HopID 8 both ways, Path Enable on 0:9 and 1:6) and,
   repeatedly, tries DP tunnels to DP OUT 9 and 10 (writes the model ignores).

Results with the fix (Windows 11 overlay of the generic-CM image, 4 GB guest):

| Setup | Result |
|---|---|
| `intel-adl`, dock on port 1 | Router OK ("Thunderbolt 3(TM) Router, QEMU - USB4 NVMe Enclosure"), rundown `DeviceFirmwareVersion` `0x44`, lanes bonded, PCIe adapter 6 tunnelled, NVMe online, 32 MiB write / read-back SHA-256 match; `device_del` removes router and disk, `device_add` brings both back and the file reads back with the same hash |
| `minimal`, `downstream-ports=1` | Router OK, the dock's switch (`104c:8232`, two `104c:8233`) and the NVMe behind it, data intact |
| `intel-adl`, dock with the ASM2464 behind it (port 1) | Both routers OK ("USB4 Router (1.0), ASMedia - 246x"), both NVMe disks online |

Without the DMA port the router failed right after reading dword `0x34`; with the DMA port
but an erased `0x734` it failed after that read; with both it starts. Unmodified Linux
(Kubuntu 26.04.1, `intel-adl`, `lc-uuid=captured`) now also logs "1: NVM version 44.0"
and has `nvm_version` 44.0 as on the real dock, and otherwise behaves as above: generation
3, the captured `unique_id`, bonding, PCIe tunnel after authorisation, 32 MiB O_DIRECT
write / read-back hash match, `device_del` removes the disk. qtest
`usb4-tb3dev-test` `dma-port`; suites tb3dev 12/12, tunnel 29/29, asm2464 4/4,
root-hotplug 17/17, icm 27/27, icm-tr 14/14, host 23/23, harness 25/25, asm4242 8/8;
`fabric-test.c` 45,816 checks, 0 failures.

## Files

| File | Purpose |
|---|---|
| `hw/usb4/usb4-router-adl.c` | Layout, images, offset mapping, operations, retimer |
| `hw/usb4/usb4-adl-data.h` | Generated register images |
| `hw/usb4/usb4-preos.c` | Pre-OS firmware CM |
| `hw/usb4/usb4-router-asm.c` | asm4242 layout, DP IN adapters, router operations, quirks a and c |
| `hw/usb4/usb4-asm-switch.c` | ASM4242 switch port and xHCI identity types |
| `tests/qtest/usb4-asm4242-test.c` | asm4242 qtest |
| `tests/usb4/gen-adl-data.py` | Image generator |
| `tests/usb4/adl-replay.py`, `adl-conformance.c`, `run-adl-conformance.sh` | Conformance check (`--routes` for device routers) |
| `hw/usb4/usb4-router-img.c` | Captured image layer shared by `intel-adl` and `asm2464` |
| `hw/usb4/usb4-router-asm2464.c`, `usb4-asm2464-data.h` | asm2464 device router: layout, images, DROM, operations, timing |
| `tests/usb4/gen-asm2464-data.py`, `run-asm2464-conformance.sh` | asm2464 image generator and replay check |
| `tests/qtest/usb4-asm2464-test.c` | asm2464 qtest |
| `hw/usb4/usb4-router-tb3.c`, `usb4-tb3-sw-data.h` | TB3 device router, also under a software CM (§8) |
| `tests/usb4/gen-tb3-sw-data.py`, `run-tb3-conformance.sh` | Power-on overlay generator and TB3 replay check |
| `tests/qtest/usb4-tb3dev-test.c` | TB3 device router on a USB4 host, and `amd`, qtest; the chained PCIe tunnel (q35) |
| `tests/usb4/run-chain-conformance.sh` | Chain replay: host, TB3 dock, ASM2464 (`adl-replay.py --chain`) |
