# Ice Lake firmware connection manager: host contract (inferred)

Status: first draft, 2026-10-22. Licence: GPL-2.0-only, like the rest of this
repository. Companion to `ICM-PROTOCOL.md` (Alpine Ridge, captured) and
`ICM-TITAN-RIDGE.md` (Titan Ridge, inferred). It describes `profile=tb3-ice-lake`: an
Intel Ice Lake integrated Thunderbolt 3 host under its firmware CM, the third variant
of the TB3 firmware-CM profile.

**Nothing in this document is captured.** There is no Ice Lake machine in
`tests/captures/`. It follows the Titan Ridge pattern: everything comes from the
Linux ICM client at the commit pinned in `docs/REFERENCES.md`. Tags:

- **[inf]** what the Linux client expects or does (`icm.c` `icm_icl_*` and the
  `icm_probe` Ice Lake case, `pci.c` `icl_nhi_ops`, `nhi_regs.h` "ICL NHI VSEC
  registers", `nhi.h`, `switch.c`, `tb_msgs.h`). A hypothesis until a capture
  confirms it.
- **[ext]** public product data outside the pinned references.
- **[emu]** an emulator choice where neither Linux nor a capture fixes a value.
- **[shared]** behaviour taken over unchanged from the Alpine Ridge or Titan Ridge
  contract.

No Linux code was copied: the model implements register offsets and message layouts
the Linux client uses, so `NOTICE` lists no adapted file.

## 1. Identity

| Item | Value | Tag |
|---|---|---|
| NHI PCI ID | `8086:8a17` (NHI0, default); `8086:8a0d` (NHI1, `host-domain=1`) | [inf] `nhi.h` `PCI_DEVICE_ID_INTEL_ICL_NHI0/1`, `pci.c` table, `icm_probe` |
| Host router ID, ROUTER_CS_0 | the NHI ID (`8086:8a17` / `8086:8a0d`) | [inf] `switch.c` `tb_switch_get_generation` lists the ICL NHI IDs as router IDs of generation 3 |
| Revision | 3 | [ext] public lspci listings of Ice Lake laptops, not checked here; Linux ignores it |
| Class | `0x088000` | [ext] as above (pre-USB4 class); Linux binds by ID [inf] |
| Subsystem | `17aa:22b0` (shared TB3 profile value) | [emu] |
| BAR0 / BAR1 MSI-X / MSI / INTx, 12 rings | as Alpine Ridge LP | [shared] [emu] |
| PCIe capability (q35) | at `0x40`, below the vendor registers of section 2 | [emu] |
| Ports | two Thunderbolt ports, tunnel targets `tunnel-port` and `tunnel-port2` | [emu] |

The PCI topology is integrated: the NHI and the two tunnel root ports
(`usb4-tunnel-port`) sit on `pcie.0`. There is no PCIe switch and no Thunderbolt xHCI
function in the model.

## 2. NHI vendor-specific PCI config registers (ICL1-ICL2)

Linux reaches the Ice Lake firmware through fixed offsets in the NHI's own config
space [inf] (`nhi_regs.h`, `pci.c`):

| Offset | Name | Model |
|---|---|---|
| `0xc8` | VS_CAP_9, bit 31 firmware ready | reads 1 while Force Power is set, else 0 [emu: the model's firmware is always running] |
| `0xcc`, `0xd0` | VS_CAP_10, VS_CAP_11, host UUID | the first two dwords of the host UUID (`uuid=` property), the same dwords the host router's link controller reports at router dwords `0x102`-`0x103`; Linux builds the root switch UUID from them plus two all-ones dwords (`icm_icl_set_uuid`) [inf] [emu value] |
| `0xe0` | VS_CAP_15, LTR | guest-writable; Linux copies the maximum into both halves [inf] |
| `0xe4` | VS_CAP_16, maximum LTR (15:0) | `0x0846` read-only [emu] |
| `0xec` | VS_CAP_18, LC mailbox done (bit 0) | set while VS_CAP_19 Valid is set [emu: every command completes at once] |
| `0xf0` | VS_CAP_19, LC mailbox command (7:1) and Valid (0) | guest-writable; commands `0x02` Go2Sx, `0x03` Go2Sx no wake, `0x21` prepare for reset [inf] have no effect on the fabric [emu] |
| `0xfc` | VS_CAP_22, Force Power (bit 1), DMA delay (31:24) | guest-writable; reset 0 [emu] |

All other bytes `0xc8`-`0xff` are read-only. Linux forces power at probe, resume and
runtime resume and waits up to 350 x 3 ms for firmware ready, or the bind fails [inf].
The ICM itself answers whether or not Force Power is set [emu]; real firmware may not
be loaded until it is (Linux comment in `icl_nhi_force_power`).

## 3. Message set (ICL3-ICL5)

The Linux Ice Lake client (`icm_icl_ops`) is the Titan Ridge client with less in it
[inf]:

- **Firmware usable**: `icm_fr_is_supported`, true on non-Apple machines. No
  operating-mode check, no allow-all mailbox (`0x23`), no firmware restart, no
  physical-port reset [inf]. The firmware status and outbound mailbox keep the shared
  values [shared].
- **3.1 Driver ready (0x03)**: one-word request; the response is the Titan Ridge
  four-word layout (`icm_tr_pkg_driver_ready_response`) with a 20 s timeout. Linux
  reads only the protocol version; it does not take the security level or the ACL
  count from it and always enables runtime PM [inf]. The model answers word 1 info =
  security level (0 by default), protocol version 2, ACL count 0; word 2 NVM version
  `0x00500000`; word 3 the NHI device ID [emu].
- **3.2 Device connected (event 0x03)**: the Titan Ridge 63-word layout
  (`icm_icl_device_connected` calls `__icm_tr_device_connected` with device RTD3
  forced on) [inf]. Route string = host lane adapter: 1 for port 1, 3 for port 2.
  A USB4 device router is announced as on Alpine Ridge (`ICM-PROTOCOL.md` 13.3): header
  flags `0xa8`, name-block Intel entry flags bit 1, no `0x12` entry; a TB3 router with
  `0xb1` and the `0x12` entry [shared].
- **3.3 Device disconnected (event 0x04)**: Titan Ridge, 3 words with the route [inf].
- **3.4 Approve**: the Ice Lake client has no approve, no key, no challenge, no boot
  ACL and no disconnect-PCIe-paths [inf]. So the model's firmware tunnels every device
  router itself at plug (security none, R22) and announces it approved; Linux reports
  `security none`, `authorized 1`. `security=user` keeps the shared Titan Ridge
  8-word approve for clients that send one (the Linux ICL client cannot) [emu].
- **3.5 Errors**: boot ACL (`0x18`), get route (`0x0a`), topology (`0x01`), keys,
  XDomain (`0x10`, `0x11`) and the USB4 router-operation proxy (`0x20`, used only with
  protocol version 3 or more) get the error flag [emu]. With protocol version 2 Linux
  falls back to router operations through config space at the router's route
  (ROUTER_CS_25/26), which the fabric answers.
- **3.6 RTD3 veto (event 0x0a)**: Ice Lake only [inf]; the model never sends it.
- **NHI mailbox**: driver-unloads (`0x07`) at runtime suspend and stop [inf]; the
  other commands as Alpine Ridge [shared].

## 4. Host router and device routers (ICL6-ICL7)

The host router is the TB3-dialect Titan Ridge 4C layout of `ICM-TITAN-RIDGE.md` 4
(lanes 1-4, NHI 5 as Upstream Adapter, PCIe Down 8 and 9, DP IN 10 and 11) with the
Ice Lake router ID [emu: Linux hard-codes no Ice Lake adapter numbers]. Linux reads it
as "Thunderbolt 3 Switch: 8086:8a17", generation 3 [inf].

**Host config access at a device router's route while the firmware owns the fabric
(ICL6).** The fabric answers a host Read Request (PDF 1) at any route it can reach,
whichever CM owns the fabric: the Linux client reads every announced router at the
event's route to register it. For a USB4 device router (the ORICO model,
`device-model=asm2464`) ROUTER_CS_0-4 at route 3 read `2463174c 001101c0 00000003
80000000 200000fe`: USB4 Version `0x20` in ROUTER_CS_4 bits 31:24, Linux "USB4
Switch: 174c:2463 (TB Version: 32)", generation 4. The TB3 dock reads `0x02` there
(generation 3). Real Ice Lake firmware is not captured; that it answers such reads is
[inf] from the Linux client depending on it.

## 5. Out of scope

BIOS Assist, pre-boot (`preboot=on`), the Thunderbolt xHCI and the USB fallback are the
P14s platform (`ICM-PROTOCOL.md` 12, 13) and are refused on this profile. No ACPI
force-power or platform power-down is modelled. An unplug while the NHI is runtime
suspended is reported when the driver next sends driver ready, as on the other ICM
variants (R12); real Ice Lake firmware would wake the domain, which is not modelled.

## 6. Requirements (`tb3-ice-lake`)

ICL1-ICL8 are covered by `tests/qtest/usb4-icm-icl-test.c` in the QEMU tree; ICL9
was checked by starting QEMU with each refused option.

- **ICL1** Identity of section 1; `host-domain=1` gives NHI1 (`8a0d`).
- **ICL2** The vendor registers of section 2.
- **ICL3** Driver ready: four words, info security 0, protocol 2, ACL 0; boot ACL, get
  route and router operation answered with the error flag.
- **ICL4** Device connected: 63 words, approved at plug (security none), route = host
  lane adapter, USB4 or TB3 form by the device router's dialect.
- **ICL5** Device disconnected: 3 words with the route; the tunnel gate closes.
- **ICL6** ROUTER_CS_0-4 of a device router readable at its route by a host Read
  Request while the firmware CM owns the fabric.
- **ICL7** Host router layout of section 4.
- **ICL8** `security=user`: the Titan Ridge approve.
- **ICL9** `bios-assist`, `preboot`, `xhci`, `usb-fallback`, `ports` other than 2 and
  `host-domain` above 1 are refused at realize.

Validation (2026-10-22): the qtest (5 cases) and an unmodified Linux guest
(`LINUX-TEST.md`, "Ice Lake profile"). The Linux run shows the model matches what the
Linux client accepts; it is not evidence about real Ice Lake firmware.

## 7. What a capture should answer

1. The vendor registers at power-on and after Force Power, and how long firmware ready
   takes; whether the ICM answers ring 0 before Force Power.
2. Driver-ready words (flags, info: security level, protocol version, ACL count).
3. Device-connected flags and link info for TB3 and USB4 devices; whether a QoS
   packet follows; whether devices are announced approved or wait (security level).
4. The host router: header, adapter numbering, capability chain, the class and
   revision of the NHI, the integrated root ports.
5. Whether the firmware answers a host Read Request at a device router's route (the
   Linux client and xHCI98 43.44 both depend on it).
