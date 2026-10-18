# NVMe driver evaluation for legacy Windows behind a USB4 / Thunderbolt tunnel

Date: 2026-10-14. Question from the xhci98 project: can it reuse the existing community
NVMe miniports for an NVMe drive in a USB4 or Thunderbolt enclosure, on Windows 98 SE and
Windows 2000 SP4, or does it need a new driver?

**Maintainer decision (2026-10-14):** fork SweetLow's **nvme9x** (working name **nvme98**)
as the base of xhci98's NVMe driver. SweetLow granted BSD-3-Clause for his port (and public domain for
`NVMEVSD.VXD`) the same day; the fork lives in its own repository, nvme98. This report gives the evidence behind that decision and lists what the fork
must fix.

All guest runs use QEMU TCG with the usb4-emu model (the integrated build of 2026-10-14,
`src/qemu` 26b5431). **Absolute times and throughput under TCG mean nothing.** Only
relative observations are reported. The Windows 2000 runs were made by a separate worker.
Its full notes are in `vms/win2k/RESULTS-win2k.md` (local, git-ignored) and are summarised
here.

## Verdict

| OS | Driver | Verdict |
|---|---|---|
| Windows 98 SE | nvme9x (SweetLow), QuickInstall 1.1.0 build | **Works with caveats** for a 512 B namespace that is present at boot or added and then left alone. **Not usable as-is for USB4:** surprise removal with I/O outstanding (or I/O issued after it) hangs that I/O forever and blocks shutdown, and a 4 KiB-sector namespace hangs Windows at startup. |
| Windows 2000 SP4 | nvme2k 1.2.0.0 (upstream) | **Works with caveats** on 512 B namespaces. The same surprise-removal failure applies, and a 4 KiB namespace gives STOP 0x1E. |
| XP x64 (for reference, from `vms/winxp64/RESULTS-winxp64.md`) | nvme2k amd64 | A 4 KiB namespace gives 32 x 4 KiB reads for a 16 KiB request, then bugcheck 0x19 BAD_POOL_HEADER. |

Neither driver needs replacing from scratch. The basic data path is solid on both:
large files, LBAs above 4 GiB, and host-verified writes. What is missing is exactly what
a hot-removable tunnelled endpoint needs: a device-gone state, command deadlines, safe
reset, and correct LBA-format handling. That is the fork's work list (see the last
section).

## Drivers examined

| Driver | Source | Version, hash | Licence |
|---|---|---|---|
| nvme9x, installed build | Windows 98 QuickInstall 1.1.0 (`C:\DRIVER\NVME9X.INF`) | `NVME2K.MPD` 17813 bytes, PE link 2026-02-18; `NVMEVSD.VXD` 6544 bytes; INF DriverVer 11/24/2025,1.0.0.2 | See nvme9x source below |
| nvme9x, download | `vms/win98/dl-nvme9x/nvme9x.zip` | sha256 `818377c21f8036f97237c6aa190a8abcb7074c5d55924072b1d9b059025e7429`; MPD 17589 bytes, PE link 2025-12-28 | Binary only, no licence text |
| nvme9x source | github.com/LordOfMice/Tools `nvme2k-src.zip` (in `tools/third-party/nvme9x-src/`) | sha256 `272b50836d7f9fe4c1a483f5868d099604916ccd4c89b4daacbc1d17c80bb4f2`. The readme names its base as nvme2k 1.0.0.2. | **No LICENSE, NOTICE or file headers.** `nvme2k.rc` credits Dominik Behr and SweetLow. It bundles Microsoft DDK `SCSI.H` and `SRB.H`. Licence: BSD-3-Clause, granted by SweetLow on 2026-10-14 (after this download). |
| nvme2k upstream | https://github.com/techomancer/nvme2k, in `tools/third-party/nvme2k/` | Release `1.2.0.0` (tag at d5be93d, 2025-12-15), `nvme2k-1.2.0.0.zip` sha256 `7314ed668494b6501d8a62bd1d57b15ea164ebf1a764f3cc282767e4fe148442`. Source HEAD 0c41727 (2026-06-16). | BSD-3-Clause, (c) 2025 Dominik Behr |

`tools/third-party/` is git-ignored. Downloaded binaries ran only inside guests.

**Licence fit for xhci98.** xhci98 is a public repository (`LICENSE`: (c) 2026 Yeo Kheng
Meng). Upstream nvme2k's BSD-3-Clause allows a fork, provided the copyright notice, the
conditions and the disclaimer are kept in source and binary distributions, and Behr's
name is not used for endorsement. The nvme9x code is derived from nvme2k 1.0.0.2, so
Behr's BSD notice applies to it even though the zip omits it. SweetLow's own changes carried
no licence in the zip; he granted BSD-3-Clause on 2026-10-14. Two rules for the fork:

- restore Dominik Behr's notice (with an SPDX tag) in every file derived from nvme2k;
- do not commit the bundled Microsoft `SCSI.H`/`SRB.H`; take them from the DDK at build
  time.

## Test setup (Windows 98)

- VM `vms/win98-nvme` (QMP 47700, VNC 127.0.0.1:47701). The system disk is an overlay
  chain onto `vms/win98-refcm/win98.qcow2` (BootGUI=0, `AUTOEXEC.BAT` runs
  `D:\USB4CM.EXE`), with a fresh per-run overlay. For the BootGUI=1 runs the overlay was
  made directly on `vms/win98/win98.qcow2`. Machine and devices are as in
  `scripts/run-win98.sh` (i440FX, `pentium3,-apic`, 512 MiB, `msi=off`, `msix=off`).
- Test disk `vms/nvme-eval/nvme8g-base.qcow2`: 8 GiB, MBR, one FAT32 partition at LBA 63,
  4 KiB clusters, made in WSL with `sfdisk` and `mformat`. Each run gets its own overlay.

  | File | Size | Purpose |
  |---|---|---|
  | `LOW.BIN` | 64 MiB random | low LBAs |
  | `BIG.BIN` | 1100 MiB random | large I/O |
  | `FILLER.BIN` | 3700 MiB zeros | pushes the next file up |
  | `HIGH.BIN` | copy of `LOW.BIN` | starts at cluster 1245188, about 4.8 GiB |

- Evidence: QEMU traces (`pci_nvme_read/write/admin/create/identify/mmio_*/err_*`,
  `usb4_tp_*`, `usb4_tb_*`, `usb4_tunnel_transition`) in `vms/win98-nvme/trace-<run>.log`,
  SeaBIOS debug output (`isa-debugcon` 0x402) in `seabios-<run>.log`, and screendumps.
  For host checks, the overlay is converted to raw and read with `mtools` and `sha256sum`.
- The tunnel comes up via `USB4CM.EXE` (tools/usb4cm) at the DOS 7.1 prompt, then `win`,
  unless stated otherwise.

## Evidence, Windows 98 SE + nvme9x

| # | Test | Result | Evidence |
|---|---|---|---|
| W1 | Basic path, generic profile (minimal host), guest CM | **Pass.** The CM brings up the PCIe tunnel. After `win` the 8 GiB volume mounts as F: with no Refresh. | `usb4_tunnel_transition router 0x1 PCIe tunnel up`; `usb4_tp_insert ... gen 1 drive=nvme0 cold=0`; `dir f:` lists all files (run t1) |
| W2 | Reads above 4 GiB | **Pass.** `fc /b F:\LOW.BIN F:\HIGH.BIN`: no differences. Reads reached LBA 0x99087f (about 4.78 GiB). | t1 trace |
| W3 | Large write above 4 GiB | **Pass.** `copy /b BIG.BIN BIG2.BIN` (1.1 GiB) landed at clusters 1261573-1543172 (about 4.8-5.9 GiB, writes to LBA 0xbce01f). `fc /b` reports no differences. | t1 trace, guest screen |
| W4 | Host offline check after a clean shutdown | **Pass.** `BIG2.BIN` sha256 7d3dccd1... = `BIG.BIN`; `HIGHCP.BIN` e57a5ddb... = `LOW.BIN`. | `verify.sh` on the raw conversion of `nvme-t1.qcow2` |
| W5 | Shutdown behaviour | The driver sets CC.SHN at Windows shutdown. **No NVMe FLUSH command was seen in the whole t1 run**, so durability rests on CC.SHN. | `pci_nvme_mmio_shutdown_set` x1, no `pci_nvme_flush_ns` |
| W6 | Throughput (TCG, relative only) | Copying 1.1 GiB took about 432 s, and the `fc` of 2 x 1.1 GiB about 977 s. Reads were 92% 4 KiB (`nlb 8`, 162k of 177k), writes mostly 32 KiB. The Windows 2000 run with nvme2k moved 64 KiB commands and was roughly 10x faster in the same emulator. Win98's small reads probably come from VFAT/VCACHE and not the miniport (inferred). | t1 trace |
| W7 | Idle surprise removal, then I/O | **Fail.** After `tunnel surprise`, the gate closes and the endpoint is removed. Then `type F:\LOW.BIN \| find` blocks forever (more than 10 min, no error, no Abort/Retry). The rest of the GUI responds slowly and the guest clock lags. After `tunnel up` (gen 2), Device Manager Remove asks for a restart. Refresh then wedged the GUI (hourglass, clock stopped, CPU in VMM code). | t2: `usb4_tp_surprise`, `usb4_tp_removed`, `insert endpoint gen 2`; EIP samples c000xxxx, HLT=0 |
| W8 | Surprise removal during a 1.1 GiB copy | **Fail.** Writes stop at the removal and the copy never completes or errors. The desktop still responds and IRQ 10 was in use (48054 interrupts). After `tunnel up`, the copy stays stuck. Start > Shut Down raises "not responding" for the DOS box. After End Task, **shutdown hangs on a blank desktop** (more than 8 min). Only a hard stop recovers. | t3 |
| W9 | Idle surprise, **no I/O**, then tunnel up + Remove + Refresh | **Pass.** Remove takes effect without a restart. Refresh reinstalls the controller from `C:\DRIVER\NVME9X.INF` on gen 2 (CC.EN, queues, identify) and `fc` of LOW/HIGH passes. | t4 |
| W10 | `device_del enc0` (CM-built tunnel) | Same as a surprise removal: `tunnel down reason 3`, gate closed, endpoint removed. The driver sees it identically. With a QOM-forced tunnel, `device_del` does **not** drop the tunnel (Windows 2000 worker; forced mode is independent of the fabric). | t4 tail |
| W11 | 4 KiB-sector namespace (`-global nvme.logical_block_size=4096 -global nvme.physical_block_size=4096`) | **Fail.** The driver initialises, then issues exactly two reads, `nlb 1 count 4096` at LBA 0 and 0x3F. LBA 0x3F is the MBR partition start used as a 4 KiB LBA, so the stack assumes 512 B sectors while each command moves 4 KiB. **Windows 98 then hangs at startup**: still on the text screen after `win`, CPU in VMM, no further I/O for 3 minutes. This is consistent with a 4 KiB DMA into a 512 B buffer (the FLBAS/LBAF decode bug below); the overrun itself is inferred. | t5 |
| W12 | Downloaded 1.0.0.2 build | Not retested. The QuickInstall build is newer and is the one in use. | |

### Boot-present NVMe and the SeaBIOS hang (test 3)

| Run | Configuration | Result |
|---|---|---|
| t8 | Generic, `FORCE_TUNNEL=1`, **BootGUI=1** (stock disk) | **Hang at the boot logo**, CPU at the SMM entry (SMM=1, EIP=0x8000). Reproduces the documented hang. nvme9x never loaded: only 4 NVMe reads, all from SeaBIOS or real mode. |
| t7 | Same, but BootGUI=0, then `win` from the DOS prompt | **Boots.** SeaBIOS mapped the NVMe as an INT 13h drive. |
| t9 | Same as t8 plus `-global ide-hd.bootindex=1 -boot strict=on` | **Boots to the desktop.** nvme9x binds the boot-present NVMe with no Refresh, and `dir E:` lists the volume. |
| t6 | BootGUI=0 + strict, check of the SeaBIOS log | SeaBIOS prints `skipping init of a non-bootable NVMe at 01:01.0`, so no INT 13h drive. Windows mounts the volume as E: and `fc` passes. |

**Conclusion: the hang is SeaBIOS plus Windows 98's GUI boot path (the logo), not nvme9x.**
Workaround: give the boot disk a `bootindex` and add `-boot strict=on`. SeaBIOS then
adds `HALT` to its boot order and skips NVMe controllers that are not in it. This is
SeaBIOS behaviour since `is_bootprio_strict()` gained the NVMe check; QEMU 11.1.2 ships
SeaBIOS rel-1.17.0. On real hardware, the equivalent is a firmware that does not hook the
enclosure into INT 13h, or Windows 98 started from DOS (BootGUI=0). Windows 2000 boots
with the NVMe present at power-on and has no such problem.

## Host types (Windows 98)

| Host | How the tunnel came up | Result |
|---|---|---|
| Generic, `host-model=minimal` | USB4CM.EXE in DOS (W1-W9) | Works; see above |
| Generic, `host-model=intel-adl` (run c1) | USB4CM.EXE in DOS: 306 control packets, 0 retries. **PCIe Down 8 is paired with port 1 and Down 9 with port 2** (the Nth PCIe Down adapter maps to the Nth port, as designed). `PCIe tunnel adapter 8 <-> 3`. | **Works.** After `win` the volume is F:, `copy`/`fc` of LOW to ADL.BIN show no differences. The reference CM works on the intel-adl host unchanged. |
| `tb3-alpine-ridge`, `BIOS=OFF_ON DEVICE_AT_BOOT=1` (run a1; P14s zero-driver path, pre-boot tunnel at power-on behind the 15c0 switch) | The emulated ICM tunnels it before POST | **Works, no hang** (BootGUI=0 and `win`; no strict). SeaBIOS maps the NVMe as INT 13h drive 0x81 and logs two `internal error detected at nvme_io_xfer:433`. DOS assigns it **D:** and real mode writes LBA 0 (MBR signature) and 0x40 (FSInfo) through SeaBIOS. On first boot, Windows asks for the new bridges, NVMe, NHI 15bf and xHCI 15c1 (no driver for the last two). nvme9x then takes over (CIDs from 32768 show the miniport): `fc` and `copy`/`fc` of a 64 MiB file pass. Not tried: BootGUI=1 on this profile. Expect the t8 hang there, and use the strict workaround. |
| `tb3-alpine-ridge`, `BIOS=OFF_OFF` + `security=none` (run b1) | The ICM tunnels at power-on (`cold=1`) because nothing needs approval | Same as boot-present: works, D:, copy/compare pass |
| `tb3-alpine-ridge`, `BIOS=OFF_OFF`, default security, tunnel forced after boot (`qom-set tb0 tunnel up`) + Refresh (run b2) | NVMe hot-added at 04:01.0 behind root port 00:1c, the 15c0 switch and the tunnel bridge | **Fail, not the driver.** Windows finds "NVMe Storage Controller (Windows 9x)" but marks it **Code 29: "BIOS did not give it an IRQ"**. `info pci` shows the NVMe with IRQ 0 and BAR0 not mapped. Remove + Refresh repeats it. nvme9x is never loaded. The same hot-add on the generic profile (bridge on bus 0) gets IRQ 10. Hypothesis: Windows 98 cannot route INTx for a function added after POST three bridges below 00:1c (no `$PIR`/BIOS interrupt line for it). This belongs to the CM and platform side (usb4-emu and xhci98 CM), not the NVMe driver. **Root cause found 2026-10-14:** SeaBIOS's `$PIR` lists only bus 0 slots 1-6, so nothing covers 00:1c; `run-win98.sh` now puts the root bridge at slot 6 (`ROOT_ADDR`), after which the hot-added NVMe gets IRQ 10 and nvme9x works (see WIN98-TEST.md). |

## Windows 2000 SP4 + nvme2k 1.2.0.0 (summary of the other worker's results)

- **Basic path:** tunnel up, Scan for hardware changes, Have Disk (unsigned prompt), no
  reboot. NTFS and FAT32 work. About 3.5 GiB were written, including above 4 GiB (top
  LBA 0xd43786), with host md5 checks OK. Mostly 64 KiB commands. Throughput was about
  10x Windows 98's in the same emulator.
- **Boot-present** (`x-force-tunnel`) boots fine with no SeaBIOS INT 13h problem.
- **Removal while idle, then rescan:** clean. Windows shows "Unsafe Removal" and the
  devices leave. Tunnel up + rescan brings the disk back with the same letters.
- **Removal during I/O, or I/O before a rescan:** the I/O hangs forever (CPU idle in
  HLT, not a busy wait), a rescan hangs, shutdown hangs for more than 5 min. Data flushed
  before the removal is intact. Clean procedure: Device Manager **Disable**, tunnel down,
  then tunnel up + Scan + **Enable**. Disable sends FLUSH, deletes the queues and sets
  CC.SHN.
- **Host types:** generic, intel-adl and Alpine Ridge pre-boot all work. The Alpine Ridge
  pre-boot run needs one restart on first boot and then mounts at logon.
- **4 KiB namespace:** `READ nlb 32 count 131072` (an 8x over-read), a PRP list read from
  guest physical address 0 (QEMU rejects it), then **STOP 0x1E**. The reboot then hangs
  in SeaBIOS with the 4Kn NVMe present at POST.
- nvme2k does not set CC.SHN at OS shutdown (it does on Disable). WHPX hangs this
  Windows 2000 image even without usb4 devices, so TCG is required.

## XP x64 + nvme2k 1.2.0.0 amd64 (summary; local results in `vms/winxp64/RESULTS-winxp64.md`)

- nvme2k built for amd64 with WDK 7.1 installs unsigned and works on a 512 B namespace
  (NTFS, copies, `fc /b`, host sha256 check, 20 x 48 MB loop) and boot-present.
- XP sees tunnel up/down only after "Scan for hardware changes".
- Surprise removal followed by I/O wedges the volume indefinitely (event 117 bus reset,
  then event 9 timeouts every 15 s; scsiport retries forever). Re-plugging does not recover.
- 4 KiB namespace: 128 KiB DMA for a 16 KiB request, then bugcheck 0x19 BAD_POOL_HEADER.
- The XP x64 image does not boot on q35, so `usb4-tunnel-port` was not tested on it.

## Windows 7 x64 (summary; local results in `vms/win7x64/RESULTS-win7x64.md`)

| | Microsoft stornvme (KB2990941 + KB3087873) | nvme2k 1.2.0.0 amd64 |
|---|---|---|
| Install | `wusa`, reboot | `pnputil`; loads only with F8 "Disable Driver Signature Enforcement" (Code 52 otherwise) |
| Interrupts | MSI-X | INTx |
| 512 B namespace | NTFS copy, MD5 and offline checks, chkdsk clean | same, and reads stornvme's data correctly |
| 4 KiB namespace | **correct** (4096 B sectors, NTFS 4K) | 128 KiB DMA for 16 KiB, bugcheck 0x19 |
| Surprise removal during reads | application blocked ~81 s, then the read fails | blocked ~64 s, then fails |
| Surprise removal idle or during a copy | clean | clean |

- **q35 + `usb4-tunnel-port`:** Windows 7's native PCIe hot-plug takes the slot (`_OSC`)
  and handles `up` / `surprise` / `up` repeatedly with no helper, no hang and no bugcheck.
  An orderly `eject` with a mounted volume ends in "device is in use"; the model's 10 s
  timeout removes it, and the next insertion is not started until `surprise` + `up`, the
  same as on Windows 11.
- **i440FX + `usb4-tunnel-bridge`:** Windows 7 does not drive SHPC (no `_OSC` on i440FX);
  with `shpc-autoenable=on` changes are seen only after a manual rescan.
- stornvme probes all 256 namespaces that QEMU's `nvme` reports and creates 150+ empty
  phantom disks (I/O unaffected). This is a QEMU `nvme` property, not a driver fault.
- **Conclusion for Windows 7 x64:** Microsoft's hotfix driver is the better choice today
  (4 KiB, removal, signed). nvme98 matters most for Windows 98/ME, 2000, XP, XP x64 and
  Vista, and for Windows 7 systems without the hotfix.

## Static analysis (Codex reviews)

Two static, read-only reviews were committed:
[codex-nvme2k-review.md](reviews/codex-nvme2k-review.md) (upstream nvme2k, the AMD64 build
tree) and [codex-nvme9x-review.md](reviews/codex-nvme9x-review.md) (the nvme9x source).
Upstream verdict: "usable with specific fixes, not as-is". The nvme9x review keeps most
critical findings and adds new ones.

| Finding | nvme2k 1.2.0.0 | nvme9x | Seen in tests |
|---|---|---|---|
| Reset/abort completes requests without stopping the hardware (stale DMA into reused buffers; no command generation check) | present, critical | present, critical | Consistent with W7/W8: no recovery once a request is stranded |
| FLBAS taken as the block-size exponent, and LBAF at the wrong offset in the identify-namespace struct (4 KiB format 0 is reported as 512 B; format index 1 as 2 B) | present, critical | present, critical | **W11 hang; Win2000 STOP 0x1E; XP x64 0x19** |
| Flush completion frees another command's PRP page (uninitialised SRB extension) | present | present | not exercised |
| No device-gone state: all-ones CSTS reads as ready; bounded multi-second stalls (shutdown about 12 s, init disable retries about 30 s); no command deadlines | present | present | W7, W8, Win2000 rows 10-11 |
| Length validation: 32-bit overflow (upstream) or none at all (nvme9x); zero-length becomes 1 block | present | present, worse | not exercised |
| Restart does not restart | present | different cause: re-init exhausts the uncached pool (N2) | not exercised |
| FUA ignored; ORDERED is "flush then I/O" with no barrier | present | present | W5 (no FLUSH seen on 9x) |
| PCI config access from `HwInitialize` | present | present | none |
| Uncached extension over XP's 100 KiB limit | present (148 KiB) | fixed (64 KiB) | none |
| 64-bit BAR high half lost on fallback discovery; queue-size maths (MQES narrowing, non-power-of-two rings) | present | present | none |
| Guard timer stops after one 100 ms poll with I/O outstanding (N1) | n/a | **new** | none (interrupts worked) |
| 9x `HwAdapterState` restore only shuts the controller down (N3) | n/a | **new** | relevant to real-mode handoff |
| Discovery can attach the wrong controller (N4); MDTS ignored (N5); legacy interrupt line overrides PnP routing (N6); PTE cache-bit change without TLB sync (N7); unsupported SERVICE ACTION IN never completes (N8) | handled upstream (N4-N6) | **new** | none |
| 64-bit LBA handling | ok | ok (SweetLow's addition) | W2/W3 above 4 GiB |
| AMD64 target | yes (WDM build, `NVMe2Kx64.sys`) | **none**; feasible (`atomic.h` needs intrinsics, keep VMM/PTE code 9x-only) | |

## How the drivers react to removal

Gate behaviour (ARCHITECTURE.md §4.4): MMIO reads return all-ones, writes and doorbells
are dropped, and no DMA or interrupts arrive. Both drivers keep their completion queues in
host RAM, so they simply never see a completion. They have no per-command deadline and
no all-ones check on the I/O path, so the request stays pending. On Windows 98 there was
no Abort/Retry and no error in more than 10 minutes. On Windows 2000 the SCSI port timeout
reset does not unblock the stack. The pending request then blocks PnP removal and
shutdown. Removal is survivable only when no request is outstanding and the OS learns of
the removal (Remove on 98, rescan on 2000) before the next I/O.

## What the fork (nvme98, based on nvme9x) must fix

Design and phases: `D:\OneDrive\git-projects\nvme98\docs\PLAN.md`. Must-haves from this
evaluation:

1. **Device-gone state and bounded recovery** (W7, W8, Win2000 rows 10-11, review #1/#7).
   Treat all-ones CSTS or MMIO as gone. Add per-command deadlines and a watchdog that
   stays armed while any command is outstanding (replacing the N1 guard timer).
   Complete all held requests with a terminal status, fast-fail new ones, quiesce before
   releasing requests, and track command generations so stale completions are rejected.
   On 9x, make sure the status used stops IOS retries, so Remove and shutdown proceed.
2. **4 KiB-sector namespaces must be supported, never refused** (maintainer decision).
   Fix the FLBAS/LBAF decode and the identify-namespace layout. Always present 512-byte
   logical sectors to the OS and translate: aligned requests pass straight through with
   LBA and count scaled, and unaligned writes go through read-modify-write in a bounce
   buffer. W11, the Windows 2000 STOP 0x1E and the XP x64 0x19 are the decode bug plus the
   missing 512e translation.
3. **Reconnect:** after tunnel up, re-initialise on the new generation and compare
   namespace identity, so W9 and the Windows 2000 rescan path also work without a manual
   Remove.
4. **Durability:** send FLUSH on SYNCHRONIZE CACHE and before stop or shutdown, translate
   FUA, and give ORDERED a real barrier (W5: Windows 98 sent no FLUSH at all). Set CC.SHN
   at OS shutdown on NT too.
5. **Remaining review defects:** PRP ownership on flush; length validation in 64-bit
   arithmetic; zero-length I/O; restart and re-init allocation (N2); 9x real-mode handoff
   (N3); config access only from permitted callbacks; 64-bit BAR; queue sizing; INQUIRY
   EVPD; SERVICE ACTION IN.
6. **Backport from upstream 1.2.0.0:** PnP-constrained discovery (N4), port/HAL interrupt
   routing on PnP targets (N6), MDTS handling (N5), and the **AMD64 target** (WDM build and
   INF). nvme9x has no AMD64 build. Make `atomic.h` use intrinsics and confine VMM/PTE
   code to the 9x build.
7. **Provenance hygiene:** restore Dominik Behr's BSD notice and add SPDX headers. Add
   SweetLow's BSD-3-Clause grant (done in nvme98). Keep the DDK headers (`SCSI.H`, `SRB.H`) out of the
   repository.
8. Keep what works: SweetLow's 64-bit LBA handling (verified above 4 GiB) and the shutdown
   and timer-rearm work.

## Recommendations for xhci98 (until nvme98 exists)

- **Windows 98:** use the QuickInstall nvme9x on 512 B namespaces only. Bring the tunnel
  up after POST (CM or `TUNNEL_UP_AFTER`). For a boot-present NVMe, use `bootindex` on the
  boot disk plus `-boot strict=on`, or BootGUI=0. Before taking a tunnel down, stop all
  I/O. After it goes down, do Remove in Device Manager before any access. After it comes
  back, Refresh. The CM driver must reproduce Remove + Refresh programmatically.
- **Windows 2000:** use nvme2k 1.2.0.0 on 512 B namespaces. Disable, then tunnel down;
  tunnel up, then Scan + Enable.
- **Thunderbolt 3 topology on Windows 98:** a tunnel that comes up after POST behind the
  15c0 switch gets no IRQ (Code 29). Either have the firmware tunnel before POST (the
  P14s pre-boot setting, which works), or the xhci98 CM must solve IRQ assignment for the
  hot-added function. Follow this up in usb4-emu (`$PIR` and interrupt-line coverage for
  root port 00:1c).
- Validate the fork against W7-W11 and Windows 2000 rows 10-16 in this emulator: surprise
  removal idle and during I/O, `device_del`, reconnect, 4 KiB namespaces, and LBAs above
  4 GiB.
