# AM5 desktop USB4 (X870 / X870E / B850 with ASMedia ASM4242): public-source research

Status: research note, 2026-10-15. Part of usb4-emu, GPL-2.0-only. Written in our own
words from public sources; no Linux code, structure definitions or header text are
reproduced. Every source is listed in §10 with its URL; all were accessed 2026-10-15.

Why this exists: Windows 98 to 7 need a legacy BIOS (CSM). Most USB4 laptops have no CSM
(`XHCI98-HANDOFF.md` §2). AM5 desktop boards on the X870 and X870E chipsets must have
USB4, which they get from a discrete ASMedia ASM4242, and many AM5 firmwares still offer
CSM. That makes them the most likely real machines that combine USB4 with a legacy BIOS.
**No X870/B850 board is available to this project and none will be (maintainer,
2026-10-15).** Everything below comes from public material. Where that runs out, the doc
says so and gives a hedge instead of a capture plan.

Confidence and source tags:

- **[pub]** seen in a public hardware dump (lspci, sysfs, dmesg, boltctl, Device
  Manager) posted by a third party. It is real-hardware evidence, but we cannot check
  context, firmware version or how faithfully it was transcribed.
- **[vendor]** an ASMedia or board-vendor datasheet, manual or support page.
- **[lkml]** a Linux mailing-list patch or bug report with measurements. It is not merged
  code unless stated.
- **[code]** behaviour of the Linux driver at our pinned commit (`docs/REFERENCES.md`),
  described in our own words.
- **[press]** press, review or forum statements without a dump.
- **[inf]** our inference from the above. It is a hypothesis.
- **[unk]** no public information found.

Confidence ratings: **high** (several independent [pub]/[vendor] sources agree),
**medium** (one good source, or consistent inference), **low** (single forum claim or
inference only).

---

## 1. Short answer: the connection-manager (CM) model

- **Under Linux and Windows 11, the ASM4242 is driven by an OS software CM. Confidence
  high.** Linux binds its `thunderbolt` driver to the host interface function
  (`1b21:2425`, class `0x0C0340`) [pub L1T-VFIO, MSI bug, linux-hardware]. Linux tries
  its firmware-CM client only for a fixed list of Intel NHI device IDs, so on a non-Intel
  host it always uses the software CM [code `icm.c`, `nhi.c`]. Public users see the
  software-CM symptoms: domain security `user`, routers enumerated by Linux, and ASM4242
  quirk patches against the software CM's path set-up and teardown [pub tinygrad #86,
  lkml]. On Windows 11 the function shows up as "USB4(TM) Host Router (Microsoft)", the
  inbox CM [pub ROG forum], and ASMedia says the chip relies on the Windows 11 inbox
  driver [vendor ASMedia].
- **No public evidence of an ASM4242 firmware CM that an OS can talk to. Confidence
  medium.** ASMedia's product page lists an integrated router, xHCI, PCIe switch and DP
  retimer, but no firmware CM, ICM-style mailbox or "firmware CM mode" [vendor]. No BIOS
  manual or forum post mentions a CM-mode option on AM5. Intel's discrete Maple Ridge, by
  contrast, ships an ICM that Linux reports as "Firmware connection manager" (§6).
- **Windows 10 needs an ASMedia driver.** ASUS tells Windows 10 users to install the
  "Asmedia USB4 Host Router Driver" (`Usb4HR64.inf/.sys`, v1.0.0.0, 2023-12-12,
  WHQL-signed, matches `PCI\VEN_1B21&DEV_2425`, setup class USB) [vendor ASUS FAQ, pub
  deskmodder INF excerpt]. Windows 10 has no inbox USB4 CM, so the driver is most likely
  ASMedia's own **host-side software CM** [inf]. It could also be a thin client of an
  undocumented firmware CM, but nothing public supports that. **Confidence low-medium.**
  Either way, Windows 10 is not given a working USB4 path by firmware alone.
- **Pre-OS / CSM: unknown [unk].** We found no source that says whether X870 firmware
  runs a pre-OS CM for the ASM4242, builds PCIe tunnels for boot devices, or leaves
  anything configured at the CSM hand-off. We found no report of booting from a USB4 NVMe
  enclosure over a PCIe tunnel on AM5 either. Booting from USB4 enclosures is reported
  only in general terms and may happen through a USB3 path.

**Consequence for xhci98.** On an X870 + ASM4242 machine booted through CSM, assume no
firmware CM. A legacy OS reaches a USB4 device's PCIe or USB3 tunnels only if xhci98
brings its own **USB4 software CM** (the primary target in `XHCI98-HANDOFF.md` §2). The
Thunderbolt 3 ICM client does not apply. Non-USB4 USB devices plugged into the USB4
ports should work through the ASM4242's own xHCI with no CM ([inf] from the USB4
fallback architecture and ASUS's note that the ports run at up to 10 Gb/s with USB
10 Gb/s devices [vendor ProArt manual]).

---

## 2. ASM4242 hardware identity

### 2.1 PCI functions

All five functions are vendor `0x1b21` (ASMedia), revision `01` [pub L1T-VFIO, MSI bug].

| Function | Device ID | Class | Name (pci.ids) | Evidence | Confidence |
|---|---|---|---|---|---|
| PCIe switch upstream port | `0x2421` | `0x0604` (PCI bridge) | ASM4242 PCIe Switch Upstream Port | [pub] L1T-VFIO lspci, IOMMU group listing; [vendor] pci.ids | high |
| PCIe switch downstream ports (×4 assumed) | `0x2423` | `0x0604` | ASM4242 PCIe Switch Downstream Port | [pub] L1T-VFIO shows `19:00.0`, `19:03.0`; MSI bug path shows `16:02.0`; ASUS path shows `13:03.0` | IDs high; count medium |
| xHCI controller | `0x2426` | `0x0C0330` [inf: "USB controller" bound by `xhci_hcd`] | ASM4242 USB 3.2 xHCI Controller | [pub] MSI bug (`77:00.0`, `xhci_hcd`, own root hub `usb5`); L1T-VFIO (`7a:00.0`) | high |
| USB4 host interface ("host router") | `0x2425` | `0x0C0340` | ASM4242 USB 4 / Thunderbolt 3 Host Router | [pub] linux-hardware (class `0c-03-40`, subsystem `1b21:2425`, 891 probes); L1T-VFIO, MSI bug, boltctl syspath | high |
| ASM2464PD (device side, for reference) | `0x2463` | n/a | ASM2464PD USB4 Device Controller 40G | [vendor] pci.ids | high |

Subsystem IDs: `1b21:2425` on the host interface of the probes listed [pub
linux-hardware]. Board vendors may override them [unk].

### 2.2 Topology (three independent public dumps agree)

```
CPU root port 00:02.2 ("Raphael/Granite Ridge GPP Bridge")
 └─ USP 1b21:2421            bus N
     └─ internal bus N+1
         ├─ DSP dev 0 (2423) → PCIe tunnel, USB4 port A   (a TB4 dock's 8086:0b26 bridges appeared here)
         ├─ DSP dev 1 (2423) → PCIe tunnel, USB4 port B   [inf: not seen in a dump]
         ├─ DSP dev 2 (2423) → xHCI 1b21:2426
         └─ DSP dev 3 (2423) → host interface 1b21:2425
```

| Board | USP | DSP → xHCI | DSP → NHI | Gap reserved for tunnels | Source |
|---|---|---|---|---|---|
| ASRock X870E Taichi Lite | `18:00.0` | `19:0?.0` → `7a:00.0` | `19:03.0` → `7b:00.0` | `1a`-`79` (96 buses) | [pub] L1T-VFIO |
| MSI X870E Tomahawk WiFi | `15:00.0` | `16:02.0` → `77:00.0` | → `78:00.0` | `17`-`76` (96 buses) | [pub] MSI bug |
| ASUS AM5 board (two USB4 ports) | `12:00.0` | → `78:00.0` [inf] | `13:03.0` → `79:00.0` | `14`-`77` (about 100 buses) | [pub] scyto gist comment |

- The root port is a CPU general-purpose port on all three boards: a "GPP Bridge" at
  `00:02.2` [pub]. The ASRock Taichi block diagram also shows the ASM4242 on a
  **CPU PCIe Gen4 x4** link [vendor Taichi manual]. Confidence high.
- **Bus padding.** Firmware leaves about 96 bus numbers between the internal switch bus
  and the xHCI/NHI buses. That is about 48 per tunnel downstream port [inf from the bus
  numbers; same on ASRock, MSI and ASUS, which points to AMD reference firmware rather
  than vendor tuning]. Confidence medium. MMIO and prefetchable padding per tunnel port:
  [unk].
- **DSP device numbers 0/1 = tunnels, 2 = xHCI, 3 = NHI.** Device 0 hosting a dock, device
  2 the xHCI and device 3 the NHI are each [pub]. Device 1 as the second tunnel port is
  [inf]. Confidence medium.
- The ASM4242 functions are split across IOMMU groups: the xHCI and the NHI are in
  separate groups, and the NHI shares its group with its DSP [pub L1T-VFIO]. This implies
  ACS on the switch [inf].
- Windows shows "PCI Express Downstream Switch Port" with **Code 51** ("waiting on another
  device") on two DSPs when the USB4 stack is unhappy [press ROG forums]. These are the
  two tunnel DSPs. In Windows' USB4 model they depend on the host router through the
  ACPI `_DSD` "usb4-host-interface" link [inf from `docs/references/microsoft/`], so
  X870 firmware very probably provides those `_DSD` links. Confidence medium.

### 2.3 USB4 router (configuration space)

| Item | Value | Evidence | Confidence |
|---|---|---|---|
| Router vendor ID (ROUTER_CS_0) | `0x174c` (ASMedia's USB vendor ID, also used by ASMedia device routers) | [lkml] Fan Ye v3 patch: "hw_vendor_id 0x174c" on two ASM4242 hosts | high (one tester, two boards) |
| Router device ID | `0x2428` (differs from the PCI ID `0x2425`) | [lkml] same patch; quirk table entry keyed on `174c:2428` | high |
| NVM version | `200011.250708` and `200111.250708` reported; ASUS firmware "250708" | [lkml]; [pub] tinygrad #86; [press] station-drivers note | medium |
| USB4 version | USB4 v1 (40 Gb/s Gen3, 2 lanes per port) | [vendor] 40 Gb/s, USB-IF certified January 2024 (TID 7443), Thunderbolt 4 certified later [press] | high for 40 Gb/s; "v1 router" [inf] |
| USB4 ports | 2 DFPs (Type-C) | [vendor] | high |
| Host interface adapter | latches the path "pending" bit and never clears it after enough frames | [lkml] Fan Ye v3: teardown waits out the full timeout without a quirk | medium |
| DMA (host interface) path | E2E flow control on the Tx ring never receives credits, so Tx stalls | [lkml] net patch, tested on an MSI X870E and an X870 | medium |
| Lane adapter buffers | 174 total buffers; host interface reports a maximum of 32 (`baMaxHI` equivalent) | [lkml] credit-clamp patch | medium |
| TMU, CLx, adapter numbering, capability list, DROM | [unk] | none found | — |
| Thunderbolt 3 device compatibility | marketed and certified, but forum reports of TB3 docks or eGPUs not detected on WRX90 and ProArt X870E with some firmware | [vendor], [press L1T-WRX90] | low (depends on firmware) |

### 2.4 Other platform facts

| Item | Value | Evidence | Confidence |
|---|---|---|---|
| Upstream link | PCIe 4.0 x4, SRIS, MSI and MSI-X | [vendor] ASMedia | high |
| INTx support | [unk]; a PCIe endpoint normally offers INTx emulation | — | — |
| DisplayPort | 2 DP sink inputs (4 lanes each, DP 1.4a, HBR3), DP alt mode, internal LTTPR retimer | [vendor] | high |
| DP-in routing | Usually the CPU iGPU's DP outputs (Taichi: "DP1/DP2" from CPU; Gigabyte: "Integrated Graphics Processor + ASMedia USB4 Controller"). ASUS ProArt also has an external "DisplayPort IN" for a discrete GPU | [vendor] manuals | high |
| xHCI | USB 3.2 Gen 2x2 capable; own root hubs | [vendor], [pub] | high |
| Lane sharing | MSI X870/X870E: USB4 shares CPU Gen5 x4 with M2_2; installing M2_2 gives x2 each; forcing M2_2 to x4 disables USB4. ASUS Strix X870-A: USB4 use disables M.2_3 | [vendor] MSI manual; [press] gaming-st | high (MSI), low (ASUS) |
| Firmware updates | Separate ASM4242 firmware and PD (ITE IT8857) firmware tools from the board vendor | [vendor] ASUS FAQ; [press] station-drivers | high |
| Add-in card | ASUS "USB4 PCIe Gen4 Card" carries an ASM4242 (also on WRX90 boards and some B650E boards per linux-hardware) | [vendor] ASUS FAQ; [pub] linux-hardware | high |

---

## 3. Linux support

- **Binding.** The NHI is matched by its USB4 host-interface class, so no ASMedia ID is
  needed for probing [code `nhi.c`; pub linux-hardware "supported from 5.6"]. With native
  `_OSC` control granted (seen on an ASUS ProArt X870E, BIOS 2402: Linux had USB4 PCIe,
  USB3, DP and XDomain control [pub tinygrad #86]) the software CM is used directly.
  Without it, the firmware-CM client still declines a non-Intel ID and Linux falls back
  to the software CM [code]. So **Linux uses the software CM in both cases**. Confidence
  high.
- **Pinned commit.** The only ASMedia entries are for ASMedia *device* routers (router
  vendor `0x174c`): NVM version and date offsets and a fixed 512 KiB NVM size [code
  `nvm.c`]. Whether that NVM code also applies to the ASM4242 host router (same router
  vendor ID) is [inf]. It would matter only for NVM upgrade. There is no ASM4242 host
  quirk at the pinned commit.
- **Pending patches (2026, not merged as far as we can see)** [lkml]: skip the wait on the
  host-interface "pending" bit (`174c:2428`); stop enabling E2E flow control on the
  thunderbolt-net Tx ring; clamp initial credits to the 7-bit hop field; a fix for a
  failed-path bring-up found on an ASM4242 host-to-host link (acked by the maintainer).
  Mika Westerberg suggested a plain revert for the E2E patch instead.
- **xHCI side.** A linux-usb report from the MSI X870E Tomahawk shows the ASM4242 xHCI
  timing out when its Run/Stop bit is cleared and on suspend. A reviewer noted that the
  chip had not halted after 64 ms against the 16 ms the xHCI spec allows, and pointed to
  a long-timeout quirk [pub MSI bug, bugzilla 220936]. A second report describes Bulk-OUT
  `-EPROTO` errors with one optical drive [pub linux-usb 2026-09]. Both are relevant to
  xhci98, which drives that xHCI.
- **Reported failures.** On an ASUS ProArt X870E, a USB4 PCIe dock was not enumerated:
  only the host router was present and the port links read `none` [pub tinygrad #86].
  ASM4242 VFIO reset problems were also reported [pub L1T-VFIO].

---

## 4. AM5 boards, BIOS options and CSM

| Topic | Finding | Evidence | Confidence |
|---|---|---|---|
| USB4 requirement | Mandatory on X870E and X870, optional on B850 (e.g. MSI MPG B850 Carbon has it; ASUS TUF B850-Plus does not) | [press] Guru3D, hwcooling, gaming-st | high for X870/E, medium for B850 examples |
| Controller | ASM4242 on every X870/X870E board we found (ASRock, ASUS, Gigabyte, MSI) | [vendor] manuals; [pub] linux-hardware board list | high |
| USB4 BIOS location | ASUS: Advanced → AMD PBS → "USB4 (ASM4242 Controller)" with a "PCIe Tunneling" option (default reported as Auto on many boards), and a controller enable/disable | [press] XDA, ROG forum | medium |
| ASRock | Docs mention a "Discrete USB4 Features" item under AMD PBS, but a Taichi Lite owner could not find any USB4 option. The AMD 800-series setup guide lists no USB4 items under AMD PBS | [pub] L1T-VFIO; [vendor] ASRock 800-series guide | low |
| MSI / Gigabyte | No USB4 or tunnelling options documented in the manuals we read. MSI has a BIOS switch that trades USB4 for M2_2 x4 | [vendor] | medium |
| CM-mode option | **None found** on any vendor | — | medium (absence) |
| Hot-plug padding options | None documented for USB4. Bus padding seen only through bus numbers (§2.2) | [inf] | low |
| CSM present | ASRock 800-series: "CSM [Disabled] [Enabled]", but OpROM policies offer only "UEFI only" or "Do not launch" (no "Legacy only"). MSI X870/X870E manuals: "it still has a CSM mode". ASUS and Gigabyte: not in the manuals we read | [vendor] | medium |
| CSM together with USB4 enabled | [unk]. No source mentions a conflict or an interlock | — | — |
| CSM practicality | Legacy option ROMs are limited (ASRock's OpROM choices), and recent GPUs may lack legacy VBIOS. A CSM boot may depend on an older GPU or on the iGPU's legacy VBIOS [inf] | [vendor] ASRock | low |
| "-CSM" model suffix | ASUS PRIME X870-P WIFI-CSM is the ASUS "Corporate Stable Model" line, not a legacy-BIOS feature [ext: general product knowledge] | — | medium |

---

## 5. What firmware does for the ASM4242 before the OS

Nothing public describes this directly [unk]. The indirect evidence:

- Windows 11 with the inbox CM gets USB4 control through `_OSC`. Linux reports native
  control on an ASUS X870E [pub]. So the firmware follows Microsoft's USB4 ACPI model.
  Under that model, firmware may run a pre-OS CM and hand over, and the OS CM cleans up
  (the behaviour `preos-cm=on` reproduces, `USB4-HOSTS.md` §3).
- With "PCIe Tunneling = Auto", users report that a device which does not accept a PCIe
  tunnel is used through USB3 instead [press XDA]. That describes the OS CM's policy,
  not firmware.
- No report shows a USB4 NVMe enclosure as a pre-boot *NVMe* device on AM5. Bootable
  enclosures in forum posts may be reached as USB mass storage [press egpu.io index].
- Linux would not reset a USB4 v1 host router at probe [code `nhi.c`: reset only for
  host interface v2 and later]. Any firmware state would be inherited and torn down by
  the software CM, as with `preos-cm=on`.

---

## 6. Intel desktop boards with discrete Thunderbolt (brief)

- **Maple Ridge (JHL8540/8340, discrete TB4) has a firmware CM, and under Linux it runs
  as "Firmware connection manager" on desktops.** An ASUS ROG Strix Z790-A with a
  ThunderboltEX 4 card (NVM 43.83) showed CM type firmware, domain security `none`, and
  `iommu_dma_protection=1` [pub omarchy #14897]. Linux's own Maple Ridge commit describes
  the ICM flows as similar to Titan Ridge [lkml]. The BIOS menu (Advanced → Thunderbolt(TM)
  Configuration) offered: Discrete Thunderbolt Support, wake, Thunderbolt Boot Support,
  DTBT Go2Sx, **Windows 10 Thunderbolt Support**, and DTBT resource settings, with no
  security-level option [pub]. MSI documents enabling "Windows 10 Thunderbolt Support" for
  Windows 10 [vendor MSI FAQ]. Confidence high that the ICM runs. Whether it keeps running
  when a CSM-booted OS never calls `_OSC` is [inf]. It probably does: Linux selects the
  ICM exactly when it was *not* granted native control and the firmware reports NVM
  authentication done [code `nhi.c`, `icm.c`].
- **Implication.** With security `none`, an ICM approves devices by itself, so PCIe
  tunnels appear with no OS driver at all, as on the P14s with pre-boot support
  (`ICM-PROTOCOL.md` §12). A Maple Ridge desktop with CSM is therefore probably *easier*
  for legacy Windows than an ASM4242 board. It uses the Titan Ridge-style ICM dialect
  (`CONTROLLER-CATALOG.md` rank 6). Confidence medium.
- **Barlow Ridge (TB5) is software CM only** (`CONTROLLER-CATALOG.md`). On a CSM boot it
  is in the same position as the ASM4242. Whether Z890 boards offer CSM: [unk]. We found
  no source either way.

---

## 7. What an emulator model of an X870 + ASM4242 system needs

Each item lists its source and confidence. "Option" means a QEMU property, so that
uncertain behaviour can be switched.

| # | Model element | Value / behaviour | Source | Conf. |
|---|---|---|---|---|
| M1 | Profile | `usb4-generic` (software CM). No Intel PCI IDs (AGENTS.md). Never a firmware CM | §1 | high |
| M2 | Host preset | `host-model=asm4242`: PCI `1b21:2425` rev `01`, class `0x0C0340`, subsystem `1b21:2425`; router `174c:2428`; 2 USB4 ports; USB4 v1 (host interface version 0) | §2.1, §2.3 | high (IDs), medium (v1) |
| M3 | PCIe switch wrapper | USP `1b21:2421` rev 01 above 4 DSPs `1b21:2423` rev 01 at devices 0-3. Devices 0/1 are the tunnel ports (hot-plug capable), device 2 the xHCI, device 3 the NHI. On q35 this is a PCIe switch under a root port. On i440FX it is an option (see H6) | §2.2 | high (IDs), medium (layout) |
| M4 | Integrated xHCI | QEMU `qemu-xhci` behind DSP 2 with ID override `1b21:2426` rev 01, class `0x0C0330`. USB3 tunnels end on its root ports (as the generic model already does) | §2.1 | high (ID); port count [unk] |
| M5 | Bus padding | Firmware (or the test harness) reserves about 48 secondary buses per tunnel DSP. MMIO and prefetch padding configurable (default e.g. 32 MiB MMIO; legacy guests need it below 4 GiB) | §2.2 | medium (bus), [unk] (MMIO) |
| M6 | Router vendor quirks (options, default on for the preset) | (a) host-interface path pending bit sticks after N frames; (b) Tx-ring E2E credits never arrive; (c) host interface max buffers 32, lane adapters 174 | §2.3 | medium |
| M7 | xHCI quirk (option) | slow halt after Run/Stop cleared (> 64 ms) | §3 | medium |
| M8 | Interrupts | MSI and MSI-X advertised, INTx kept for legacy guests (polling must work, AGENTS.md); USB4 spec interrupt clearing (non-Intel rules, already in `usb4-generic`) | §2.4 | high (MSI/X), INTx [unk] |
| M9 | Pre-OS behaviour | `preos-cm=off` default (no evidence firmware builds tunnels); `preos-cm=on` as the alternative to test | §5 | low |
| M10 | ACPI | `_OSC` USB4 support, `_DSD` "usb4-host-interface" on the two tunnel DSPs, ExternalFacingPort, consistent with Code 51 dependency behaviour | §2.2, §5 | medium |
| M11 | DP | DP IN adapters present in the router (2 sinks) with no DP source in QEMU; DP tunnels not modelled beyond capability presence | §2.4 | medium |
| M12 | Security | no TB security levels; Linux shows `user` (software CM) | §1 | high |

What is not modelled and does not need to be: ASM2464 or other device-side ASMedia
routers (a separate preset, `CONTROLLER-CATALOG.md` rank 3), PD controller firmware, and
NVM upgrade.

---

## 8. What stays uncertain without hardware, and how to hedge it

| Unknown | Why it matters | Model hedge | What the xhci98 CM must tolerate |
|---|---|---|---|
| Whether X870 firmware runs a pre-OS CM, and what it leaves at the CSM hand-off | A legacy OS inherits that state | `preos-cm=off` default, `preos-cm=on` tested too | Router already enumerated, paths enabled, lanes bonded; or nothing at all. Clean up as Windows does or adopt, but never assume a cold router |
| Whether a hidden ASM4242 firmware CM exists (e.g. used by the Windows 10 driver) | Would offer a second path for legacy OSes | Do not model one. Our evidence says the host is software-CM only | Detect nothing ICM-like on a non-Intel ID; go straight to the software CM |
| Router capability details (adapter numbers, TMU, CLx, vendor capabilities, DROM, router operations supported) | A CM that hard-codes them breaks on the real chip | Preset adapter numbering configurable; router operations may return "not supported" | Discover adapters from capability chains; handle "not supported" for every router operation; poll with timeouts (`XHCI98-HANDOFF.md` §2 already says this) |
| DSP layout (is device 1 really the second tunnel port?) | PCI topology the legacy OS sees | Topology option; default 0/1 = tunnels | Find tunnel ports through the PCIe Downstream Entry Mapping router operation or the `_DSD` link, not by device number |
| MMIO/prefetch padding per tunnel DSP under CSM, and whether BARs stay below 4 GiB | Win9x/2000 can use only 32-bit addresses; an endpoint may not fit | Padding sizes as options; a test with zero padding (forces OS re-allocation) | Handle an endpoint whose BAR is unassigned or does not fit; report it instead of crashing |
| INTx support on the ASM4242 functions | Legacy guests without MSI | Keep INTx and a "no-INTx" option | Work by polling alone |
| xHCI root-port count and USB2/USB3 port pairing | Which xHCI ports carry USB3 tunnels | Option; default 2 USB3 + 2 USB2 | Map USB3 tunnels by the router's USB3 adapter number, not by port number |
| Vendor quirks M6/M7 | Hang or long timeouts | On by default for the preset | Bounded waits on the pending bit; no E2E flow control on DMA rings; clamp credits; long xHCI halt timeout |
| Whether CSM can be enabled while the ASM4242 is enabled, per board | Is the machine a legacy target at all | n/a | n/a: a question for whoever owns such a board |
| TB3 device behaviour behind the ASM4242 | Firmware-dependent, reported broken on some versions | Test the generic TB3-device path only | Treat TB3 devices as optional |

Tools: if someone ever runs `tools/p14s-capture` on such a board, the Linux script
already finds the NHI by class `0x0C0340` and dumps the whole root-port subtree (switch,
xHCI, tunnels). Its Intel-only ID list and the Intel mailbox/firmware-status offsets in
`nhi_mmio_dump.py` (`0x39900`-`0x39944`) do not apply and should be skipped for vendor
`0x1b21` [inf from reading the scripts]. The Windows 11 script's Thunderbolt pattern
would need `VEN_1B21` added. No change is proposed now, because no hardware will be
available.

---

## 9. Recommendation

1. **Keep the xhci98 priority as it is: a USB4 software CM first.** On X870 + ASM4242 it
   is the only route to USB4 devices for a legacy OS. Public evidence shows no firmware
   CM. Plain USB devices on the USB4 ports need only xhci98's xHCI driver.
2. **An `asm4242` host preset is worth adding to `usb4-generic` as a low-cost
   identity-and-quirks preset** (M2-M8, M12), about 2-3 days. It must stay clearly labelled
   "public-source, uncaptured". It must not claim register-level fidelity like
   `intel-adl`, because no config-space image exists. Ship M9 and M10 as options. Rank it
   with the AMD host (`CONTROLLER-CATALOG.md` rank 4) because both are non-Intel
   software-CM hosts, and update the catalogue when the preset lands.
   **Done 2026-10-15** as `host-model=asm4242` ([USB4-HOSTS.md](../USB4-HOSTS.md) §5):
   M1-M6, M8-M12 as described there, M7 (xHCI halt quirk) not modelled.
3. **Write the xhci98 CM to the hedges in §8.** They cost little and protect against every
   unknown above.
4. **Maple Ridge desktop boards with CSM look like the friendlier legacy target** (ICM, no
   driver needed with security `none`). They are worth noting for the maintainer, but
   modelling them still waits on Titan Ridge / Maple Ridge ICM work (catalogue ranks 5
   and 6).
5. Re-check public sources for an ASM4242 `lspci -xxx` / tbtools register dump now and
   then. Several Linux developers own ASM4242 hosts (§3). Such a dump would raise M2-M6
   to "observed" without the project needing hardware.

---

## 10. Sources (all accessed 2026-10-15)

Vendor and datasheets:
- ASMedia ASM4242 product page: https://www.asmedia.com.tw/product/e20zx49yU0SZBUH5/363Zx80yu6sY3XH2.html
- PCI ID repository, vendor 1b21: https://admin.pci-ids.ucw.cz/read/PC/1b21
- ASUS FAQ "ASMedia ASM4242 USB4 Driver Update": https://www.asus.com/support/FAQ/1051472
- ASUS ProArt X870E-Creator WiFi manual (E23930): https://dlcdnets.asus.com/pub/ASUS/mb/SocketAM5/ProArt_X870E-CREATOR_WIFI/E23930_ProArt_X870E-CREATOR_WIFI_EM_WEB.pdf
- ASRock X870E Taichi manual (block diagram): https://download.asrock.com/Manual/X870E%20Taichi.pdf
- ASRock AMD 800 Series Software/BIOS Setup Guide 1.1: https://download.asrock.com/Manual/Software/AMD%20X870/Software_BIOS%20Setup%20Guide_English.pdf
- MSI MAG X870E Tomahawk WiFi user guide: https://download-2.msi.com/archive/mnu_exe/mb/MAGX870ETOMAHAWKWIFI_English.pdf
- MSI MAG X870 Tomahawk WiFi user guide: https://download-2.msi.com/archive/mnu_exe/mb/MAGX870TOMAHAWKWIFI_English.pdf
- Gigabyte X870 Gaming X WiFi7 manual: https://download.gigabyte.com/FileList/Manual/mb_manual_x870-gaming-x-wifi7_1001_240828_e.pdf
- MSI FAQ "How to enable Thunderbolt function in BIOS": https://us.msi.com/faq/3358
- Microsoft USB4 ACPI requirements: https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-acpi-requirements

Public hardware dumps and bug reports:
- Level1Techs, "VFIO - ASM4242 USB4 Thunderbolt controller" (ASRock X870E Taichi Lite lspci, IOMMU groups, boltd path): https://forum.level1techs.com/t/vfio-asm4242-usb4-thunderbolt-controller-igpu-passthrough/228541
- linux-usb / kernel bugzilla 220936, ASM4242 xHCI on MSI X870E Tomahawk WiFi: https://ratatoskr.run/linux-usb/2026/01/8892625/t
- linux-usb, ASM4242 Bulk-OUT -EPROTO report: https://ratatoskr.run/linux-usb/2026/09/17515220/t
- linux-hardware.org, 1b21:2425 device page (class, probes, boards): https://linux-hardware.org/?id=pci:1b21-2425-1b21-2425
- scyto "Thunderbolt Networking Setup" gist, ASM4242 boltctl comment: https://gist.github.com/scyto/67fdc9a517faefa68f730f82d7fa3570?permalink_comment_id=5281892
- tinygrad asm2464pd-firmware issue #86 (ASUS ProArt X870E, NVM, `_OSC` grant): https://github.com/tinygrad/asm2464pd-firmware/issues/86
- omarchy issue #14897 (Z790 + ThunderboltEX 4, firmware CM): https://github.com/omacom/omarchy/issues/14897
- deskmodder.de, "Funktioniert USB4 unter Windows 10?" (Usb4HR64.inf excerpt): https://deskmodder.de/phpBB3/viewtopic.php?p=450121
- Microsoft Q&A, ASM4242 USB4 malfunction (Device Manager names, MSI X870E): https://learn.microsoft.com/en-us/answers/questions/5873414/usb4-thunderbolt-malfunction-after-windows-11-upda

Linux mailing-list patches:
- Fan Ye, "[PATCH v3] thunderbolt: Stop waiting on a path pending bit that never clears": https://ratatoskr.run/b4-sent/2026/08/17401615
- "[PATCH v2] thunderbolt: Clamp DMA tunnel ..." (credits): https://ratatoskr.run/b4-sent/2026/08/17391298
- "[PATCH net] net: thunderbolt: do not enable ..." (Tx E2E; Westerberg reply): https://ratatoskr.run/netdev/2026/07/17307339/t
- "[PATCH 5.10 01/52] thunderbolt: Add support for Intel Maple Ridge": https://lkml.rescloud.iu.edu/2210.0/01106.html

Press, forums, drivers:
- XDA, "USB4 promises 40Gbps speeds, but one BIOS toggle ...": https://www.xda-developers.com/usb4-pcie-tunneling-bios-setting/
- ROG forum, Strix X870-I PCIe tunnelling fails, Code 51: https://rog-forum.asus.com/t5/amd-800-series/rog-strix-x870-i-usb4-asm4242-pcie-tunneling-fails-host-pcie/td-p/1152782 (403 to our fetcher; search snippet only)
- ROG forum, X870E-E downstream switch port Code 51: https://rog-forum.asus.com/t5/amd-800-series/x870e-e-pci-express-downstream-switch-port-code-51/td-p/1077394 (search snippet only)
- Level1Techs, ASUS WRX90 ASM4242 and Thunderbolt 3: https://forum.level1techs.com/t/enabling-asus-wrx90-asm4242-to-work-with-thunderbolt3/225566
- ASRock forum, "Thunderbolt 4 / USB4 questions": https://forum.asrock.com/forum_posts.asp?TID=34416
- Station-Drivers, ASM4242 driver 1.0.0.0: https://www.station-drivers.com/index.php/en/component/remository/Drivers/Asmedia/ASM-1x4x-2x4x-314x2-3242-4242--...--and--107x-2074-USB-3.x--and--USB-4.x-Controllers/Drivers/Asmedia-ASM4242-USB-4.x-Controller-Drivers-Version-1.0.0.0000/lang,en-gb/
- Storage Newsletter, ASM4242 USB-IF certification: https://www.storagenewsletter.com/2024/02/05/asmedia-usb4-host-controller-asm4242-passed-usb-if-certification
- Guru3D, ASM4242 Thunderbolt 4 certification: https://www.guru3d.com/story/asmedia-asm4242-usb4-host-controller-chip-reaches-thunderbolt-4-certification/
- Guru3D, X870E chipset overview: https://www.guru3d.com/review/colorful-igame-x870e-vulcan-w-oc-v14-review/page-2/
- hwcooling, X870/X870E/B850/B840 differences: https://hwcooling.net/en/x870-x870e-b850-and-b840-boards-for-amd-differences-and-release-dates
- gaming-st.com, AM5 USB4 guide (lane sharing, B850 examples): https://gaming-st.com/pcparts/am5-motherboard-usb4-guide/
- Intel patent US11513808 (FW/SW CM switching; legacy OS needs FW CM; Intel, not ASMedia): https://patents.google.com/patent/US11513808

Local references: `docs/references/linux-thunderbolt/drivers_thunderbolt/{nhi.c,icm.c,nvm.c}`
at the pinned commit; `tools/p14s-capture/`.
