# Platform matrix

One page for "what does a legacy-OS driver face on real Thunderbolt 3 and USB4 machines,
and how does this model reproduce it". Each cell links to the document that holds the
evidence. `observed` means seen on real hardware in `tests/captures/`; `inferred` means
expected but not captured.

## 1. The two kinds of host

| | Thunderbolt 3, firmware CM | USB4, software CM |
|---|---|---|
| Real machine captured | ThinkPad P14s Gen 1, Intel JHL6240 Alpine Ridge LP (NHI 8086:15bf) | Framework 13 12th gen, Intel Alder Lake-P integrated USB4 (two domains, NHI 8086:463e / 466d) |
| Who builds tunnels | Controller firmware (ICM). The OS driver approves devices over ring 0 | The OS connection manager (USB4 Spec 2.0, CM Guide 2.0) |
| What an OS driver must implement | ICM client: mailbox, driver-ready, approve, PCI rescan | Full CM: enumeration, router operations, lane bonding, TMU, paths, PCIe/USB3 tunnels, hot-plug |
| PCI class of the NHI | 0x088000 (observed; Intel's Windows INF matches on it) | 0x0C0340 |
| Interrupts on the NHI | INTA# (IRQ 11 under CSM), MSI 1 vector, MSI-X 16 vectors (observed) | MSI/MSI-X; INTx per implementation (check the capture) |
| Model profile | `profile=tb3-alpine-ridge` (+ `TOPOLOGY=switch`); Titan Ridge: `profile=tb3-titan-ridge` (inferred, §1a) | `profile=usb4-generic`, `host-model=minimal` (default), `intel-adl`, or `asm4242` (public sources only, §1b) |
| Model conformance | ICM wire contract and register values from the capture ([ICM-PROTOCOL.md](ICM-PROTOCOL.md) R1-R33) | 95.6% of 82,107 captured host-router read dwords replayed identically ([USB4-HOSTS.md](USB4-HOSTS.md) §2) |
| Proven guests | Linux firmware-CM client (M2) | Windows 11 built-in CM, Linux software CM (M4/M5), `tools/usb4cm` DOS reference CM |

### 1a. Titan Ridge (Thunderbolt 3, firmware CM, not captured)

| | Alpine Ridge LP (captured) | Titan Ridge 4C / 2C (inferred) |
|---|---|---|
| Typical machines | ThinkPad P14s Gen 1 and other 2016-2019 TB3 laptops | most 2018-2020 TB3 laptops and desktops (JHL7540 two ports, JHL7340 one port) |
| NHI / router IDs | `15bf` / `15c0` | `15eb` / `15ea`, 2C `15e8` / `15e7` |
| ICM messages an xhci98 client sends | allow-all (mailbox), driver ready, get route, approve (UUID, key, id), boot ACL | allow-all (mailbox), driver ready (4-word answer), approve (UUID, route, id), boot ACL; no get route |
| Device events | link and depth, connection key | route string, no key |
| Force power | platform ACPI WMI (captured on the P14s) | expected the same (platform ACPI), not captured |
| Model | `profile=tb3-alpine-ridge` | `profile=tb3-titan-ridge` (`ports=1` for 2C); `PROFILE=tb3-titan-ridge` with `run-linux.sh`, `run-win98.sh` (`BIOS=` too) and `run-cm-test.sh` |
| Evidence | [ICM-PROTOCOL.md](ICM-PROTOCOL.md) R1-R31, captures | [ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md) T1-T12, Linux client only; Linux binds and tunnels both ports in emulation |

The BIOS knobs of §2 (`BIOS=<Assist>_<Pre-boot>`, `DEVICE_AT_BOOT`, security level, boot
ACL) apply to both variants in the model; whether real Titan Ridge firmware behaves the
same is not captured.

### 1b. AM5 desktop USB4 (ASMedia ASM4242, not captured, public sources only)

| | Intel Alder Lake-P (captured) | ASMedia ASM4242 on AM5 X870 / X870E (public sources) |
|---|---|---|
| Why it matters | reference for the software-CM model; the Framework has no CSM | the likeliest real USB4 machine that also offers CSM (MSI and ASRock manuals) [vendor] |
| PCI | integrated NHI `8086:463e` / `466d` | switch `1b21:2421` above four `1b21:2423` ports: tunnels at 0/1 ([pub]/[inf]), xHCI `1b21:2426` at 2, NHI `1b21:2425` (class `0C0340`) at 3 [pub] |
| Router | `8087:463e`, captured images | `174c:2428`, USB4 v1, two ports [lkml][vendor]; adapter numbers, TMU, DROM [unk] |
| CM a legacy OS faces | software CM (no CSM on the machine) | software CM; no public sign of a firmware CM or of pre-OS tunnels [inf] |
| Vendor quirks | none modelled | HI path Pending never clears, Tx E2E credits never arrive, 174 lane buffers / baMaxHI 32 [lkml] |
| Model | `host-model=intel-adl` | `host-model=asm4242` (`HOST_MODEL=asm4242` with `run-linux.sh`, q35 switch or flat topology; i440FX stand-in with SHPC tunnel bridges) |
| Evidence | Framework capture, 95.6% replay match | [research/AM5-USB4.md](research/AM5-USB4.md); Linux binds it, enumerates both device routers, shows NVM `200011.250708` and tunnels NVMe in emulation ([USB4-HOSTS.md](USB4-HOSTS.md) §5). Not checked against hardware |

Most real USB4 hosts (all AMD, and Intel when the OS takes native control) need a
software CM. A legacy OS never calls `_OSC`, so whether a given USB4 platform then runs a
firmware CM for it is per-platform and not captured (inferred, see §4).

## 2. P14s BIOS settings (Thunderbolt 3, observed under Windows 98 SE / DOS)

Assist = "Thunderbolt BIOS Assist Mode", Pre-boot = "Support in Pre Boot Environment",
device = TS3 Plus dock attached at power-on. Source:
[tests/captures/p14s-gen1/README.md](../tests/captures/p14s-gen1/README.md).

| Assist | Pre-boot | Device at boot | Switch + NHI | TB xHCI 15c1 | Device's PCIe tree | What a Win98 driver must do |
|---|---|---|---|---|---|---|
| off | off | yes | present | present | absent | ICM client: approve, then rescan |
| off | on | yes | present | present | **present** | Nothing for the boot device (device driver only); ICM client for hot-plug |
| on | off | yes | present | absent | absent | ICM client |
| on | on | yes | present | absent | **present** | Nothing for the boot device; ICM client for hot-plug |
| on | on / off | no | **absent** | absent | absent | Force power (ACPI WMI `\_SB.WTBT` "TF", [ICM-PROTOCOL.md](ICM-PROTOCOL.md) §11.2), rescan, then ICM client |
| off | on / off | no | present | present | absent | ICM client |

Other observed facts: pre-OS the NHI has memory decode only, MSI/MSI-X off, INTx on IRQ
11; with Assist on the platform keeps PCIe hot-plug (no native hot-plug for the OS) and
the controller powers down after the last device leaves: within 35 s with the dock,
about 11 s with the ORICO (Linux runs).

With a **USB4 device** (ORICO AAGM2-U4, ASMedia ASM2464PD, 2026-10-15) instead of the
dock, observed under Windows 98 and Linux
([captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md)):

| Assist | Pre-boot | Switch + NHI | TB xHCI 15c1 | Device | What a Win98 driver must do |
|---|---|---|---|---|---|
| off | off | present | present | **USB 3.2 disk on the TB xHCI** at boot (observed; that it fell back during POST is inferred) | xHCI driver for the disk; or an ICM client that approves it after a replug, within about 9 s |
| off | on | present | present | NVMe tunnelled, configured by the BIOS | nothing for the boot device |
| on | off | switch present, **NHI hidden** | present but **without resources** | unusable | nothing works without assigning the xHCI's resources (or an ACPI rescan) |
| on | on | present | absent | NVMe tunnelled (1 lane) | nothing for the boot device |

The pre-boot rows tunnelled the ORICO although it was not in the boot ACL. The
Windows 98 `$PIR` lists 00:1c and the tunnel port in every run, so a tunnel brought up
later by a driver gets an IRQ (link 61, IRQ 10) on the real machine.

Model: `BIOS=<Assist>_<Pre-boot>` and `DEVICE_AT_BOOT=0|1` on `scripts/run-win98.sh` and
`scripts/run-linux.sh` reproduce all eight dock states; verified in Windows 98
([WIN98-TEST.md](WIN98-TEST.md), "P14s BIOS matrix"). With `DEVICE_MODEL=asm2464` they
reproduce the four ORICO states (QEMU branch `usb4-p14s`, 2026-10-15, R33, in main as of `b5936c4`): verified
with unmodified Linux against the captures, one line per cell, in
[ICM-PROTOCOL.md](ICM-PROTOCOL.md) §13.7 (USB disk on the TB xHCI before the OS and 9.35
s fallback after a replug; pre-boot tunnel with `boot` 1 and boltd's approve on
replug; NHI hidden and `xhci_hcd ... fail, -16`; 1 lane and the 2.8 s first
driver-ready). Stand-ins: the USB side is QEMU's `usb-uas` with the captured USB and
SCSI identity on every machine type (in main as of QEMU `36f6254`; before
it a Bulk-Only `usb-storage`; xhci98's `xhciuas.sys` is the Windows 98 to 7 driver for
it, and `usb-fallback=bot` keeps Bulk-Only for guests without a UAS driver), at 5 Gb/s
instead of the captured 10 Gb/s, and "without resources" means the xHCI shows no BAR.
Under Windows 98 (2026-10-16, QEMU `usb4-posthang`, in main as of `2a893ea`), only boot and disk use were run, for OFF_ON and OFF_OFF ([WIN98-TEST.md](WIN98-TEST.md), "SMM hang at the boot logo"). The cells were not compared with the captures.
Pre-boot now tunnels every attached device, as observed (`preboot-acl-only=on` for the
old model). The ACPI hot-plug notification used with Assist on (a bus check to the root
port) is modelled in main as of QEMU `25fd4eb` (`root-hotplug=acpi` on the root bridge,
[ARCHITECTURE.md](ARCHITECTURE.md) §4.4a); without it a guest must rescan.

**The controller leaving under a running OS.** Observed (R32): after the last device
leaves with Assist on, the controller reads all-ones at about 11 s and is removed at
about 15 s, and it does not come back on replug. A surprise removal of the tree is the
same without the delay. Here is what a legacy OS on the emulator sees, by
`root-hotplug` (in main as of QEMU `25fd4eb`, [WIN98-TEST.md](WIN98-TEST.md) "The controller
tree leaving"):

| Guest | `acpi` | `restore` | `none` (default) |
|---|---|---|---|
| Windows 98 SE, APM mode (the xhci98 image) | no effect (no ACPI driver) | the tree comes back with its configuration; devnodes unchanged | the tree comes back unconfigured; devnodes stale |
| Windows 98 SE, ACPI mode | devnodes removed and re-added automatically | as in APM mode | as in APM mode |
| Windows 2000, `acpi=off` (the xhci98 launch line) | no effect. A rescan removes the tree ("Unsafe Removal"); after the return, a rescan cannot configure the bridges | a rescan removes the tree; a rescan after the return brings it back configured | as `acpi` |
| Linux (`acpiphp`) | removed and re-added automatically | rescan needed | rescan needed |

In every mode the controller's registers and config space read all-ones from the moment
it leaves. That is the removal signal a driver must handle.

## 3. USB4 platform states (software CM)

| Situation | Real-world source | Model |
|---|---|---|
| OS gets native control, nothing pre-configured | Framework capture (Linux SW CM, `_OSC` granted) | default |
| Firmware ran a CM before the OS and left tunnels up | Common on USB4 BIOSes; Windows documents a "host router config space cleanup" | `preos-cm=on`; Windows and Linux both tear down and rebuild ([USB4-HOSTS.md](USB4-HOSTS.md) §3) |
| On-board retimers on the port | Framework capture (8087:15ee) | `host-model=intel-adl` answers sideband enumeration |
| Two domains per host | Alder Lake (TDM0/TDM1) | one `usb4-host` per domain, `host-domain=0|1` |
| TB3 device on a USB4 host | Framework capture with the TS3 Plus | `usb4-device dialect=tb3` on `usb4-generic` (any host model; branch `usb4-tb3dev`, in main as of `b5936c4`): power-on state and software-CM behaviour of the dock, 93.3% replay match ([USB4-HOSTS.md](USB4-HOSTS.md) §8) |
| Discrete USB4 host behind its own PCIe switch, vendor quirks | AM5 ASM4242 public dumps and Linux patches (not captured) | `host-model=asm4242`, `TOPOLOGY=switch`, quirk options ([USB4-HOSTS.md](USB4-HOSTS.md) §5) |
| A USB4 device router behind a Thunderbolt 3 firmware CM | P14s capture with the ORICO (2026-10-15): announced with its own flags, UUID order and name block, approved like a TB3 device, falls back to USB 9.4 s after an announcement without approval | `tb3-alpine-ridge` with `usb4-device dialect=usb4,device-model=asm2464` and `xhci=<TB xHCI>` (branch `usb4-p14s`, in main as of `b5936c4`): captured event form, router operations forwarded, USB fallback to a USB disk on the TB xHCI (UAS with the captured identity, `usb-fallback=bot` for Bulk-Only, in main as of `36f6254`), Assist function visibility; ASM2464 PCIe link registers as captured (in main as of `36f6254`); Linux matches the four captured cells ([ICM-PROTOCOL.md](ICM-PROTOCOL.md) R33, §13.7) |
| A real USB4 device router (NVMe enclosure) | Framework capture with the ORICO AAGM2-U4, ASMedia ASM2464PD (2026-10-15) | `usb4-device device-model=asm2464`: captured identity, DROM, layout, quirks, its PCIe switch on q35; 97.1% replay match ([captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md)) |
| Firmware CM tunnel at boot, OS resets it | Framework capture with the ORICO: firmware enumerated the host router with a 254 ms notification timeout and tunnelled the NVMe; Linux's "0: resetting" dropped it, the enclosure came back after about 0.6 s and was re-tunnelled after authorisation | `preos-cm=on`; asm2464 reconnects 590 ms after a Downstream Port Reset |

## 4. Not captured yet

- A USB4 machine booting a legacy OS through CSM: whether its firmware runs a CM (and
  which message set) when `_OSC` is never called. The Framework has no CSM; AM5 X870
  boards with the ASM4242 have CSM but none is available, so `asm4242` is public-source
  only.
- A USB4 device router with a USB3 tunnel, CL states or an accessible NVM (the ORICO's
  ASM2464 disables its USB3 adapter in the DROM, supports no CL state and refuses NVM
  Sector Size). (A USB4 device behind the P14s's Thunderbolt 3 firmware CM was captured
  on 2026-10-15.)
- Which ICM commands Intel's Windows driver sends (its ETW is not decodable).

## 5. Which doc to read

| Need | Document |
|---|---|
| ICM wire contract, registers, ACPI, BIOS effects | [ICM-PROTOCOL.md](ICM-PROTOCOL.md) |
| Titan Ridge dialect and layout (inferred) | [ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md) |
| Real USB4 host presets (Alder Lake, ASM4242) and conformance | [USB4-HOSTS.md](USB4-HOSTS.md) |
| Real USB4 device router (ORICO / ASM2464): capture analysis and preset | [captures/ORICO-ASM2464.md](captures/ORICO-ASM2464.md) |
| The same enclosure on the P14s (Alpine Ridge ICM), BIOS matrix, Windows 98 `$PIR` | [captures/P14S-ORICO-2026-10-15.md](captures/P14S-ORICO-2026-10-15.md) |
| What the Windows 11 CM required | [WINDOWS-DEBUG.md](WINDOWS-DEBUG.md) |
| Windows 98 test bed and results | [WIN98-TEST.md](WIN98-TEST.md) |
| Linux test bed | [LINUX-TEST.md](LINUX-TEST.md) |
| Tunnel bridges, docks, chains, forcing tunnels | [USAGE-tunnel.md](USAGE-tunnel.md) |
| Polling reference CM in C89 | [../tools/usb4cm/README.md](../tools/usb4cm/README.md) |
