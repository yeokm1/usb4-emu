# Linux guest test (software CM, `usb4-generic`)

How the roadmap M4 exit was checked with an unmodified Linux guest: a Kubuntu
26.04.1 live ISO (kernel 7.0.0-30-generic, stock `thunderbolt` module, `bolt`
daemon), booted without installing anything.

## Booting

`scripts/run-linux.sh` (foreground; run it in the background yourself):

- copies the QEMU build (default `src/qemu/build`, override with `BUILD_EXE`)
  to `vms/linux/bin` so rebuilds are not blocked;
- extracts `casper/vmlinuz` and `casper/initrd` from the ISO into
  `vms/linux/boot` (7-Zip) and boots them directly with `-kernel/-initrd`, so
  no GRUB menu has to be driven. The ISO stays read-only as an IDE CD-ROM and
  casper finds its root filesystem there;
- kernel command line: `boot=casper console=tty0 console=ttyS0,115200
  systemd.unit=multi-user.target thunderbolt.dyndbg=+p` (plus `APPEND`);
- q35, WHPX, 4 vCPUs, 4 GB, SeaBIOS, the same USB4 devices as
  `scripts/run-cm-test.sh` with one port: `usb4-tunnel-port` tp0 at 5.0,
  `usb4-host` at 4.0, `usb4-device` enc0 on port 1 with `vms/linux/nvme.qcow2`,
  `-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off`;
- QMP on 127.0.0.1:47350, serial console on 127.0.0.1:47351,
  trace in `vms/linux/usb4-trace.log`, QEMU PID in `vms/linux/qemu.pid`.

Boot to a login prompt takes about a minute under WHPX. Stop with
`python scripts/qmp.py --port 47350 cmd quit`.

## Serial console

`scripts/serial.py` is a small expect-style client for the TCP serial port:

```
python scripts/serial.py send 'kubuntu'          # live user, empty password
python scripts/serial.py send 'sudo -i'
python scripts/serial.py send 'export TERM=dumb PS1="# "; unset PROMPT_COMMAND; dmesg -n 1'
python scripts/serial.py run 'ls /sys/bus/thunderbolt/devices' [timeout]
```

`run` waits for a unique end marker, so it returns as soon as the command
finishes; it strips the OSC 3008 shell-integration sequences systemd emits.
`dmesg -n 1` keeps kernel messages off the console so they do not interleave
with command output.

## Results (2026-10-14, kernel 7.0.0-30-generic)

All observed on the console and cross-checked in the usb4 trace.

Probe (`dmesg | grep thunderbolt`):

```
thunderbolt 0000:00:04.0: using software connection manager
thunderbolt 0000:00:04.0: created link from 0000:00:05.0
thunderbolt 0000:00:04.0: security level set to user
thunderbolt 0000:00:04.0:  USB4 Switch: 46f4:4040 (Revision: 1, TB Version: 32)
thunderbolt 0000:00:04.0: 1: link: USB4
thunderbolt 0-1: new device found, vendor=0x46f4 device=0x4
thunderbolt 0-1: QEMU USB4 NVMe Enclosure
thunderbolt 0000:00:04.0: 1: link width set to symmetric, dual lanes
```

The "created link" line is the ACPI `_DSD` USB4 port reference on the tunnel
port. Lane bonding, TMU (bi-directional HiFi on the device router), credit
allocation and DROM parsing all succeed.

sysfs: `0-0`, `0-1`, `domain0`; `domain0/security` = `user`,
`domain0/deauthorization` = `1`, `domain0/iommu_dma_protection` = `0`;
`0-0` is "QEMU / USB4 Host Router"; `0-1` is "QEMU / USB4 NVMe Enclosure",
`generation` 4, `rx_speed` 20.0 Gb/s, `rx_lanes` 2, `authorized` 0 at boot
(`boltctl list` shows it connected, not stored, so bolt does not auto-authorise).

`echo 1 > /sys/bus/thunderbolt/devices/0-1/authorized`: the CM programs the
PCIe Down path 0:6 -> 1:1 -> 1:3 and the Up path 1:3 -> 0:1 -> 0:6 (HopID 8),
then pciehp reports "Button press", "Card present", "Link Up", and the QEMU
NVMe enumerates as 01:00.0; `/dev/nvme0n1` (2 GB) appears. Raw 64 MiB
O_DIRECT write and read back, and mkfs.ext4 + file copy + remount with
dropped caches: SHA-256 identical.

`echo 0 > .../0-1/authorized`: the CM deactivates both paths; pciehp reports
"Link Down", "Card not present"; 01:00.0 and `/dev/nvme0n1` are gone.
Re-authorising brings the same disk back with its data.

Physical unplug (`device_del enc0`): one Hot Unplug event on 0:1, "switch
unplugged", tunnel torn down, NVMe removed. `device_add` of a new enc0: plug
events on 0:1 and 0:2, device router enumerated and bonded again,
`authorized=0` until authorised, then the disk is back.

### Model fix needed for removal

Before commit `8df9474` (QEMU branch `usb4-linux`), `authorized=0` left the
gated NVMe endpoint in Linux. The trace showed the slot did the surprise
removal (PDS cleared, PDC set), but Linux pciehp had written Slot Control
0x17f1: with an attention button present it enables ABPE, CCIE, HPIE and
Data Link Layer State Changed Enable, not PDCE. Stock QEMU makes DLLSCE
read-only and never sets DLLSC, so no interrupt was raised. The fix makes
DLLSCE writable on the tunnel port (which advertises Data Link Layer Link
Active Reporting) and sets DLLSC when a surprise removal takes an active link
down (PCIe Base 4.0 §7.5.3.10, §7.5.3.11). Other ports are unchanged.

### Remaining observation

At boot, after Linux resets the host router and bonds the lanes, Linux
logs "0:1: switch unplugged" once and re-enumerates the device router within
about 100 ms. The events the model sends are: plug 0:1 and 0:2 on enumeration
(Spec §6.8.1.2), unplug and plug of both after the router reset, then the
Hot Unplug for the Lane 1 adapter after successful bonding that Spec §4.1.2.3
requires. On a hot plug after boot the same lane 1 unplug is ignored by
Linux ("got unplug event for disconnected port"), so this is ordering of
stale events in the guest's queue, not a lost device. The end state is
correct.

## Negative cases

The M4 exit's negative cases are not Linux-visible and are covered by the
fabric harness (`tests/usb4/fabric-test.c` in the QEMU tree): `test_evaluator`
(each missing tunnel input: path entry, adapter enable on either side,
Configuration Ready, PCIe Tunneling On keeps the tunnel down), `test_device`
(Path Enable admin-down, missing PTO, Configuration Valid cleared drops
Configuration Ready, lock bit gates control packets but not an established
tunnel) and `test_host_router` (ERR_LOCK from a locked downstream adapter).

## Alpine Ridge profile (firmware CM, `tb3-alpine-ridge`), M2 exit

Run 2026-10-14 against the QEMU branch `usb4-icm` at 5ee4f7e (usb4-emu 8a9a8ac plus the
ICM fixes), same Kubuntu live ISO and kernel 7.0.0-30.

```
PROFILE=tb3-alpine-ridge VM_DIR=vms/linux-icm QMP_PORT=47500 SERIAL_PORT=47501 \
    BUILD_EXE=src/wt-icm/build/qemu-system-x86_64.exe scripts/run-linux.sh
```

`PROFILE=tb3-alpine-ridge` adds `profile=tb3-alpine-ridge` to `usb4-host` and
`dialect=tb3` to the device router; `HOST_OPTS` appends host properties
(`,security=none`, `,msix=off`, `,rtd3=on`); `VM_DIR` keeps parallel runs apart.

Probe: `total paths: 12`, `using firmware connection manager`, `security level set to
user`, host `Thunderbolt 3 Switch: 8086:15c0`, device `8086:15d3` with its DROM read by
EEPROM bit-bang, `0-1: new device found, vendor=0x46f4 device=0x4`. With
`HOST_OPTS=,msix=off` the NHI binds with one MSI vector (`MSI: Enable+ Count=1/1`); by
default it takes the 16-vector MSI-X in BAR1 as on the P14s.

sysfs: `domain0/security` `user`, `boot_acl` 16 empty slots, `deauthorization` 0; `0-1`
`generation` 3, `unique_id` `<DROM UID, little endian>-ffff-ffffffffffff` as in the
capture, no `nvm_*` attributes (no DMA port), `authorized` 0. Names follow the device
router's DROM: with `vendor-name=CalDigit,, Inc.,model-name=TS3 Plus` Linux logs
"CalDigit, Inc. TS3 Plus" and sysfs shows the captured strings. `boltctl` lists the
device as Thunderbolt 3, 2 x 20 Gb/s.

- `echo 1 > 0-1/authorized`: the ICM programs the PCIe paths, pciehp reports card
  present and link up, the NVMe enumerates as 01:00.0, `/dev/nvme0n1` reads back a
  64 MiB O_DIRECT write with the same SHA-256.
- Driver unbind and bind (`/sys/bus/pci/drivers/thunderbolt`): mailbox driver-unloads,
  then driver-ready; the device is re-announced approved, `authorized` 1, the NVMe stays
  and keeps its data.
- `device_del enc0`: device-disconnected event, `0-1` removed, pciehp link down,
  `/dev/nvme0n1` gone. `device_add` of a tb3 `usb4-device`: announced unapproved, read
  again, authorising brings back the same disk with its data.
- `HOST_OPTS=,security=none`: domain `none`, `0-1` authorised at boot, the NVMe present
  from the first PCI scan (cold plug, no hot-plug event); unplug and re-plug come back
  authorised without user action.

Model fixes found by this run: a re-plugged tb3 router got ERR_LOCK for every config
request because the fabric set the USB4 Lock bit on the tb3 host lane adapters on
disconnect (3cc9b2c); and under `security=none` the machine reset tore down and rebuilt
the firmware tunnel, so the boot NVMe was surprise-removed and re-inserted before the
guest ran and pciehp dismissed it (5ee4f7e: tunnel evaluation is held during a fabric
reset with an ICM).

## Titan Ridge profile (firmware CM, `tb3-titan-ridge`)

Run 2026-10-15 against the QEMU branch `usb4-tr` at 178237c, same Kubuntu live ISO,
kernel 7.0.0-30. The profile is inferred from the Linux client
([ICM-TITAN-RIDGE.md](ICM-TITAN-RIDGE.md)), so this run shows the model and the Linux
Titan Ridge client agree; it says nothing about real Titan Ridge firmware.

```
PROFILE=tb3-titan-ridge DEVICE2=1 VM_DIR=vms/linux-tr QMP_PORT=48120 SERIAL_PORT=48121 \
    BUILD_EXE=src/wt-tr/build/qemu-system-x86_64.exe scripts/run-linux.sh
```

`PROFILE=tb3-titan-ridge` gives the 4C host (two Thunderbolt ports) with tunnel ports
tp0 (00:05.0) and tp1 (00:06.0); `DEVICE2=1` adds a second tb3 device router on port 2.
Boot to a login prompt took about a minute, as on the other profiles.

- Probe: lspci names the NHI "JHL7540 Thunderbolt 3 NHI [Titan Ridge 4C 2018]
  [8086:15eb] (rev 06)"; `total paths: 12`, `using firmware connection manager`,
  `security level set to user`, host `Thunderbolt 3 Switch: 8086:15ea`, `Max Port
  Number: 11`, `Upstream Port Number: 5`, ports 1-4 lane, 5 inactive (no DMA port), 6
  and 7 "not implemented", 8 and 9 PCIe, 10 and 11 DP, "linked ports 1 <-> 2" and
  "3 <-> 4".
- Titan Ridge path: the usb4 trace has no get-route command at all; both device routers
  (`8086:15d3`) are read at the route string carried in the device-connected event,
  `Route String: 0x1` for port 1 and `0x3` for port 2, and appear as `0-1` and `0-3`
  (generation 3, `authorized` 0, `unique_id` `<DROM UID>-ffff-ffffffffffff`). `boltctl`
  lists both as Thunderbolt 3, 2 x 20 Gb/s. `domain0/boot_acl` 16 slots,
  `deauthorization` 0.
- `echo 1 > 0-1/authorized` and `0-3/authorized`: 8-word approve commands, pciehp card
  present and link up on 00:05.0 and 00:06.0, NVMe 01:00.0 (`USB4EMU01`) and 0a:00.0
  (`USB4EMU02`). A 32 MiB O_DIRECT write and read-back matched (SHA-256) on both; ext4
  on `nvme0n1` with a file copy, unmount, drop caches and remount matched.
- `device_del enc1`: pciehp link down on slot 2, 3-word device-disconnected with route
  3, `0-3` removed (Linux also logs a debug-level "runtime resuming timed out" for the
  removed router, part of its disconnect handling). `device_add` of a tb3 router on port
  2: announced unapproved, re-read, authorising brings back the same data.
- Driver unbind and bind: driver-unloads, driver-ready; both routers re-announced
  approved, `authorized` 1, both NVMe disks stay.
- `BIOS=OFF_ON PROFILE=tb3-titan-ridge DEVICE2=1` (switch topology `usb4-tr-*`,
  pre-boot on, port-1 device in the boot ACL): lspci shows the Titan Ridge 4C bridges
  `8086:15ea`, the NHI behind 02:00.0, the xHCI `8086:15ec` and the port-1 NVMe from the
  first PCI scan; `0-1` `authorized` 1 and `boot` 1, `0-3` (not in the ACL) 0.
  Authorising `0-3` brings its NVMe up behind the second tunnel downstream port 02:04.0.
- `HOST_OPTS=,rtd3=on`: the NHI runtime-suspends (mailbox driver-unloads) and resumes
  with driver ready; the Titan Ridge client only refreshes the re-announced router (no
  new enumeration), and after approval the NVMe stays readable while the NHI is
  suspended.

## ASMedia ASM4242 preset (`host-model=asm4242`, public sources only)

Run 2026-10-15 against the QEMU branch `usb4-asm`, same Kubuntu live ISO and kernel:

```
HOST_MODEL=asm4242 DEVICE2=1 VM_DIR=vms/linux-asm QMP_PORT=48140 SERIAL_PORT=48141     BUILD_EXE=src/wt-asm/build/qemu-system-x86_64.exe scripts/run-linux.sh
```

The default `TOPOLOGY=switch` places the NHI, the xHCI and two tunnel downstream ports
behind the ASM4242 PCIe switch IDs; `TOPOLOGY=bridge` puts them on `pcie.0`. Linux binds
the NHI as a software-CM host (`USB4 Switch: 174c:2428`, `NVM version 200011.250708`,
device links to both tunnel ports), enumerates and bonds both device routers, and after
authorisation both NVMe disks read back what was written; deauthorisation and unplug
remove only the affected disk. Details, the two model fixes this run found, and what is
inferred: [USB4-HOSTS.md](USB4-HOSTS.md) §5.
