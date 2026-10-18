#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Yeo Kheng Meng
"""Read-only dump of selected Thunderbolt NHI BAR0 registers.

Usage:
    nhi_mmio_dump.py RESOURCE0 [--out PREFIX] [--label TEXT] [--rings N]
    nhi_mmio_dump.py RESOURCE0 --watch SECONDS [--watch-max SECONDS]
                     [--out PREFIX] [--label TEXT]

--watch samples only the small WATCH set below (no ring registers) every
SECONDS and appends one tab-separated line per sample to PREFIX.tsv (or
stdout), with CLOCK_MONOTONIC (the dmesg clock), CLOCK_BOOTTIME and wall
time, plus the device's power/runtime_status and power_state. The file is
opened and mapped again for every sample. MMIO sampling stops at the
first all-ones sample taken while the device is not runtime suspended
(the controller is gone or not decoding); after that only the sysfs
presence of the device is polled, so the time it disappears is recorded.
It ends when the device disappears, after --watch-max seconds, or when
killed.

RESOURCE0 is /sys/bus/pci/devices/<bdf>/resource0 on the target, or any
regular file of at least 0x40000 bytes for testing.

Safety rules (see tools/p14s-capture/README.md):
  * The file is opened O_RDONLY and mapped PROT_READ. Nothing is written.
  * Only 32-bit, 4-byte aligned loads are issued, one per register.
  * Only the allow-listed ranges below are read. Everything else in the
    BAR is left alone, and the deny list is enforced even for --extra.
  * Interrupt status registers are never read: on Intel NHIs a read of
    the ring interrupt status clears the bits that were read
    (docs/ARCHITECTURE.md section 4.1), which would steal an interrupt
    from the running driver.

Register offsets are the common NHI host interface layout (USB4 Spec 2.0
section 12.6, cross-checked against FreeBSD nhi_reg.h, BSD-2-Clause) plus
the Intel firmware status and mailbox registers named in
docs/ARCHITECTURE.md section 3.
"""

import argparse
import json
import mmap
import os
import sys
import time

BAR_MIN = 0x40000

# (start, length, reason). Never read, not even via --extra.
DENY = [
    (0x19400, 0x400, "RX ring status area: semantics on Intel NHIs undocumented, "
                     "may be read-to-clear"),
    (0x37800, 0x18, "ring interrupt status (read clears on Intel), plus "
                    "write-only status clear and status set registers"),
    (0x38208, 0x10, "write-only interrupt mask clear / mask set registers"),
    (0x39898, 0x4, "host interface reset register (not needed, avoid)"),
]


# Registers sampled by --watch: identity, Intel control and firmware state,
# mailboxes and the ring interrupt enables. All are plain reads with no
# side effects (README "The NHI register reader").
WATCH = [
    (0x39640, "HOST_CAPS"),
    (0x39864, "DMA_MISC"),
    (0x39900, "INMAIL_DATA"),
    (0x39904, "INMAIL_CMD"),
    (0x39908, "MAIL_39908"),
    (0x3990c, "OUTMAIL_CMD"),
    (0x39944, "FW_STS"),
    (0x38200, "INT_MASK0"),
]


def allow_list(rings):
    """Return [(offset, name)] for the registers we read."""
    regs = [
        (0x39640, "HOST_CAPS (hop count / ring count)"),
        (0x39864, "DMA_MISC (Intel interrupt auto-clear bit 2)"),
        (0x39900, "INMAIL_DATA"),
        (0x39904, "INMAIL_CMD"),
        (0x39908, "mailbox 0x39908 (between INMAIL_CMD and OUTMAIL_CMD)"),
        (0x3990c, "OUTMAIL_CMD (firmware operating mode)"),
        (0x39944, "FW_STS (ICM enable, NVM auth done, CIO reset)"),
        (0x38200, "INT_MASK0"),
        (0x38204, "INT_MASK1"),
    ]
    for n in range(rings):
        b = n * 0x10
        regs += [
            (0x00000 + b, "TX[%d] base lo" % n),
            (0x00004 + b, "TX[%d] base hi" % n),
            (0x00008 + b, "TX[%d] prod/cons" % n),
            (0x0000c + b, "TX[%d] size" % n),
            (0x08000 + b, "RX[%d] base lo" % n),
            (0x08004 + b, "RX[%d] base hi" % n),
            (0x08008 + b, "RX[%d] prod/cons" % n),
            (0x0800c + b, "RX[%d] size / buffer size" % n),
        ]
        t = n * 0x20
        regs += [
            (0x19800 + t, "TX[%d] options" % n),
            (0x19804 + t, "TX[%d] options+4" % n),
            (0x29800 + t, "RX[%d] options" % n),
            (0x29804 + t, "RX[%d] options+4 (SOF/EOF masks)" % n),
        ]
    for v in range(16):
        regs.append((0x38c00 + 4 * v, "INT_THROTTLE[%d]" % v))
    for v in range(5):
        regs.append((0x38c40 + 4 * v, "INT_VEC_ALLOC[%d]" % v))
    return sorted(set(regs))


def denied(off):
    for start, length, _ in DENY:
        if start <= off < start + length:
            return True
    return False


def read32(view, off):
    if off & 3:
        raise ValueError("unaligned offset 0x%x" % off)
    if denied(off):
        raise ValueError("offset 0x%x is on the deny list" % off)
    # memoryview 'I' items are fetched with a single 4-byte copy, which
    # compiles to one aligned 32-bit load on x86.
    return view[off >> 2]


def parse_extra(text):
    start, _, length = text.partition(":")
    start, length = int(start, 0), int(length or "4", 0)
    return [(o, "extra") for o in range(start & ~3, start + length, 4)]


def sysfs_read(path):
    try:
        with open(path) as f:
            return f.read().strip() or "-"
    except OSError as e:
        return "err:%s" % (e.strerror or e.errno)


def sample_once(resource):
    """Map, read the WATCH set, unmap. Returns (values, error text)."""
    try:
        fd = os.open(resource, os.O_RDONLY)
    except OSError as e:
        return None, "open:%s" % (e.strerror or e.errno)
    try:
        size = os.fstat(fd).st_size
        if size < BAR_MIN:
            os.close(fd)
            return None, "size 0x%x" % size
        mm = mmap.mmap(fd, size, access=mmap.ACCESS_READ)
    except OSError as e:
        os.close(fd)
        return None, "mmap:%s" % (e.strerror or e.errno)
    view = memoryview(mm).cast("I")
    try:
        vals = [read32(view, off) for off, _ in WATCH]
    finally:
        view.release()
        mm.close()
        os.close(fd)
    return vals, ""


def watch(args):
    dev = os.path.dirname(os.path.abspath(args.resource))
    out = open(args.out + ".tsv", "a") if args.out else sys.stdout
    clk_boot = getattr(time, "CLOCK_BOOTTIME", time.CLOCK_MONOTONIC)

    def emit(fields):
        line = "\t".join([
            "%.3f" % time.clock_gettime(time.CLOCK_MONOTONIC),
            "%.3f" % time.clock_gettime(clk_boot),
            time.strftime("%Y-%m-%dT%H:%M:%S")] + fields)
        out.write(line + "\n")
        out.flush()

    out.write("# watch %s label=%s interval=%ss max=%ss\n" %
              (args.resource, args.label, args.watch, args.watch_max))
    out.write("\t".join(["# monotonic", "boottime", "wall",
                         "runtime_status", "power_state"] +
                        ["%s@0x%05x" % (n, o) for o, n in WATCH] +
                        ["note"]) + "\n")
    out.flush()
    t_end = time.monotonic() + args.watch_max
    mmio = True
    try:
        while time.monotonic() < t_end:
            if not os.path.exists(args.resource):
                emit(["-", "-"] + ["-"] * len(WATCH) + ["device gone"])
                break
            rs = sysfs_read(os.path.join(dev, "power", "runtime_status"))
            ps = sysfs_read(os.path.join(dev, "power_state"))
            if mmio:
                vals, err = sample_once(args.resource)
                if vals is None:
                    emit([rs, ps] + ["-"] * len(WATCH) + [err])
                else:
                    ones = all(v == 0xffffffff for v in vals)
                    note = ""
                    if ones and rs != "suspended":
                        note = "all ones: MMIO sampling stops, presence only"
                        mmio = False
                    elif ones:
                        note = "all ones while runtime suspended"
                    emit([rs, ps] + ["0x%08x" % v for v in vals] + [note])
            else:
                emit([rs, ps] + ["-"] * len(WATCH) + ["present"])
            time.sleep(args.watch)
    except KeyboardInterrupt:
        pass
    if out is not sys.stdout:
        out.close()
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("resource")
    ap.add_argument("--out", help="output prefix (writes .txt and .json)")
    ap.add_argument("--label", default="")
    ap.add_argument("--rings", type=int, default=0,
                    help="rings to dump (default: from HOST_CAPS, max 32)")
    ap.add_argument("--extra", action="append", default=[],
                    help="extra OFFSET[:LEN] to read (deny list still applies)")
    ap.add_argument("--watch", type=float, metavar="SECONDS",
                    help="sample the WATCH set periodically (see above)")
    ap.add_argument("--watch-max", type=float, default=3600,
                    metavar="SECONDS", help="stop watching after this long")
    args = ap.parse_args()
    if args.watch is not None:
        if args.watch <= 0:
            ap.error("--watch needs a positive interval")
        return watch(args)

    try:
        fd = os.open(args.resource, os.O_RDONLY)
        size = os.fstat(fd).st_size
        if size < BAR_MIN:
            raise OSError("size 0x%x is smaller than 0x%x" % (size, BAR_MIN))
        # MAP_SHARED, PROT_READ
        mm = mmap.mmap(fd, size, access=mmap.ACCESS_READ)
    except OSError as e:
        # e.g. EPERM under kernel lockdown, which forbids mapping BARs.
        msg = "# ERROR: cannot map %s read-only: %s\n" % (args.resource, e)
        if args.out:
            with open(args.out + ".txt", "w") as f:
                f.write(msg)
        sys.stderr.write(msg)
        return 1
    view = memoryview(mm).cast("I")

    caps = read32(view, 0x39640)
    rings = args.rings
    if not rings:
        rings = caps & 0x7ff
        if caps == 0xffffffff or rings == 0 or rings > 32:
            rings = 32
    rings = min(rings, 32)

    regs = allow_list(rings)
    for e in args.extra:
        regs += parse_extra(e)
    rows = []
    for off, name in regs:
        if denied(off):
            rows.append({"offset": off, "name": name, "skipped": "deny list"})
            continue
        rows.append({"offset": off, "name": name, "value": read32(view, off)})

    all_ones = all(r.get("value") == 0xffffffff for r in rows if "value" in r)
    result = {
        "resource": args.resource,
        "label": args.label,
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "bar_size": size,
        "rings_dumped": rings,
        "all_ones_warning": all_ones,
        "skipped_ranges": [{"start": s, "length": n, "reason": r}
                           for s, n, r in DENY],
        "registers": rows,
    }
    view.release()
    mm.close()
    os.close(fd)

    lines = ["# NHI BAR0 dump %s  label=%s  size=0x%x  rings=%d" %
             (result["time"], args.label, size, rings)]
    if all_ones:
        lines.append("# WARNING: every value is 0xffffffff; device is "
                     "probably in D3 or not decoding")
    for s, n, r in DENY:
        lines.append("# skipped 0x%05x-0x%05x: %s" % (s, s + n - 1, r))
    for r in rows:
        if "value" in r:
            lines.append("0x%05x 0x%08x %s" % (r["offset"], r["value"],
                                               r["name"]))
        else:
            lines.append("0x%05x ---------- %s (skipped)" % (r["offset"],
                                                             r["name"]))
    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out + ".txt", "w") as f:
            f.write(text)
        with open(args.out + ".json", "w") as f:
            json.dump(result, f, indent=1)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
