# Framework Laptop 13 (12th gen Intel) captures

A reference USB4 host, not a target of the xhci98 project. Collected with
`tools/p14s-capture/` on 2026-10-14 and 2026-10-15. Statements are `observed` per `AGENTS.md`.

## linux-ts3plus

Two runs with the CalDigit TS3 Plus alone. The 2026-10-14 run
(`p14s-linux-20261014-143756-framework13.tar.gz`) is the source of
`docs/USB4-HOSTS.md` §1-§4 and of `gen-adl-data.py`; the 2026-10-15 run adds a traced
first bind, suspend and a DisplayPort tunnel.

### 2026-10-14 (`p14s-linux-20261014-143756-framework13.tar.gz`)

- Kubuntu 26.04.1 live, kernel 7.0.0-38-generic, UEFI boot, Secure Boot off.
- Interactive run (rebind, unplug, plug, approve, unplug) with the CalDigit TS3 Plus
  (a Thunderbolt 3 device router) attached.
- Alder Lake-P integrated Thunderbolt 4 / USB4: two host interfaces (00:0d.2 and
  00:0d.3, two domains) and four tunnel root ports 00:07.0-07.3 (8086:466e, 463f, 462f,
  461f).
- The firmware grants native USB4 through `_OSC` (USB3, DP, PCIe, XDomain all OS
  controlled) and Linux uses its **software connection manager** on both domains. This
  is the real-hardware counterpart of the model's `usb4-generic` profile.
- An on-board retimer (8087:15ee) appears on the port with the dock.
- The trace holds about 43,000 config reads, 13,000 writes, 2,900 error notifications and
  43 hot-plug events, covering a TB3 device router behind a USB4 host. This is reference
  data for the generic host router layout and for a future "TB3 device on a USB4 host"
  feature.

### 2026-10-15, first bind (`p14s-linux-20261015-150918-fw13-ts3plus.tar.gz`)

Label `fw13-ts3plus`, SHA-256 in the `.sha256` file (the copy received was verified
against its original `.sha256` before the scrub; the file now holds the post-scrub hash).

- Installed Kubuntu 26.04.1, kernel 7.0.0-38-generic, UEFI boot, Secure Boot off,
  lockdown none. `_OSC` grants USB3, DP, PCIe and XDomain to the OS; Linux software
  connection manager on both domains, security level `user`. The TS3 Plus (Alpine Ridge
  device router `8086:15d3`, DROM vendor `0x3d`, generation 3, NVM 44.0) is on host
  adapter 3 of domain 1 (00:0d.3, tunnel root port 00:07.3), through the on-board
  retimer `1-0:3.1`, as router `1-3`. boltd has it stored (`iommu` policy) and authorised
  it on every connect.
- Options: `interactive=1 rebind=1 redact=1 watch-mmio=1 watch-tail=90 suspend=1 dp=1`.
  Boot command line `thunderbolt.dyndbg=+p
  modprobe.blacklist=thunderbolt,typec,typec_ucsi,ucsi_acpi trace_buf_size=64M`
  (`system/lsmod.txt` has neither `thunderbolt` nor `typec`). Boot tracing was
  **first-bind** (`capture-info.txt`): the script loaded the module with both NHIs held
  back, turned the tracepoints on and bound the driver, so `trace-thunderbolt.txt` starts
  with the first driver bind since power-on (57.26 s). The TB3 dock was attached at
  power-on and the firmware had set up its PCIe tunnel before the OS (dock bridges
  enumerated at 1.0 s, `7e:04.0` pciehp at 1.20 s). With no driver bound, the link of
  root port 00:07.3 went down at 3.99 s and the dock's USB controllers disconnected at
  4.30 s, so `pci/lspci-*.txt` (taken before the bind) has no dock devices; the host
  router still held that boot PCIe path (HopID 8 on 0:3 and 0:9, valid) when the driver
  first read it. `snap-1-initial` has no debugfs because the driver was not loaded yet.
- Sequence (dmesg time): first bind of 0d.2 at 56.97 s and 0d.3 at 57.28 s, host
  router reset ("0: resetting") at 57.24 s and 57.55 s, unplug event on 0:3 at 57.71 s,
  plug at 58.31 s, router 3 enumerated, PCIe tunnel 0:9 <-> 3:6 at 59.21 s; rebind of
  0d.2 then 0d.3 (83.6-88.8 s, same pattern); unplug 112.88 s; plug 137.77 s; a short
  unplug and re-plug inside the plug step at 158.51-159.22 s (re-enumerated, PCIe tunnel
  again at 160.22 s); suspend-to-idle 216.45-232.97 s (paths torn down and rebuilt on
  resume); DP tunnel 0:5 <-> 3:8 activated at 260.47 s and deactivated at 291.54 s;
  unplug 318.84 s; 90 s watch tail.
- Inside: `trace-thunderbolt.txt` (57.26-428.71 s: about 44,400 reads, 8,900 writes,
  6,500 error responses, 48 hot-plug events; 15 lines hold two interleaved records),
  `dmesg-live.txt`, `snap-*/debugfs-thunderbolt/` for `1-0`, `1-3` and the retimer
  (router, adapter, path and counter spaces, DROM), `pci/tb-complex-with-device/` (the
  dock's Alpine Ridge bridges `7d:00.0` and `7e:00.0`-`7e:04.0`, two FL1100 and an
  ASM1142 xHCI, the I210 at `82:00.0`), `mmio/` and `watch/` for both NHIs, ACPI tables.
- Redaction: the tool's redaction ran on the machine (`REDACTIONS.txt`, first section:
  USB serial numbers, MAC addresses, DMI serials and system UUID, PCIe Device Serial
  Numbers of non-Thunderbolt functions). Scrubbed on the host on 2026-10-15 with
  `tools/p14s-capture/scrub.py` (second section of `REDACTIONS.txt`, new hashes in
  `MANIFEST.txt` and the `.sha256`): the host name (1,581 occurrences in 6 files), the
  root and resume filesystem UUIDs on the kernel command line (38 occurrences in 6 files)
  and the MAC-derived Device Serial Number of the dock's I210 (`82:00.0`, raw config
  bytes, `lspci` and sysfs). Kept on purpose: the Thunderbolt router UIDs and UUIDs
  (`unique_id`, DROM UID) and the Device Serial Number of the dock's Thunderbolt bridges,
  which is derived from the router UID. Checked after the scrub: none of the found values
  remains in any member, text or binary, and only the 10 scrubbed members differ from
  the received archive.

## linux-orico

`p14s-linux-20261015-121048-fw13-orico.tar.gz` (label `fw13-orico`, SHA-256 in the
`.sha256` file, verified). Analysis: [`docs/captures/ORICO-ASM2464.md`](../../../docs/captures/ORICO-ASM2464.md).

- Installed Kubuntu 26.04.1 (not the live image), kernel 7.0.0-38-generic, UEFI boot,
  Secure Boot off, lockdown none. Linux software connection manager on both domains,
  module parameters as shipped (`clx=Y`, `host_reset=Y`, `bw_alloc_mode=Y`).
- Device: ORICO AAGM2-U4 USB4 NVMe enclosure, ASMedia ASM2464PD device router (router ID
  `174c:2463`, DROM vendor `0xb8`, "ASMedia 246x"), with an SK hynix Gold P31 NVMe
  (`1c5c:174a`) behind the ASM2464's PCIe switch (`1b21:2463` upstream and downstream
  port). Attached to USB4 port 2 of domain 1 (host adapter 3, tunnel root port 00:07.3),
  through the platform's on-board retimer (`8087:15ee`).
- Options: `interactive=1 rebind=1 redact=1 watch-mmio=1 watch-tail=90 suspend=1 dp=0`.
  Boot command line had `thunderbolt.dyndbg=+p trace_event=thunderbolt:* trace_buf_size=64M`:
  the driver's boot-time debug log is in `dmesg-live.txt`, but the boot trace buffer is
  empty (the trace event was requested before the module loaded: "Failed to enable trace
  event"), so `trace-thunderbolt.txt` starts at the rebind (71.2 s).
- Sequence (dmesg time): device attached at power-on, firmware PCIe tunnel enumerated by
  the PCI core at 1.25 s, Linux host reset at 2.32 s and re-enumeration; rebind of 0d.2
  then 0d.3 (71-75 s, with "0: resetting" again); unplug 101.3 s; plug 129.4 s (boltd
  authorised the stored device at once, so the approve step had nothing to do);
  suspend-to-idle 201.9-218.4 s; unplug 244.5 s; 90 s watch tail.
- Inside: `trace-thunderbolt.txt` (about 23,000 records: 21,800 reads, 1,400 writes, 59
  error notifications, 33 hot-plug events; 15 lines hold two interleaved records, the
  first of which is truncated), `dmesg-live.txt`, `snap-*/debugfs-thunderbolt/1-3/`
  (router and adapter registers, path and counter spaces, DROM), `pci/` (ASM2464 switch
  and NVMe config space with and without the device), `mmio/` and `watch/` for both NHIs,
  ACPI tables.
- Redaction: the tool's redaction ran (`REDACTIONS.txt`): USB serial numbers, Wi-Fi MAC
  addresses, DMI serials and system UUID, and the PCIe Device Serial Number capability of
  the NVMe and the internal SSD (text and raw config bytes zeroed). Checked by hand: no
  remaining serial number, MAC or NVMe serial (`pci/nvme-with-device.txt` lists model
  names only). This archive and the 2026-10-14 `linux-ts3plus` one were scrubbed again
  on the host on 2026-10-15 with `tools/p14s-capture/scrub.py` (second section of
  `REDACTIONS.txt`, new hashes in `MANIFEST.txt` and the `.sha256`): the host name, the
  filesystem UUIDs on the kernel command line, and (`linux-ts3plus`) the MAC-derived
  Device Serial Number of the dock's I210 NIC are removed. Kept on purpose: the
  Thunderbolt router UIDs and UUIDs (domain and device `unique_id`, DROM UID), which the
  model needs. `gen-adl-data.py` and `gen-asm2464-data.py` produce byte-identical
  headers from the scrubbed archives, and the conformance figures are unchanged.

## linux-ts3plus-orico

`p14s-linux-20261015-152339-fw13-ts3plus-orico.tar.gz` (label `fw13-ts3plus-orico`,
SHA-256 in the `.sha256` file; the copy received was verified against its original
`.sha256` before the scrub, the file now holds the post-scrub hash).

- Same machine, OS, kernel, boot command line and settings as the 2026-10-15
  `linux-ts3plus` run (installed Kubuntu 26.04.1, 7.0.0-38-generic, UEFI, Secure Boot
  off, lockdown none, software connection manager, security level `user`). Boot tracing
  was **first-bind** (`capture-info.txt`; `system/lsmod.txt` has neither `thunderbolt` nor
  `typec`); `trace-thunderbolt.txt` starts with the first driver bind (32.34 s).
- Devices: the CalDigit TS3 Plus on host adapter 3 of domain 1 (router `1-3`, Alpine
  Ridge `8086:15d3`, generation 3) and the ORICO AAGM2-U4 (ASM2464PD, router ID
  `174c:2463`, DROM vendor `0xb8`, generation 4) daisy-chained on the dock's downstream
  Thunderbolt port: router `1-303` (route `0x303`, depth 2), a USB4 device router behind a
  TB3 device router. Both links run at 20 Gb/s per lane and are bonded. PCI: 00:07.3 ->
  dock `7d:00.0` -> `7e:04.0` -> ASM2464 switch `83:00.0`/`84:00.0` -> NVMe `85:00.0`
  (SK hynix Gold P31). boltd has both devices stored (`iommu` policy) and authorised them
  on every connect.
- Options: `interactive=1 rebind=1 redact=1 watch-mmio=1 watch-tail=90 suspend=1 dp=1`.
- Sequence (dmesg time): both devices attached at power-on; the firmware's PCIe tunnels
  were up before the OS (NVMe `85:00.0` enumerated at 1.01 s and enabled at 1.65 s) and
  the link of 00:07.3 went down at 3.70 s with no driver bound. First bind of 0d.2 at
  32.06 s and 0d.3 at 32.36 s, host router reset at 32.32 s and 32.63 s, unplug event on
  0:3 at 32.82 s, plug at 33.42 s, router 3 at 33.43 s, router 303 at 34.32 s, PCIe
  tunnels 0:9 <-> 3:6 at 34.65 s and 3:7 <-> 303:3 at 34.66 s, NVMe enabled at 35.80 s;
  rebind of 0d.2 then 0d.3 (60.1-66.5 s, same pattern, NVMe at 66.53 s); unplug 87.24 s;
  plug 111.05 s, both routers and both tunnels up by 112.29 s, then a **bouncy
  re-plug**: 0:4 plug and unplug and 0:3 unplug events at 112.47 s (both tunnels torn down before the
  NVMe was enumerated), plug event on 0:3 at 113.21 s, further 0:4 plug/unplug events at
  113.22, 113.52 and 113.96 s, rescan at 114.47 s, tunnels again at 115.70 s, NVMe enabled
  at 116.82 s (trace events at lines 49077-49111 of `trace-thunderbolt.txt`);
  suspend-to-idle 170.04-187.34 s (both host routers and both device routers restored, both PCIe tunnels rebuilt at
  186.37 s); DP tunnel 0:5 <-> 3:8 (DP OUT on the dock) activated at 216.50 s and
  deactivated at 246.10 s; unplug 265.32 s; 90 s watch tail.
- Inside: `trace-thunderbolt.txt` (32.34-370.42 s: about 46,800 reads, 9,200 writes,
  6,500 error responses, 62 hot-plug events; 17 lines hold two interleaved records),
  `dmesg-live.txt`, `snap-*/debugfs-thunderbolt/` for `1-0`, `1-3`, `1-303` and the
  retimer (router, adapter, path and counter spaces, DROMs), `pci/tb-complex-with-device/`
  (dock functions as in `linux-ts3plus`, plus the ASM2464 switch and the NVMe), `mmio/`
  and `watch/` for both NHIs, ACPI tables.
- Redaction: the tool's redaction ran on the machine (`REDACTIONS.txt`, first section,
  including the NVMe's Device Serial Number). Scrubbed on the host on 2026-10-15 with
  `tools/p14s-capture/scrub.py` together with the `linux-ts3plus` run: the host name
  (1,659 occurrences in 6 files), the root and resume filesystem UUIDs (38 occurrences
  in 6 files) and the I210's MAC-derived Device Serial Number (3 members). Kept on
  purpose: Thunderbolt router UIDs, UUIDs and DROMs, and the Device Serial Number of the
  dock's Thunderbolt bridges. Checked after the scrub: none of the found values remains,
  and only the 10 scrubbed members differ from the received archive.
