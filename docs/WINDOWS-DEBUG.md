# Debugging the Windows 11 USB4 connection manager

How to see what the Windows 11 in-box USB4 connection manager (CM) is doing when it runs
against our `usb4-generic` model, plus how the test VM is driven. Everything here is a
summary in our own words of public Microsoft pages (linked) and of what we observed in
the guest (build 10.0.26300, in-box drivers dated 08/24/2026, version 10.0.26100.9278).

## 1. The test VM

The VM lives in `vms/win11/` (git-ignored). Scripts:

| Command (Git Bash, repo root) | What it does |
|---|---|
| `scripts/win11-install.sh` | Creates `win11.qcow2` and its OVMF vars and runs a fully unattended install from the ISO (about 12 minutes to a working agent with WHPX). |
| `scripts/run-win11.sh [qemu args]` | Boots the VM headless in the background. Extra arguments go to the end of the QEMU command line. `QEMU=<path to qemu-system-x86_64.exe>` selects the binary (default `vms/qemu-baseline`). |
| `scripts/stop-win11.sh` | ACPI power button through QMP, then `quit` after `TIMEOUT` seconds (default 180). |
| `scripts/win11-revert.sh [name]` | Reverts disk and OVMF vars to snapshot `base-install` (VM must be stopped). `SAVE=1` creates a snapshot instead. |
| `python scripts/guest.py exec "<PowerShell>"` | Runs a script in the guest as SYSTEM. Also `exec -f file.ps1`, `put`, `get`, `wait`, `ping`. |
| `python scripts/qmp.py screendump x.png` | Screenshot (PNG). Also `cmd`, `hmp`, `sendkey`. |

Ports (127.0.0.1 only; written to `vms/win11/ports.env`): QMP 47101, VNC 47102, private
supervisor QMP 47103, guest agent 47110 (forwarded to guest port 8000). The agent token is
in `vms/win11/agent-token`; `guest.py` reads it from there.

Machine: q35, WHPX, `-cpu max`, 4 vCPUs, 8 GB, OVMF without Secure Boot, system disk on the
q35 AHCI controller, e1000e on slirp with `restrict=on` (no internet, host forward works;
set `NET_RESTRICT=off` to allow it), qemu-xhci with a USB tablet for VNC.

**Guest resets.** On this host (AMD Ryzen AI MAX+ 395, WHPX) an in-place guest reset does
not work: after the reset the boot CPU spins in early OVMF (RIP `0x834e06`), and with more
than one vCPU the APs stop with `WHPX: Unexpected VP exit code 4`. Cold starts are fine. So
QEMU runs with `-no-reboot` under `scripts/vm_supervisor.py`, which watches the private QMP
socket and relaunches QEMU with the same command line when the shutdown reason is a reset.
Consequences: the QEMU PID changes on every guest reboot (`vms/win11/qemu.pid` always has
the current one), QMP clients are disconnected on reboot, and any device state that is not
on disk (e.g. emulated USB4 fabric state) starts fresh, like a cold boot. Reboot history is
in `vms/win11/supervisor.log`; QEMU stderr in `vms/win11/qemu.log`.

Useful QEMU additions for USB4 work:
`-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -device ... -trace 'usb4_*' -D <abs path to log>`.

## 2. Which driver binds the host router

Observed in the installed guest:

- `C:\Windows\INF\usb4hostrouter.inf` (Class `USB`, ClassGuid
  `{36FC9E60-C465-11CF-8056-444553540000}`, DriverVer `08/24/2026,10.0.26100.9278`) is the
  only in-box INF that names the host router. Its model section has exactly two hardware IDs:
  - `PCI\USB4_MS_CM` - PCIe-enumerated host router
  - `ACPI\ACPI0015` - ACPI-enumerated host router

  Both map to the same install section: service `Usb4HostRouter` (kernel driver, demand
  start, `Usb4HostRouter.sys`, loaded from the DriverStore folder
  `usb4hostrouter.inf_amd64_*`), device description "USB4(TM) Host Router (Microsoft)".
  The hardware section sets, under the device's `Interrupt Management` key,
  `MSISupported=1` and `MessageNumberLimit=16`, and under `DMA Management`
  `RemappingSupported=1`. The service `Parameters` key gets `ForceLogsInMiniDump=1` and
  `WppRecorder_UseTimeStamp=1`.
- No in-box INF matches `PCI\CC_0C0340` (searched all of `C:\Windows\INF\*.inf`). The class
  code alone does not bind anything.
- `usb4devicerouter.inf` (service `Usb4DeviceRouter`, `Usb4DeviceRouter.sys`) binds the
  child devices the host router driver creates: `USB4\DEVICE_ROUTER` ("USB4 Router"),
  `USB4\ROOT_DEVICE_ROUTER` ("USB4 Root Router") and `USB4\TBT3_DEVICE_ROUTER`
  ("Thunderbolt 3(TM) Router").
- `usb4p2pnetadapter.inf` provides "USB4(TM) P2P Network Adapter" (inter-domain
  networking; not needed for us).
- Event provider present: `Microsoft-Windows-USB-USB4DeviceRouter-EventLogs`
  `{D07E8C3F-78FB-4C22-B77C-2203D00BFDF3}`. There is no `*USB4*` event log channel.

Where `PCI\USB4_MS_CM` comes from (Microsoft, "USB4 ACPI requirements"): the PCI bus
driver adds it to the hardware IDs of a PCIe host router only when the platform firmware
implements **both** the platform-wide `_OSC` with *Native USB4 Support* granted (OS calls
with the query flag clear and the bit set, firmware leaves it set) **and** the `_OSC` for
USB (USB4 capabilities). USB tunneling, DisplayPort tunneling and inter-domain must be
granted or the CM puts the device into a failed state; PCIe tunneling may be withheld by
policy (then no PCIe tunnels, which defeats our purpose, so grant it). The settings must not
change during a boot session. For the generic profile this means: without the ACPI `_OSC`
pieces, Windows sees an unknown class `0C0340` device with no driver. The same page also
asks for `_DSD` port mapping (Device Properties UUID `daffd814-6eba-4d8c-8a91-bc9bbf4aa301`,
properties `usb4-host-interface` = reference to the host interface ACPI device, whose name
must end in a digit 0-7, and `usb4-port-number`) on the tunneled PCIe downstream ports and
USB 3 ports, and requires USB4-associated PCIe root ports to be marked as hot-plug capable
in D3 (PCIe `_DSD` for root ports).

To check the binding from the host:

```sh
python scripts/guest.py exec "Get-PnpDevice -PresentOnly | ? { \$_.HardwareID -match 'USB4' -or \$_.CompatibleID -match 'CC_0C03' } | fl FriendlyName,Status,Problem,InstanceId,HardwareID,CompatibleID"
python scripts/guest.py exec "pnputil /enum-devices /class USB /drivers"
```

## 3. Logs and traces

Microsoft's hub page is
[USB4 debugging and troubleshooting](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-debugging-and-troubleshooting).
What it and its sub-pages give us:

- **ETW trace session** ([Examining CM driver traces](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-examining-connection-manager-driver-traces)).
  Microsoft's `BusesTrace.cmd` ([busiotools](https://github.com/microsoft/busiotools/tree/master/usb/tracing),
  MIT) drives `wpr.exe` with the `Usb4WithTunnelsProfile` from `BusesAllProfile.wprp`. Can
  trace the current boot or from the next boot. The USB4 providers in that profile:

  | Provider | GUID | Kind |
  |---|---|---|
  | Host router driver | `{505A6797-992E-43E6-B84E-235E41E3FD82}` | WPP |
  | Device router driver | `{1B502FCB-68CD-4407-A59E-1EAF8AB9EA26}` | WPP |
  | `Microsoft.Windows.USB.USB4.HostRouter` | `{575BA31F-2B45-58C2-64FD-F5DC757B6137}` | TraceLogging |
  | `Microsoft.Windows.USB.USB4.DeviceRouter` | `{AE795D36-2B11-5EFB-C7E0-5D552BC55D6C}` | TraceLogging |
  | PCI bus driver (in the same profile) | `{47711976-08C7-44EF-8FA2-082DA6A30A30}` | WPP |

  The profile also pulls in USB host/hub, PnP (`Microsoft-Windows-Kernel-PnP`), display and
  NetAdapter providers. WPP messages need the driver's trace format data to decode; public
  symbols may or may not carry it, so treat the `.etl` as something to keep and decode
  later, and rely on the TraceLogging events for immediate reading.
- **TraceLogging rundown** ([TraceLogging rundown events](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-tracelogging-rundown-events)).
  When a session enables the two TraceLogging providers above, the drivers emit a
  `RundownStart` marker, then one event per router (`DeviceRouterInformation`: domain,
  topology ID, vendor/model from the DROM, UUID from ROUTER_CS_7/8, firmware version), per
  port (`PortInformation`: lane adapter numbers, supported/current link speed and width from
  LANE_ADP_CS_0/1, adapter state, bonding, PORT_CS_18 fields), per PCIe/DP/USB3/other
  adapter (adapter number, ADP_CS_2 type, tunneled or not), per inter-domain peer, and a
  `RundownComplete` marker. Afterwards they keep logging router arrival and
  `DeviceRouterRemoval`. These are self-describing, so `tracerpt` decodes them without
  symbols. This is the quickest way to see how far enumeration of our fabric got and which
  register values the CM read.
- **In-flight recorder (IFR)** (same page). Both drivers keep WPP messages in an always-on
  circular buffer, readable from a kernel debugger or a kernel memory dump with
  `!rcdrkd.rcdrlogdump Usb4HostRouter.sys` / `Usb4DeviceRouter.sys`. The INF sets
  `ForceLogsInMiniDump=1`, so a bugcheck minidump should include it. We have no kernel
  debugger attached, so this matters only if the guest bugchecks.
- **Kernel debugger extension** ([USB4 kernel debugger extension](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-kernel-debugger-extension)):
  domain and router dumps, only with a kernel debugger.
- **System event log** ([display tunnel events](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-system-event-log-events-for-display-tunnels)):
  source `USB-USB4DeviceRouter-EventLogs` writes events 1 (monitor enumerated) and 2
  (monitor failed) to the System log. Display-tunnel only; not useful for PCIe tunnels, but
  the collector includes the System log anyway.
- **Settings and Device Portal**: Settings > Bluetooth & devices > USB > USB4 hubs and
  devices shows the domain and can copy it to the clipboard;
  [Windows Device Portal](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/usb4-windows-device-portal)
  has a USB4 view. Both need an interactive session (VNC on 127.0.0.1:47102).

### The helper: `scripts/guest-usb4-trace.ps1`

Installed in the snapshot as `C:\usb4agent\guest-usb4-trace.ps1` (re-`put` it after
changing the script). It uses `logman` (in box; `wpr` profiles are not needed) with the six
providers above at verbose level, all keywords.

```sh
python scripts/guest.py exec 'C:\usb4agent\guest-usb4-trace.ps1 start'
#   ... hot-plug / reproduce ...
python scripts/guest.py exec --timeout 900 'C:\usb4agent\guest-usb4-trace.ps1 collect'
python scripts/guest.py get 'C:\usb4agent\traces\usb4-latest.zip' vms/win11/usb4-trace.zip
```

`collect` stops the session and zips: the `.etl`, a `tracerpt` XML decode and summary,
all PnP devices, properties of USB4/PCI/storage devices, `pnputil` problem-device and PCI
listings, `Get-Disk`, the last 6 hours of the System and Kernel-PnP event logs, and
`setupapi.dev.log` (driver selection details: look for `USB4_MS_CM`).

For problems during boot (the host router is present from power-on), use
`bootstart`, reboot the guest (the supervisor relaunches QEMU with the same arguments), then
`collect` (it includes `usb4emu-boot.etl`) and `bootstop`.

## Host router validation gate (test-signing required)

Observed 2026-10-14 on build 26300 with `Usb4HostRouter.sys` 10.0.26100.9278:

- With the ACPI `_OSC` grants in place, PnP adds `PCI\USB4_MS_CM` and loads
  `Usb4HostRouter.sys` for the emulated host (1b36:00f4), but the device stops with
  Code 31, problem status `0xC00000BB` (`STATUS_NOT_SUPPORTED`), before the driver
  touches BAR0.
- The driver starts the same host router once test-signing is on (below), so Windows
  appears to gate host routers it has not validated and to lift that gate under
  test-signing (inferred from this behaviour, not verified).
- Fix used here: in the guest, `bcdedit /set testsigning on` and reboot. The test VMs
  boot OVMF without Secure Boot, so this is allowed. With it, the host router starts
  (status OK) and the CM begins talking to the host router over ring 0.
- Adding an emulated Intel IOMMU (`-device intel-iommu,intremap=off`) did not change the
  Code 31 result, so DMA remapping is not the gate.

## Finding Windows CM failures: TraceLogging assertion events

The WPP traces of `Usb4HostRouter.sys` and `Usb4DeviceRouter.sys` cannot be decoded
without Microsoft's format files, but both drivers also emit TraceLogging events, and
their assertion events carry the failing check's text and function name. This was the
decisive tool for the root router failure:

1. In the guest: `C:\usb4agent\guest-usb4-trace.ps1 start`
2. `pnputil /restart-device "<host router instance id>"` (or reboot with `bootstart`)
3. `C:\usb4agent\guest-usb4-trace.ps1 stop` then `collect`, and copy the zip out with
   `scripts/guest.py get`. Look for `AssertionFailure` events in the decoded XML.

Pair this with the QEMU side, `-trace 'usb4_*'`, which logs every ring 0 control packet
decoded, every router operation and why the tunnel is or is not up
(`usb4_tunnel_inputs`, `usb4_tunnel_path`).

## What the Windows CM required of the model (observed 2026-10-14, build 26300)

- Test-signing in the guest (validation gate, above).
- One USB3 Gen X Down adapter per USB4 port on the host router. Without it the root
  router device fails with Code 10, from the assertion "Unexpected number of USB3 down
  adapters" in the device router driver's adapter validation. The adapters grant USB3
  bandwidth requests at once since no xHCI sits behind them.
- Windows' PCIe hot-plug driver ignores a hot insert that arrives while it is still
  initialising the tunnel root port during boot, and leaves the slot powered off. The
  tunnel port repeats the presence-detect / attention-button request (at most 3 times)
  when the guest re-arms slot interrupts while the endpoint has never been powered.
- An eject request for an endpoint whose volume is mounted is never completed by
  Windows after the gate has closed, so admin-down defaults to surprise removal
  (`orderly-admin-down=on` restores the eject request). See `docs/USAGE-tunnel.md`.

## Thunderbolt 3 device routers (2026-10-16)

The device router driver handles a TB3 router (`USB4\TBT3_DEVICE_ROUTER`, "Thunderbolt
3(TM) Router") differently from Linux: it reads the DROM and the NVM version through the
router's DMA port (Host Interface adapter, mailbox at adapter dwords `0x3f`-`0x50`) at the
offset in router dword `0x34`, never by EEPROM bit-bang, and reads the eGPU dword at flash
`0x734`. A TB3 router without an NHI-typed adapter, or with an erased `0x734`, fails with
Code 10 and problem status `0xC000009E`. Details in `USB4-HOSTS.md` §8 "Windows 11
built-in CM".

How it shows: the TraceLogging rundown lists the router with no DROM data, and the
`usb4_*` trace shows where enumeration stops (no `AssertionFailure` events come out).
