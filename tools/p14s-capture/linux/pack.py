#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Pack a capture directory into a FAT32/Windows-safe .tar.gz.

Usage: pack.py SRC_DIR OUT_DIR NAME

Writes OUT_DIR/NAME.tar.gz (or NAME.tar.gz.001, .002, ... below 4 GB each
if it is ever larger; join with `cat NAME.tar.gz.0* > NAME.tar.gz`) and
OUT_DIR/NAME.tar.gz.sha256. The archive is first built next to SRC_DIR
(RAM on a live system), so only the final files touch OUT_DIR.

Inside the archive every path component is FAT32/Windows-safe:
  * ':' '*' '?' '"' '<' '>' '|' '\\' and control characters become '_'
    (PCI addresses: 0000:00:04.0 -> 0000_00_04.0);
  * trailing dots and spaces become '_';
  * reserved device names (CON, NUL, COM1, ...) get a '_' prefix;
  * names that would differ only by case get a '~N' suffix;
  * symlinks, device files, FIFOs and sockets are not stored.
PATHMAP.tsv at the archive root lists every original path and what it was
stored as (or why it was skipped).
"""

import hashlib
import io
import os
import re
import stat
import sys
import tarfile
import time

BAD = re.compile(r'[:*?"<>|\\\x00-\x1f\x7f]')
RESERVED = {"con", "prn", "aux", "nul"} | \
    {"com%d" % i for i in range(1, 10)} | {"lpt%d" % i for i in range(1, 10)}
PART = 3900 * 1024 * 1024        # stay well below the FAT32 4 GiB limit


def safe_component(name):
    s = BAD.sub("_", name)
    s = re.sub(r"[. ]+$", lambda m: "_" * len(m.group(0)), s)
    if not s:
        s = "_"
    if s.split(".")[0].lower() in RESERVED:
        s = "_" + s
    return s[:200]


def unique(name, taken):
    """Avoid names that differ only by case within one directory."""
    if name.lower() not in taken:
        taken.add(name.lower())
        return name
    stem, dot, ext = name.partition(".")
    n = 2
    while True:
        cand = "%s~%d%s%s" % (stem, n, dot, ext)
        if cand.lower() not in taken:
            taken.add(cand.lower())
            return cand
        n += 1


def main():
    src, out_dir, name = sys.argv[1], sys.argv[2], sys.argv[3]
    top = safe_component(name)
    work = os.path.dirname(os.path.abspath(src))
    tmp = os.path.join(work, top + ".tar.gz")
    rows = []
    entries = []                  # (abs path, arcname)
    dirmap = {src: top}
    taken = {}                    # arc dir -> set of lowercased names
    for dirpath, dirs, files in os.walk(src):
        dirs.sort()
        arcdir = dirmap[dirpath]
        t = taken.setdefault(arcdir, {"pathmap.tsv"} if arcdir == top
                             else set())
        for d in list(dirs):
            p = os.path.join(dirpath, d)
            rel = os.path.relpath(p, src)
            if os.path.islink(p):
                rows.append((rel, "(skipped: symlink -> %s)" % os.readlink(p)))
                dirs.remove(d)
                continue
            a = unique(safe_component(d), t)
            dirmap[p] = arcdir + "/" + a
            if a != d:
                rows.append((rel + "/", os.path.relpath(dirmap[p], top) + "/"))
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, src)
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode):
                kind = "symlink -> " + os.readlink(p) \
                    if stat.S_ISLNK(st.st_mode) else "not a regular file"
                rows.append((rel, "(skipped: %s)" % kind))
                continue
            a = unique(safe_component(f), t)
            arc = arcdir + "/" + a
            entries.append((p, arc))
            stored = arc[len(top) + 1:]
            if stored != rel:
                rows.append((rel, stored))

    pathmap = "# original path<TAB>name in this archive (unchanged paths are not listed)\n"
    pathmap += "".join("%s\t%s\n" % r for r in rows)
    now = time.time()
    with tarfile.open(tmp, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        def add_dir(arc):
            ti = tarfile.TarInfo(arc)
            ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, now
            tar.addfile(ti)
        for arc in sorted(set(dirmap.values())):
            add_dir(arc)
        data = pathmap.encode()
        ti = tarfile.TarInfo(top + "/PATHMAP.tsv")
        ti.size, ti.mode, ti.mtime = len(data), 0o644, now
        tar.addfile(ti, io.BytesIO(data))
        for p, arc in entries:
            ti = tar.gettarinfo(p, arc)
            ti.mode, ti.uid, ti.gid, ti.uname, ti.gname = 0o644, 0, 0, "", ""
            with open(p, "rb") as fh:
                tar.addfile(ti, fh)

    size = os.path.getsize(tmp)
    outs = []
    with open(tmp, "rb") as fin:
        if size <= PART:
            outs.append(top + ".tar.gz")
        else:
            outs = ["%s.tar.gz.%03d" % (top, i + 1)
                    for i in range((size + PART - 1) // PART)]
        sums = []
        for o in outs:
            h = hashlib.sha256()
            left = PART
            with open(os.path.join(out_dir, o), "wb") as fo:
                while left:
                    buf = fin.read(min(left, 1 << 20))
                    if not buf:
                        break
                    h.update(buf)
                    fo.write(buf)
                    left -= len(buf)
                fo.flush()
                os.fsync(fo.fileno())
            sums.append("%s  %s\n" % (h.hexdigest(), o))
    os.remove(tmp)
    with open(os.path.join(out_dir, top + ".tar.gz.sha256"), "w") as f:
        f.write("".join(sums))
        f.flush()
        os.fsync(f.fileno())
    print("DONE. %d files, %d renamed or skipped. Send %s:" %
          (len(entries) + 1, len(rows), "this file" if len(outs) == 1
           else "these files"))
    for o in outs + [top + ".tar.gz.sha256"]:
        print("  " + os.path.join(os.path.abspath(out_dir), o))
    if len(outs) > 1:
        print("Join with: cat %s.tar.gz.0* > %s.tar.gz" % (top, top))
    return 0


if __name__ == "__main__":
    sys.exit(main())
