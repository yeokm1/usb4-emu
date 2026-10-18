# Re-enumeration experiment: can a driver make Windows 98 SE / 2000 see a tunnel change?

For the xhci98 project. When a USB4/TB tunnel comes up or goes down, the endpoint appears
or disappears behind a PCI-to-PCI bridge whose child bus belongs to the OS PCI bus driver
(Windows 98: PCI.VXD under CONFIGMG; Windows 2000: pci.sys). Neither system has an SHPC
driver, so neither notices on its own. Question: can a kernel-mode driver, with no
user-mode EXE, make the OS (1) enumerate a newly tunnelled endpoint and (2) drop a removed
one?

Test code (throwaway, GPL-2.0-only): [tools/reenum-test](../tools/reenum-test/README.md). Run on
2026-10-14.

## Answer

**Driver-only is feasible on both systems, but with a different mechanism on each.**

| | New endpoint enumerated | Stale endpoint dropped | Side effects |
|---|---|---|---|
| **98 SE, B**: WDM driver calls CONFIGMG `Reenumerate_DevNode` on the bridge devnode (VxD dynalink from a system thread) | **Yes**: NVMe devnode created, nvme9x loaded, volume mounted, Explorer AutoPlay opened it | **Yes**: `Query_Remove_SubTree` + `Remove_SubTree` (both CR_SUCCESS), then reenumerate; volume gone ("F:\ is not accessible"). Re-up (generation 2) re-enumerates cleanly | None seen. No reboot, no hang, no prompts |
| 98 SE, A: WDM filter on the bridge + `IoInvalidateDeviceRelations` | No | No | **Harmful**: a WDM stack on the bridge devnode stops PCI.VXD from enumerating behind it, even for `CM_Reenumerate_DevNode` |
| 98 SE, C: `CM_Reenumerate_DevNode` (CFGMGR32 EXE) | Yes | Yes (a bridge reenumerate drops the vanished child) | None |
| **2000, A**: upper filter on the bridge + `IoInvalidateDeviceRelations(BusRelations)` | **Yes**: pci.sys reports the NVMe, nvme2k loads, F: mounts | **Yes**: pci.sys reports it missing, surprise removal | "Unsafe Removal of Device" dialog on every down. Filter must be boot-start if installed as a class filter (else STOP 0x7B) |
| 2000, C: `CM_Reenumerate_DevNode` (CFGMGR32 EXE) | Yes | Yes (after a scan; the stale devnode stays until then) | Same Unsafe Removal dialog |
| 2000, B | n/a (no CONFIGMG) | | |

Recommendation for the xhci98 CM driver:

1. **Windows 98 SE**: the CM driver is a WDM function driver on the host interface (NHI)
   devnode. On a tunnel change it calls CONFIGMG directly (VxD service 0033h through the
   `INT 20h` dynalink, from a PASSIVE_LEVEL system thread): `Locate_DevNode`, find the
   tunnel bridge's devnode (walk with `Get_Child`/`Get_Sibling`/`Get_Device_ID`, match
   `PCI\...\BUS_bb&DEV_dd&FUNC_ff`), then `Reenumerate_DevNode(bridge, 0)`. On a tunnel
   down, optionally `Query_Remove_SubTree` + `Remove_SubTree` on the bridge's children
   first; a plain reenumerate also dropped a vanished child here. **Never attach a WDM
   driver to the bridge devnode on Windows 98.**
2. **Windows 2000**: the CM driver needs the bridge's PDO, which only a driver in the
   bridge's stack has. Ship a small upper filter for the tunnel bridge (device-specific
   `UpperFilters` from an INF matching the bridge's hardware ID, or a System-class filter
   that attaches only to bridges and is boot-start) and have it call
   `IoInvalidateDeviceRelations(Pdo, BusRelations)` when the CM driver says a tunnel
   changed (or poll as the test filter did). pci.sys then does the rest.
3. One binary can do both: `IoIsWdmVersionAvailable(1, 0x10)` is FALSE on Windows 98
   (WDM 1.00) and TRUE on 2000, as xhci98 already uses.
4. No user-mode EXE is needed. The CFGMGR32 EXE works on both systems as a fallback.

## Setup

- Models: generic profile, i440FX, `usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,
  chassis_nr=1,shpc-autoenable=on,msi=off`, `usb4-host ... msi=off,msix=off`, a
  `usb4-device` with an NVMe (overlay of `vms/win98/nvme32.qcow2`, FAT32). Tunnel toggled
  with QMP `qom-set /machine/peripheral/tb0 tunnel up|down` (`down` is surprise removal).
- Windows 98 SE: overlay of `vms/win98/win98.qcow2` in `vms/win98-reenum/` through
  `scripts/run-win98.sh` (TCG, `pentium3,-apic`), QEMU copy from `vms/win98/bin`
  (integrated build of 08:09 that day). NVMe driver: QuickInstall's nvme9x.
- Windows 2000 SP4: overlay of `vms/win2k/win2k-xonly.qcow2` in `vms/win2k-reenum/`,
  `pc,acpi=off`, `pentium3,-apic`, 256 MB (the xhci98 Win2000 xHCI-only VM's flags),
  QEMU copy from `vms/win98/bin` (single bridge) and `vms/win2k/bin` (Alpine Ridge tree).
  NVMe driver: nvme2k 1.2.0.0 (`tools/third-party/nvme2k`), installed by the Found New
  Hardware wizard the first time the NVMe was enumerated.
- `reenum.sys` polls the bridge's secondary bus (vendor ID of function 0 of each device,
  config mechanism #1) every 500 ms and logs to the QEMU debug console (`-debugcon`,
  port 0xE9). Built with MSVC 6.0 + Windows 2000 DDK from the xhci98 tree, run in place
  (`tools/reenum-test/build.cmd`). Imports: 22 `ntoskrnl.exe` names, all present in
  98 SE's NTKERN.
- Evidence: `vms/win98-reenum/debugcon-r1.keep.log` (A, B, C on 98),
  `debugcon-r2.log` (B with the registry install), `trace-r*.log` (tunnel and `pci_nvme_*`
  traces); `vms/win2k-reenum/debugcon-r1.keep.log` (A on 2000), `debugcon-ar1.log`
  (Alpine Ridge tree). These are local (`vms/` is git-ignored); the relevant lines are
  quoted below.

## Windows 98 SE

### Getting a WDM driver loaded

- On the `usb4-host` devnode: `reenum98.inf` (`DevLoader=*ntkern`, `NTMPDriver=reenum.sys`)
  installed through the Add New Hardware wizard, or the same values written by `b98.reg`
  plus a copy of the `.sys` and a restart. Both work. The registry path needs the `Driver`
  value under `HKLM\Enum\PCI\...` to name a new `System\NNNN` class key; Windows 98's
  regedit writes it.
- `DriverEntry` gets `RegistryPath = System\CurrentControlSet\Services\Class\System\0029`
  (the driver key), not a Services key.
- `IoGetDeviceProperty(DevicePropertyBusNumber/Address)` work on 98 (the bridge filter
  read 00:05.0).

### Mechanism B (CONFIGMG from the WDM driver): works

The driver builds a 6-byte thunk in non-paged pool, `CD 20 <service | 8000h> 0033h`
(VMM dynalink with the jump bit, so a cdecl call reaches the service with the caller's
arguments) and calls it from its polling thread. Service numbers are the Windows 95/98
DDK's CONFIGMG table (0 Get_Version, 2 Locate_DevNode, 4 Get_Child, 5 Get_Sibling,
7 Get_Device_ID, 12 Query_Remove_SubTree, 13 Remove_SubTree, 51 Reenumerate_DevNode,
54 Get_DevNode_Status). They were checked at run time: `Get_Version` returned 040Bh, the
root devnode's ID read back as `HTREE\ROOT\0`, and `Get_DevNode_Status` of the NVMe gave
the same value (18086ACEh) as `CM_Get_DevNode_Status` from the EXE. The DDK headers are not
on this machine (`D:\isos\1830_usa_ddk.iso` is the Server 2003 SP1 DDK, which has no VxD
headers), so the numbers are from the DDK documentation as remembered and verified as
above.

```
[reenum] poll start role=00000002 mode=00000002 bridge 00000000:00000005.00000000 sec=00000001 mask=00000000
                                      (qom-set tunnel up)
[reenum] presence change sec=00000001 00000000 -> 00000002
[reenum] bridge devnode C29AEA90 PCI\VEN_1B36&DEV_0001&SUBSYS_00000000&REV_00\BUS_00&DEV_05&FUNC_00
[reenum]   children: 00000000
[reenum] Reenumerate_DevNode(bridge) cr=00000000
[reenum] bridge children 3 s later:
[reenum]   child dn=C1C872F0 status=18086ACE problem=00000000 PCI\VEN_1B36&DEV_0010&SUBSYS_11001AF4&REV_02\082800
                                      (qom-set tunnel down)
[reenum] presence change sec=00000001 00000002 -> 00000000
[reenum] removed PCI\VEN_1B36&DEV_0010&SUBSYS_11001AF4&REV_02\082800 query cr=00000000 remove cr=00000000
[reenum] Reenumerate_DevNode(bridge) cr=00000000
[reenum]   children: 00000000
```

- Up: QEMU trace shows nvme9x's controller bring-up and reads (`pci_nvme_*`, 164 events);
  Explorer AutoPlay opened "Nvme32 (F:)". Down: refreshing that window gives "F:\ is not
  accessible". Up again: generation 2 inserted after the settle timeout (Windows 98 never
  acknowledges the empty slot), enumerated with its BAR assigned and F: back. Repeated
  with the registry-installed driver (r2): same.
- A DOS box with `copy con F:\HOLD.TXT` in progress during the down: Query_Remove was not
  vetoed, and finishing the copy gave "Path not found". `copy con` probably opens the file
  only at the end, so a real open-handle veto was not tested.
- The NVMe's instance ID on 98 is `082800`, not `BUS_01&DEV_01&FUNC_00`, so the driver
  matches vanished children by `VEN_&DEV_` against what is still on the bus.

### Mechanism A (WDM filter on the bridge): not possible

- The bridge's driver key (`System\0028`, from MACHINE2.INF `PCI_BRIDGE_DRV`) has **no
  DevLoader**: PCI.VXD enumerates the bridge's child bus itself.
- `UpperFilters="reenum.sys"` on the bridge's hardware key: never loaded (no AddDevice for
  the bridge across a restart). NTKERN only builds a WDM stack for a devnode it is the
  device loader of.
- `DevLoader=*ntkern` + `NTMPDriver=reenum.sys` on the bridge's driver key: the driver
  loads on the bridge (and the `UpperFilters` copy is then honoured too, two instances).
  `IoInvalidateDeviceRelations(BusRelations)` makes NTKERN send
  `IRP_MN_QUERY_DEVICE_RELATIONS(BusRelations)` to that stack, which completes with no
  relations; PCI.VXD is not asked. Worse, with NTKERN as the bridge's loader,
  `CM_Reenumerate_DevNode(bridge)` from the EXE also finds nothing: the NVMe never
  appears. The bridge devnode is effectively broken while the WDM driver owns it.

```
[reenum] presence change sec=00000001 00000000 -> 00000002
[reenum] IoInvalidateDeviceRelations(BusRelations) called
[reenum] QUERY_DEVICE_RELATIONS(Bus) role=00000001
[reenum] QUERY_DEVICE_RELATIONS(Bus) done st=00000000 count=FFFFFFFF   (no relations)
cmreenum scan: CM_Reenumerate_DevNode -> 0, 0 child(ren)
```

### Mechanism C (CFGMGR32 EXE): works

`cmreenum scan` (find the bridge by ID prefix, `CM_Reenumerate_DevNode(bridge, 0)`)
enumerates the NVMe. After a tunnel down the NVMe devnode stays (`cmreenum list` shows it,
status unchanged) until a reenumerate: both `cmreenum scan` and Device Manager Refresh
removed it in this run. That differs from [WIN98-TEST.md](WIN98-TEST.md) "Tunnel down, and
up again", where Refresh kept the stale NVMe (different model build and sequence; not
investigated further).

## Windows 2000 SP4

### Baseline

Tunnel up with nothing installed: the bridge has 0 children (`cmreenum list`); Windows
does nothing.

### Mechanism C (CFGMGR32 EXE): works

`cmreenum scan` enumerated the NVMe (`PCI\VEN_1B36&DEV_0010&...\3&269A81A1&0&0828`), the
Found New Hardware wizard installed nvme2k, and F: (NVME32) listed. Tunnel down: the
devnode stays (status 0180200Ah) until `cmreenum scan`, which removes it; Windows then
shows "Unsafe Removal of Device" (NVMe Storage Controller, QEMU NVMe Ctrl SCSI Disk).
Up + scan: F: back.

### Mechanism A (bridge upper filter + IoInvalidateDeviceRelations): works

Installed as a System-class upper filter (the values in `filter2k.reg`, typed in by hand on the VM; the default ImagePath was used); `AddDevice` attaches only to
PDOs with compatible ID `PCI\CC_0604` and returns success without attaching otherwise.

- **The service must be boot-start (`Start=0`).** With `Start=3` the next boot stopped with
  `STOP 0x7B INACCESSIBLE_BOOT_DEVICE`: the PCI bus is System class and could not start
  without its class filter. Recovered with Last Known Good. A device-specific
  `UpperFilters` on the bridge (from an INF) avoids touching every System device.

```
[reenum] AddDevice hwid=PCI\VEN_1B36&DEV_0001&SUBSYS_00000000&REV_00
[reenum] attached role=00000001 mode=00000001 bridge 00000000:00000005.00000000
                                      (qom-set tunnel up)
[reenum] presence change sec=00000001 00000000 -> 00000002
[reenum] QUERY_DEVICE_RELATIONS(Bus) role=00000001
[reenum] QUERY_DEVICE_RELATIONS(Bus) done st=00000000 count=00000001
[reenum] IoInvalidateDeviceRelations(BusRelations) called
                                      (qom-set tunnel down)
[reenum] presence change sec=00000001 00000002 -> 00000000
[reenum] QUERY_DEVICE_RELATIONS(Bus) done st=00000000 count=00000000
```

- Up: nvme2k started, F: listed, no user action. Down: surprise removal and the Unsafe
  Removal dialog. Two full down/up cycles: same each time.
- A pending Found New Hardware wizard (here the driverless `usb4-host`, "Universal Serial
  Bus (USB) Controller") holds back installation of the next new device: the NVMe's disk
  child did not get F: until that wizard was cancelled. A real deployment has drivers for
  everything, but a CM driver should not assume the volume appears immediately.

### Alpine Ridge switch topology (2000, mechanism A)

`TOPO=ar tools/reenum-test/run2k.sh` (root bridge 00:1c.0, switch upstream 01:01.0
`8086:15C0`, downstream ports 02:00.0 / 02:01.0 (tunnel) / 02:02.0, NHI behind 02:00.0,
`profile=tb3-alpine-ridge`, QEMU from `vms/win2k/bin`). The class filter attached to all
five bridges; the tunnel bridge 02:01.0 has secondary bus 4.

```
[reenum] presence change sec=00000004 00000000 -> 00000002
[reenum] QUERY_DEVICE_RELATIONS(Bus) done st=00000000 count=00000001
[reenum] IoInvalidateDeviceRelations(BusRelations) called
cmreenum list "PCI\VEN_1B36&DEV_0010": PCI\VEN_1B36&DEV_0010&SUBSYS_11001AF4&REV_02\5&4178E3E3&0&080808E0
                                      (qom-set tunnel down)
[reenum] presence change sec=00000004 00000002 -> 00000000
[reenum] QUERY_DEVICE_RELATIONS(Bus) done st=00000000 count=00000000
cmreenum list "PCI\VEN_1B36&DEV_0010": no devnode
```

The one level deeper slot behaves the same. (The NVMe at the new location was waiting on
the Found New Hardware wizard, so no volume was checked there.) Windows 98 was not run on
this topology; mechanism B only needs the tunnel bridge's devnode ID, which on 98 is
`PCI\VEN_8086&DEV_15C0...\BUS_02&DEV_01&FUNC_00` by the same naming.

## Caveats

- The experiment polls config space with mechanism #1 directly, with interrupts disabled
  around the address/data pair (uniprocessor guests). A product driver should get presence
  from its CM (the tunnel state it set up) rather than racing the OS for CF8/CFC.
- CONFIGMG was called from a WDM system thread (system VM, ring 0, PASSIVE_LEVEL). No
  appy-time deferral was needed for any call used here, including `Remove_SubTree` of a
  devnode with a mounted volume.
- Windows Me was not tested. Windows 98's IoInvalidateDeviceRelations behaviour on a
  devnode NTKERN does not load (a PCI.VXD bridge) cannot be reached at all: a WDM driver
  has no PDO for it.
- Unsafe-removal dialogs on 2000 come with surprise removal. An orderly path (CM asks the
  OS to remove the endpoint before tearing the tunnel down, e.g. `IoRequestDeviceEject`
  on the endpoint's PDO from the bridge filter) was not tested.
