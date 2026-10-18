#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Host-side privacy scrub of finished captures, run by the integrator on
arrival and before committing.

Usage: scrub.py [options] INPUT...

INPUT is a Linux capture archive (.tar.gz), a Windows 11 capture (.zip) or
a directory (for example a Windows 98 capture folder, scrubbed in place).
All inputs are scanned first, so a value found in one capture (a USB
serial in ENUM.REG, a host name in a Linux log) is removed from all of
them. The engine is linux/redact.py; see its docstring for what is found
and how it is replaced. Thunderbolt router UUIDs, DROMs and the Device
Serial Number of Thunderbolt/USB4 controller functions are kept.

Archives are rewritten with the same member order, names and metadata;
only the content of changed members differs. The archive's REDACTIONS.txt
gets a section listing the replacements per file and category, its
MANIFEST.txt / MANIFEST.sha256 gets the new hashes, and the sidecar
NAME.sha256 is regenerated in its original format.

Options:
  --out DIR        write archives to DIR (default: replace in place)
  --secrets FILE   extra literal strings to remove, one per line
  --keep-dsn V:D   also keep the Device Serial Number of PCI vendor:device
                   (hex), repeatable
  --list           print the values found, by category (for review; the
                   output contains the secrets), and change nothing
  --dry-run        report counts per file, change nothing
"""

import gzip
import hashlib
import io
import os
import re
import sys
import tarfile
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "linux"))
import redact  # noqa: E402

MANIFESTS = ("MANIFEST.txt", "MANIFEST.sha256")


class Container:
    """An archive or directory as an ordered list of (name, bytes)."""

    def __init__(self, path):
        self.path = path
        self.files = []          # [name, data]
        if os.path.isdir(path):
            self.kind = "dir"
            for dp, dirs, fs in os.walk(path):
                dirs.sort()
                for f in sorted(fs):
                    p = os.path.join(dp, f)
                    with open(p, "rb") as fh:
                        self.files.append([os.path.relpath(p, path),
                                           fh.read()])
        elif path.endswith(".tar.gz") or path.endswith(".tgz"):
            self.kind = "tar"
            with open(path, "rb") as fh:
                raw = fh.read()
            self.gz_mtime = int.from_bytes(raw[4:8], "little")
            self.gz_name = None
            if raw[3] & 0x08:    # FNAME
                end = raw.index(b"\0", 10)
                self.gz_name = raw[10:end].decode("latin1")
            tar = tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz")
            self.members = tar.getmembers()
            for m in self.members:
                if m.isfile():
                    self.files.append([m.name, tar.extractfile(m).read()])
            self.tar_format = tar.format
        elif path.endswith(".zip"):
            self.kind = "zip"
            z = zipfile.ZipFile(path)
            self.infos = z.infolist()
            for i in self.infos:
                if not i.is_dir():
                    self.files.append([i.orig_filename, z.read(i)])
        else:
            raise SystemExit("unsupported input: " + path)

    def write(self, out):
        data = {n: d for n, d in self.files}
        if self.kind == "dir":
            for n, d in self.files:
                p = os.path.join(self.path, n)
                with open(p, "rb") as fh:
                    if fh.read() == d:
                        continue
                with open(p, "wb") as fh:
                    fh.write(d)
            return
        if self.kind == "tar":
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w",
                              format=self.tar_format) as t:
                for m in self.members:
                    if m.isfile():
                        d = data[m.name]
                        m.size = len(d)
                        t.addfile(m, io.BytesIO(d))
                    else:
                        t.addfile(m)
            gz = io.BytesIO()
            with gzip.GzipFile(filename=self.gz_name or "", mode="wb",
                               fileobj=gz, compresslevel=9,
                               mtime=self.gz_mtime) as g:
                g.write(buf.getvalue())
            blob = gz.getvalue()
        else:
            zb = io.BytesIO()
            with zipfile.ZipFile(zb, "w") as z:
                for i in self.infos:
                    zi = zipfile.ZipInfo(i.orig_filename, i.date_time)
                    zi.filename = i.orig_filename   # keep '\' separators
                    zi.compress_type = i.compress_type
                    zi.external_attr = i.external_attr
                    zi.create_system = i.create_system
                    z.writestr(zi, b"" if i.is_dir()
                               else data[i.orig_filename])
            blob = zb.getvalue()
        with open(out, "wb") as fh:
            fh.write(blob)
        side = self.path + ".sha256"
        if os.path.exists(side):
            with open(side, "rb") as fh:
                old = fh.read()
            new_hash = hashlib.sha256(blob).hexdigest()
            text = re.sub(rb"^[0-9a-fA-F]{64}", lambda m: (
                new_hash.upper() if m.group(0).isupper() else new_hash
            ).encode(), old, count=1)
            with open(out + ".sha256", "wb") as fh:
                fh.write(text)


def main(argv):
    out_dir, secrets, keep, mode, inputs = None, [], set(), "apply", []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":
            out_dir = argv[i + 1]
            i += 1
        elif a == "--secrets":
            with open(argv[i + 1], encoding="utf-8", errors="replace") as f:
                secrets += f.read().splitlines()
            i += 1
        elif a == "--keep-dsn":
            v, d = argv[i + 1].split(":")
            keep.add((int(v, 16), int(d, 16)))
            i += 1
        elif a in ("--list", "--dry-run"):
            mode = a[2:]
        elif a.startswith("-"):
            print(__doc__, file=sys.stderr)
            return 2
        else:
            inputs.append(a)
        i += 1
    if not inputs:
        print(__doc__, file=sys.stderr)
        return 2

    r = redact.Redactor(secrets, keep)
    conts = [Container(p) for p in inputs]
    for c in conts:
        for n, d in c.files:
            if os.path.basename(n.replace("\\", "/")) != "REDACTIONS.txt":
                r.collect(n, d)
    r.finish()

    if mode == "list":
        cats = {}
        for s, (cat, _) in r.literal.items():
            cats.setdefault(cat, []).append(s)
        cats["pcie-dsn (redacted)"] = ["%016x" % v for v in r.dsn_redact]
        cats["pcie-dsn (kept)"] = ["%016x" % v for v in r.dsn_keep]
        cats["guid-node"] = sorted(r.nodes)
        for cat in sorted(cats):
            for s in sorted(cats[cat]):
                print("%-20s %s" % (cat, s))
        return 0

    for c in conts:
        log, hashes = [], {}
        for f in c.files:
            n, d = f
            base = os.path.basename(n.replace("\\", "/"))
            if base in MANIFESTS or base == "REDACTIONS.txt":
                continue
            nd, counts = r.apply(n, d)
            nn = r.apply_name(n)
            if nn != n:
                counts["path"] = counts.get("path", 0) + 1
                raise SystemExit("%s: member name %r holds a secret; "
                                 "renaming is not supported" % (c.path, n))
            if nd != d:
                hashes[hashlib.sha256(d).hexdigest()] = \
                    hashlib.sha256(nd).hexdigest()
                f[1] = nd
            if counts:
                log.append((n.replace("\\", "/"), counts))
        title = "scrub.py (host-side, after capture)"
        print("== %s: %d files changed" % (c.path, len(log)))
        for n, counts in log:
            print("   %6d  %s  (%s)" % (sum(counts.values()), n, ", ".join(
                "%s %d" % kv for kv in sorted(counts.items()))))
        if mode == "dry-run" or not log:
            continue
        for f in c.files:
            base = os.path.basename(f[0].replace("\\", "/"))
            if base == "REDACTIONS.txt" and c.kind != "dir":
                old = f[1]
                nl = b"\r\n" if b"\r\n" in old else b"\n"
                add = redact.format_log(log, title).encode()
                add = add.replace(b"\n", nl)
                if not old.endswith(nl):
                    add = nl + add
                nd = old + add
                hashes[hashlib.sha256(old).hexdigest()] = \
                    hashlib.sha256(nd).hexdigest()
                f[1] = nd
        for f in c.files:
            base = os.path.basename(f[0].replace("\\", "/"))
            if base in MANIFESTS:
                t, _ = r.apply(f[0], f[1])
                t = re.sub(rb"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])",
                           lambda m: _rehash(m.group(0), hashes), t)
                f[1] = t
        if c.kind == "dir":
            c.write(None)
        else:
            out = c.path if out_dir is None else \
                os.path.join(out_dir, os.path.basename(c.path))
            c.write(out)
    return 0


def _rehash(h, hashes):
    new = hashes.get(h.decode().lower())
    if new is None:
        return h
    return (new.upper() if h.decode().isupper() else new).encode()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
