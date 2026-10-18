# reenum-test: re-enumeration experiment (throwaway)

Test code for [docs/REENUM-EXPERIMENT.md](../../docs/REENUM-EXPERIMENT.md): can a
kernel-mode driver make Windows 98 SE and Windows 2000 SP4 enumerate an endpoint that
appears behind the tunnel's PCI-to-PCI bridge, and drop one that disappears? This is not a
product driver. GPL-2.0-only, like the rest of this repository.

| File | What |
|---|---|
| `reenum.c` | `reenum.sys`, one WDM binary for both systems. Bridge-filter role (upper filter on a PCI-to-PCI bridge) or host role (function driver of the `usb4-host`, standing in for a CM driver). It polls the bridge's secondary bus every 500 ms through config mechanism #1 and, on a presence change, runs `ReenumMode` 1 (`IoInvalidateDeviceRelations(bridge PDO, BusRelations)`) or 2 (Windows 98 only: CONFIGMG `Reenumerate_DevNode` on the bridge devnode, `Query_Remove_SubTree`/`Remove_SubTree` on a vanished child, called through the VMM `INT 20h` dynalink). Logs to the QEMU debug console, port 0xE9. |
| `cmreenum.c` | `cmreenum.exe`, the user-mode baseline (CFGMGR32): `list`, `scan` (`CM_Reenumerate_DevNode` on the bridge), `remove` (remove each child, then scan). Same binary on 98 and 2000. |
| `build.cmd` | Builds both with MSVC 6.0 and the Windows 2000 DDK from the xhci98 checkout, run in place (`XHCI98=` overrides its path). All outputs and TEMP files go to `out/` (git-ignored). |
| `reenum98.inf` | Windows 98: installs `reenum.sys` as the `usb4-host` function driver (host role, `ReenumMode` 2). Copy to `C:\WINDOWS\INF\OTHER`, then Device Manager Remove + Refresh, or Update Driver from the disk. |
| `b98.reg` | The same by registry (run `D:\install b98`, then restart). Verified. |
| `a1-98.reg`, `a2-98.reg` | Windows 98 mechanism A variants: `UpperFilters` on the bridge's hardware key; `DevLoader=*ntkern` + `NTMPDriver` on the bridge's driver key (`System\0028` on the test image). |
| `filter2k.reg`, `install2k.cmd` | Windows 2000 mechanism A: service key plus a System-class `UpperFilters` entry. The install script assumes the transfer disk is D: (it was E: on the test VM). |
| `mkdisk.sh` | Builds a 32 MiB MBR + FAT16 transfer disk with the binaries (WSL mtools). |
| `run98.sh`, `run2k.sh` | Launch the experiment overlays (`vms/win98-reenum`, `vms/win2k-reenum`) with the transfer disk, `-debugcon` and tunnel/NVMe traces. QMP 47800 / 47810. `TOPO=ar run2k.sh` uses the Alpine Ridge switch tree. |
| `typekeys.py` | Types text or key chords over QMP; `--dvorak` for the Windows 2000 guest. |

Toggle the tunnel from the host:

```
python scripts/qmp.py --port 47800 cmd qom-set '{"path":"/machine/peripheral/tb0","property":"tunnel","value":"up"}'
```

Windows 98: bring the tunnel down before rebooting; an NVMe present at POST makes SeaBIOS
hook it into INT 13h and Windows 98 hangs at the logo (docs/WIN98-TEST.md).
