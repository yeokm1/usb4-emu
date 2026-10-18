# Using the PCIe tunnel bridges

How to run the gated tunnel bridges (`usb4-tunnel-port` on q35,
`usb4-tunnel-bridge` on i440FX) and force a tunnel up or down without a
connection manager. Design: `ARCHITECTURE.md` §4.4.

## q35: `usb4-tunnel-port`

```
-machine q35
-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
-drive if=none,id=nvdisk,file=nvme.qcow2,format=qcow2
-device usb4-tunnel-port,id=tp0,bus=pcie.0,addr=0x6,chassis=1,nvme-drive=nvdisk,nvme-serial=USB4EMU01
-device usb4-host,id=u4,bus=pcie.0,addr=0x4,profile=usb4-generic,tunnel-port=tp0
-device usb4-device,bus=u4.0,port=1,drive=nvdisk,serial=USB4EMU01
```

- The `-global` is required. It turns off ACPI PCI hot-plug on q35 so that
  the port's native PCIe hot-plug handles the slot. Without it QEMU warns
  at start-up and hot-plug does not reach the guest.
- **`usb4-host` must be on the root bus at an even slot, function 0**
  (`addr=0x2`, `0x4`, `0x6`, ...). Its ACPI node is QEMU's `Sxx`
  (`xx` = devfn in hex, e.g. `addr=0x4` gives `\_SB.PCI0.S20`). Windows
  requires the host interface's node name to end in a digit 0-7.
- `nvme-drive`/`nvme-serial` on the port are the fallback. When a tunnel
  comes up for a `usb4-device`, its `drive`/`serial` are used.
- Pick addresses that do not clash with other devices. In the Windows test
  VM, slot 3 is taken by `qemu-xhci`.
- The endpoint is QEMU's `nvme` at devfn 0 behind the port. It is created
  as `<port-id>-nvme<generation>`, e.g. `/machine/peripheral/tp0-nvme1`.

ACPI generated when a `usb4-host` with `profile=usb4-generic` (or no
profile) exists:

- `\_SB._OSC` grants Native USB4 Support (platform-wide UUID, DWORD 2
  bit 18) and every USB `_OSC` tunneling control (UUID
  `23A0D13A-26AB-486C-9C5F-0FFA525A575A`, DWORD 3 bits 0-3). It never
  sets Capabilities Masked.
- The port's `_DSD` contains `usb4-host-interface` (pointing at the
  host's node), `usb4-port-number` (port property `usb4-port`, default
  0), `HotPlugSupportInD3` and `ExternalFacingPort`. The last two can be
  turned off with `acpi-hotplug-in-d3=off` and `acpi-external-facing=off`.
- The port also carries a USB4 DVSEC (PCIe tunneled port) and a Device
  Serial Number capability copied from the host (`usb4-dvsec=off` removes
  them).

Verified on Windows 11: the host gets hardware ID `PCI\USB4_MS_CM` and
the inbox `Usb4HostRouter` driver is selected.

## i440FX: `usb4-tunnel-bridge` (legacy guests)

```
-machine pc
-global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
-drive if=none,id=nvdisk,file=nvme.qcow2,format=qcow2
-device usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1,shpc-autoenable=on,nvme-drive=nvdisk
```

- A `pci-bridge` with SHPC (`shpc=on` is required, and is the default).
  `usb4-host,tunnel-port=tb0` accepts it just as it accepts the q35 port.
  The endpoint sits in SHPC slot 1 (secondary-bus device 1).
- The SHPC slot state is part of the access gate. Only Enabled lets the
  endpoint be reached; Disabled and Power-only keep it gated.
- `shpc-autoenable=on` is for guests without an SHPC driver, such as
  Windows 98. It enables the slot on insertion while the slot is
  unclaimed, meaning the guest has issued no slot-state command since the
  last bridge reset. Explicit guest commands always win. With it off, the
  guest enables the slot itself through SHPC, using either the BAR or the
  config-space DWORD window; both work.
- Add `msi=off` for guests without MSI.

## Dock mode (q35 only)

A `usb4-device` with `dock=on` stands for a Thunderbolt/USB4 dock. When
its PCIe tunnel comes up the guest sees, behind the tunnel port, a PCIe
switch with three functions instead of a single NVMe:

```
usb4-tunnel-port (root port)
  x3130-upstream                 <port-id>-dock<gen>
    xio3130-downstream 0  ->  nvme       <port-id>-dock<gen>-nvme
    xio3130-downstream 1  ->  e1000e     <port-id>-dock<gen>-nic
    xio3130-downstream 2  ->  qemu-xhci  <port-id>-dock<gen>-xhci
                                 usb-storage or usb-tablet  <port-id>-dock<gen>-usb
```

```
-machine q35
-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
-drive if=none,id=nvdisk,file=nvme.qcow2,format=qcow2
-blockdev driver=qcow2,node-name=usbdisk,file.driver=file,file.filename=usb.qcow2
-netdev user,id=docknet,restrict=on
-device usb4-tunnel-port,id=tp0,bus=pcie.0,addr=0x5,chassis=1,slot=1
-device usb4-host,id=u4,bus=pcie.0,addr=0x4,tunnel-port=tp0
-device usb4-device,id=dock0,bus=u4.0,port=1,dock=on,drive=nvdisk,serial=USB4EMU01,nic-netdev=docknet,usb-drive=usbdisk
```

| `usb4-device` property | meaning |
|---|---|
| `dock=on` | dock mode. Default `off`: the single NVMe as before. |
| `drive`, `serial` | the dock's NVMe, as in single-NVMe mode. |
| `nic-netdev` | `-netdev` id for the e1000e. Absent: the NIC has no backend (link up, nothing connected). |
| `usb-drive` | **`-blockdev` node name** for a `usb-storage` on the dock's xHCI. Absent: a `usb-tablet` instead. |

- Ids only: the backends are attached by the endpoints the tunnel port
  creates on each tunnel up, and released when the dock goes away.
- `usb-drive` must be a `-blockdev` node. A `-drive` backend is deleted
  by QEMU when its `usb-storage` is unplugged (legacy auto-delete via the
  internal SCSI disk), so the next tunnel up would fail. The NVMe `drive`
  may be either; `nvme` does not auto-delete.
- QEMU warns `netdev docknet has no peer` at start-up. That is expected:
  the NIC exists only while the tunnel is up.
- Each tunnel up builds a fresh generation of the whole tree in one bottom
  half, then the root port raises one presence-detect event. The downstream
  ports have native hot-plug off (the dock's functions are fixed). A
  replacement dock waits until the previous one has released its drives.
- Removal: the gate closes synchronously and covers the whole subtree:
  DMA of every function (they inherit the tunnel port's gate address space),
  config access and INTx on every subordinate bus, and the MMIO/I/O windows
  (nested inside the tunnel port's). The upstream port is then removed, which
  removes everything below it. `USB4_TUNNEL_ENDPOINT` events carry the
  switch's generation; `DEVICE_DELETED` is emitted for each device.
- Resources: `usb4-tunnel-port` now defaults its firmware reservation
  hints to `bus-reserve=8`, `mem-reserve=8M` and `io-reserve=4K` (only
  when not set explicitly). The dock needs 5 bus numbers (switch internal
  bus plus three downstream buses below the port's secondary bus), three
  1 MiB memory windows and one I/O window for the NIC.
- `dock=on` behind `usb4-tunnel-bridge` (i440FX, SHPC) is refused with a
  warning and the NVMe alone is inserted.
- With `scripts/run-cm-test.sh`, pass `NO_DEVICE=1` and add the
  `-blockdev`, `-netdev` and `-device usb4-device,...,dock=on` arguments.

## Forcing the tunnel (no CM)

Both bridge types have a writable QOM property `tunnel`:

```
{"execute":"qom-set","arguments":{"path":"/machine/peripheral/tp0","property":"tunnel","value":"up"}}
```

HMP: `qom-set /machine/peripheral/tp0 tunnel up`.

| value | effect |
|---|---|
| `up` | gate opens and a fresh `nvme` (or dock) is hot-plugged. Uses the `usb4-device` on the host USB4 port this bridge backs if there is one, otherwise `nvme-drive`. |
| `down` | admin-down. The gate closes immediately, then quiesce and **surprise removal** (default, see below) |
| `eject` | the gate closes immediately, then quiesce and an **orderly eject request** to the guest. If the guest does not complete it, the endpoint is removed after `eject-timeout-ms` (default 10000) |
| `surprise` | the gate closes immediately, then quiesce and surprise removal |

Other properties:

- `x-force-tunnel=on`: the tunnel is up from power-on. The endpoint is
  cold-plugged, so firmware enumerates it.
- `settle-ms` (default 2000): after a removal, a replacement waits until
  the guest acknowledges the empty slot or this timeout expires.
- `orderly-admin-down=on`: makes `down` (and CM admin-down) use the eject
  request, as `eject` does.
- `endpoint` (read-only): e.g. `live gen=2 gate=open`.
- `x-hold-deferred=on|off`: a test hook. While on, the deferred stages
  (quiesce, notify, remove, insert) are held, so the gate can be probed in
  between.

## QMP event

`USB4_TUNNEL_ENDPOINT { qom-path, generation, stage }` is emitted at each
lifecycle step:

- `gated`: stage 1, the access gate has closed.
- `cutoff`: the endpoint has been reset and drained. After this event,
  guest memory no longer changes on the endpoint's behalf.
- `eject-requested`
- `removed`
- `settle-timeout`
- `gate-open`
- `inserted`
- `insert-failed`

`DEVICE_DELETED` follows `removed` for the endpoint.

## Tracing

`-trace 'usb4_tp*' -trace 'usb4_tb*' -trace 'usb4_acpi*' -D trace.log`
logs state changes, the deferred stages, gate toggles and Slot Control
writes. Add `-trace 'pcie_cap_slot*'` or `-trace 'shpc*'` for the stock
slot machinery.

## Known limitation: orderly eject on Windows

The gate closes before any eject request (gate before you unplug), so the
guest cannot reach the device while it handles the request. On Windows 11
with a mounted volume, the eject request is never completed and the
timeout forces removal. Windows then leaves the slot powered off with the
power indicator on, and ignores the next insertion until a surprise
removal resets its slot state. For this reason:

- `down` (admin-down) uses surprise removal by default. This matches real
  hardware: tearing down a PCIe tunnel drops the link. Windows handles it
  cleanly, and reconnecting works repeatedly. Verified: the NTFS volume
  and file hash survive up/down/surprise cycles.
- `eject` is still available but has the problem above.
- On insertion, the port withdraws the stock Attention Button Pressed if
  the power indicator is not off, because Windows treats it as an eject
  request there.
- A tunnel that comes up while Windows is still booting is hot-inserted
  before Windows has initialised the port's hot-plug controller, and
  Windows leaves the slot unpowered. While a hot-inserted endpoint has
  never been powered, the port re-raises Presence Detect Changed plus the
  attention button each time the guest re-arms Hot-Plug and Attention
  Button interrupts. It does this at most 3 times (trace
  `usb4_tp_power_retry`). With this, the CM-driven NVMe appears on a cold
  boot with no manual step.
