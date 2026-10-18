# Overnight log, 2026-10-16

This file records decisions made while you were away and anything waiting for you.

## Decisions taken (internal, recommended option)

- **00:20 nvme98 int-0.2.** The removal transaction may relinquish 9x DMA blocks at the
  RDY=0 acknowledgement, once the queue gates are closed, as well as at the end of EngStop.
  Codex found this safe. The engine's N2 contract text is being updated to match.

## Review status

- **int-0.2** (engine + interface 3 + pool + clean-eject handshake): Codex says not ready.
  There are 3 P1s: a shutdown can earn clean-eject credit it shouldn't, the ISR keeps
  dispatching after DRAIN, and a hypothesised claim race. There are also 3 P2s. The fix
  agent is working on them.
- **qual-9x** (interface 3): Codex says not adoption-ready. Your conditional D4 approval
  does not apply, because there is 1 P1 in the cm9x worker handoff (a duplicate-op window)
  and 5 P2s. The fix agent is working on them. The finding is in the CM stand-in that xhci98
  mirrors, so the fixed handoff pattern will be written into the header rules for xhci98.

- **engine b01fc59** (D3 ME write-through, the ME gone-deadline fix, the CM poll hook):
  **Codex-cleared** in round 6, no findings. It is being merged into int-0.2. Codex flagged
  one item for later: before an NT CM receiver is enabled, the bus-change notification must
  move into the common evidence path. It is dormant today.

## Blog screenshots: done (`temp\blog\`, 9 PNGs, full screen)

**Windows 11**, 1280x800, with `winver` showing 26H2 build 26300.9457:
- `win11-devmgr.png`, `win11-devmgr-ts3plus.png`: Alpine Ridge host with the TS3 dock tree
  (NVMe, NIC, USB disk).
- `win11-devmgr-orico.png`, `win11-devmgr-usb4.png`: USB4 Host Router, then Root Router, then
  the ASMedia 246x router, then the ASM2464 switch, then the NVMe.
- `win11-devmgr-tb3-usb4.png`: both hosts in one VM.

**Windows 98 SE**, 1024x768, with `ver` showing 4.10.2222. System Properties allows only one
window, so the General tab couldn't be shown alongside Device Manager.
- `win98-devmgr.png`, `win98-devmgr-orico.png`: xhci98 2.4.0.0, then the root hub, then the
  ORICO fallback USB disk.
- `win98-devmgr-ts3plus.png`: Alpine Ridge tree with the NVMe behind the tunnel.
- `win98-devmgr-tb3-usb4.png`: both hosts in one VM.

**Caveats you may want to fix before publishing:**
- **Windows 11, Thunderbolt NHI.** It shows as "Base System Device" with a warning: no image
  has Intel's Thunderbolt driver installed. One shot has its Properties dialog open.
- **Windows 11, TS3 Plus on the USB4 host.** This fails with Code 10, so the TS3 shots use the
  Alpine Ridge host. The fix agent is investigating.
- **Windows 98, NHI.** It shows as "PCI System Peripheral ?", because there's no 9x NHI driver.
  The generic USB4 host shows as "PCI Universal Serial Bus ?": xhci98 has no USB4 host driver.
- **Windows 98, xhci98 version.** The shots use xhci98 2.4.0.0, not the 3.0.0.0 dry cut. The
  ORICO appears as a Bulk-Only USB disk, not "ASMedia ASM246X" UAS. On 98 the dock and the
  ORICO show only their NVMe, because i440FX supports one bridge level.
- **Windows 98, tunnels.** They were brought up from QMP after boot, because devices present
  at power-on hang 98 SE. A fix agent is working on that hang.
- **Re-shoot option.** If you want the 3.0.0.0 dry-cut build and the UAS identity in the 98
  shots, they can be redone.

## Emulator: Windows 11 Code 10 on the TS3 dock is FIXED (branch only, not merged)

- **Branch:** `usb4-win11tb3` (bbc1725 + d5bfd79), docs on `usb4-win11tb3-docs` (99ff97c).
- **What was wrong:** Windows reads a TB3 router's flash through its DMA port, which Linux
  doesn't need. The model hid that port, and an erased eGPU dword at flash 0x734 failed
  Windows' validation.
- **Fix:** expose a read-only DMA port, under a software CM only.
- **Tests:** Win11 binds the dock, its PCIe devices and NVMe, and a chained ORICO; data is
  intact. Linux and the replays are unchanged, with a slight improvement on the dock.
- **Review:** **Codex-cleared** after the P2 fixes. Current heads are QEMU `d99e41b` + `20c8784`
  and docs `a0f1a50`. The Microsoft symbol names and diagnostic text are gone, verified by
  grep across the code, the docs and the commit messages. It can merge once you decide on the
  disassembly-method paragraph (item 0) and give the go-ahead to move main.

## Emulator: Win98 hang at the logo with a disk at power-on, root-caused (branch only)

- **Cause:** a QEMU core bug in the TCG emulator's SMM handling. It is not in our USB4 model,
  SeaBIOS or the image.
  - TCG's address-translation cache doesn't separate SMM from normal mode.
  - After IO.SYS draws the logo, the cached VGA mapping at 0xa8000 is reused when SeaBIOS
    enters SMM for a disk call.
  - The CPU then runs logo pixels.
- **Fix:** flush the cache on SMM entry and exit, in `target/i386/tcg/system/smm_helper.c`.
  Branch `usb4-posthang` 5748fdd, docs on `usb4-posthang-docs` 305500f. There is a new qtest.
- **Tests:** Win98 SE boots with the TS3/NVMe pre-boot and with the ORICO, both as pre-boot
  and as USB fallback. Data verified. xhci98's image has the same bug with different timing.
- **Review:** **Codex-cleared** at QEMU `0702fa0` and docs `da21183`. The new qtest also covers
  the flush on SMM exit (RSM): it fails when only that flush is removed. It stays unmerged, as
  you asked; it is ready to land with the Win11 dock fix once you OK moving usb4-emu main.
  xhci98 should hear about this one: their image has the same latent bug. Like the NVMe fix, it is
  a local fork fix. Upstreaming would be your decision, under QEMU's AI-content policy.

## Interface 3: second fix round done, Codex re-review 3 running

These header-rule changes alter what xhci98 builds against. They are listed here for your D4
decision, because your pre-approval covered adoption with no P0/P1, not design changes:

1. **R6f, new rule.** The CM worker handoff uses one state word plus an operation id, moving
   IDLE→SUBMITTED→RUNNING→DONE→IDLE with a locked compare-exchange. A result is accepted only
   for the submitted id. Separate busy and done flags are no longer allowed.
2. **R11 O6.** The 30 s limit is now elapsed time from the first Remove_SubTree attempt, even
   while a call is still running, and that call stays with its port.
3. **R11 / R12 S4.** The CM checks its deadline before reading the acknowledgement, so a late
   acknowledgement never changes the verdict.
4. **R10.** Only nvme98's internal thresholds changed, to 8500/5500 ms. The published bounds
   are unchanged: 12000 ms for the receiver and 14000 ms for the CM wait.
5. **R6e.** The wording is narrowed. Behaviour is unchanged.

Accounting now uses a checked `AcctRef` value plus an `AcctBoot` marker, and fails closed
when a CM is present.

**Codex re-review 3:** no P0 or P1 findings remain; the P1 worker handoff is fixed. Five P2s are
still open: an accounting edge case, a late DONE after the O6 deadline, and three decoder
issues. A fourth fix round is under way.

**Interface 3 is CLEARED by Codex at qual-9x `cf56ccd` after five re-review rounds: no
findings, adoption-ready.** The integration agent is merging it into int-0.2 now. Because
the header rules changed (R6f, O6, late acks), I haven't treated D4 as adopted or told
xhci98. Please confirm adoption in the morning, and I'll send xhci98 the final interface 3
message.

Earlier round: **fourth fix round done (qual-9x 97f0050), Codex re-review 4.** One more
header clause for xhci98, in R11 O6: "a call that completes after the deadline counts for the
O6 retries, never as a clean removal".

## Waiting for you

0. **Licensing check, important.** To find the 0x734 rule, the agent disassembled Microsoft's
   `Usb4DeviceRouter.sys` with objdump. The binary and its disassembly are local only, in
   `E:\usb4-emu-vms\win11tb3`, and are not committed. However, the docs commit describes
   "the disassembly method" in WINDOWS-DEBUG and cites internal function names. Microsoft's
   licence may restrict reverse engineering, and AGENTS.md says "facts, not text". Options:
   - (a) Keep only the interoperability facts: "Windows reads flash 0x734 and needs bits 11:9
     ≤ 6". Drop the method and the function names from the docs, delete the local
     disassembly, and don't reverse-engineer Microsoft binaries again.
   - (b) Keep as is.
   - (c) Drop the 0x734 fact as well and find another basis.
   Recommendation: (a). The code fix itself contains no Microsoft code.
   **Codex check (done):** there is no Microsoft binary, listing or code in the diffs. It did
   find one reproduced Microsoft diagnostic string and three internal Microsoft function names,
   in the docs, in a code comment and in the commit message. Those are being paraphrased or
   removed now, which follows from Codex's review whatever you decide. Still held for you: the
   disassembly-method paragraph in WINDOWS-DEBUG.md (lines 231-235), and deleting the local
   copy of the binary and its disassembly. No further Microsoft binaries will be disassembled.

1. **D3 registry location.** On 9x the write-through setting is the REG_SZ `WriteThrough`
   under `HKLM\System\CurrentControlSet\Services\nvme98`, the same key as the CM locator.
   It isn't in the adapter's driver key, because a miniport has no documented route to its
   devnode. The values are `auto` (the default; cache off on Me, unchanged elsewhere), `off`,
   `cacheoff` and `fua`. On NT the setting is `writethrough=` in DriverParameter. Accept, or
   choose another location? The INF doesn't write a default yet.
2. **Me "Disk Write Error" still appears after a surprise removal, even with write-through
   on.** The failing writes are VFAT lazy writes that arrive after the device has gone; the
   driver never had that data. The remaining options:
   - (a) The release notes tell Me users to eject cleanly first. The clean-eject handshake
     flushes before removal.
   - (b) The INF or readme disables Me file-system write-behind for removable disks. This
     costs performance on every disk the setting covers.
   - (c) Both.
   Recommendation: (a), plus documenting (b) as an optional setting.
