# Fixes to QEMU's NVMe controller

AGENTS.md says not to write an NVMe model. The endpoint is QEMU's own `hw/nvme`. This
file records the small fixes that the usb4-emu fork of QEMU carries in `hw/nvme`. They
are local fixes in this fork. The `x-` test hook used by the harness (`docs/HARNESS.md`)
is a separate thing and is not listed here.

These commits are not prepared for upstream QEMU. QEMU's `docs/devel/code-provenance.rst`
declines contributions generated with AI tools, and upstream patches need a
`Signed-off-by` from the author. Whether any of this goes upstream, and in what form, is
the maintainer's decision under that policy.

## 1. Pin-based interrupt state on CQ head doorbells and controller reset

QEMU branch `usb4-nvmeirq`, based on `usb4-emu` 25fd4eb, in main as of QEMU `36f6254`:

- `hw/nvme: keep pin-based interrupt state consistent on CQ head doorbells`
- `tests/qtest/nvme-test: interrupt tests for CQ head doorbells`

### Symptom

nvme98 found this running Windows guests on QEMU's `nvme` device with INTx and no
MSI-X. One redundant Completion Queue Head doorbell write leaves INTx asserted after the
next completion is consumed. The guest then sees an interrupt storm with empty queues.
nvme98's `stormtest=1` test switch provokes it on purpose (nvme98 commit e3956b6). That
switch writes the current head to the I/O CQ head doorbell once after bring-up. A
controller reset with a completion still posted leaves the line asserted in the same
way.

### Cause

For pin-based interrupts, `NvmeCtrl.cq_pending` counts the completion queues that hold
unconsumed entries. `nvme_irq_deassert()` clears the vector's bit in `irq_status`, and
with it the pin, only when that count is zero. In the unfixed `hw/nvme/ctrl.c`:

1. **MMIO doorbell.** The CQ head doorbell in `nvme_process_db` decremented
   `cq_pending` whenever head == tail after the write. It did so even when the queue
   was already empty before the write. A write of the current head on an empty queue
   therefore drives the count to -1.
   - The next completion raises it back to 0 and asserts the pin.
   - Consuming that completion drops the count to -1 again. `nvme_irq_deassert()` sees
     a non-zero count and leaves `irq_status` set, so the pin stays asserted.
   - Each further redundant write moves the count further from zero.
2. **ioeventfd path.** `nvme_cq_notifier` had the same unconditional decrement.
3. **Head past the tail.** Both paths assumed a queue is pending exactly when head !=
   tail, but a head write beyond the tail breaks that assumption. Take an empty queue
   whose head is written one beyond the tail and then written back. This sequence
   decrements a count that was never incremented.
4. **Controller reset.** `nvme_ctrl_reset()` freed every completion queue but did not
   clear `cq_pending` or `irq_status`, and did not update the pin. INTx stayed asserted
   across CC.EN 1 -> 0. The stale count then broke the first completion after the
   controller was enabled again.
5. **Migration.** `cq_pending` and `irq_status` are migrated verbatim. A count that an
   unfixed source has already corrupted would keep INTx stuck on the destination too.

### Fix

- **Pending count follows transitions.** `nvme_cq_update_pending()` recomputes whether
  a queue is pending (head != tail) after every head or tail move: the MMIO doorbell,
  the ioeventfd notifier and `nvme_post_cqes()`. It changes `cq_pending` only when the
  queue moves between pending and empty, and deasserts on a move to empty. A queue is
  therefore counted exactly while head != tail, whatever value the guest writes.
- **Repeated head write.** A head write equal to the current head returns before
  anything changes. It releases no entry, so the interrupt state must not change (NVMe
  Base 1.4c Section 4.1).
- **Controller reset.** `nvme_ctrl_reset()` sets `cq_pending` and `irq_status` to zero
  after deleting the queues, and calls `nvme_irq_check()` once INTMS is cleared
  (Section 7.3.2 Controller Level Reset, Section 7.5.1 pin-based interrupts).
- **Migration.** `post_load` ignores the migrated `cq_pending` and `irq_status`. It
  rebuilds both from the restored queues (a queue is pending while head != tail) and
  updates the pin.
- **Opt-in strict mode: `x-strict-cq-db`** (default off). When it is on, a head write
  beyond the tail is ignored. If an Asynchronous Event Request is outstanding, the
  write is reported as an error event with Invalid Doorbell Write Value (Section 4.1,
  Figure 147), as QEMU already does for values beyond the queue size. A new trace event,
  `pci_nvme_ub_db_wr_invalid_cqhead_empty`, logs it. Figure 147 also lists a write of
  the previous value as a possible cause of this error; strict mode does not report
  that case.

With the default settings, a guest that writes correct doorbell values sees no change,
with INTx or with MSI-X. The only guest-visible differences are:

- INTx no longer sticks after a redundant or out-of-range head write.
- INTx is dropped at controller reset.
- INTx no longer sticks after migrating from a source whose count was corrupted.

Head writes beyond the tail are still accepted, as before.

### Tests

The tests are added to `tests/qtest/nvme-test.c`, which runs under `qos-test` on the
`pc` machine. They read the pin from the Interrupt Status bit of the PCI Status register,
which QEMU updates on every INTx level change. Only `msix-cq-db-past-tail` enables MSI-X.
It leaves every vector masked, so notifications only set pending bits.

| Test | Checks |
|---|---|
| `nvme-tests/intx-cq-db-redundant` | Repeated current-head writes on an empty queue and on a non-empty queue, across a phase wrap of an 8-entry admin CQ. INTx follows the queue state. |
| `nvme-tests/intx-cq-db-past-tail` | Default settings. A head written one beyond the tail and then back to the tail does not corrupt the count. Later completions assert and deassert INTx. |
| `nvme-tests/intx-cq-db-strict` | With `x-strict-cq-db=on`, a head write past the tail is ignored and posted as an AER with dword 0 `0x00010100` (error type, Invalid Doorbell Write Value, Error Information log). Without an outstanding AER it is still ignored. |
| `nvme-tests/msix-cq-db-past-tail` | MSI-X enabled, default settings. A head write past the tail is accepted. With the controller's head one past its tail the queue counts as full, so a new command's completion is held, and no event completes the outstanding AER. A rejected write would let both through. Writing the head back releases the held completion. |
| `nvme-tests/intx-reset` | CC.EN 1 -> 0 with a completion posted drops INTx. After re-enabling, completions assert and deassert normally. |
| `nvme-tests/intx-migrate` | The migration stream is relayed through the test over unix sockets, and the test sets `cq_pending` to -1 on the way, as an unfixed source could send it. On the destination, completions still assert and deassert INTx. |

Results, 2026-10-15, MSYS2 UCRT64 build:

- **Without the fix** (25fd4eb `hw/nvme` with the new tests):
  - `intx-cq-db-redundant`, `intx-cq-db-past-tail` and `intx-reset` fail. In each case
    INTx is still asserted when it should be deasserted.
  - `intx-cq-db-strict` cannot start, because the property does not exist.
  - `msix-cq-db-past-tail` passes. This confirms the default MSI-X behaviour is the
    same as before.
  - With the fix applied except the `post_load` rebuild, `intx-migrate` fails: INTx
    stays asserted after the first completion on the destination.
- **With the fix:**
  - All 11 nvme qos tests pass. These are `nop`, `oob-cmb-access`, `pmr-test-access`,
    `reg-read`, `migrate` and the six new tests.
  - All usb4 qtests pass: host 23, tunnel 29, icm 26, icm-tr 14, harness 25,
    asm4242 8, asm2464 4, tb3dev 9, root-hotplug 17. That is 155 ok and 0 not ok.
  - `checkpatch.pl` reports 0 errors and 0 warnings.

Running `qos-test` on Windows: set `QTEST_QEMU_BINARY=./qemu-system-x86_64` without
`.exe`. `qtest_get_arch()` takes everything after `-system-` as the architecture. With
the `.exe` suffix it gets `x86_64.exe`, and no qos test registers (`1..0`).

`intx-migrate` relays the stream over sockets because `file:` migration fails on a
Windows host with "Failed to set FD nonblocking". The source keeps the connection open
after reporting `completed`, so the reader stops at the first idle receive timeout
after completion instead of waiting for EOF.

### Not covered

- **Shadow doorbell head values are not range-checked in strict mode.** With Doorbell
  Buffer Config enabled, a head read from shadow doorbell memory (in `nvme_post_cqes()`
  and the ioeventfd notifier) is not checked even when `x-strict-cq-db` is on. The
  pending count still stays consistent.
- **One shared counter for all vectors.** `cq_pending` is a single count, not one per
  vector. If completion queues on different interrupt vectors are used in INTx mode,
  the bit of a vector that emptied while another vector's queue was pending can stay
  set in `irq_status`. Guests normally use vector 0 for every queue in INTx mode.

### Effect on nvme98

The storm comes from the doorbell and reset bookkeeping described above, and both are
fixed. On a QEMU with this fix, `stormtest=1` no longer produces a storm. nvme98's
mask-and-poll storm recovery in `EngInterrupt` can no longer be exercised against
QEMU's nvme device. The recovery is still a reasonable safety net on a shared line or
on real hardware. Removing it is nvme98's decision; nothing here requires its removal.
