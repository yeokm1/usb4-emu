# USB3 tunneling: QEMU USB devices behind a device router

Roadmap M7. A USB device (QEMU `usb-storage`, `usb-mouse`, a `usb-hub` with devices
behind it) on a QEMU `qemu-xhci` stands for what sits behind a dock's or an enclosure's
USB3 Gen X Upstream adapter. It is on the xHCI only while a connection manager has the
USB3 tunnel to that device router up, and leaves the xHCI when the tunnel goes down: the
CM's teardown, an unplug of the router, a cable pull, a host router reset, a system
reset. The guest's xHCI driver sees ordinary connects and disconnects on its root ports;
no xHCI register reflects the tunnel.

Code: `hw/usb4/usb4-fabric-usb3.c` (when the tunnel is up), `hw/usb4/usb4-usb3.c`
(attach and detach of the USB devices, the ACPI `_DSD`), the USB3 adapter registers in
`hw/usb4/usb4-router.c`, `preos-usb3` in `hw/usb4/usb4-preos.c`. Test:
`tests/qtest/usb4-usb3-test.c` (9 cases, below).

## 1. Properties

| Object | Property | Type | Effect |
|---|---|---|---|
| `usb4-device` | `usb3-dev` | string | `:`-separated ids of USB devices behind this router's USB3 Up adapter. Each is kept detached from its xHCI port (the port stays claimed) except while the USB3 tunnel to this router is up. A named `usb-hub` takes every device behind it along. Refused on a `dialect=tb3` router, on `device-model=asm2464`, behind a `dialect=tb3` parent and on a firmware-CM host (section 5) |
| `usb4-device` | `x-usb3-tunnel` | string, read | `up\|down reason=up\|admin-down\|eject\|surprise ups=N downs=N attached=id:1 id2:0`: the tunnel as the fabric last reported it, the transitions seen since realize, and whether each `usb3-dev` device is on its port now (`-` if no such device) |
| `usb4-host` | `usb3-xhci` | string | Id of the `qemu-xhci` whose SuperSpeed root ports the host's USB3 Down adapters feed. ACPI only: the `_DSD` with `usb4-host-interface` and `usb4-port-number` on that port, which Windows 11's CM wants (Microsoft "USB4 ACPI requirements"). Both devices on the root PCI bus |
| `usb4-host` | `usb3-port1`, `usb3-port2` | uint32 | QEMU USB port on `usb3-xhci` for USB4 port 1 / 2 (0: none). `qemu-xhci` shows QEMU port n as USB2 port n and SuperSpeed port `p2` + n |
| `usb4-host` | `preos-usb3` | bool | With `preos-cm=on`: the pre-OS firmware CM also builds a USB3 tunnel to every device router with a USB3 Up adapter (section 4). Default off |

`usb3-dev` names the devices; it does not check which xHCI port they are on. Put them on
the port `usb3-portN` names for the router's host port (behind a daisy chain: the host
port the chain hangs off), as real hardware wires USB3 Down adapter p to one root port.
Create them on the command line: a USB device added later with `device_add` attaches at
once and is gated only from the next transition of its router's tunnel.

Example (i440FX, generic profile, an enclosure with a disk and a hub with a mouse):

```
-device qemu-xhci,id=xhci,bus=pci.0,addr=0x5
-drive if=none,id=ud,file=usb.img,format=raw
-device usb-storage,id=stor0,bus=xhci.0,port=1,drive=ud
-device usb-hub,id=hub0,bus=xhci.0,port=2
-device usb-mouse,id=m0,bus=xhci.0,port=2.1
-device usb4-host,id=u4,bus=pci.0,addr=0x4,msi=off,msix=off,usb3-xhci=xhci,usb3-port1=1
-device usb4-device,id=enc0,bus=u4.0,port=1,usb3-dev=stor0:hub0
```

`scripts/run-cm-test.sh` with `USB3=1` sets the same up on q35 for Windows 11.

## 2. What the connection manager must do

The tunnel is up when all of these hold (Connection Manager Guide 2.0 section 5.5,
USB4 Specification 2.0 Table 8-14 and section 9.1.2), and down as soon as one stops:

1. The device router is connected and lane 0 of its upstream link is in CL0.
2. The parent (host router: enumerated; device router in a chain: as in 3) is ready,
   and the device router has Configuration Valid, Configuration Ready and USB3
   Tunneling On (ROUTER_CS_5 bit 25; Guide 3.2.3 "must set USB3 Tunneling").
3. HopID 8 paths both ways between the parent's USB3 Gen X Down adapter for that port
   and the router's USB3 Gen X Up adapter, with buffers (credits or ISE) at each lane
   ingress. The lane HopIDs are the CM's choice (not 8 in the qtest).
4. Path Enable (ADP_USB3_GX_CS_0 bit 31) on both USB3 adapters.
5. In a daisy chain, the parent's own USB3 tunnel is up.

Registers as the model answers them:

| Register | Model |
|---|---|
| ADP_USB3_GX_CS_0 | Path Enable and Valid (bits 31:30) writable on both adapters |
| ADP_USB3_GX_CS_1 | Host Controller Ack (bit 31) follows Connection Manager Request at once; Consumed Up/Down Bandwidth read 0 (no USB device books bandwidth) |
| ADP_USB3_GX_CS_2 | Connection Manager Request (bit 31) and Allocated Up/Down Bandwidth (23:0) writable on the Down adapter; hardwired 0 on the Up adapter |
| ADP_USB3_GX_CS_3 | Scale (5:0) writable on the Down adapter |
| ADP_USB3_GX_CS_4 | Max Supported Link Rate 20 Gb/s (bits 18:12 = 1); while the tunnel is up USB3 Link Valid (bit 7), Actual Link Rate 10 Gb/s (0) and link state U0 (0); `host-model=intel-adl` keeps its captured idle value while down |

The bandwidth handshake is not a condition: a CM that skips it gets the tunnel too.
xHCI98's `tbt_u4cm.c` (`tbtU4Usb3Tunnel`: the 500 ms gap after a teardown, the
handshake, paths at weight 2, Path Enable with Valid on the Down adapter then the Up
adapter) and the Windows 11 CM both work against it; the qtest follows the same order.

**Teardown** (Guide 5.5.2): the first write that breaks a condition, normally Path
Enable cleared on the Down adapter, takes the tunnel down inside that write. The USB
devices are detached in the same call (the gate, AGENTS.md "Gate before you unplug"):
the xHCI reports the disconnect and cancels their transfers, as for a guest port
disable. Clearing Valid, the paths and the bandwidth afterwards is cleanup the model
does not check.

**Setup timing**: the devices are attached from a bottom half right after the write
that completed the conditions (never from MMIO context), so the xHCI's port status
change event follows the CM's write by one main loop iteration. Real hardware takes a
USB3 link training time here; the model takes none.

## 3. Unplug, resets and faults

| Event | USB3 tunnel | USB devices |
|---|---|---|
| CM clears Path Enable or a path | down, `admin-down` | detached at once |
| `device_del` of the `usb4-device` | down, `surprise` | detached at once; a re-added router starts with the tunnel down |
| `x-cable=false` ([FAULTS.md](FAULTS.md)) | down, `surprise` | detached at once; `x-cable=true` plugs the router back with the tunnel down |
| A parent in the chain unplugged | down | detached |
| `x-host-reset=router`, or a rule's `host-reset` | down | detached; the CM restarts and builds again |
| System reset | down (the fabric is reset) | detached; with `preos-usb3` the firmware rebuilds it |

Fault rules combine with it as with the PCIe tunnel. `pdf=write route=1
act=drop+unplug dev=enc0`, set just before the CM's last Path Enable write, gives a
write that took effect (the tunnel came up) whose reply never comes, with the router
gone behind it: the CM gets the hot unplug instead of its reply and the devices end
detached. The qtest checks that and a rule-fired host router reset with the tunnel up.

## 4. `preos-usb3`: a USB3 tunnel built before the OS

With `preos-cm=on,preos-usb3=on` the emulated platform firmware (`usb4-preos.c`,
[USB4-HOSTS.md](USB4-HOSTS.md) section 3) also sets USB3 Tunneling On with PCIe
Tunneling On, does the bandwidth handshake (scale 0, 275 units = 9000 Mb/s each way),
programs the USB3 paths at weight 2 with lane HopIDs 10 (down) and 11 (up), next to the
PCIe tunnel's 8 and 9, and sets Path Enable with Valid on the Down adapter, then the Up
adapter. The USB devices are on the xHCI before the OS starts, as after a BIOS that
boots from USB behind a dock. The OS CM finds the tunnel in config space (Guide 4.2,
discovery of existing tunnels; xHCI98's `tbtU4Follow` for USB3) and may keep it or tear
it down. Without `preos-usb3` the firmware builds no USB3 tunnel, as before.

## 5. Thunderbolt 3 and the firmware CM

A Thunderbolt 3 router has no USB3 adapters. USB reaches a TB3 dock through the PCIe
tunnel, to the dock's own xHCI: `usb4-device dialect=tb3 dock=on usb-drive=<node>`
(q35, `usb4-tunnel-port`) puts a `qemu-xhci` with a `usb-storage` (or a tablet) in the
dock's PCIe switch. It comes and goes with the PCIe tunnel, so under the firmware CM
it follows the ICM: on the approve (Alpine Ridge, Titan Ridge with `security=user`) or
at plug (Ice Lake, security none), and it is gone at device disconnected.

The firmware-CM profiles here (`tb3-alpine-ridge`, `tb3-titan-ridge`, `tb3-ice-lake`)
model Thunderbolt 3 host routers (the Ice Lake one is read as generation 3 by Linux,
[ICM-ICE-LAKE.md](ICM-ICE-LAKE.md) section 4), so they have no USB3 Down adapter and
`usb3-dev` is refused on them. This is what xHCI98's ICM client assumes: its status
record reports no USB3 tunnel on the Falcon, Alpine and Titan Ridge rows (`IcmNoUsb3`,
`src\cm\cm_statos.c`) and "not known" on the Ice Lake row, whose real hosts include
Tiger Lake and Alder Lake integrated USB4 hosts under the ICM, where the firmware does
build USB3 tunnels to USB4 devices [ext]. That firmware (a USB4-generation ICM host
with USB3 Down adapters) is not modelled; the roadmap lists it under "Other Intel ICM
generations".

## 6. Not modelled

- USB 2.0 over the Type-C USB 2 pair: on real hardware a USB 2.0 device in a dock
  stays connected without a USB3 tunnel. Here every `usb3-dev` device, USB 2.0 ones
  and a `usb-hub` included, follows the tunnel.
- USB3 link training time, link power states (U1-U3), Consumed Bandwidth from the
  xHCI, and the bandwidth limit (the allocated bandwidth is stored, not enforced).
- A check that the `usb3-dev` devices sit on the root port `usb3-portN` names.

## 7. Tests

`tests/qtest/usb4-usb3-test.c` (2026-10-22), 9 cases, all on the model alone (no guest):

| Case | What |
|---|---|
| `setup-data-teardown` | i440FX, software CM over ring 0: the disk absent until the last Path Enable write, then on a SuperSpeed root port; an xHCI driver in the test addresses it, reads its device descriptor (46f4:0001) and sector 0 with bulk-only SCSI (TEST UNIT READY, READ(10)), compared with the image; teardown detaches it at the first write; built again, sector 1 read |
| `surprise-unplug` | `device_del` with the disk addressed: gone, hot unplug event; `device_add` again: the disk stays away until the CM builds the tunnel; `x-cable` false/true the same |
| `fault-rule` | `pdf=write route=1 act=drop+unplug dev=enc0` on the last Path Enable write: no reply, hot unplug, the tunnel up then down (`ups=1 downs=1`), disk detached; replug and rebuild; then `pdf=read route=0 act=host-reset` with the tunnel up: down, rings disabled, the CM restarts and rebuilds |
| `hub` | `usb3-dev=stor0:hub0` with a `usb-mouse` behind the hub: all three follow the tunnel |
| `system-reset` | tunnel down and disk gone after `system_reset`, rebuilt afterwards |
| `preos` | `preos-usb3=on`: the disk on the xHCI with no guest CM, USB3 Tunneling On, Path Enable and Valid, paths and bandwidth readable; the OS CM tears it down; without `preos-usb3` no tunnel |
| `refused` | `usb3-dev` with `dialect=tb3`, with `device-model=asm2464`, behind a TB3 parent, on a `tb3-alpine-ridge` host |
| `icm-dock-ar`, `icm-dock-icl` | TB3 dock (`dock=on usb-drive=`) under the Alpine Ridge firmware CM (driver ready, device connected, approve) and the Ice Lake one (tunnel at plug): the dock's xHCI behind the tunnel port and switch, its disk addressed and sector 1 read; `x-cable=false` closes the gate at once and removes the dock's functions |

Guest exits owed (roadmap M7): a USB device behind the tunnel on the xHCI in Linux
(software CM, `usb4-generic`) and Windows 11 (the Windows 11 half was shown on
2026-10-14 with `USB3=1`), and suspend and resume keeping the device relations.
