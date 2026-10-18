# ThinkPad P14s Gen 1 captures

Golden data from the maintainer's real machine, collected with `tools/p14s-capture/`.
Each archive is the tool output (redacted by the tool, then scrubbed on the host with
`tools/p14s-capture/scrub.py`, see [Redaction](#redaction)) plus its `.sha256`.
Statements derived from these files are `observed` in the sense of `AGENTS.md`.

## linux-assistOFF_prebootOFF (2026-10-14)

- Kubuntu 26.04.1 live, kernel 7.0.0-38-generic, **legacy/CSM boot**, lockdown none.
- BIOS: Thunderbolt BIOS Assist off, Support in Pre Boot Environment off,
  security level `user`.
- Interactive run: driver rebind, unplug, plug, approve, unplug.
- Thunderbolt device: **CalDigit TS3 Plus** dock (generation 3, TB3), which contains two
  Fresco Logic FL1100 xHCIs, an ASMedia ASM1142 xHCI and an Intel I210 NIC behind its own
  PCIe switch.

### Facts that change the plan (observed)

- The controller is **not Titan Ridge**. It is an Intel **JHL6240 Alpine Ridge LP (2016)**:
  NHI `8086:15bf` at 05:00.0, its USB 3.1 controller `8086:15c1` at 2b:00.0. The TB
  complex hangs off PCH root port 00:1c.4 with bus range 03-2b: upstream port 03:00.0,
  downstream ports 04:00.0 (NHI), 04:01.0 (tunnel, buses 06-2a) and 04:02.0 (xHCI).
- Firmware CM is running: `FW_STS` (0x39944) = 0x800001a1 and `OUTMAIL_CMD` (0x3990c)
  = 0x800003f5 at every snapshot.
- The trace holds the ICM conversation (15 ICM commands, 15 responses, 4 events, e.g.
  driver-ready `tb_tx ICM_CMD data=[0x00000003]` answered by a two-dword response),
  plus about 53,000 config reads and 8,000 writes.

The docs were retargeted to the `tb3-alpine-ridge` profile on 2026-10-14; the decoded
wire contract is `docs/ICM-PROTOCOL.md`.

### Deliberate deviation of the model from this capture

The host router's adapter 3 is NHI-typed (it is the NHI and the router's upstream
adapter) and the dock router's adapter 5 is NHI-typed; Linux finds them by probing
adapters 3, 5 and 7 and reads NVM versions 23.0 and 44.0 through their DMA-port
mailbox. The model by default reports no NHI-typed adapter at 3, 5 or 7, so the probe
fails and no NVM attributes appear (`docs/ARCHITECTURE.md` §4.2). A read-only DMA port
that matches this capture is specified as optional requirement R20 in
`docs/ICM-PROTOCOL.md`.

## win98/ (Windows 98 SE, MS-DOS mode, CSM boot, 2026-10-14)

`CAPTURE.BAT` runs with the CalDigit TS3 Plus plugged in at power-on (except `ON_ON_NO`).
Folder name = BIOS Thunderbolt BIOS Assist / Support in Pre Boot Environment. What
`PCIDUMP.TXT` shows on the Thunderbolt side (observed):

| Run | Assist | Pre-boot | TB switch 03-04 + NHI 05:00.0 | TB xHCI 2b:00.0 (15c1) | Dock behind tunnel (15d3 switch, 2x FL1100, ASM1142, I210) |
|---|---|---|---|---|---|
| OFF_OFF | off | off | present | present | absent |
| OFF_ON | off | on | present | present | **present** |
| ON_OFF | on | off | present | absent | absent |
| ON_ON | on | on | present | absent | **present** |
| ON_ON_NO | on | on, dock unplugged | **absent** | absent | absent |
| ON_OFF_N | on | off, dock unplugged | **absent** | absent | absent |
| OFF_OFF_N | off | off, dock unplugged | present | present | absent |
| OFF_ON_N | off | on, dock unplugged | present | present | absent |

So with pre-boot support on, the firmware CM approves and tunnels the dock before any OS
runs, and a driverless Windows 98 sees the dock's PCIe devices directly. With no device
at power-on the whole controller stays powered down and invisible.

The `_N` runs settle the power question: the controller is powered down with nothing
attached only when BIOS Assist is on (`ON_ON_NO`, `ON_OFF_N`), whatever the pre-boot
setting. With Assist off it stays powered, with
the NHI and its xHCI present, whether or not a device is attached.

## linux-assistON_prebootON (2026-10-14)

Kubuntu live, BIOS Assist on, pre-boot on, interactive plug sequence.

## win11-assistOFF_prebootOFF (2026-10-14)

Windows 11 with the Intel Thunderbolt driver, Assist off, pre-boot off: PnP, drivers,
registry, ACPI tables and an ETW trace across the plug sequence.

## Session 2026-10-15: ORICO AAGM2-U4 (USB4) on the Alpine Ridge firmware CM

BIOS N2XET46W 1.36 (2026-06-02), Thunderbolt security level User Authorization, CSM
boot for every run. Settings as recorded by the maintainer:
[`bios-settings-2026-10-15.txt`](bios-settings-2026-10-15.txt). Device: ORICO AAGM2-U4
USB4 NVMe enclosure (ASMedia ASM2464PD device router, SK hynix Gold P31 inside), the same
unit as `../framework13-12th/linux-orico`. Analysis:
[`docs/captures/P14S-ORICO-2026-10-15.md`](../../../docs/captures/P14S-ORICO-2026-10-15.md).
Statements are `observed` per `AGENTS.md`.

### Linux (installed Kubuntu 26.04.1, kernel 7.0.0-38-generic)

Each folder holds the tool archive (host-scrubbed, see Redaction) and its `.sha256`.
Options `interactive=1 rebind=1 redact=1 watch-mmio=1`, `watch-tail` 90 or 120. The
kernel command line had `thunderbolt.dyndbg=+p trace_event=thunderbolt:*
trace_buf_size=64M`: the driver debug log covers the boot, but the boot trace is empty
("Failed to enable trace event: thunderbolt:*", the driver is a module), so every
`trace-thunderbolt.txt` starts at the driver rebind. The ORICO was attached at power-on.

| Folder | Assist | Pre-boot | What happened |
|---|---|---|---|
| `linux-orico-assistOFF_prebootOFF` | off | off | No PCIe tunnel at boot: the enclosure enumerated as a USB 3.2 Gen 2 UAS disk on the Thunderbolt xHCI (2b:00.0). Replug: announced through the ICM (not approved), then after 9.4 s it dropped off the fabric and came back as the USB disk again |
| `linux-orico-assistOFF_prebootON` | off | on | Tunnel built before the OS, NVMe at boot, `boot` = 1, although the enclosure was not in the boot ACL. Replug: announced, approved by boltd, tunnel, NVMe re-enumerated from reset |
| `linux-orico-assistON_prebootOFF` (label `p14s-orico_assistON`) | on | off | NHI hidden throughout; Thunderbolt xHCI present but without resources (driver probe failed). No Thunderbolt traffic; the TB bridges were removed after the final unplug |
| `linux-orico-assistON_prebootON` (label `p14s-orico_assistONprebootON`) | on | on | Tunnel before the OS, one lane only. First unplug: device-disconnected event, NHI registers all-ones 11 s later, controller removed after 15 s; the replug did not bring it back. No `watch/icm-probe.tsv` (the controller was gone before the tail watch) |

### win98-orico/ (Windows 98 SE, MS-DOS mode, 2026-10-15)

`CAPTURE <folder> N` (PCIDUMP 1.1 with `$PIR`, INT 1Ah B10Eh and `/N`), folder
`A<Assist 0/1>P<Pre-boot 0/1>_<OR = ORICO at power-on | NO = nothing attached>`. The
runs were made after the Linux runs (13:12-13:28). `ENUM.REG`, `CONFIG.TXT`,
`AUTOEXEC.TXT` and `MEM.TXT` are byte-identical in all eight runs (`ENUM.REG` is the
registry of the last Windows GUI session, not of the DOS boot). PCI presence:

| Run | Switch 03-04 | NHI 05:00.0 | TB xHCI 2b:00.0 | ORICO tree (06:00 / 07:00 `1b21:2463`, 08:00 NVMe) | `$PIR` size |
|---|---|---|---|---|---|
| A0P0_OR | present | present | present | absent | 0x120 |
| A0P0_NO | present | present | present | absent | 0x120 |
| A0P1_OR | present | present | present | **present** | 0x150 |
| A0P1_NO | present | present | present | absent | 0x120 |
| A1P0_OR | present | **absent** | present, **unconfigured** (BARs 0, command 0, line 0xff) | absent | 0x110 |
| A1P0_NO | absent | absent | absent | absent | 0xc0 |
| A1P1_OR | present | present | absent | **present** | 0x140 |
| A1P1_NO | absent | absent | absent | absent | 0xc0 |

`PCIDUMPN.TXT` holds the NHI registers only for A1P1_OR (BAR0 `e0000000`); with BAR0
at `e0100000` PCIDUMP refused ("A20 off and no XMS"), a tool limitation described in
the analysis.

### Redaction

The Linux tool's redaction ran on the machine (`REDACTIONS.txt`: DMI serials and UUID,
USB serials, MAC addresses, Device Serial Number lines). On 2026-10-15 every archive,
the Windows 11 zip and the Windows 98 folders in this directory were additionally
scrubbed on the host with `tools/p14s-capture/scrub.py`; each archive's
`REDACTIONS.txt` has a second section listing the replacements per file and category,
and its `MANIFEST.txt` / `MANIFEST.sha256` and the `.sha256` beside it carry the new
hashes. Removed by that pass:

- host names (`<HOST>`) and the Windows user name in the `.etl` trace's log file path
  (same-length `X`);
- the root and swap (resume) filesystem UUIDs on the kernel command line and in the
  systemd and ext4 messages (all-zero UUID of the same format);
- the PCIe Device Serial Number of the dock's Intel I210 NIC (`8086:1533`), which is
  derived from its MAC address: raw config bytes (`0x58`), `lspci -xxxx` hex (`58`),
  sysfs `serial_number`, and the Windows instance IDs and logs (`X`);
- the MAC address node of the Windows device container GUIDs (zeroed);
- the serial numbers of USB devices in Windows 98 `ENUM.REG` (USB sticks, card readers,
  USB NICs, a webcam, the fingerprint reader) and in the Windows 11 dump (the dock's
  card reader), as same-length `X`.

Kept on purpose: the Thunderbolt UUIDs (host, dock, ORICO, boot ACL), DROMs, and the
PCIe Device Serial Number of Thunderbolt controller functions (host `15bf`/`15c0`/`15c1`,
dock `15d3`), which is derived from the router UID and already appears in the docs.
Generated model data (`usb4-adl-data.h`, `usb4-asm2464-data.h`) and the conformance
replays are byte-identical before and after the scrub. The copyright line of the capture
script copy (`capture-linux.sh.used`) still names its author.
