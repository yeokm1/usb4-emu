#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""One-off host-side repair of the P14s capture of 2026-10-23
(p14s-linux-20261023-000123-orico-suspend.tar.gz), run before scrub.py.

On the machine, redact.py (before its fix of 2026-10-23) collected the
iSerial of the two xHCI root hubs, which Linux sets to the controller's PCI
address (0000:00:14.0, 0000:2b:00.0), and the iSerial "0001" of a USB
device as USB serials. It replaced them with runs of X in the files it
reached, then crashed renaming pci/tb-complex-with-device/0000:2b:00.0/
config.bin, and the archive was packed with redaction incomplete and no
REDACTIONS.txt. Damaged members: capture.log, dmesg-live.txt,
dmesg-final.txt, pci/lspci-xxxx-all.txt.

This puts the addresses back without restoring anything secret: a damaged
line is replaced by the identical line of an undamaged log of the same
kernel buffer (same timestamp; the same text wherever it has no X), and
only when exactly one line fits:

  dmesg-live.txt  <- system/dmesg-boot-raw.txt (same monotonic timestamps)
  dmesg-final.txt <- dmesg-live.txt, same line (dmesg -T of the same buffer)
  capture.log     the Thunderbolt PCI complex list: its missing member is
                  the Thunderbolt xHCI (pci/tb-complex*/0000_2b_00.0)
  lspci-xxxx-all.txt  "# $ lspci -s X" is followed by the device's header

A restored line may carry a value that is a secret (none is known to); the
scrub.py run that follows removes every collected secret from every member
again. MANIFEST.txt gets the new hashes, and a new REDACTIONS.txt member
records this repair (scrub.py appends its own section).

Usage: repair-20261023.py IN.tar.gz OUT.tar.gz
"""

import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scrub  # noqa: E402

X = "XXXXXXXXXXXX"
TS = re.compile(r"^\[[^\]]*\] ?")


def template(line):
    """Regex for LINE with every run of 4+ X matching the same length."""
    out, pos = "", 0
    for m in re.finditer(r"X{4,}", line):
        out += re.escape(line[pos:m.start()]) + \
            "[0-9A-Za-z:._-]{%d}" % len(m.group(0))
        pos = m.end()
    return re.compile(out + re.escape(line[pos:]) + r"\r?$")


def repair(get, log):
    """GET(name) -> list of lines. Returns {name: lines} and the count of
    damaged lines left."""
    left, out = 0, {}
    by_ts = {}
    for r in get("system/dmesg-boot-raw.txt"):
        m = TS.match(r)
        if m:
            by_ts.setdefault(m.group(0), []).append(r)
    live = get("dmesg-live.txt")
    n = 0
    for i, line in enumerate(live):
        if "XXXX" not in line or not TS.match(line):
            continue
        t = template(line)
        c = [r for r in by_ts.get(TS.match(line).group(0), [])
             if t.match(r)]
        if len(c) == 1:
            live[i], n = c[0], n + 1
        elif X in line:
            left += 1
    out["dmesg-live.txt"] = live
    log.append("%6d  dmesg-live.txt  (lines restored from "
               "system/dmesg-boot-raw.txt)" % n)
    final = get("dmesg-final.txt")
    n = 0
    for i, line in enumerate(final):
        if "XXXX" not in line:
            continue
        src = TS.sub("", live[i]) if i < len(live) else ""
        if "XXXX" not in src and template(TS.sub("", line)).match(src):
            final[i], n = TS.match(line).group(0) + src, n + 1
        elif X in line:
            left += 1
    out["dmesg-final.txt"] = final
    log.append("%6d  dmesg-final.txt  (lines restored from dmesg-live.txt)"
               % n)
    cl = get("capture.log")
    n = 0
    for i, line in enumerate(cl):
        if "Thunderbolt PCI complex:" in line and X in line:
            cl[i] = line.replace("0000:05:00.0 " + X + " ",
                                 "0000:05:00.0 0000:2b:00.0 ")
            n += 1
        elif X in line:
            left += 1
    out["capture.log"] = cl
    log.append("%6d  capture.log  (Thunderbolt PCI complex list)" % n)
    lx = get("pci/lspci-xxxx-all.txt")
    n = 0
    for i, line in enumerate(lx):
        if X in line and line.startswith("# $ lspci -s "):
            m = re.match(r"([0-9a-f]{2}:[0-9a-f]{2}\.[0-7]) ", lx[i + 1])
            if m:
                lx[i], n = line.replace(X, "0000:" + m.group(1)), n + 1
                continue
        if X in line:
            left += 1
    out["pci/lspci-xxxx-all.txt"] = lx
    log.append("%6d  pci/lspci-xxxx-all.txt  (lspci -s commands)" % n)
    return out, left


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    c = scrub.Container(argv[0])
    files = {n: f for n, f in ((f[0], f) for f in c.files)}
    top = c.files[0][0].split("/")[0]

    def get(rel):
        return files[top + "/" + rel][1].decode("latin1").split("\n")

    log = ["# repair-20261023.py (host-side, before scrub.py): PCI addresses "
           "that the failed on-machine redact.py run had replaced with X, "
           "put back from undamaged copies of the same logs; see the "
           "script's docstring",
           "# The on-machine run wrote no REDACTIONS.txt: it crashed "
           "renaming a directory named after a PCI address."]
    out, left = repair(get, log)
    if left:
        raise SystemExit("%d damaged lines left; nothing written" % left)
    hashes = {}
    for rel, lines in out.items():
        f = files[top + "/" + rel]
        new = "\n".join(lines).encode("latin1")
        hashes[hashlib.sha256(f[1]).hexdigest()] = \
            hashlib.sha256(new).hexdigest()
        f[1] = new
    m = files[top + "/MANIFEST.txt"]
    m[1] = re.sub(rb"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])",
                  lambda x: hashes.get(x.group(0).decode(),
                                       x.group(0).decode()).encode(), m[1])
    c.add_member("REDACTIONS.txt", ("\n".join(log) + "\n").encode())
    c.write(argv[1])
    print("\n".join(log))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
