# Capture versus Linux: how well `drivers/thunderbolt` predicted the two captured hosts

Status: first draft, 2026-10-15. Licence: GPL-2.0-only, like the rest of this repository.
Short quotations from Linux `drivers/thunderbolt` (GPL-2.0-only, copyright Intel
Corporation and the other authors named in those files) are marked as quotations and
attributed to file and function.

This document checks every Linux behaviour, expectation, quirk or branch that applies to
the controllers we have captured against what the hardware did:

- **Alpine Ridge LP** (ThinkPad P14s Gen 1, NHI `8086:15bf`, firmware connection manager,
  Linux ICM client). Profile `tb3-alpine-ridge`.
- **Alder Lake-P integrated USB4 host** (Framework Laptop 13, 12th gen, NHI `8086:463e` /
  `466d`, native USB4 `_OSC`, Linux software CM). Preset `usb4-generic`
  `host-model=intel-adl`.
- **ASMedia ASM2464PD USB4 device router** (ORICO AAGM2-U4 NVMe enclosure on the same
  Framework, Linux software CM; added 2026-10-15). `usb4-device device-model=asm2464`;
  analysis in `captures/ORICO-ASM2464.md`.

Verdicts:

- **CONFIRMED**: the captures show the hardware doing what Linux expects. A citation
  follows. "(negative)" means Linux expects something *not* to happen and it did not.
- **CONTRADICTED**: the hardware differed from what Linux expects or assumes. Both sides
  are cited.
- **NOT EXERCISED**: the captures never reached that branch.

Linux reference: `docs/references/linux-thunderbolt/drivers_thunderbolt/`, pinned commit
`24a19b953e2a` (`COMMIT.txt`). Locations are `file:function` (or `file:SYMBOL` for a
constant or table) at that commit.

Related documents: `ICM-PROTOCOL.md` (Alpine Ridge wire contract, R1-R32),
`USB4-HOSTS.md` (`intel-adl`, replay check, `preos-cm`), `CONTROLLER-CATALOG.md`
(per-generation differences), `PLATFORM-MATRIX.md`.

## 0. Sources and citation prefixes

Capture archives are under `tests/captures/`; paths below are inside the extracted run
folder.

| Prefix | File |
|---|---|
| `T:n`, `D:n`, `M:step`, `S<n>:path`, `P:path` | P14s Assist off / pre-boot off Linux run, as defined in `ICM-PROTOCOL.md` §0 (`trace-thunderbolt.txt`, `dmesg-live.txt`, `mmio/0000_05_00.0-<step>.txt`, `snap-<n>-*/`, `pci/`) |
| `AON-T:n`, `AON-D:n`, `AON-S1:path`, `AON-M:step` | P14s Assist on / pre-boot on Linux run (`p14s-linux-20261014-133751-assistON_prebootON`) |
| `P98:<run>` | P14s Windows 98 `win98/<run>/PCIDUMP.TXT` |
| `W:path` | P14s Windows 11 run (see `ICM-PROTOCOL.md` §10) |
| `F-D:n` | Framework `dmesg-live.txt`, line n (it starts at boot, so boot lines are included) |
| `F-T:n` | Framework `trace-thunderbolt.txt`, line n |
| `F-M:<nhi>-<step>` | Framework `mmio/0000_00_<nhi>-<step>.txt` |
| `F-P:path` | Framework `pci/path`; `config.bin` is the raw 4 KiB config space |
| `F-S<n>:path` | Framework `snap-<n>-*/path` |
| `F-L:time` | Framework `capture.log`, line with that wall-clock time |
| `F-A:table` | Framework `firmware/acpi/<table>.bin` |
| `O-D:n`, `O-T:t` | Framework + ORICO run (`linux-orico`): `dmesg-live.txt` line n, `trace-thunderbolt.txt` record at time t (`captures/ORICO-ASM2464.md` §0) |
| `R1`-`R4` `-T:t`, `-D:t`, `-W:t`, `-S<n>:path` | P14s + ORICO runs of 2026-10-15 (Assist / pre-boot off-off, off-on, on-off, on-on): trace time, dmesg time, `watch/` sample time, snapshot (`captures/P14S-ORICO-2026-10-15.md` §0) |

## 1. Alpine Ridge LP (P14s Gen 1, firmware CM)

### 1.1 NHI, PCI and interrupts

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-1 | Bind by vendor/device ID; `0x15bf` is in the ID table, class code plays no part (`pci.c:nhi_ids`) | CONFIRMED | Bound to `8086:15bf`, class `0x088000` (`P:tb-complex/0000_05_00.0/lspci.txt`, `D:1501`) |
| AR-2 | A platform property `IMR_VALID` = 0 aborts the bind; absent means valid (`pci.c:nhi_pci_imr_valid`) | CONFIRMED | Bind proceeds (`D:1501`-`D:1512`) |
| AR-3 | Every Intel-vendor NHI gets interrupt auto-clear; only Falcon Ridge gets the E2E workaround (`pci.c:nhi_pci_check_quirks`); the client sets DMA misc bit 2 and never bit 17 (`nhi.c:ring_interrupt_active`) | CONFIRMED | `0x39864` = `0x01000016`: bit 2 set, bit 17 clear, at every step (`M:1`-`M:7`) |
| AR-4 | Try 6..16 MSI-X vectors, fall back to one MSI, never INTx (`pci.c:nhi_pci_init_msi`) | CONFIRMED | MSI-X enabled with 16 entries, MSI disabled (`P:tb-complex/0000_05_00.0/lspci.txt`) |
| AR-5 | With a single MSI, the handler relies on read-to-clear of the status block at `0x37800` (`nhi.c:nhi_interrupt_work`, `nhi.c:nhi_clear_interrupt`) | NOT EXERCISED | MSI-X was used; the tool never reads `0x37800` |
| AR-6 | Per-ring MSI-X vector in the allocation registers, 4 bits per ring index (`nhi.c:ring_interrupt_active`) | CONFIRMED | `0x38c40` = 0 (TX ring 0 on vector 0), `0x38c44` = `0x00010000` (RX ring 0, index 12, on vector 1) (`M:3`) |
| AR-7 | Throttle entry of the ring's vector is written with the ring interval rounded to 256 ns; control rings use interval 0, so Linux writes 0 (`nhi.c:ring_interrupt_active`, `nhi.c:tb_ring_throttling`) | **CONTRADICTED** | Entries 0 and 1 read `0x000001f4` after every bind, identical to the unbound value (`M:1`-`M:7`). The write of 0 is not visible on read-back |
| AR-8 | Ring enable bit = hop for TX, hop + hop count for RX; enable by read-modify-write, mask by read-modify-write on Intel (`nhi.c:ring_interrupt_active`, `nhi.c:nhi_mask_interrupt`) | CONFIRMED | "bit 12 (0x1 -> 0x1001)" (`D:1512`); `0x38200` = 0 after unbind (`M:2-unbound`) |
| AR-9 | Ring count from host capabilities bits 9:0; host-router reset only from interface version `0x40` (`nhi.c:nhi_probe`, `nhi.c:nhi_reset`) | CONFIRMED | `0x39640` = `0x0000000c`, "total paths: 12" (`D:1501`), no reset message |
| AR-10 | Interrupts disabled at probe and shutdown (`nhi.c:nhi_disable_interrupts`) | CONFIRMED | `0x38200` = 0 unbound (`M:2-unbound`) |
| AR-11 | Control ring 0: raw mode, 10 descriptors, 256-byte RX frames, all PDF bits accepted (`nhi.c:tb_ring_start`, `ctl.c:tb_ctl_alloc`) | CONFIRMED | Options `0xc0000000`, RX size `0x0100000a`, RX PDF masks `0xffffffff` (`M:3`) |
| AR-12 | IOMMU DMA protection only if an external-facing port in the segment sits behind an IOMMU with pre-boot protection (`pci.c:nhi_pci_check_iommu`) | CONFIRMED (negative) | "IOMMU DMA protection is disabled" (`D:1502`): the root port has ExternalFacingPort (`ICM-PROTOCOL.md` §11.1) but the DMAR flags byte is `0x01`, platform opt-in (bit 2) clear, in this CSM boot (`firmware/acpi/DMAR.bin` offset 37) |

### 1.2 Connection manager selection, ICM start and NHI mailbox

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-13 | No native USB4 `_OSC` grant, so try the firmware CM first, software CM as fallback (`nhi.c:nhi_select_cm`, `acpi.c:tb_acpi_is_native`) | CONFIRMED | No "USB4 _OSC" line in `dmesg-live.txt`; "using firmware connection manager" (`D:1506`) |
| AR-14 | Alpine Ridge dialect selected by NHI ID; supported if firmware status bit 0 (ICM enabled) is set (`icm.c:icm_probe`, `icm.c:icm_ar_is_supported`, `icm.c:icm_firmware_running`) | CONFIRMED | `0x39944` = `0x800001a1` at every dump, bound or not, Assist on or off (`M:*`, `AON-M:1-initial`) |
| AR-15 | Restart stopped firmware through the upstream port's PCIe-to-CIO mailbox, only with `start_icm` (`icm.c:icm_firmware_start`, `icm.c:icm_firmware_reset`, `icm.c:icm_ar_cio_reset`, `icm.c:pcie2cio_write`) | NOT EXERCISED | Firmware always running |
| AR-16 | Physical-port link reset at init happens only when the restart path found the upstream port (`icm.c:icm_reset_phy_port`) | CONFIRMED (negative) | No link drop at rebind: the approved dock was re-announced with its tunnel intact (`ICM-PROTOCOL.md` §6.2) |
| AR-17 | Poll NVM-authenticated (bit 31) up to 60 x 50 ms, then read the operating mode (`icm.c:icm_ar_get_mode`) | CONFIRMED | Bit 31 set at every read (`M:*`); bind took no measurable wait (`D:1505`-`D:1506`) |
| AR-18 | Operating mode from outbound mailbox bits 11:8: 3 = CM mode; 0 = safe mode (minimal host router, no driver ready); anything else aborts (`nhi.c:nhi_mailbox_mode`, `icm.c:icm_firmware_init`, `icm.c:icm_driver_ready`) | CONFIRMED (mode 3) | `0x3990c` = `0x800003f5` (`M:*`). Safe and wrong-mode branches NOT EXERCISED |
| AR-19 | Mailbox `0x23` (allow all devices) on bind, but not on resume, which goes straight to driver ready (`icm.c:icm_firmware_init` vs `icm.c:icm_complete`) | CONFIRMED | Inbound command `0x23` after rebind (`M:3`); `0x07` after the runtime suspends and still `0x07` after the resumes (`M:5`, `M:6`, `M:7`) |
| AR-20 | Mailbox handshake: request bit 31, error bit 30, 500 ms poll; code stays in bits 7:0 (`nhi.c:nhi_mailbox_cmd`) | CONFIRMED | Bits 31 and 30 clear, last code kept, in every dump. Error path NOT EXERCISED |
| AR-21 | `0x07` (driver unloads) on unbind and runtime suspend (`icm.c:icm_stop`, `icm.c:icm_runtime_suspend`) | CONFIRMED | `M:2-unbound`, `M:5-plugged`; tunnels and approval survive (`ICM-PROTOCOL.md` §2.3) |
| AR-22 | `0x05` (save devices) before `0x07` on system suspend (`icm.c:icm_suspend`, `icm.c:icm_fr_save_devices`) | NOT EXERCISED | No system suspend in any run |
| AR-23 | `0x06` (disconnect PCIe paths) for host NVM upgrade (`icm.c:icm_disconnect_pcie_paths`) | NOT EXERCISED | |

### 1.3 Driver ready and ICM timing

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-24 | Two-word driver-ready response: security level, boot-ACL count and supported bit, RTD3 = flags bit 6 (`icm.c:icm_ar_driver_ready`) | CONFIRMED | `0x0100e203 0x28010b60` (`T:2`): level `user` (`D:1513`), 16 ACL slots (`S6:boltctl.txt`), root switch runtime PM on (`S1:sys-bus-thunderbolt/0-0/power/runtime_status` = `suspended`) |
| AR-25 | Disable boot ACL if the count exceeds 16 (`icm.c:icm_driver_ready`) | CONFIRMED (negative) | Count 16, feature kept (`S6:boltctl.txt` "bootacl: 2/16") |
| AR-26 | After driver ready, poll router dword 0 (100 ms timeout, 50 tries 50 ms apart) until the firmware answers (`icm.c:__icm_driver_ready`) | CONFIRMED | Polls unanswered 123.284-123.852 while the firmware announces the dock, success at 123.956 (`T:3`-`T:11`), inside the 7.5 s budget |
| AR-27 | RTD3 support decides root-switch runtime PM (`icm.c:icm_ar_driver_ready`, `icm.c:icm_start`) | CONFIRMED | Assist on: root switch runtime PM `unsupported` (`AON-S1:sys-bus-thunderbolt/0-0/power/runtime_status`). The frame, traced on 2026-10-15: `0x01002203 0x28010b60`, flags `0x22`, RTD3 bit 6 clear (`R4-T:86.764`); Assist off `0x0100e203` (`R1-T:101.784`) |
| AR-28 | ICM commands time out after 5 s and are retried 3 more times (`icm.c:icm_request`, `ICM_TIMEOUT`, `ICM_RETRIES`) | CONFIRMED | Assist on, after the dock left: the boot-ACL read was sent 4 times, 110.55, 116.02, 121.14, 126.26 s (`AON-T:2`-`AON-T:5`), never answered. Every other command was answered within 2.6-358 ms |
| AR-29 | No protocol version on Alpine Ridge, so no USB4 proxy operations (`icm.c:icm_driver_ready`) | CONFIRMED (negative) | No proxy message in `D:`, no code `0x20` in `T:` |

### 1.4 Events

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-30 | Device-connected: link, depth, approved, boot, key, connection id, dual-lane and 20 Gb/s flags (`icm.c:icm_fr_device_connected`) | CONFIRMED | `T:9`, `T:27886`, `T:34163`; sysfs `rx_lanes`/`tx_lanes` 2 at 20.0 Gb/s (`S6:sys-bus-thunderbolt/0-1/`). Second device (USB4 ORICO): flags `0xa8` with 2 lanes (`R2-T:81.411`, `R2-S1`), `0x88` with 1 lane under Assist on + pre-boot (`R4-T:87.362`, `R4-S1`) |
| AR-31 | Device RTD3 taken from the Intel vendor entry of the name block (`icm.c:parse_intel_vss`, `icm.c:intel_vss_is_rtd3`) | CONFIRMED | Entry type `0x10`, flags `0x01` (`T:9`); dock router runtime-suspends (`S1:.../0-1/power/runtime_status`). The firmware builds the entry for a non-Intel USB4 router too: `b8 00 63 24 11 02`, RTD3 clear (`R2-T:81.411`) |
| AR-32 | Rejected bit (topology limit) makes the client ignore the device (`icm.c:icm_fr_device_connected`) | NOT EXERCISED | |
| AR-33 | Same UUID at the same link and depth: refresh id, key and route only (`icm.c:icm_fr_device_connected`, `icm.c:update_switch`) | CONFIRMED | No get route and no config reads after `T:34163` |
| AR-34 | New device: get route by link and depth (`icm.c:icm_ar_get_route`) | CONFIRMED | `T:833`-`T:834`, `T:27887`-`T:27888`, route 1 |
| AR-35 | Device-disconnected removes the router at that link and depth (`icm.c:icm_fr_device_disconnected`) | CONFIRMED | `T:21087`, `D:1606` |
| AR-36 | Devices unplugged while the driver was away produce no event; a rescan 500 ms after driver ready removes them (`icm.c:icm_complete`, `icm.c:icm_rescan_work`) | CONFIRMED | Unplug in runtime suspend (`D:2031`), resume at 250.81 (`D:2035`), removal at 251.32 (`D:2066`) |
| AR-37 | Security level field of the event flags (bits 4:3) stored per device (`icm.c:icm_fr_device_connected`) | CONFIRMED (parse) | Reads 2 while the domain is 1 (`T:9`, `D:1513`). Linux never compares the two, so this is not a contradiction; the meaning stays open (`ICM-PROTOCOL.md` §9 item 8) |
| AR-38 | Host-to-host (XDomain) connect/disconnect and DisplayPort-changed events (`icm.c:icm_fr_xdomain_connected`, `icm.c:icm_dp_event`) | NOT EXERCISED | |

### 1.5 Approval, security, boot ACL, pre-boot

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-39 | Approve by UUID, key and id, 10 s timeout (`icm.c:icm_fr_approve_switch`, `ICM_APPROVE_TIMEOUT`) | CONFIRMED | `T:34153` to `T:34154`, 358 ms; the tunnel came up while it was processed (`D:1689`) |
| AR-40 | Approve error flag means tunnel creation failed (`icm.c:icm_fr_approve_switch`) | NOT EXERCISED | |
| AR-41 | Key and challenge at level `secure` (`icm.c:icm_fr_add_switch_key`, `icm.c:icm_fr_challenge_switch_key`) | NOT EXERCISED | Level `user` only |
| AR-42 | Boot-ACL read (`icm.c:icm_ar_get_boot_acl`) | CONFIRMED | `T:7099`-`T:7100` |
| AR-43 | Boot-ACL write (`icm.c:icm_ar_set_boot_acl`) | CONFIRMED | `T:7101`-`T:7102`; write flag echoed, no error |
| AR-44 | Boot bit (link info bit 10) becomes the `boot` attribute (`icm.c:icm_fr_device_connected`) | CONFIRMED | `AON-S1:sys-bus-thunderbolt/0-1/boot` = 1 with pre-boot on. Frames (2026-10-15): `0x0d110110` (approved, boot) on the re-announcement after the rebind (`R2-T:81.411`, `R4-T:87.362`), and `0x0c110210` (boot, not approved) for a device plugged later with pre-boot on (`R2-T:130.710`); `boot` = 1 in sysfs (`R2-S5`). The boot-time frame itself is still untraced |
| AR-45 | No per-device de-authorisation on this dialect (`domain.c:deauthorization_show`, ICM ops without a disapprove hook) | CONFIRMED | `S6:sys-bus-thunderbolt/domain0/deauthorization` = 0 |

### 1.6 Runtime PM and platform power

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-46 | Autosuspend after 15 s idle; rings stopped, mailbox `0x07`, NHI to D3 (`tb.h:TB_AUTOSUSPEND_DELAY`, `nhi.c:nhi_runtime_suspend`, `icm.c:icm_runtime_suspend`) | CONFIRMED | Approve response 174.86, suspend 193.16 (`D:2016`); `M:5` inbound `0x07`, lspci D3 |
| AR-47 | Runtime resume = driver ready + 500 ms rescan; tunnels survive (`icm.c:icm_runtime_resume`, `icm.c:icm_complete`) | CONFIRMED | `T:34155`-`T:34163` |
| AR-48 | While bound, the NHI and its firmware stay reachable; the driver has no notion of a platform powering the controller off under it (`icm.c:icm_request`; `nhi.c:nhi_shutdown` only runs on removal) | **CONTRADICTED** | Assist on: after the device-disconnected event (`AON-T:1`, 96.75 s) the firmware answered nothing (`AON-T:2`-`AON-T:5`), and at 131.80 s the ring registers read all-ones and the whole controller was removed by the platform (`AON-D:1459`-`AON-D:1466`). With the ORICO (2026-10-15): NHI registers all-ones 10.4-11.4 s after the device-disconnected event, platform removal at 15.4 s (`R4-W:121.269`, `R4-W:122.271`, `R4-D:126.196`) |
| AR-49 | No force-power mechanism for discrete Thunderbolt 3 in Linux (Ice Lake and later only, `pci.c:icl_nhi_force_power`) | NOT EXERCISED | Never needed in the Linux runs (Assist off keeps the controller powered, P98 `OFF_OFF_N`). The empty-controller Assist-on case was only seen under DOS (P98 `ON_ON_NO`) |

### 1.7 Router config space, DROM and NVM under the firmware CM

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| AR-50 | Router IDs `0x15c0` / `0x15d3` map to generation 3 and Alpine Ridge (`tb.h:tb_switch_is_alpine_ridge`, `switch.c:tb_switch_alloc`) | CONFIRMED | sysfs `generation` 3 (`S6`), "Thunderbolt 3 Switch" (`D:1515`, `D:1549`) |
| AR-51 | Host UUID from the link-controller registers (`lc.c:tb_lc_read_uuid`, `switch.c:tb_switch_set_uuid`) | CONFIRMED | `T:97`, `S6:.../0-0/unique_id` |
| AR-52 | Host DROM: Apple EFI property first, else the NVM copy through the DMA port followed by the UID through the EEPROM (`eeprom.c:tb_drom_host_read`, `eeprom.c:tb_drom_copy_efi`, `eeprom.c:tb_drom_copy_nvm`) | CONFIRMED (NVM path) | NVM DROM reads (`ICM-PROTOCOL.md` §5.2), then EEPROM UID (§5.4), "uid: 0x109a61598508800" (`D:1521`). EFI branch NOT EXERCISED (CSM boot) |
| AR-53 | Device DROM by EEPROM bit-bang (`eeprom.c:tb_drom_device_read`, `eeprom.c:tb_drom_bit_bang`, `eeprom.c:tb_eeprom_read_n`) | CONFIRMED | `T:925`-`T:6952`, `D:1554`-`D:1556` |
| AR-54 | DROM UID CRC-8 and data CRC-32 checks (`eeprom.c:tb_drom_parse_v1`) | CONFIRMED | No mismatch warnings for either router, including the host NVM copy with its placeholder UID |
| AR-55 | DMA port found at adapter 3, 5 or 7; NVM version through flash reads (`dma_port.c:dma_find_port`, `dma_port.c:dma_port_flash_read`, `switch.c:tb_switch_add_dma_port`) | CONFIRMED | `T:99`, `T:919`-`T:921`; NVM 23.0 and 44.0 (`D:1547`, `D:1602`) |
| AR-56 | NVM write and authentication through the DMA port (`dma_port.c:dma_port_flash_write`, `dma_port.c:dma_port_flash_update_auth`) | NOT EXERCISED | The tools never touch NVM |
| AR-57 | Under the ICM the client never configures links, TMU, CL states or paths (ICM CM ops have no tunnel or link operations, `icm.c:icm_ar_ops`) | CONFIRMED (negative) | The only writes are the EEPROM control dword and the DMA-port mailbox (`ICM-PROTOCOL.md` §5); with a USB4 device router also ROUTER_CS_25/26 for DROM Read and NVM Sector Size router operations, still no link, TMU or path access (`R2-T:81.567`-`81.580`, `ICM-PROTOCOL.md` §13.3) |
| AR-58 | Adapters disabled in the DROM are skipped (`eeprom.c:tb_drom_parse_entry_port`, `switch.c:tb_switch_add`) | CONFIRMED | "disabled by eeprom" (`D:1577`, `D:1593`-`D:1594`) |

## 2. Alder Lake-P integrated USB4 host (Framework 13, software CM)

### 2.1 NHI, PCI and interrupts

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-1 | Bind ADL NHI0/NHI1 by ID with the Ice Lake-class integrated ops (`pci.c:nhi_ids`, `pci.c:icl_nhi_ops`) | CONFIRMED | Bound `8086:463e` and `8086:466d`, class `0x0c0340` (`F-P:tb-complex/0000_00_0d.2/lspci.txt`, `.../0d.3/`) |
| ADL-2 | `IMR_VALID` property check (`pci.c:nhi_pci_imr_valid`) | CONFIRMED | Bind proceeds (`F-D:1848`) |
| ADL-3 | Force power: set bit 1 and DMA delay `0x22` in the top byte of config `0xfc`, then poll firmware-ready bit 31 of `0xc8` (`pci.c:icl_nhi_force_power`) | CONFIRMED | `0xfc` = `0x22061002`, `0xc8` = `0x80001703` (0d.2) / `0xd0001703` (0d.3) (`F-P:tb-complex/0000_00_0d.{2,3}/config.bin`) |
| ADL-4 | Force power is dropped on shutdown, and Linux expects the controller to stay accessible: "accessible even if Force Power is off" (`pci.c:icl_nhi_force_power` comment; `pci.c:icl_nhi_shutdown`) | CONFIRMED | With 0d.2 unbound, BAR0 still answered and firmware status read `0x00000100` instead of `0x000001a1` (`F-L:14:38:36`). New fact: bits 0, 5 and 7 of firmware status follow force power |
| ADL-5 | Copy the maximum LTR at `0xe4` into both halves of `0xe0` (`pci.c:icl_nhi_set_ltr`) | CONFIRMED | `0xe4` = `0x000097ff`, `0xe0` = `0x97ff97ff` (`F-P:.../config.bin`) |
| ADL-6 | Link-controller mailbox (`0xf0` / `0xec`) used only while the ICM is the CM (`pci.c:icl_nhi_suspend`, `pci.c:icl_nhi_lc_mailbox_cmd`) | CONFIRMED (negative) | `0xec` = `0xf0` = 0 (`F-P:.../config.bin`) |
| ADL-7 | Under an ICM, the host UUID would be config `0xcc`, `0xd0`, then two all-ones words (`icm.c:icm_icl_set_uuid`) | NOT EXERCISED | Values present: `0xcc` = `0x98dc0b40`, `0xd0` = `0x80874fb1`, the high and low halves of the router UID `0x98dc0b4080874fb1` (`F-D:1877`). In that order the ICM path would report `400bdc98-b14f-8780-...` while the software CM reports `b14f8780-400b-dc98-...` (`F-S1:boltctl.txt`): the domain UUID would change with the CM mode |
| ADL-8 | Intel auto-clear quirk applies to every Intel NHI (`pci.c:nhi_pci_check_quirks`) | CONFIRMED | `0x39864` = `0xff000816`: bit 2 set, bit 17 clear, both NHIs, every step (`F-M:*`) |
| ADL-9 | 6..16 MSI-X vectors, else one MSI (`pci.c:nhi_pci_init_msi`) | CONFIRMED | MSI-X Enable+, 16 vectors, table in BAR2 (`F-P:.../lspci.txt`). MSI fallback NOT EXERCISED |
| ADL-10 | Throttle entry of the ring's vector written as 0 (`nhi.c:ring_interrupt_active`) | **CONTRADICTED** | Bits 15:0 of entries 0 and 1 read `0x01f4` while bound; bits 31:16 vary between dumps (`0x000e01f4`, `0x004701f4`, `0x003601f4`, ...) and read 0 when idle (`F-M:*`). Linux's mask covers bits 15:0 only and has no notion of the upper half |
| ADL-11 | Vector allocation and ring enable bits as for any NHI (`nhi.c:ring_interrupt_active`) | CONFIRMED | `F-D:1859`-`F-D:1861`; `0x38c44` = `0x00010000`; `0x38200` = 0 unbound (`F-M:0d.3-2-unbound`) |
| ADL-12 | Ring 0 raw, 10 descriptors, 256-byte frames (`nhi.c:tb_ring_start`) | CONFIRMED | `0x0800c` = `0x0100000a` (`F-M:0d.2-1-initial`) |
| ADL-13 | 12 rings, interface version 0, so no host-router reset (`nhi.c:nhi_probe`, `nhi.c:nhi_reset`) | CONFIRMED | `0x39640` = `0x0000000c`, "total paths: 12" (`F-D:1848`) |
| ADL-14 | IOMMU DMA protection when an external-facing port is behind a pre-boot-protecting IOMMU (`pci.c:nhi_pci_check_iommu`) | CONFIRMED | "IOMMU DMA protection is enabled" (`F-D:1849`); DMAR flags `0x05` (platform opt-in set) (`F-A:DMAR` offset 37); boltctl "security: iommu+user" (`F-S1:boltctl.txt`) |

### 2.2 Connection manager selection, ACPI and firmware status

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-15 | Any USB4 `_OSC` control granted: software CM, no ICM probe (`nhi.c:nhi_select_cm`, `acpi.c:tb_acpi_is_native`) | CONFIRMED | "USB4 _OSC: OS controls USB3+ DisplayPort+ PCIe+ XDomain+" (`F-D:366`); "using software connection manager" (`F-D:1853`, `F-D:1964`) |
| ADL-16 | `_DSD` "usb4-host-interface" links tunnel root ports to their NHI (`acpi.c:tb_acpi_add_links`) | CONFIRMED | 00:07.0 and 07.1 to 0d.2 (`F-D:1854`-`F-D:1855`), 07.2 and 07.3 to 0d.3 (`F-D:1965`-`F-D:1966`). This upgrades the TUID-to-TDM mapping that `USB4-HOSTS.md` §1 marked inferred to observed |
| ADL-17 | Tunnelling allowed per `_OSC` bit (`acpi.c:tb_acpi_may_tunnel_pcie`, `..._usb3`, `..._dp`) | CONFIRMED (PCIe) | PCIe tunnel built (§2.5). USB3 and DP grants NOT EXERCISED (no USB3 or DP sink device) |
| ADL-18 | A Tiger Lake-class ICM is usable only if firmware status bit 31 rises within 10 ms (`icm.c:icm_tgl_is_supported`) | NOT EXERCISED | Native `_OSC` skips the ICM probe. Firmware status `0x000001a1` (bit 0 set, bit 31 clear), outbound mailbox 0, inbound 0 at all 14 dumps of both NHIs (`F-M:*`): had the ICM been probed it would have been rejected. The Framework is UEFI-only (no CSM), so the non-`_OSC` state cannot be produced on it |
| ADL-19 | Retimer `_DSM` power-on for NVM upgrade with nothing attached (`acpi.c:tb_acpi_power_on_retimers`) | NOT EXERCISED | |
| ADL-20 | Software CM has no boot ACL (`domain.c:boot_acl_show` with zero slots) | CONFIRMED | "bootacl: 0/0" on both domains (`F-S1:boltctl.txt`) |

### 2.3 Host router, router operations and DisplayPort resources

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-21 | USB4 version byte `0x20` makes the host a USB4 router (generation 4) (`switch.c:tb_switch_alloc`, `usb4.c:usb4_switch_setup`) | CONFIRMED | "USB4 Switch: 8087:463e (Revision: 2, TB Version: 32)" (`F-D:1864`) |
| ADL-22 | Adapters answering invalid-address are "not implemented" (`switch.c:tb_init_port`) | CONFIRMED | Adapters 10, 11 (`F-D:1925`-`F-D:1926`; error code 2 at `F-T:228`, `F-T:230`) |
| ADL-23 | Buffer allocation router operation `0x33` gives the credit parameters (`usb4.c:usb4_switch_credits_init`) | CONFIRMED | `F-T:65`; USB3 32, DP AUX 1, DP main 0, PCIe 64, DMA 14 (`F-D:1870`-`F-D:1875`) |
| ADL-24 | Host DROM through DROM-read operation `0x24`, UID from router CS (`eeprom.c:tb_drom_host_read`, `usb4.c:usb4_switch_drom_read`, `usb4.c:usb4_switch_read_uid`) | CONFIRMED | `F-T:81`, `F-T:95`; "DROM version: 3", uid (`F-D:1876`-`F-D:1877`) |
| ADL-25 | NVM support decided by the NVM-sector-size operation `0x25` (`switch.c:nvm_upgradeable`, `switch.c:tb_switch_nvm_add`, `usb4.c:usb4_switch_nvm_sector_size`) | CONFIRMED | Router CS 26 reads `0x40000025` (Operation Not Supported) (`F-T:337`-`F-T:359`); no host NVM version is printed |
| ADL-26 | USB3 bandwidth limited to 16376 Mb/s on Intel ADL hosts (`quirks.c:quirk_usb3_maximum_bandwidth`) | CONFIRMED | `F-D:1937`-`F-D:1939` |
| ADL-27 | Lane adapters 1/2 and 3/4 paired (`switch.c:tb_switch_default_link_ports`) | CONFIRMED | `F-D:1940`-`F-D:1941` |
| ADL-28 | DP IN adapters raise plug events when the router is enumerated; DP resource checked with operation `0x10` (`tb.c:tb_dp_resource_available`, `usb4.c:usb4_switch_query_dp_resource`) | CONFIRMED | `F-D:1878`-`F-D:1879`, `F-D:1947`-`F-D:1948`; `F-T:521` |
| ADL-29 | DisplayPort tunnel set-up (`tb.c:tb_tunnel_dp`) | NOT EXERCISED | "no suitable DP OUT adapter available" (`F-D:2507`): no monitor on the dock |

### 2.4 TMU, CL states and power management

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-30 | Host TMU set to uni-directional LowRes at start (`tb.c:tb_start`, `tmu.c:tb_switch_tmu_configure`) | CONFIRMED | `F-D:1942`-`F-D:1945`; domain 1 changed from the bi-directional HiFi left by the previous driver instance (`F-D:2052`-`F-D:2054`) |
| ADL-31 | TMU of a Thunderbolt 3 device router left in bi-directional HiFi (`tb.c:tb_enable_tmu`) | CONFIRMED | `F-D:2156` |
| ADL-32 | CL states only between USB4 routers (`clx.c:tb_switch_clx_is_supported`, `tb.c:tb_enable_clx`) | CONFIRMED (negative) | No CL-state activity with the TB3 dock although `clx=Y` (`system/thunderbolt-params.txt`) |
| ADL-33 | CL0s/CL1/CL2 on a USB4 link (`clx.c:tb_switch_clx_enable`) | CONFIRMED (negative) | With a USB4 device router attached, CLx stays off because the ASM2464 reports no CL0s/CL1/CL2 support (LANE_ADP_CS_0 `0x003c01c0`): "3:1: CLx: CL0s/CL1 not supported", "0:3: CLx: CL0s/CL1 supported" (`O-D:1235`-`O-D:1236`). Enabling CL states is still not exercised |
| ADL-34 | Before runtime suspend: wake enables and Enter Sleep (`switch.c:tb_switch_suspend`, `usb4.c:usb4_switch_set_wake`, `usb4.c:usb4_switch_set_sleep`) | CONFIRMED | "enabling wakeup: 0x3f" (`F-D:2484`), resume succeeds |
| ADL-35 | Runtime resume restores the host router and re-enables TMU (`tb.c:tb_runtime_resume`, `tb.c:tb_restore_children`, `tb.c:tb_enable_tmu`) | CONFIRMED | TMU reads "off" after each resume, so router state was lost in runtime D3, and is set to bi-directional HiFi (`F-D:2502`, `F-D:2577`) |
| ADL-36 | Autosuspend after 15 s idle (`tb.h:TB_AUTOSUSPEND_DELAY`) | CONFIRMED | Domain 0 suspends 18.8 s after start (81.16 to 99.95, `F-D:1856`, `F-D:2483`) |
| ADL-37 | System suspend and resume, wake reasons (`tb.c:tb_suspend_noirq`, `tb.c:tb_resume_noirq`, `usb4.c:usb4_switch_check_wakes`) | CONFIRMED | Suspend-to-idle with the ASM2464 attached: wakes 0x1f on device and host router, rings stopped; on resume wake reasons read ("USB4 wake: no ..."), host and device router restored, TMU re-enabled, the PCIe tunnel torn down and rebuilt ("tunnels restarted"), NVMe re-initialised (`O-D:2364`-`O-D:2497`). The device router had been reset in suspend (`captures/ORICO-ASM2464.md` §9) |

### 2.5 Hot plug, links, retimers and tunnels (TB3 dock on the USB4 host)

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-38 | Hot plug on a USB4 port: scan, wait for the port up to 10 x 100 ms (`tb.c:tb_scan_port`, `switch.c:tb_wait_for_port`) | CONFIRMED | `F-D:2090`-`F-D:2092`; lane 1 (0:4) took 3 retries, about 300 ms (`F-D:2160`-`F-D:2162`) |
| ADL-39 | A TB3 device router behind a USB4 host: generation 3, plug events from the TB3 router acknowledged (`switch.c:tb_switch_alloc`, `switch.c:tb_plug_events_active`) | CONFIRMED | "Thunderbolt 3 Switch: 8086:15d3" (`F-D:2094`); acks for 3:9, 3:2, 3:10 (`F-D:2101`-`F-D:2103`) |
| ADL-40 | TB3 device DROM by EEPROM bit-bang under the software CM (`eeprom.c:tb_drom_device_read`) | CONFIRMED | `F-D:2104`-`F-D:2108`, 0x70 bytes in about 490 ms |
| ADL-41 | TB3 device UUID from its link controller (`lc.c:tb_lc_read_uuid`, `switch.c:tb_switch_set_uuid`) | CONFIRMED | `F-T:1198` (`0x000003c6 0x18879000 0x30efca23 0x26d04222`) gives `c6030000-0090-8718-23ca-ef302242d026` (`F-S6:sys-bus-thunderbolt/1-3/unique_id`). Under the P14s ICM the same dock is `001121a0-fc0e-3d00-ffff-ffffffffffff` (`S6:.../0-1/unique_id`); Linux has no expectation that the two agree (see §4, C3) |
| ADL-42 | TB3 device NVM version through its DMA port (`dma_port.c:dma_port_flash_read`) | CONFIRMED | "NVM version 44.0" (`F-D:2159`) |
| ADL-43 | Link marked configured: link-controller register on the TB3 router, Port Configured on the USB4 port (`switch.c:tb_switch_configure_link`, `lc.c:tb_lc_configure_port`, `usb4.c:usb4_port_configure`) | CONFIRMED | Route 3 router dword `0x1a9` `0x160` to `0x40010160` (`F-T:7517`); host port 3 dword `0xa3` (`F-T:917`) |
| ADL-44 | Lane bonding and credit recomputation (`switch.c:tb_switch_lane_bonding_enable`, `switch.c:tb_port_update_credits`) | CONFIRMED | Credits 120 to 60 and back, lane 1 0 to 60 to 0 (`F-D:2154`-`F-D:2155`); "symmetric, dual lanes" (`F-D:2172`); sysfs 2 lanes (`F-S6:.../1-3/rx_lanes`) |
| ADL-45 | Link speed read from the lane adapter (`switch.c:tb_switch_update_link_attributes`) | CONFIRMED | "current link speed 20.0 Gb/s" (`F-D:2152`) |
| ADL-46 | Bonding produces plug and unplug events on lane 1 and the upstream port; they are ignored (`tb.c:tb_handle_hotplug`) | CONFIRMED | `F-D:2207`-`F-D:2214` |
| ADL-47 | Retimer scan on the port: NVM authentication status, NVM version, then inbound sideband disabled (`retimer.c:tb_retimer_scan`, `retimer.c:tb_retimer_nvm_read`, `usb4.c:usb4_port_retimer_unset_inbound_sbtx`) | CONFIRMED | `F-D:2173`-`F-D:2176` (8087:15ee, NVM 10.0); index 2 gets No Response (`USB4-HOSTS.md` §1) |
| ADL-48 | Sideband transactions complete well inside the 500 ms timeouts (`usb4.c:usb4_port_sb_read` and the retimer operations) | CONFIRMED | Pending for about 1-2 ms, about 100 ms before No Response (`USB4-HOSTS.md` §1; polling at `F-T:` dword `0x91` of port 3) |
| ADL-49 | The device's second port is probed once and found unplugged (`tb.c:tb_scan_port`, `switch.c:tb_wait_for_port`) | CONFIRMED | "3:3: is unplugged (state: 7)" (`F-D:2177`) |
| ADL-50 | PCIe down adapter of a USB4 host from the PCIe-down mapping (`tb.c:tb_find_pcie_down`, `usb4.c:usb4_switch_map_pcie_down`) | CONFIRMED | Port 2 (lanes 3/4) to adapter 9 (`F-D:2178`), which is root port 07.3 (`F-D:2215`) |
| ADL-51 | PCIe paths: HopID 8 both ways, weight 1, priority 3, credits 32/64 on lanes and 7 on protocol adapters (`tunnel.c:tb_tunnel_alloc_pci`, `tunnel.c:tb_pci_init_path`, `path.c:tb_path_activate`) | CONFIRMED | `F-D:2179`-`F-D:2206`; writes acknowledged (`F-T:8141` onward) |
| ADL-52 | After the PCIe tunnel, Alpine Ridge device routers get their internal xHCI connected to a port that reports a USB plug (`switch.c:tb_switch_xhci_connect`, `lc.c:tb_lc_is_usb_plugged`, `lc.c:tb_lc_is_xhci_connected`) | CONFIRMED | Port 1 link-controller dword `0x13d` = `0x00c30250`, port 3 `0x23d` = `0x02c00010`, USB-plugged bit 31 clear on both, so no connect write (`F-T:8163`, `F-T:8167`) |
| ADL-53 | Tunnel only after authorisation at level `user` (`domain.c`, `tb.c:tb_tunnel_pci`) | CONFIRMED | boltd policy `iommu`, device stored, tunnel follows enumeration (`F-S1:boltctl.txt`, `F-D:2178`) |
| ADL-54 | Unplug: CM sees the unplug, deactivates paths, removes the router; PCIe link down follows (`tb.c:tb_handle_hotplug`) | CONFIRMED | Event 110.414, deactivation 110.415, PCIe link down 110.435 (`F-D:2516`-`F-D:2529`) |
| ADL-55 | USB3 tunnel (`tb.c:tb_create_usb3_tunnels`) | NOT EXERCISED | TB3 device has no USB3 adapter; the ASM2464's DROM marks its adapter 4 unused ("3:4: disabled by eeprom", `O-D:1206`), so no USB3 tunnel either |
| ADL-56 | USB4 device router: Configuration Valid, device router operations, USB4 DROM (`switch.c:tb_switch_configuration_valid`, `usb4.c`) | CONFIRMED | ASM2464: Configuration Ready 0.3 ms after Configuration Valid (`O-T:75.6418`-`O-T:75.6421`); Buffer Allocation, DROM Read and NVM Sector Size operations (§2.7); the DROM is the TBT3-compatible revision 1 format, not the USB4 one |
| ADL-57 | Asymmetric links, Gen 4 (`tb.c:tb_configure_asym`) | NOT EXERCISED | v1 host |
| ADL-58 | DP bandwidth allocation mode (`tb.c:tb_handle_dp_bandwidth_request`) | NOT EXERCISED | |
| ADL-59 | Host-to-host (XDomain) (`xdomain.c`) | NOT EXERCISED | |
| ADL-60 | Retimer NVM upgrade (`retimer.c`) | NOT EXERCISED | |

### 2.6 Pre-OS CM handover and timing

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ADL-61 | Boot firmware may have created tunnels; on a USB4 v1 host with `host_reset` the CM resets the ports instead of adopting them. Quote: "Boot firmware might have created tunnels of its own" (`tb.c:tb_start`; `switch.c:tb_switch_reset`) | CONFIRMED | The UEFI firmware had tunnelled the dock: 7d:00.0 `8086:15d3` enumerated at 1.00 s, before the driver loaded (`F-D:515`). Linux reset: 07.3 link down at 1.71 s (`F-D:1223`), dock re-found at 3.66 s (`F-D:1409`). Same on rebind: "0: resetting" (`F-D:1946`, `F-D:2055`), unplug then plug events (`F-D:2056`, `F-D:2090`) |
| ADL-62 | Configuration-space requests answered within 100 ms, 4 retries (`tb.c:TB_TIMEOUT`, `ctl.c:TB_CTL_RETRIES`) | CONFIRMED | Replies in about 0.2-0.4 ms (e.g. `F-T:1`-`F-T:2`) |
| ADL-63 | Router operation completes within 500 ms (`usb4.c:usb4_native_switch_op`) | CONFIRMED | Operation Valid clears after about 1 ms (`F-T:337`-`F-T:359`; `USB4-HOSTS.md` §1) |

An unexplained boot event sits next to ADL-61: after the first reconnect the dock dropped
again at 6.55 s ("pciehp: Cannot add device at 0000:7d:00", retimer and device
disconnected, `F-D:1545`-`F-D:1548`) and came back at 7.44 s. The boot ran without
`thunderbolt.dyndbg`, so the cause is not visible. It is not counted as a contradiction.

### 2.7 USB4 device router: ASMedia ASM2464PD (ORICO AAGM2-U4)

Linux software CM on the Framework (domain 1, route 3). Details and the register-level
findings that Linux does not care about are in `captures/ORICO-ASM2464.md`.

| ID | Linux behaviour or expectation (source) | Verdict | Evidence |
|---|---|---|---|
| ASM-1 | A router reporting USB4 version `0x20` is a USB4 router, generation 4, whatever its vendor (`switch.c:tb_switch_alloc`) | CONFIRMED | "USB4 Switch: 174c:2463 (Revision: 0, TB Version: 32)" (`O-D:1178`), sysfs `generation` 4 |
| ASM-2 | ROUTER_CS_6 TBT3-Not-Supported and Internal-Host-Controller bits read at setup (`usb4.c:usb4_switch_setup`) | CONFIRMED | "TBT3 support: yes, xHCI: no" |
| ASM-3 | Credit parameters from Buffer Allocation; parameters the router does not report keep their defaults (`usb4.c:usb4_switch_credits_init`) | CONFIRMED | Only PCIe 64 reported and used (`O-D:1186`-`O-D:1187`); path credits 64 on lane ingress (`O-D:2172`) |
| ASM-4 | USB4 routers: DROM through the DROM Read operation, UID from router config space (`usb4.c:usb4_switch_drom_read`, `eeprom.c:tb_drom_read`) | CONFIRMED | "DROM version: 1", uid `0x70912700174c608e` (`O-D:1188`-`O-D:1189`). The DROM's UID field holds the same two dwords in the other order; Linux never compares them |
| ASM-5 | TBT3-compatible DROM: UID CRC-8 and data CRC-32 checked, lane, PCIe and generic entries parsed (`eeprom.c:tb_drom_parse_v1`) | CONFIRMED | No CRC warning; vendor `0xb8`, "ASMedia", "246x" (`O-D:1214`) |
| ASM-6 | An adapter marked unused in the DROM is skipped (`eeprom.c:tb_drom_parse_entry_port`) | CONFIRMED | "3:4: disabled by eeprom"; only ADP_CS_0 of adapter 4 is ever read |
| ASM-7 | NVM support decided by NVM Sector Size; status 2 means not supported (`usb4.c:usb4_switch_nvm_sector_size`, `switch.c:tb_switch_nvm_add`) | CONFIRMED | ROUTER_CS_26 `0x02000025` three times (`O-T:75.2650`-`O-T:75.2672`), no NVM version shown, no `nvm_version` in sysfs |
| ASM-8 | ASMedia NVM layout: version at NVM `0x28`, date at `0x1c`, ASMedia byte order (`nvm.c:asmedia_switch_nvm_version`) | NOT EXERCISED | The router refused NVM Sector Size (ASM-7), so the NVM was never read |
| ASM-9 | Configuration Valid answered by Configuration Ready within 50 ms (`usb4.c:usb4_switch_configuration_valid`) | CONFIRMED | 0.3 ms |
| ASM-10 | Lane bonding with a USB4 device router; device lane credits unchanged (`switch.c:tb_switch_lane_bonding_enable`) | CONFIRMED | "3: link width set to symmetric, dual lanes" (`O-D:1220`); device lanes keep 66 buffers |
| ASM-11 | CL states only if both ends support them (`clx.c:tb_switch_clx_enable`) | CONFIRMED (negative) | ADL-33 |
| ASM-12 | Device router TMU: bi-directional HiFi when CL states are off (`tb.c:tb_enable_tmu`) | CONFIRMED | "3: TMU: mode set to: bi-directional, HiFi" (`O-D:1242`) |
| ASM-13 | PCIe tunnel to the router's PCIe Upstream adapter; unplug tears it down before the PCIe link drops (`tunnel.c:tb_tunnel_alloc_pci`, `tb.c:tb_handle_hotplug`) | CONFIRMED | `O-D:2168`-`O-D:2196`; unplug: paths deactivated 0.5 ms after the event, pciehp Link Down 22 ms after it (`O-D:2027`-`O-D:2042`) |
| ASM-14 | USB3 tunnel to a USB4 device router (`tb.c:tb_tunnel_usb3`) | NOT EXERCISED | ASM-6: adapter 4 unused |

## 3. Trust summary

Counts from the tables above. "Trust" is CONFIRMED / (CONFIRMED + CONTRADICTED), i.e. how
often Linux was right where the hardware could tell. "Coverage" is the share of the
listed Linux behaviours the captures reached at all.

### 3.1 Alpine Ridge LP (firmware CM)

| Area | Items | CONFIRMED | CONTRADICTED | NOT EXERCISED | Trust | Coverage |
|---|---|---|---|---|---|---|
| NHI, PCI, interrupts (1.1) | 12 | 10 | 1 | 1 | 91% | 92% |
| CM selection, ICM start, mailbox (1.2) | 11 | 8 | 0 | 3 | 100% | 73% |
| Driver ready, ICM timing (1.3) | 6 | 6 | 0 | 0 | 100% | 100% |
| Events (1.4) | 9 | 7 | 0 | 2 | 100% | 78% |
| Approval, security, boot ACL, pre-boot (1.5) | 7 | 5 | 0 | 2 | 100% | 71% |
| Runtime PM, platform power (1.6) | 4 | 2 | 1 | 1 | 67% | 75% |
| Router config, DROM, NVM (1.7) | 9 | 8 | 0 | 1 | 100% | 89% |
| **Total** | **58** | **46** | **2** | **10** | **96%** | **83%** |

### 3.2 Alder Lake-P (software CM)

| Area | Items | CONFIRMED | CONTRADICTED | NOT EXERCISED | Trust | Coverage |
|---|---|---|---|---|---|---|
| NHI, PCI, interrupts (2.1) | 14 | 12 | 1 | 1 | 92% | 93% |
| CM selection, ACPI, firmware status (2.2) | 6 | 4 | 0 | 2 | 100% | 67% |
| Host router, router operations, DP resources (2.3) | 9 | 8 | 0 | 1 | 100% | 89% |
| TMU, CL states, power (2.4) | 8 | 8 | 0 | 0 | 100% | 100% |
| Hot plug, links, retimers, tunnels (2.5) | 23 | 18 | 0 | 5 | 100% | 78% |
| Pre-OS handover, timing (2.6) | 3 | 3 | 0 | 0 | 100% | 100% |
| **Total** | **63** | **53** | **1** | **9** | **98%** | **86%** |

ADL-33, ADL-37 and ADL-56 moved from NOT EXERCISED to CONFIRMED with the ORICO run
(2026-10-15).

### 3.3 ASMedia ASM2464PD device router (2.7)

| Area | Items | CONFIRMED | CONTRADICTED | NOT EXERCISED | Trust | Coverage |
|---|---|---|---|---|---|---|
| USB4 device router (2.7) | 14 | 12 | 0 | 2 | 100% | 86% |

### 3.4 Reading the numbers

- Where the captures could check it, Linux predicted both controllers almost perfectly:
  96-98%. The failures are in two places Linux does not model at all: a throttle register that
  does not read back what Linux writes, and a platform that powers the controller off
  under a bound driver.
  No ICM message layout, router register, operation, path or timing expectation was
  contradicted.
- Coverage is lowest where the test devices could not reach: a USB4 device router (CL
  states, USB3 tunnel, Configuration Valid, device router operations), DisplayPort, system
  suspend, error and security-level branches, and anything that starts the ICM firmware
  or uses safe mode. These are the items of §5.
- So the Linux source is a good stand-in for the hardware for the *happy path* of both
  CMs. It is weakest on platform behaviour (BIOS Assist, pre-boot, CSM, firmware
  hand-over), which Linux leaves to ACPI and the firmware. That is exactly what a legacy
  OS on these machines meets first, so the platform captures (`PLATFORM-MATRIX.md`) stay
  the authority there.
- `[inf]` statements in `ICM-PROTOCOL.md` and `CONTROLLER-CATALOG.md` that rest on Linux
  alone can be trusted for message layouts and register semantics. Platform statements
  inferred from Linux (power, hand-over, which CM runs) need a capture.

## 4. Contradictions and their modelling impact

| # | What Linux expects | What the hardware did | Profile | Current model follows | Impact and action |
|---|---|---|---|---|---|
| C1 | The throttle entry of a ring's MSI-X vector holds the value written (0 for the control rings) (`nhi.c:ring_interrupt_active`) | Bits 15:0 read `0x01f4` regardless (AR-7, ADL-10). ADL bits 31:16 change between dumps and are 0 when idle, which looks like a live counter | both | **Hardware** (2026-10-15): `usb4-host` `itr-fixed=auto` (default) keeps the Interval at `0x1f4` and ignores writes on the TB3 profiles and `host-model=intel-adl`; the minimal host stores writes. Bits 31:16 (the Spec Table 12-34 Counter) read 0, unmodelled | Low. No known client reads it back. `itr-fixed=on/off` overrides |
| C2 | A bound NHI and its ICM keep answering; only timeouts and PCI removal are handled (`icm.c:icm_request`, `nhi.c:nhi_shutdown`) | With BIOS Assist on, the ICM stopped answering once the last device left (four 5 s timeouts, AR-28) and the platform removed the controller about 35 s later (AR-48) | `tb3-alpine-ridge` (Titan Ridge follows, inferred) | **Hardware** (2026-10-15): the removal is R27, and from the last device's departure until the power-off the ICM drops every command unanswered (R32, `usb4-host` `assist-icm-silence`, default on) | Medium for xhci98: a legacy ICM client on an Assist-on machine must survive unanswered commands after the last unplug. 2026-10-15 (ORICO): power-off 10.4-11.4 s after the departure, removal 15.4 s, no return on replug; in the dock run the controller was still present at +15.9 s, so the delay varies (`ICM-PROTOCOL.md` R32). Still open: when the silence starts and whether mailbox and config traffic are also ignored (the tool now probes every 2 s during the unplug, §5.1) |
| C3 | (Not a Linux expectation, a model assumption.) A TB3 device router's link-controller UUID is the DROM UID followed by all ones, the form the ICM reports | The TS3 Plus's link-controller UUID is unrelated to its DROM UID (ADL-41): `c6030000-0090-8718-23ca-ef302242d026` under the software CM versus `001121a0-fc0e-3d00-ffff-ffffffffffff` from the ICM | future TB3-device-on-USB4 preset; `tb3-alpine-ridge` unaffected (Linux never reads a device router's link-controller UUID under the ICM, `ICM-PROTOCOL.md` §5.1) | **Hardware** on a USB4 host (branch `usb4-tb3dev`, 2026-10-15): the TB3 device router's link-controller UUID is unrelated to its DROM UID: derived per device by default (two docks never share one), the captured value with `lc-uuid=captured`; the ICM event UUID stays derived from the DROM UID; under `tb3-alpine-ridge` the link-controller UUID is still the DROM form, which no CM there reads | Done as proposed; Linux on the model shows the real dock's `unique_id` ([USB4-HOSTS.md](USB4-HOSTS.md) §8) |

Deviations the captures confirm but which are deliberate, not contradictions:

- **`intel-adl` interrupt rule.** Real ADL runs the Intel auto-clear rule (ADL-8). The
  model keeps an emulator PCI identity, so Linux applies the non-Intel rule (Spec Disable
  ISR Auto-Clear, explicit clear register). This follows `AGENTS.md` (no Intel PCI IDs on
  the generic profile). Since 2026-10-15 `usb4-host` `intel-autoclear=on` (intel-adl
  only) adds the Intel rule: while the guest sets DMA misc bit 2, an MSI-X delivery
  clears its cause, as on `tb3-alpine-ridge` (R7). It stays off by default: with the
  emulator identity no client sets bit 2 (Linux keys the Intel rule on the vendor ID),
  bit 2 is vendor defined in Spec Table 12-14, and the default should stay the Spec
  behaviour the identity promises. A guest driver written against the real ADL register
  set, or a future Intel-identity ADL variant, turns it on. That variant would also need
  the config-space block of ADL-3 to ADL-7.
- **ADL firmware status and config-space block.** Real values: firmware status
  `0x000001a1` with force power, `0x00000100` without (ADL-4, ADL-18); config `0xc8`,
  `0xcc`, `0xd0`, `0xe0`, `0xe4`, `0xfc` as in ADL-3 to ADL-7. The generic profile models
  none of them; Linux never reads them on the emulator identity. A future "TGL-class
  under ICM" model (`CONTROLLER-CATALOG.md` §7 rank 5) should start from these values
  and keep the `0xcc` / `0xd0` order, which Linux's ICM path would turn into a different
  domain UUID from the software CM's (ADL-7).
- **Alpine Ridge DMA port hidden by default** (`ARCHITECTURE.md` §4.2): Linux reads the
  NVM versions through it on real hardware (AR-55); R20 remains the opt-in. The TB3 dock
  on a USB4 host has it since `usb4-win11tb3` (2026-10-16, in main as of QEMU `2a893ea`), so ADL-42 ("NVM version
  44.0") is reproduced there (`USB4-HOSTS.md` §8).

## 5. What to capture next

Ordered by value to the xhci98 drivers and to the two models. The P14s runs so far were
all CSM boots; the Framework is UEFI-only (no CSM), so the "firmware CM for a legacy OS"
question cannot arise on it natively.

| Priority | Machine and device | What it settles | Items |
|---|---|---|---|
| 1 | P14s + Thunderbolt 3 NVMe enclosure, Linux, Assist off, pre-boot off then on, tracing from boot | The PCIe tunnel to an NVMe endpoint, the project's end goal, on the real ICM; the device-connected event with `boot` = 1 and the driver-ready frame under pre-boot (only the end state was seen, AR-44); whether pre-boot needs the boot ACL or approves any device (`ICM-PROTOCOL.md` §12.1) | AR-44, AR-27; R25. **Mostly done 2026-10-15 with the USB4 ORICO** (tunnel to NVMe, approve, `boot` frames after rebind, pre-boot without the ACL). Open: the boot-time frames, which need the new first-bind tracing (§5.1 item 1) |
| 2 | P14s + any TB3 device, Linux, Assist on, tracing from boot, periodic NHI sampling across the last unplug | Driver-ready flags under Assist (RTD3 bit, AR-27); exact window in which the ICM stops answering and when the controller is removed (C2, AR-48) | AR-27, AR-28, AR-48. **Partly done 2026-10-15**: flags `0x22` (AR-27), power-off 11 s after the departure with the ORICO. Open: the start of the silence; repeat with the dock and the 2 s unplug probe |
| 3 | P14s Windows 98, CSM, with and without the dock, Assist off and on | The PCI IRQ routing table (`$PIR`) and BIOS routing options for the NHI and tunnel slots, which a legacy PCI driver and Windows 98's IRQ steering use; firmware status and operating mode as the DOS environment leaves them (open in `ICM-PROTOCOL.md` §9 item 6) | Platform; AR-14, AR-18 under DOS. **Done 2026-10-15** (`win98-orico/`, `captures/P14S-ORICO-2026-10-15.md` §1, §6): `$PIR` covers 00:1c and the tunnel DSP; under DOS firmware status `0x800001a1`, mode 3 (one configuration) |
| 4 | ~~Framework + ORICO AAGM2-U4 (ASMedia USB4 NVMe enclosure), Linux~~ **Done 2026-10-15** (`linux-orico`, §2.7) | Configuration Valid, device router operations, DROM, CL-state refusal, TMU, suspend, PCIe tunnel to NVMe confirmed. Still open: USB3 tunnel and the ASMedia NVM layout (the ORICO disables both), CL states actually enabled | ADL-55, ASM-8, ASM-14 need another USB4 device (a USB4 dock, or an enclosure with USB3 tunnelling) |
| 5 | ~~P14s + ORICO AAGM2-U4, Linux~~ **Done 2026-10-15** (`captures/P14S-ORICO-2026-10-15.md` §4) | A USB4 device behind a TB3 ICM: the Intel vendor entry exists, flags `0xa8`, UUID words in UID-high-first order, approve as for TB3, generation 4; an unapproved device falls back to USB after 9.4 s | AR-30, AR-31 for a second device |
| 6 | P14s, Linux, UEFI boot (Assist off, pre-boot off) | The UEFI counterpart of the CSM runs: DMAR opt-in and IOMMU protection (AR-12), host DROM from an EFI property (AR-52), `_OSC` differences, firmware status | AR-12, AR-52 |
| 7 | Framework, Linux, tracing from boot; optional suspend and DP steps | Cause of the boot-time disconnect after the hand-over reset (§2.6); system suspend paths (ADL-37); DP tunnel with a monitor on the dock (ADL-29); force-power state across unbind and runtime suspend (ADL-4) | ADL-4, ADL-29, ADL-37, ADL-61 |
| 8 | Framework, Windows 11 (existing script) | How the Windows CM treats the firmware's pre-OS tunnel on real hardware (compare `USB4-HOSTS.md` §3, observed only in emulation) | ADL-61 for Windows |
| 9 | P14s, system suspend (s2idle) with a device attached, Linux | Save-devices mailbox `0x05` and resume ordering | AR-22 |
| 10 | P14s, security level No Security and Secure Connect (only if the maintainer agrees to change the BIOS setting) | Level reporting, key and challenge messages | AR-41 |

Open question, not a Framework capture: **does a USB4 / Thunderbolt 4 machine that still
offers CSM run its firmware CM for an OS that never calls `_OSC`, and which message set
does it speak?** Candidates are desktop boards with a discrete Maple Ridge or Barlow
Ridge card or an ASMedia ASM4242 USB4 controller, and some early Tiger Lake laptops. If
one becomes available, run the Linux tool under CSM (firmware status, outbound mailbox
mode, which CM Linux picks) and the Windows 98 tool with a device at power-on. The
Framework's `0x000001a1` (ADL-18) is the native-`_OSC` baseline to compare against.

### 5.1 Capture-tool additions needed

Described only; the tools are not changed here. Status 2026-10-15: items 1-9 are
implemented. Item 1 had to be redone: `trace_event=thunderbolt:*` cannot enable the
events of a modular driver at boot ("Failed to enable trace event", all 2026-10-15 boot
traces empty), so the tool now verifies the boot trace and supports a traced first bind
(`modprobe.blacklist=thunderbolt`, see `tools/p14s-capture/README.md` step 2). The ICM
probe of item 4 also runs every 2 s during the unplug prompts, and PCIDUMP 1.2 falls
back to a wrap test when HIMEM cannot enable A20 (item 9 read only one of eight P14s
runs with 1.1).

Linux (`tools/p14s-capture/linux/capture-linux.sh`, `nhi_mmio_dump.py`):

1. **Boot-time tracing check.** Read `/proc/cmdline`; if `thunderbolt.dyndbg=+p` and
   `trace_event=thunderbolt:*` are absent, print a prominent warning before the first
   prompt and record "boot tracing: no" in `MANIFEST.txt`. Recommend also
   `trace_buf_size=64M`. Items 1, 2 and 7 depend on it.
2. **Unique dump labels per NHI.** With two NHIs the tool unbinds them one after the other
   and writes both dumps under the same `2-unbound` name, so the second overwrote the
   first; the `0x00000100` firmware status of ADL-4 survives only in `capture.log`. Name
   the files `2-unbound-<nhi>` and keep every dump.
3. **NHI config space per step.** Save the first 256 bytes of every NHI's PCI config
   space (sysfs `config`, read-only) next to each MMIO dump, so force power, firmware
   ready and LTR (ADL-3 to ADL-6) are seen across unbind, runtime suspend and resume.
   Today the tool saves config space only once without and once with the device.
4. **Periodic sampler (`--watch-mmio SECONDS`).** During each interactive wait, sample
   the safe register set (`0x39640`, `0x39864`, `0x39900`-`0x3990c`, `0x39944`, `0x38200`)
   plus the NHI's `power/runtime_status` and `power_state` every N seconds with
   timestamps, until the NHI disappears. Stop on all-ones. Needed for item 2.
5. **Optional suspend step (`--suspend`).** After the plug step, ask, then run
   `rtcwake -m freeze -s 15` with tracing on. Items 7 and 9.
6. **Optional DisplayPort step.** Prompt to connect a monitor to the dock and wait, so DP
   resource, DP tunnel and (on USB4) bandwidth-allocation traffic is recorded. Item 7.

Windows 98 (`tools/p14s-capture/win98/PCIDUMP.LST`, rebuilt with `gen_pcidump.py`):

7. **`$PIR` dump.** Scan `F0000h`-`FFFFFh` on 16-byte boundaries for the signature
   `$PIR`, check the table checksum, and print the header (version, size, router
   bus/devfn, exclusive IRQ bitmap, compatible router ID) and every slot entry (bus,
   device, INTA#-INTD# link value and IRQ bitmap, slot number) as hex lines. Read-only.
8. **PCI BIOS IRQ routing options.** Call INT 1Ah `B10Eh` (Get PCI Interrupt Routing
   Options) with a buffer and print the returned entries and the dedicated-IRQ bitmap.
   Compare with item 7; Windows 98 uses one or the other.
9. **Optional pre-OS NHI registers (`/N` switch).** When the NHI (`8086:15bf`) has BAR0
   assigned and memory decode enabled, read the dwords at BAR0 + `0x39640`, `0x39864`,
   `0x39904`, `0x3990c` and `0x39944` with 32-bit flat addressing (big-real mode), and
   print them. Never read `0x37800`-`0x37817`. This answers what firmware status and
   operating mode the firmware leaves for a driverless DOS / Windows 98 boot (item 3).

Windows 11: no change; run the existing `capture-win11.ps1` on the Framework (item 8).
