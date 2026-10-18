# AGENTS.md

Guidance for AI coding agents and new contributors working in this repository.

## What this repository is

A Thunderbolt 3 / USB4 host emulator for QEMU. The end goal is a device model faithful
enough that an operating system's connection manager (CM), whether in the guest or emulated
firmware, can enumerate routers and bring up a PCIe tunnel to an NVMe endpoint. It exists so
the xhci98 project can develop drivers for Windows 98 through Windows 7 without real
hardware. This repository is the QEMU model only. Those drivers are not developed here.

The real demo hardware is a ThinkPad P14s Gen 1 with an Intel JHL6240 Alpine Ridge LP
Thunderbolt 3 controller (NHI `8086:15bf`, confirmed by the 2026-10-14 capture), so the
Alpine Ridge firmware-CM profile `tb3-alpine-ridge` is the first target. Titan Ridge is
an uncaptured later variant, modelled from the Linux client only as
`profile=tb3-titan-ridge` (`docs/ICM-TITAN-RIDGE.md`).

Read these first, in order:

1. `docs/ARCHITECTURE.md` for the two host profiles, the component split and the
   guest-visible contract.
2. `docs/ROADMAP.md` for the current milestone and its exit criterion.
3. `docs/REFERENCES.md` for where the specs and reference sources are and what each
   licence allows.
4. `docs/ICM-PROTOCOL.md`, started in M0 with the Intel host interface MMIO semantics and
   completed with the Alpine Ridge firmware CM wire contract from the P14s capture.
   Intel-specific MMIO and ICM code is implemented from that document.

## Layout

| Path | Contents |
|---|---|
| `docs/` | Design docs. Committed. |
| `docs/references/` | Third-party specs and sources. Git-ignored. Re-fetch per `docs/REFERENCES.md`. |
| `src/qemu/` | QEMU working tree: upstream v11.1.2 plus our patches on branch `usb4-emu`. Git-ignored; recreate with `src/setup-qemu.sh`. Device code under `hw/usb4/`. |
| `src/patches/` | The QEMU fork as a committed patch series (`git format-patch` of `usb4-emu` against the pinned tag). Regenerate with `src/export-patches.sh`. |
| `src/build-qemu.sh` | Configure and build a QEMU tree with the MSYS2 toolchain. |
| `vms/` | Guest disk images, firmware vars and logs. Git-ignored. |
| `tests/` | Guest-side test scripts and image manifests. |
| `tests/captures/` | Register, sysfs, DROM and trace captures from the real P14s Gen 1. Golden data. |
| `NOTICE` | Copyright and licence notices for incorporated Linux (GPL-2.0-only), BSD and MIT material. |

## Ground rules

- **Cite the reference.** When implementing register semantics, name the USB4
  Specification 2.0 or CM Guide 2.0 section in a code comment. For Thunderbolt 3 dialect
  and ICM behaviour, which have no public spec, cite `docs/ICM-PROTOCOL.md` or the
  hardware capture that confirms it.
- **Two profiles, one fabric.** `tb3-alpine-ridge` impersonates an Intel controller on
  purpose so guests take the firmware-CM path. `usb4-generic` must never use Intel PCI IDs. Exception (maintainer,
  2026-10-14): the opt-in `host-model=intel-adl` preset reports Intel's router vendor ID
  (8087) inside USB4 config space, as the captured Alder Lake host does; its PCI identity
  stays emulator-specific and the default `host-model=minimal` uses no Intel IDs.
  Second exception (maintainer, 2026-10-15): the opt-in Thunderbolt 3 device router
  `usb4-device dialect=tb3` reports Intel's TB3 router ID (8086:15d3, as the captured
  CalDigit TS3 Plus does) inside USB4 config space on any `usb4-generic` host, because
  Linux treats a non-Intel TB3 router as generation 1 and skips its link controller and
  Plug Events setup. No Intel PCI ID is used on the generic profile.
  Both drive the same ring engine, fabric, tunnel evaluator and PCI integration; profile
  differences live in a thin profile layer (PCI identity, interrupt clearing mode, config
  dialect, who programs paths). Do not fork the shared parts.
- **The emulated ICM programs paths like a guest would.** It writes the same fabric state a
  software CM writes, so the tunnel evaluator stays profile-agnostic and unit-testable.
- **Polling must work.** Descriptor completion and ring indices are visible as soon as a
  descriptor completes, independent of interrupt delivery or masking. Interrupt status is
  cleared only by the rules in `docs/ARCHITECTURE.md` §4.1, which depend on the profile
  and on the guest's control-register settings, or by host interface reset. Never clear
  status for any other reason.
- **Never hot-plug from MMIO context.** Endpoint realisation and removal run from a bottom
  half.
- **Gate before you unplug.** A tunnel going down closes the access gate synchronously,
  in the same call that changed the fabric state: MMIO, config writes, new DMA and
  interrupts stop at once. Quiesce, hot-unplug and removal follow from a bottom half and
  the guest may delay the eject. DMA gating uses the tunnel bridge's secondary-bus gate
  address space, never the bridge's own bus-master bit. Emulator removal work is
  generation-checked, and a replacement endpoint waits until the guest has acknowledged
  the empty slot or a settle timeout expires. Slot power and indicator state set by the
  guest persists across the empty interval and applies to the replacement; on the SHPC
  bridge the subclass enforces that state through the access gate, because stock SHPC
  does not. Legacy guests without an SHPC driver use `shpc-autoenable=on`, which
  only acts on slots the guest has never commanded since bridge reset; any explicit
  guest slot command takes precedence. See
  `docs/ARCHITECTURE.md` §4.4.
- **Do not write an NVMe model.** The endpoint is QEMU's existing `nvme` device. This
  repo only decides when it is reachable.
- **Legacy Windows guests are first-class targets.** The xhci98 drivers for Windows 98
  through Windows 7 will use this model. Anything that only works with MSI, PCIe extended
  config space, or 64-bit DMA addresses is a bug unless it is behind the q35 profile.
- **Record milestone exits.** When a `docs/ROADMAP.md` exit criterion is met, add the date
  and how it was verified under that milestone.
- **Do not commit `docs/references/`.** It is ignored for licence and size reasons.

## Licence rules

This repository is GPL-2.0-only (relicensed from MIT by the maintainer on 2026-10-15, to
match xhci98 and to allow adapting Linux code). Files written here carry
`SPDX-License-Identifier: GPL-2.0-only` and their own copyright line. The reference
material has four licence classes and each has a rule. See the table in
`docs/REFERENCES.md`.

- **GPL-2.0-only (Linux `drivers/thunderbolt`).** Code, structure definitions and tables
  may be adapted. A file that adapts Linux code keeps the copyright lines of the Linux
  file(s) it came from, is `GPL-2.0-only`, names the source file(s) in its header and is
  listed in `NOTICE` with the source file and the pinned Linux commit from
  `docs/REFERENCES.md`. Linux is GPL-2.0-only, not "or later", so nothing here may be
  relicensed to a later GPL version.
- **BSD-2-Clause (FreeBSD `sys/dev/thunderbolt`) and MIT (Intel tbtools).** Code and data
  may be adapted. An adapted or substantially derived file keeps the original copyright
  line, licence conditions and disclaimer in its header, with an SPDX tag, and is listed
  in `NOTICE`. Generated tables from `registers.json` carry the tbtools copyright and
  permission notice. Keep the incorporated notice intact when the file also contains
  GPL-2.0-only work from here.
- **USB-IF and Microsoft documents.** Cite section numbers. Facts, not text.
- **No code flows into nvme98.** nvme98 is a separate BSD-3-Clause project. Code from this
  repository (GPL-2.0-only) must not be copied or adapted into it. xhci98 is
  GPL-2.0-only and may adapt code from here, keeping the notices.

Accuracy rule, independent of licensing: the hardware captures in `tests/captures/` are
the source of truth. Behaviour taken only from Linux (or any other driver) is tagged
`inferred` in the docs until a capture confirms it, and `observed` only when a capture
shows it. Inferred behaviour is a hypothesis. Adapting Linux code does not make its
behaviour observed.

History: until 2026-10-15 Linux was a behaviour-only reference under a clean-room
process (a reader wrote descriptions into `docs/`, implementers worked only from those).
`docs/ICM-PROTOCOL.md` and the code built from it were written that way. That
requirement is withdrawn; those documents stay valid and need not be rewritten.

## Working with the references

- Register layouts: `docs/references/tbtools/registers.json` is machine-readable and is the
  source for generated bitfield tables. `docs/references/freebsd-thunderbolt/sys_dev_thunderbolt/tbcfg_reg.h`
  and `nhi_reg.h` are the BSD-licensed cross-check.
- BSD-licensed code reference: `docs/references/freebsd-thunderbolt/sys_dev_thunderbolt/`.
  `nhi.c` and `nhi_reg.h` for rings, `router.c` and `tbcfg_reg.h` for control packets and
  router config, `hcm.c` for the host CM skeleton. It has no ICM code and its CM is less
  complete than Linux. Linux is the more complete source and may also be adapted (see
  "Licence rules").
- Control protocol: Spec §6 and Appendix A.2 for CRC test vectors; `tb_msgs.h` in the
  Linux sources.
- ICM protocol: `icm.c` (Alpine Ridge functions are prefixed `icm_ar_`, and Alpine Ridge
  also reuses the Falcon Ridge `icm_fr_` event and approve handlers; Titan Ridge ones are
  `icm_tr_`), `nhi.c` mailbox functions and the matching structures in `tb_msgs.h`.
  `docs/ICM-PROTOCOL.md` is the reviewed description and records which parts are
  observed on the P14s.
- Thunderbolt 3 dialect: `lc.c`, `eeprom.c`, `cap.c`, `dma_port.c` and the `TB_VSE_CAP_*`
  definitions in `tb_regs.h`.
- What a software CM does: the CM Guide 2.0 PDF. The Linux `tb.c`, `switch.c`, `usb4.c`,
  `path.c` and `tunnel.c` files are the worked example.
- Windows 11 platform requirements: `docs/references/microsoft/*.txt`.

## Validation

- M1 is validated by qtests and a ring-level test driver only. Unmodified Linux binding
  is an exit criterion of M2 (Alpine Ridge profile) and M4 (generic profile), because the
  Linux probe unwinds if CM startup fails.
- Linux success looks like the expected CM type in `dmesg`, the device router under
  `/sys/bus/thunderbolt/devices`, and a working `/dev/nvme0n1` after authorisation.
  Per-device deauthorisation only exists on the generic profile.
- Windows 11 with the pinned Intel Thunderbolt driver package is a smoke gate in M3 and
  full validation in M5; the built-in Windows CM on the generic profile is M5.
- Legacy Windows (98 through 7) is tested from the xhci98 project, on the i440FX machine
  with the `pci-bridge`-based tunnel bridge. Keep that profile working even though it is
  not validated here.

## Conventions

- Device code is C in QEMU style (`checkpatch.pl` clean, QOM types, `qemu/osdep.h` first).
- Property names on the QEMU devices use the terms from the USB4 spec: router, adapter,
  path, HopID, tunnel. Use Thunderbolt-era names only where the TB3 dialect or ICM defines
  them.
- Commits are small and each one builds. Commit messages end with the attribution line
  required by the session that produced them.
