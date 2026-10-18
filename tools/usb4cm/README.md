# usb4cm: a polling reference USB4 connection manager

`usb4cm` is a small USB4 software connection manager (CM) written in C89. It is
for the xhci98 project, which will write a USB4 CM for its Windows 98 and Windows
2000 drivers. It shows that the legacy path works end to end: a polling CM with no
interrupts and 32-bit DMA brings up a PCIe tunnel on the `usb4-generic` profile,
and the NVMe appears behind the i440FX tunnel bridge. Its code is meant to be
copied into xhci98.

| Path | What |
|---|---|
| `core/` | The CM core. Strict C89, no OS calls, all hardware access through callbacks. GPL-2.0-only. |
| `host/` | Host test: links the core to the usb4-emu fabric model and checks that the tunnels come up. |
| `dos/` | `USB4CM.EXE`, a DOS front-end (Open Watcom 2.0, DOS/32A), the same approach as xhci98's `XHCIQUAL.EXE`. |

All of it was written from the USB4 Specification 2.0 ("Spec") and the USB4
Connection Manager Guide 2.0 ("Guide"), with tbtools `registers.json` as a
cross-check of field positions. It uses no Linux or FreeBSD code.

## Core architecture

```
 front-end (DOS, WDM driver, host test)
   | U4CM_OPS: mmio_rd/mmio_wr (BAR0), dma_alloc (<4 GB), udelay, log
   v
 u4hi.c  host interface: HI reset, ring 0 TX/RX in Raw Mode, CRC32C,
         read/write requests with sequence numbers, timeout and retry,
         error notifications, hot plug event queue + acknowledgment
   v
 u4cm.c  CM: host router enumeration, adapter discovery by capability
         walk, device router per USB4 port, DROM via router operation,
         CV/CR handshake, lane bonding, PCIe and USB3 tunnel paths
```

- **Polling only** (Spec 12.3, 12.4). Interrupts stay masked. A TX descriptor
  counts as consumed when the Consumer Index passes it or DD is set. An RX frame
  is ready when its descriptor has DD set. The CM then gives the descriptor back
  by writing its index as the RX Consumer Index. The core never reads or clears
  the interrupt status register, so the profile's read-clears rules
  (ARCHITECTURE.md §4.1) do not affect it.
- **Transport** (Spec 6.4). One request is outstanding at a time, with a 2-bit
  sequence number. A response must echo Address, Size, CS and SN. The Adapter
  field is not compared, because for Router CS requests the router reports the
  adapter that the request arrived on. An error notification (event code below
  32) fails the request at once and its code is left in `last_event`. A timeout
  retries up to `retries` times (default 3) with a new sequence number. A hot
  plug event that arrives at any point is acknowledged at once (HP_ACK with
  PG = 2 or 3) and queued, and copies the router retransmits are dropped.
- **Host router** (Guide 3.2.1, 3.2.2). The CM writes ROUTER_CS_1..4 in a single
  write: depth 0, TopologyID Valid, CM USB4 Version 1.0. It then waits for Router
  Ready and walks every adapter's capability list. A lane adapter that has a USB4
  Port Capability is lane 0 of a port, and lane 1 is the next adapter. The Nth
  PCIe Down and USB3 Down adapters are taken to belong to port N. That mapping is
  a platform property: it holds for the model, but a real host needs a check, for
  example with the Get PCIe Downstream Entry Mapping router operation.
- **Device router** (Guide 3.1.1, 3.2). The CM uses lane 0 in CL0 to decide that
  something is connected, so a device that was already attached at boot, and sent
  no hot plug event, is still found. It then clears Lock on both lanes of the
  downstream-facing port, enumerates at route = host lane 0 adapter and depth 1,
  discovers adapters, and reads the DROM with the DROM Read router operation
  (meta = dword address, size in [19:15]). It checks the CRC32C and parses the
  ASCII vendor and model entries.
- **Lane bonding** (Guide 7.1). The CM sets Target Link Width to dual on both
  lanes at both ends, then sets Lane Bonding on host lane 0. It waits for the
  negotiated width x2 and acknowledges lane 1's hot unplug. If the lanes are
  already bonded, or lane 1 is not in CL0, it skips this step.
- **PCIe tunnel** (Guide 3.2.3, 5.2.1, 5.3.1). On the device router the CM sets
  PTO, then CV, and waits for CR. It then programs four path entries, reading and
  writing each one once:
  - host PCIe Down HopID 8 to host lane HopID 8
  - device lane HopID 8 to device PCIe Up HopID 8
  - device PCIe Up HopID 8 to device lane HopID 9
  - host lane HopID 9 to host PCIe Down HopID 8

  Each entry gets priority 3 and weight 1. A lane-ingress entry gets IFC and 32
  credits; a protocol-ingress entry gets EFC and ESE. Path Enable is set on the
  device PCIe Up adapter first, then on the host PCIe Down adapter. The CM then
  waits for LTSSM L0 on the host adapter.
- **USB3 tunnel** (Guide 5.5.1), optional. It uses lane HopIDs 10 and 11, PE and
  V on both USB3 adapters, then UTO.
- **Re-runnable.** A second run on a configured fabric re-writes the same values
  and causes no tunnel transition. The host test checks this.

Not implemented: TMU configuration, daisy chains (depth 2 and deeper), DisplayPort,
unplug handling after the run, credit sizing from the adapters' buffer counts
(fixed 32), the TB3 dialect and ICM, and USB4 v2 features.

### Callback contract (`core/usb4cm.h`)

| Callback | Contract |
|---|---|
| `mmio_rd(ctx, off)`, `mmio_wr(ctx, off, v)` | 32-bit access to BAR0 at byte offset `off`. The core touches only ring 0 registers, HI caps/reset and IMC (below 0x3a000). |
| `dma_alloc(ctx, size, align, &phys)` | Called once in `u4cm_init`: about 9 KB, zeroed, physically contiguous, 32-bit physical address, cache-coherent. The caller frees it after `u4cm_stop`. |
| `udelay(ctx, us)` | Busy wait of at least `us`. Millisecond granularity is fine (DOS uses `delay()`). Every timeout is counted through it, so a fake clock makes the core deterministic, as in the host test. |
| `log(ctx, lvl, fmt, a, b, c, d)` | printf-style with four `u32` arguments (`%lx`, `%lu`, `%ld`). No varargs in the core. A WDM driver can pass it straight to `DbgPrint`. |
| `logs(ctx, lvl, prefix, s)` | String log (DROM names). |

The core keeps all its state in one `U4CM` struct, about 4 KB. Its deepest call
chain, a DROM read, uses about 2 KB of stack, which fits a Windows 98 kernel
stack. It does no allocation beyond
`dma_alloc` and uses no 64-bit arithmetic: route strings are `{hi, lo}` dword
pairs and DMA addresses are 32-bit. It does not depend on any library: no libc,
no `<stdint.h>`. `u4types.h` defines `u8/u16/u32`. Define `U4_HAVE_TYPES` to
supply them yourself, for example as the DDK's `UCHAR/USHORT/ULONG`.

API: `u4cm_init`, `u4cm_run(flags)` (or the individual steps
`u4cm_host_init`, `u4cm_connect`, `u4cm_pcie_tunnel`, `u4cm_usb3_tunnel`),
`u4cm_poll` (acknowledges hot plug events while idle), `u4cm_stop`, and the raw
`u4cm_read` / `u4cm_write`.

### What xhci98 can lift

- `core/` as it is: it already follows xhci98's "pure, DDK-free core" rules (C89,
  no bitfields, dword plus mask macros, no 64-bit math). Compile with
  `XHCI_HOST_TEST`-style host tests (see `host/`) and inside the driver with
  `U4_HAVE_TYPES`.
- In a WDM driver, back `dma_alloc` with a common buffer below 4 GB, `udelay`
  with `KeStallExecutionProcessor`, and the MMIO callbacks with
  `READ/WRITE_REGISTER_ULONG`. Run `u4cm_run` from a worker thread, not at
  DISPATCH_LEVEL, because it busy-waits. A timer can call `u4cm_poll`
  periodically to acknowledge hot plug events.
- After the tunnel comes up, the driver must make the PnP manager enumerate the
  bridge's secondary bus again (ARCHITECTURE.md §7). The DOS front-end shows that
  the endpoint answers config cycles on that bus once the tunnel is up.

## Build and run

### Host test (MSYS2 gcc + glib, the same toolchain as the fabric test)

```bash
scripts/msys2-shell.sh "$PWD/tools/usb4cm/host/run-host-test.sh"
```

It first compiles the core with `gcc -std=c89 -pedantic -Werror
-Wdeclaration-after-statement`. It then links the core against the model's
`usb4-ctl/fabric/router/drom/tunnel` sources through a ring 0 shim that does
Raw Mode TX/RX in a fake physical arena, and runs four scenarios:

- device attached before the CM starts, then a second run with no transition;
- both ports, with port 2 hot plugged after host enumeration, plus USB3 tunnels
  and no hot plug retransmits left over;
- nothing attached;
- the Spec A.2 CRC vectors.

Result (2026-10-14): `8855 checks, 0 failures`.

### DOS: `USB4CM.EXE`

```
tools\usb4cm\dos\build.cmd        (Open Watcom 2.0 at C:\WATCOM; outputs stay in tools\usb4cm\dos)
USB4CM [/USB3] [/NOBOND] [/V] [/WAIT:s] [/LOG:file]
```

`USB4CM.EXE` does the following:

1. Finds the first PCI function with class 0C0340 by mechanism #1.
2. Sets Memory Space and Bus Master in its command register.
3. Maps 256 KB of BAR0 with DPMI 0800h.
4. Allocates the ring memory in conventional memory with DPMI 0100h. In the flat
   model, linear equals physical below 1 MB.
5. Runs the core.
6. Polls the secondary bus of every PCI-to-PCI bridge until a 1B36:0010 or class
   010802 function answers. It waits up to `/WAIT` seconds, default 10.

`/V` logs every control packet. Exit code 0 means a tunnel came up and the NVMe
answered.

The EXE embeds the DOS/32A extender as its stub (`wlink system dos32a`), under
the DOS/32 Advanced DOS Extender licence (BSD-style; `C:\WATCOM\binw\license.d32`).
It requires the acknowledgment "This product uses DOS/32 Advanced DOS Extender
technology.", which the program prints in its banner and this file repeats. The
Open Watcom C runtime linked into the EXE is under the Sybase Open Watcom Public
License. The EXE is a build output and is not committed.

## Validation in the Windows 98 VM (2026-10-14)

Setup: an overlay of the Windows 98 SE disk, so the base install is untouched.
The machine is i440FX under TCG with `-cpu pentium3,-apic`. The USB4 devices are
`usb4-host` on the `usb4-generic` profile with `msi=off,msix=off`, and
`usb4-tunnel-bridge` with `shpc-autoenable=on,msi=off`. `x-force-tunnel` is
not used, and the NVMe is QEMU's `nvme` on an overlay of `nvme32.qcow2`.
`USB4CM.EXE` is on a read-only vvfat disk, which DOS sees as D:. The overlay's
`MSDOS.SYS` has `BootGUI=0`, so the VM boots to the DOS 7.1 prompt.
`AUTOEXEC.BAT` runs `D:\USB4CM.EXE /LOG:C:\USB4CM.LOG`.

```bash
qemu-img create -f qcow2 -b ../win98/win98.qcow2 -F qcow2 vms/win98-refcm/win98.qcow2   # then BootGUI=0 + AUTOEXEC.BAT
qemu-img create -f qcow2 -b ../win98/nvme32.qcow2 -F qcow2 vms/win98-refcm/nvme32.qcow2
VM_DIR=$PWD/vms/win98-refcm NVME=$PWD/vms/win98-refcm/nvme32.qcow2 QMP_PORT=47650 VNC_PORT=47651 \
  scripts/run-win98.sh -drive if=ide,index=1,format=raw,snapshot=on,file=fat:16:vms/win98-refcm/fat \
  -trace 'usb4_*' -D vms/win98-refcm/usb4-trace.log
```

The DOS run worked first time, with no model changes. `C:\USB4CM.LOG` from the
guest, abridged:

```
USB4 host 00:04.0 1b36:00f4 BAR0 fea00000
Ring 0 up (DMA block at 00014b00). Running the CM...
    router 00000000000000: 46f4:4040 enumerated
    host USB4 port 1: lane adapters 1/2, PCIe Down 6
    router 00000000000001: 46f4:0004 enumerated
    DROM version 3, 63 bytes, CRC32 ok  (vendor QEMU, model USB4 NVMe Enclosure)
    port 1: lanes bonded, x2
    port 1: PCIe tunnel adapter 6 <-> 3, ADP_PCIE_CS_0 8c010400
Control packets: 286 sent, 286 received, 0 retries, 0 CRC errors
Port 1: PCIe tunnel UP
  bridge 00:05.0, secondary bus 01:
    01:01.0 1b36:0010 class 010802  <- NVMe
NVMe controller found behind the tunnel.
```

The QEMU trace has the CM's ring 0 packets, for example `usb4_host_frame_decode
ring0 TX WRITE route 0x0000000000000000 cm 0 cs 2 adapter 0 addr 0x1 dwords 4`.
It then has `usb4_tunnel_transition router 0x1 PCIe tunnel up reason 0`,
`usb4_tp_insert tb0: insert endpoint gen 1 drive=nvme0 serial=USB4EMU01 cold=0`
and `usb4_tb_autoenable tb0: shpc-autoenable: slot Enabled on insertion`.

**DOS to Windows.** Typing `win` at the prompt afterwards starts the Windows 98
GUI without a machine reset, so the fabric and the tunnel stay up. The trace
shows no further transition. Windows enumerates the NVMe at startup with no
Device Manager Refresh, and Explorer shows **Nvme32 (F:)** with its
`README.TXT`. C: is the system disk, D: the vvfat disk and E: the CD-ROM. A
real reboot (reset) would reset the fabric and take the tunnel down, so the CM
would have to run again.
