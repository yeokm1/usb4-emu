# Test harness

Deterministic fault injection for the NVMe endpoint behind a tunnel
bridge. It exists for nvme98's phase-0.0 feasibility gates and its
recovery tests: the "Harness work needed" table in nvme98
`docs/TESTING.md`, and PLAN 0.0 and 0.10. All of it is test-only. Every
property starts with `x-`, defaults to off and changes nothing until it
is set.

Faults fire **synchronously in the device model**, in the same call that
observes their trigger: the NVMe controller fetching a command, a
completion about to be posted, or a guest write to the debug port. They
do not depend on following QMP or trace output. Gate actions use the
stage 1 gate of `ARCHITECTURE.md` §4.4, so a gate-close lands between
two guest steps. QMP and hook-driven gating are test stimuli only. A
driver never treats them as evidence (PLAN 0.0). See
[Exact-point and event-following tests](#exact-point-and-event-following-tests)
for what "synchronous" guarantees and what it does not.

Code: `hw/usb4/usb4-harness.c`, `hw/usb4/usb4-debug-port.c`, the gate
override in `hw/usb4/usb4-tunnel-slot.c`, and a small hook in QEMU's
NVMe model (`include/hw/nvme/nvme-test-hook.h`, marked "usb4-emu test
hook" in `hw/nvme`). Tests: `tests/qtest/usb4-harness-test.c`.

## Where the controls live

Every harness property is on the tunnel bridge: `usb4-tunnel-port`
(q35), `usb4-tunnel-bridge` (i440FX) or `usb4-tunnel-dsp`. It acts on
the NVMe controller behind that bridge, including the NVMe of a dock.
Each property can be set at start-up on `-device` and changed at run
time with `qom-set` on the bridge path:

```
-device usb4-tunnel-bridge,id=tb0,...,x-rdy-set-delay-ms=2000
{"execute":"qom-set","arguments":{"path":"/machine/peripheral/tb0",
 "property":"x-faults","value":"at=fetch op=read nth=3 act=surprise"}}
```

Within `-device`, a value cannot contain a comma. Quote values that
contain spaces or `;` for the shell.

The hook is installed on every endpoint the bridge inserts. Settings
persist across tunnel down and up, and apply to the next endpoint. Rule
match counters persist until `x-faults` is set again. A rejected value
(a malformed rule, an out-of-range number) leaves the previous setting
in force.

| Property | Type | Effect |
|---|---|---|
| `x-faults` | string | Fault rules, separated by `;` (below). Setting it replaces the rules and resets their counters |
| `x-release` | string | Write: release held commands. `all`, `tag:<name>`, `reopen`, `rdy0-ack` or a token number. Read: the held tokens. Tokens are unique across endpoints: a token of a removed endpoint never names a command of its replacement |
| `x-gate` | string | `normal`, `closed` or `reads-fail`. A harness gate override with no endpoint reset (below). Setting `normal` reopens |
| `x-rdy-set-delay-ms` | int | After CC.EN goes 0 to 1, CSTS.RDY reads 0 for this many ms. `-1` means RDY never reads 1 |
| `x-rdy-clear-delay-ms` | int | After CC.EN goes 1 to 0, CSTS.RDY reads 1 for this many ms. `-1` means a failed disable: RDY never clears |
| `x-shst-delay-ms` | int | After CC.SHN is set, CSTS.SHST reads 01b (occurring) for this many ms. `-1` means never complete |
| `x-cfs` | bool | CSTS.CFS reads 1 |
| `x-hang` | string | `off`, `stuck` or `ones`. A hung controller behind a live tunnel (below) |
| `x-intx-drop-every` | uint | Suppress every Nth INTx assertion of the endpoint. `0` is off |
| `x-intx-drop-range` | string | Suppress assertions `A-B` (1-based, inclusive). Empty is off |
| `x-marker-doorbell` | uint | A BAR0 offset (an unused doorbell, e.g. `0x1ff8`). Writes there are traced as clock markers and dropped. `0` is off |
| `x-harness-state` | string (read) | Held commands, INTx counters, stage and marker counts, deferred-disable state, `ruleN=matched/fired` (`:off` for a disarmed rule) |

Timing faults change what the guest reads, not what the controller does.
Delays run on `QEMU_CLOCK_VIRTUAL`. Under qtest that clock advances with
`clock_step`. In a running VM it follows host time.

- With `x-rdy-clear-delay-ms`, the controller has already reset. Only
  CSTS lies.
- With `x-rdy-set-delay-ms`, the controller is already running. A driver
  that rings doorbells before RDY would be served.
- `x-cfs` only sets the status bit.
- The delays count from the guest's CC writes. A function-level reset of
  the endpoint (FLR, PCI reset, the slot's quiesce) clears CC behind the
  guest's back: the harness then forgets the CC value it saw, so the next
  CC.EN=1 starts the RDY set delay again. The reset also unfreezes a
  `stuck` CSTS and drops a deferred disable (below). Configured faults,
  rules, counters and `x-hang` stay.

## Fault rules (`x-faults`)

A rule is a list of `key=value` items separated by spaces. Rules are
separated by `;`.

```
at=fetch op=read lba=2048-2055 nth=2 act=hold delay=6000 tag=r1
```

**Trigger (`at=`, required):**

| `at=` | Fires when |
|---|---|
| `fetch` | The controller has fetched a matching command from a submission queue, before the command executes (before any data transfer). This is after submission: the guest wrote the SQ entry and rang the doorbell, and the controller consumed the entry (the SQ head moves past it) |
| `complete` | The completion of a matching command is about to be queued for posting. Data has been transferred; the CQE and interrupt have not happened yet |
| `stage` | The guest writes a matching stage code to the debug port, before that write returns |

**Match keys** (all optional):

| Key | Values |
|---|---|
| `sq` | `any` (default), `admin`, `io` (any I/O queue) or a queue ID |
| `op` | A name or an opcode number. Names: I/O `read`, `write`, `flush`, `compare`, `write-zeroes`, `write-uncorrectable`, `dsm`, `verify`; admin `identify`, `abort`, `create-sq`, `create-cq`, `delete-sq`, `delete-cq`, `get-log-page`, `set-features`, `get-features`, `async-event`. A name also sets `sq=io` or `sq=admin` if `sq` is not given. A number needs `sq=` to choose between admin and I/O |
| `nsid` | Namespace ID |
| `lba` | `N` or `LO-HI`. Matches LBA commands (read, write, compare, write zeroes, write uncorrectable, verify) whose range `[SLBA, SLBA+NLB]` overlaps it |
| `code` | Stage code (`at=stage`). Without it, any code matches |
| `nth` | Fire on the Nth match (default 1) |
| `repeat` | `on`: fire on every match from the Nth on. Default `off` fires once |
| `armed` | `on` (default) or `off`. A disarmed rule neither matches nor counts until an `arm` action with its `tag=` |

**Actions** (`act=a+b+...`):

| Action | Effect |
|---|---|
| `surprise`, `eject`, `admin-down` | Take the tunnel down with that reason. Stage 1 closes the gate in this call. Stages 2-4 (endpoint reset at the cutoff, notify, remove) follow from the bottom half as usual |
| `gate` | Harness gate closed: all of stage 1 (MMIO/I/O all-ones, config all-ones, INTx masked, DMA alias off). No stage 2-4: the endpoint is not reset, quiesced or removed |
| `reads-fail` | MMIO/I/O and config read all-ones, writes are dropped and INTx is masked. **The DMA alias stays open** (MSI included) and the endpoint is not reset |
| `reopen` | End the harness gate override without reset, then release `release=reopen` commands |
| `hold` | `fetch` or `complete` only. Hold the command before it executes (`fetch`) or before its completion is posted (`complete`). Released by `delay=`, `release=`, `x-release` or a `release` action. A reset or queue deletion discards it, like any outstanding command |
| `drop` | `fetch`: consume the command without executing or completing it. `complete`: execute it but never post its completion |
| `release` | Release held commands with this rule's `tag=`, or all if it has none |
| `cfs` | Set `x-cfs` |
| `hang-stuck`, `hang-ones`, `unhang` | Set `x-hang` |
| `arm`, `disarm` | Arm or disarm every other rule with the same `tag=` (required). Every arming restarts the armed rule's match count, whether or not it was already armed, so its `nth=` counts from the latest arming trigger and a one-shot rule that already fired fires again |
| `reset-controller` | `stage` only. Reset the controller as if CC.EN went from 1 to 0, before the debug-port write returns: outstanding and held commands are discarded, CC reads 0 and CSTS.RDY reads 0 (no `x-rdy-clear-delay-ms`, the guest did not write CC). No-op while the controller is disabled |
| `none` | Nothing. Use it with `status=` or `dw0=` |

**Action parameters:**

| Key | Applies to | Values |
|---|---|---|
| `delay=MS` | `hold` | Release after MS ms of virtual time |
| `release=` | `hold` | `manual` (default), `rdy0-ack` or `reopen` (below) |
| `tag=NAME` | `hold`, `release` | Groups held commands for `x-release=tag:NAME` and `act=release` |
| `status=N` | `at=complete` | Replace the Status Field: Status Code Type in bits 10:8, Status Code in bits 7:0, DNR in bit 14. For example `0x6` is Internal Error |
| `dw0=N` | `at=complete` | Replace completion dword 0. For Abort, bit 0 = 1 means "not aborted" |

If several rules fire for one command, `drop` wins over `hold`. Every
side action runs.

Each firing is traced as `usb4_h_fire`, with host and virtual
nanoseconds. It also emits the QMP event `USB4_HARNESS` with
`qom-path`, `rule` (index), `trigger`, `token` and `actions`. Held
commands are identified by a token. Tokens appear in `x-release`,
`x-harness-state` and the traces `usb4_h_hold` and `usb4_h_release`.

When a released command runs:

- Released by `x-release`, `x-gate=normal`, `x-hang=off` (QMP) or by
  `delay=` (a timer): it runs to completion before the `qom-set` or
  timer returns. It is executed, its block I/O is drained and its
  completion is posted. The drain takes part in the tunnel slots'
  lifecycle serialization (`ARCHITECTURE.md` §4.4): no slot's quiesce,
  removal or insertion runs while it drains. A completion rule that takes
  the tunnel down during the drain closes the gate at once (stage 1);
  stages 2-4 follow after the release is done.
- Released by a rule action (a `fetch`, `complete` or `stage` trigger):
  a hook callback or debug-port write never drains. The command starts
  from the controller's bottom half, soon after the trigger returns, and
  completes like any other command.

## Gate overrides and the reopen cases

`x-gate`, and the actions `gate`, `reads-fail` and `reopen`, override the
access gate on top of the tunnel state. Neither override starts stages
2-4. The bridge emits `USB4_TUNNEL_ENDPOINT` stages `harness-gated`,
`harness-reads-fail` and `harness-reopened`. The `endpoint` property
shows `gate=closed dma=open` for reads-fail. An override ends when its
endpoint is removed, so a fresh endpoint starts with the gate open.

**Hold release points:**

- **`release=reopen`:** when the override ends (`x-gate=normal` or
  `act=reopen`), the held command runs to completion before the guest's
  first access after the reopen. This is R4-3 case (ii). With
  `x-gate=normal` both happen before the `qom-set` returns. With
  `act=reopen` (a rule action, which cannot drain) the gate stays closed
  until the slot's bottom half has reopened it and run the commands, so
  the guest may see the endpoint gated for a moment after the trigger.
  Without `release=reopen` commands held, `act=reopen` reopens at once.
- **`release=rdy0-ack`:** R4-3 case (i). While such a command is held, a
  guest write that clears CC.EN is **deferred**: the controller does not
  see it and keeps the command alive. CC reads back the written value
  and CSTS.RDY reads 0 (after any `x-rdy-clear-delay-ms`). The first
  CSTS read that shows RDY=0 is the driver's acknowledgement. At that
  point the command is released: its data transfer and CQE land. Then
  the deferred write is applied, and the controller resets. Both happen
  from the slot's bottom half, right after that CSTS read. A further CC
  write before the deferred one is applied is queued behind it: the
  deferred write is applied first, then the further one. Without an
  acknowledgement before it, the held command is never released: the
  reset of the deferred write discards it. CC reads back the last value
  written. The trace `usb4_h_defer` shows `deferred`, `rdy0-ack`,
  `queued` and `applied`.

## Hung controller (`x-hang`)

| Mode | Effect |
|---|---|
| `stuck` | CSTS keeps the value the guest saw at its first read after the hang |
| `ones` | Every BAR0 read returns all-ones |

In both modes:

- BAR0 writes are dropped.
- Commands fetched after the hang, and completions not yet posted, are
  held. They are released by `x-hang=off`.
- Config space still answers with valid IDs, because the tunnel stays
  up.

## Lost interrupts

The hook sits on the controller's INTx output. A suppressed assertion
keeps the pin low until the controller deasserts. Because the line is
level-triggered, the interrupt is lost until the driver polls and
consumes the completion. PCI Status.Interrupt Status follows the pin.
MSI and MSI-X are not affected: the legacy targets use INTx. Counters:
`intx-asserts` and `intx-dropped` in `x-harness-state`.

## Debug port (`usb4-debug-port`)

`-device usb4-debug-port[,iobase=0x5a0]` adds an ISA device for i440FX
or q35. It provides 16 I/O ports, 0x5a0-0x5af by default. That range is
clear of every ISA device QEMU's pc and q35 machines can carry at its
default address (among them `cs4231a` at 0x534, `fw_cfg` at 0x510,
`pvpanic` at 0x505, `isa-debug-exit` at 0x501, `ib700` at 0x441, `ne2000`
at 0x300, `sb16` and `adlib` at 0x220 and 0x388), of the firmware's PM
and SMBus blocks (0x600, 0x700) and of the PCI I/O windows (0x1000 and
up). Its 10-bit ISA alias, 0x1a0, is free too. Registers are 32-bit:

| Offset | Access | Meaning |
|---|---|---|
| +0 | W | Stage code. Traced as `usb4_dbg_stage` (sequence, code, argument, host and virtual ns). Every slot's `at=stage` rules fire, and their actions take effect (see [Exact-point and event-following tests](#exact-point-and-event-following-tests)), before the write returns |
| +0 | R | `0x42443455` ("U4DB"). Use it for detection |
| +4 | W | Argument recorded with the next stage write (e.g. an SRB tag) |
| +8 | W | Marker, low 32 bits |
| +C | W | Marker, high 32 bits. Records `usb4_dbg_marker` (sequence, 64-bit value, host and virtual ns) |

The property `counts` reads `stages=N markers=M`.

Stage codes are chosen by the nvme98 debug build. For example: just
before `RequestComplete`, after the RMW pre-read, before the write-back.

## Measurement events (nvme98 TESTING "Measurement definitions")

`-trace usb4_tp_gate -trace usb4_tp_cutoff -trace usb4_dbg_marker -D trace.log`
logs the events below. All `host_ns` values are `QEMU_CLOCK_HOST`
(wall clock, the clock of QMP event timestamps). All `vm_ns` values are
`QEMU_CLOCK_VIRTUAL`.

| Event | Trace | Fields and QMP |
|---|---|---|
| T0, gate closed | `usb4_tp_gate` | `closed=1 dma_open=0 host_ns= vm_ns=`. A reads-fail gate logs `closed=1 dma_open=1`. QMP event: `USB4_TUNNEL_ENDPOINT` stage `gated` |
| Stage 2 complete (endpoint reset and drained; the guest-memory cutoff) | `usb4_tp_cutoff` | `gen`, `host_ns`, `vm_ns`. QMP event: stage `cutoff` |
| Clock correlation | `usb4_dbg_marker` or `usb4_h_marker` | The debug build writes its TSC as a marker, through the debug port or the marker doorbell, together with a TSC-stamped debugcon line |

G3 qualification checks that the CM notification's marker is later than
`usb4_tp_cutoff`.

## Namespace layouts and NN

Set these on `usb4-device`. `usb4-tunnel-port` and `usb4-tunnel-bridge`
have the same two properties as the fallback for a forced tunnel.

- `nvme-namespaces=nsid:drive[;nsid:drive...]` gives the inserted `nvme`
  one `nvme-ns` per entry. Leave `drive=` unset to have no NSID 1.
- `nvme-nn=N` sets the Number of Namespaces in Identify Controller.
  QEMU's default is 256, and stornvme then creates phantom disks. NN is
  also the highest NSID the controller accepts: a command naming an NSID
  above it (Identify Namespace included) fails with Invalid Namespace or
  Format, and no namespace above it can exist (a layout entry or an
  `nvme-ns` hot-plugged with `nsid` above NN is refused), so the active
  namespace list stays within it.

The layout is validated before the endpoint is inserted: the syntax,
NSIDs from 1 to NN with none twice, no drive twice, no NSID 1 when the
endpoint has its own `drive=` (that is NSID 1), and every drive exists.
A bad layout inserts nothing: the bridge reports `USB4_TUNNEL_ENDPOINT`
stage `insert-failed`, logs the reason and keeps the slot empty, with no
drive left attached. The bridge's own `nvme-namespaces` is checked at
realize, except for the drives. A drive still held by the previous
endpoint delays the insertion instead (it is retried). Should creating a
validated layout still fail, the endpoint is removed again and the
insertion reported as failed: the guest never keeps a partial layout.

```
-device usb4-device,id=enc0,bus=u4.0,port=1,nvme-namespaces=2:nvme0,nvme-nn=4,serial=USB4EMU01
-device usb4-device,...,"nvme-namespaces=2:nvme0;5:nvme1",nvme-nn=8
```

The namespaces are re-created for each fresh endpoint. Their drives are
released when the old endpoint is removed. Docks do not take a namespace
layout.

## Recipes for the TESTING cases

| TESTING case | Settings |
|---|---|
| Fault at an exact NVMe command | `x-faults=at=fetch op=write lba=63-70 nth=1 act=surprise` (or `at=complete`) |
| Gate close without endpoint reset | `act=gate`, later `x-gate=normal` |
| Delay a completion past the 5 s deadline | `at=complete op=read nth=4 act=hold delay=6000` |
| Drop a completion | `at=complete op=read nth=4 act=drop` |
| Fault at a driver step | `at=stage code=0x21 act=surprise` (code written just before `RequestComplete`) |
| Cancellation between RMW stages (exact point) | `at=fetch op=write act=hold tag=wb armed=off; at=stage code=0x22 act=arm tag=wb` (0x22 written after the pre-read): the write-back is held at fetch, unexecuted, while the test issues the abort; release or drop it afterwards. For the forced-reset variant: `at=stage code=0x22 act=reset-controller` |
| Bring-up, delayed RDY | `x-rdy-set-delay-ms=2000` |
| RDY never set | `x-rdy-set-delay-ms=-1` |
| Identify fails | `at=complete op=identify repeat=on act=none status=0x6` |
| Delayed RDY clear | `x-rdy-clear-delay-ms=50` |
| Failed disable | `x-rdy-clear-delay-ms=-1` |
| Shutdown not completing | `x-shst-delay-ms=-1` |
| Hung behind a live tunnel | `x-hang=stuck` or `x-hang=ones` |
| Presence lost, DMA path open (R4-1) | `at=fetch op=read tag=late act=hold`, then `x-gate=reads-fail` (or `act=reads-fail` on a stage). Release (a) before or (b) after the gone deadline with `x-release=tag:late` |
| Reopen without endpoint reset (R4-3) | `at=fetch op=read act=hold release=rdy0-ack` (case i) or `release=reopen` (case ii), with `x-gate=closed` then `x-gate=normal` |
| Abort, not aborted | `at=complete op=abort act=none dw0=1`, with the target held (`at=fetch op=read act=hold tag=t`) |
| Abort, target completion after the Abort's | Target `at=complete op=read act=hold tag=t`, plus `at=complete op=abort act=release tag=t`. The release is queued behind the Abort's completion |
| Abort, target completion before the Abort's | Hold the Abort (`at=complete op=abort act=hold tag=a`), plus `at=complete op=read act=release tag=a` |
| Several live children, two delayed | Two `hold` rules with `lba=` ranges or `nth=` |
| Lost interrupts | `x-intx-drop-every=3` or `x-intx-drop-range=10-12` |
| Timestamps | Debug port markers, `x-marker-doorbell`, and the trace events above |
| Namespace layouts | `nvme-namespaces=2:drive`, several entries, `nvme-nn` |

## Exact-point and event-following tests

An **exact-point** test needs the fault in place at a precise point of
the driver's execution, with nothing the driver does next able to slip
in between. The harness guarantees that only for what a trigger does
synchronously, inside the call that observed it:

- `at=stage`: everything the stage rule's actions do happens before the
  guest's debug-port write returns, so before the driver's next
  instruction: the gate closes (`surprise`, `eject`, `admin-down`,
  `gate`, `reads-fail`), the controller resets (`reset-controller`),
  rules are armed or disarmed (`arm`, `disarm`), status bits and hangs
  change.
- `at=fetch`: a hold or drop takes the command after its submission (SQ
  entry written, doorbell rung, entry consumed) and before it executes:
  no data moves and no completion is posted. Combined with `arm` on a
  stage rule, "the next matching command after stage X" is held at that
  point.
- `at=complete`: a hold, drop or override takes the completion after
  the data transfer and before the CQE and the interrupt.

Deferred steps, which are **not** exact: released commands started by a
rule action (they run from the controller's bottom half), the gate
reopen of `act=reopen` with `release=reopen` commands held, the end of a
deferred disable, and stages 2-4 of a tunnel down.

An **event-following** test reacts to the QMP event `USB4_HARNESS` (or
`USB4_TUNNEL_ENDPOINT`) from the test client. The event is emitted
synchronously, but the client acts on it later, while the guest keeps
running: whatever the client does lands at an unknown later point. Use
it only where the point does not matter, for example to time a release
long after a deadline. For "do X between driver steps A and B" use a
stage rule whose action does X, or one that arms a `fetch` hold that
keeps step B from executing until the client has done X.

## Limits

- The hook covers QEMU's `nvme` endpoint only.
- The CC and CSTS read faults see reads that cover the whole 32-bit
  register: a 4-byte read at the register, or an 8-byte read at 0x10 or
  0x18. CC writes are recognised at offset 0x14 only, as in QEMU's
  controller model.
- A `reads-fail` gate keeps MSI and MSI-X writes open, along with DMA.
- Not migratable, like the tunnel bridges.
