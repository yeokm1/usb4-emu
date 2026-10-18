#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Yeo Kheng Meng
"""Redact host-identifying data from a capture directory, in place.

Usage: redact.py DIR [SECRETS_FILE]

SECRETS_FILE (optional) holds one literal string per line (system/board/
chassis serials, system UUID, NIC MAC addresses, host name). In addition,
the following are found automatically in the capture itself:

  * host names: "Hostname set to <...>", `uname -a`, syslog/journal lines,
    PowerShell transcript "Machine:", COMPUTERNAME=, PSComputerName;
  * user names: C:\\Users\\<name>\\ and /home/<name>/ paths (text, and
    ASCII or UTF-16 strings in binary files such as .etl traces);
  * filesystem and partition UUIDs: UUID=, PARTUUID=, root=/resume=UUID=,
    /dev/disk/by-uuid/, "mounted filesystem <uuid>";
  * USB serial numbers: "SerialNumber:" lines, lsusb "iSerial", and the
    serial part of Windows instance IDs (USB\\VID_x&PID_y\\<serial>,
    USBSTOR\\...\\<serial>&0, XHCIUAS\\...), including Windows 98 ENUM.REG;
  * PCIe Device Serial Numbers of functions that are not Thunderbolt/USB4
    controllers (these are usually derived from a MAC address), taken from
    raw config space files (config.bin) and from lspci "Device Serial
    Number" and sysfs "serial_number" lines. Every form is replaced: the
    raw bytes, `lspci -xxxx` hex, the dashed form, Windows instance IDs
    and the decimal DEVPKEY_PciDevice_SerialNumber;
  * the MAC address node of time-based (version 1) GUIDs generated after
    2018, such as Windows device container IDs;
  * MAC-address-shaped tokens and "Serial Number:" values in text files.

Text files get placeholders (<HOST>, <USER>, <MAC>, <REDACTED>) or a
same-length run of X; filesystem UUIDs become the all-zero UUID of the
same format. Binary files get same-length replacements ('X' bytes, 0x58
for a Device Serial Number) so offsets stay valid.

Kept on purpose: Thunderbolt router UUIDs (unique_id, boot_acl, ICM events,
DROM) and the PCIe Device Serial Number of Thunderbolt/USB4 controller
functions, which is derived from the router UID. They identify the
Thunderbolt chips, not the owner, and the emulator needs them.

Writes a log of what was changed to DIR/REDACTIONS.txt (counts per file
and category, not the secrets). tools/p14s-capture/scrub.py runs the same
engine on finished archives (.tar.gz, .zip) and Windows 98 folders.
"""

import datetime
import os
import re
import struct
import sys
import uuid

UUID_RE = (r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
           r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
ZERO_UUID = "00000000-0000-0000-0000-000000000000"
GENERIC_HOSTS = {"localhost", "ubuntu", "kubuntu", "xubuntu", "lubuntu",
                 "debian", "fedora", "archiso", "linux", "live", "(none)"}
SKIP_USERS = {"public", "default", "default user", "all users", "root"}
PLACEHOLDER = re.compile(r"^<[A-Z]+>$|^X+$|^\*+$", re.I)

# Thunderbolt/USB4 controller functions (Intel). Their PCIe Device Serial
# Number is the router UID and is kept. Everything else is redacted.
TB_DEVICES = {
    0x1513, 0x151a, 0x151b, 0x1547, 0x1548, 0x1549, 0x156a, 0x156b,
    0x156c, 0x156d, 0x1575, 0x1576, 0x1577, 0x1578, 0x15b5, 0x15b6,
    0x15bf, 0x15c0, 0x15c1, 0x15d2, 0x15d3, 0x15d4, 0x15d9, 0x15da,
    0x15db, 0x15dc, 0x15dd, 0x15de, 0x15e7, 0x15e8, 0x15e9, 0x15ea,
    0x15eb, 0x15ec, 0x15ef, 0x15f0, 0x0b26, 0x1133, 0x1134, 0x1135,
    0x1136, 0x1137, 0x1138, 0x5780, 0x5781, 0x5782, 0x5783, 0x5784,
    0x5785, 0x5786, 0x5787, 0x8a0d, 0x8a17, 0x8a1d, 0x8a1f, 0x8a21,
    0x8a23, 0x9a1b, 0x9a1d, 0x9a1f, 0x9a21, 0x9a23, 0x9a25, 0x9a27,
    0x9a29, 0x9a2b, 0x9a2d, 0x463e, 0x466d, 0x467e, 0x461e, 0x461f,
    0x462e, 0x462f, 0xa73e, 0xa76d, 0xa71e, 0x7ec2, 0x7ec3, 0x7ec4,
    0x7ec5, 0x7ec6, 0x7ec7, 0xa833, 0xa834, 0xa86d, 0xa86e,
}
# USB4 host interface class (0c0340) and Thunderbolt NHI (088000).
TB_CLASSES = {0x0c0340, 0x088000}

TEXT_HOST = [
    re.compile(r"Hostname set to <([^>\s]+)>"),
    re.compile(r"^Linux (\S+) \d+\.\d+\S* #", re.M),
    re.compile(r"^[A-Z][a-z]{2} [ \d]\d \d\d:\d\d:\d\d (\S+) "
               r"(?:kernel|systemd|bolt|boltd)", re.M),
    re.compile(r"Machine: (\S+) \(Microsoft"),
    re.compile(r"\bCOMPUTERNAME=([^\s;]+)"),
    re.compile(r"PSComputerName[ \t]*:[ \t]*(\S+)"),
    re.compile(r"(?:Username|RunAs User): ([^\\\s]+)\\"),
]
USER_PATS = [
    re.compile(r"[A-Za-z]:\\+(?:Users|Documents and Settings)\\+"
               r"([^\\/:*?\"<>|\r\n\x00]{1,64})\\", re.I),
    re.compile(r"(?<![\w/])/home/([a-z_][a-z0-9_.-]{0,31})(?=[/\s'\"]|$)",
               re.M),
    re.compile(r"(?:Username|RunAs User): [^\\\s]+\\(\S+)"),
]
FSUUID_PATS = [
    re.compile(r"\b(?:PART|PT)?UUID(?:_SUB)?=\"?(" + UUID_RE + r")"),
    re.compile(r"\b(?:PART|PT)?UUID=\"?([0-9a-fA-F]{8}-[0-9a-fA-F]{2})\b"),
    re.compile(r"\bUUID=\"?([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})\b"),
    re.compile(r"\bUUID=\"?([0-9A-Fa-f]{16})\b"),
    re.compile(r"/dev/disk/by-(?:part)?uuid/(" + UUID_RE + r")"),
    re.compile(r"mounted filesystem (" + UUID_RE + r")"),
]
USB_SERIAL_PATS = [
    re.compile(r"SerialNumber:[ \t]*(\S[^\r\n]*)"),
    re.compile(r"iSerial[ \t]+\d+[ \t]+(\S[^\r\n]*)"),
]
# Windows instance IDs: <enumerator>\<hardware id>\<instance>, also with
# '#' separators (device interface paths) and doubled backslashes (.reg).
WIN_INST = re.compile(
    r"(?<![A-Za-z0-9_])(?:USB|USBSTOR|XHCIUAS|USBPRINT)(?:\\\\|\\|#)"
    r"([^\\#\]\s\"',;]+)(?:\\\\|\\|#)([^\\#\]\s\"',;{}]+)", re.I)
DSN_LINE = re.compile(r"(?:Device Serial Number|serial_number:)[ \t]*"
                      r"((?:[0-9a-fA-F]{2}-){7}[0-9a-fA-F]{2})")
V1_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-1[0-9a-fA-F]{3}-"
                     r"[89abAB][0-9a-fA-F]{3}-([0-9a-fA-F]{12})")

MAC = re.compile(r"(?<![0-9A-Fa-f:])[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}"
                 r"(?!:?[0-9A-Fa-f])")
SERIAL = re.compile(r"((?:Serial Number|SerialNumber|serial)[ \t]*[:=][ \t]*)"
                    r"(?!<)(\S[^\r\n]*)")
V1_EPOCH = datetime.datetime(2018, 1, 1)
# Absent, all-ones, or already redacted (0x58 bytes).
NO_DSN = (0, 0xffffffffffffffff, 0x5858585858585858)


def kind(data):
    """'utf16' (with BOM), 'text' or 'bin'."""
    if data[:2] == b"\xff\xfe":
        return "utf16"
    if b"\0" in data[:65536]:
        return "bin"
    return "text"


def views(data):
    """Text views of a file for collection: (str, is_text)."""
    k = kind(data)
    if k == "utf16":
        return [data[2:len(data) - (len(data) % 2)].decode("utf-16-le",
                                                          "replace")], True
    out = [data.decode("latin1")]
    if k == "bin":
        for o in (0, 1):
            n = len(data) - o - ((len(data) - o) % 2)
            out.append(data[o:o + n].decode("utf-16-le", "replace"))
    return out, k == "text"


def parse_dsn(data):
    """(vendor, device, class, dsn or None) of a raw PCI config file."""
    if len(data) < 64:
        return None
    vid, did = struct.unpack_from("<HH", data, 0)
    if vid in (0, 0xffff):
        return None
    cls = int.from_bytes(data[9:12], "little")
    off, n = 0x100, 0
    while off and len(data) >= off + 12 and n < 64:
        h = struct.unpack_from("<I", data, off)[0]
        if h in (0, 0xffffffff):
            break
        if h & 0xffff == 3:
            return vid, did, cls, struct.unpack_from("<Q", data, off + 4)[0]
        off, n = h >> 20, n + 1
    return vid, did, cls, None


class Redactor:
    def __init__(self, secrets=(), keep_dsn=()):
        self.literal = {}        # secret -> (category, text replacement)
        self.dsn_keep = set()
        self.dsn_redact = set()
        self.nodes = set()       # v1 GUID nodes (12 hex, lower case)
        self._dsn_text = set()   # DSNs seen in lspci/sysfs text
        self.keep_dsn_ids = set(keep_dsn)
        for s in secrets:
            s = s.strip()
            if len(s) >= 4 and s.lower() not in (
                    "none", "not specified", "default string",
                    "to be filled by o.e.m.", "0123456789", ZERO_UUID):
                self.literal.setdefault(s, ("secret", "<REDACTED>"))

    # ---- collection ----------------------------------------------------
    def _add(self, value, cat, repl):
        value = value.strip()
        if not value or PLACEHOLDER.match(value) or "<" in value:
            return
        self.literal.setdefault(value, (cat, repl))

    def collect(self, name, data):
        base = os.path.basename(name.replace("\\", "/"))
        if base in ("config.bin", "config") or base.endswith(".config.bin"):
            p = parse_dsn(data)
            if p and p[3] not in (None,) + NO_DSN:
                vid, did, cls, dsn = p
                keep = (vid == 0x8086 and (did in TB_DEVICES or
                                           cls in TB_CLASSES)) or \
                    (vid, did) in self.keep_dsn_ids
                (self.dsn_keep if keep else self.dsn_redact).add(dsn)
        texts, is_text = views(data)
        for t in texts:
            for rx in USER_PATS[:1]:
                for m in rx.finditer(t):
                    u = m.group(1)
                    if u.lower() not in SKIP_USERS:
                        self._add(u, "user", "<USER>")
            for m in V1_UUID.finditer(t):
                self._v1(m)
            if not is_text and t is not texts[0]:
                continue
            for rx in TEXT_HOST:
                for m in rx.finditer(t):
                    h = m.group(1)
                    if h.lower() not in GENERIC_HOSTS:
                        self._add(h, "host", "<HOST>")
            for rx in USER_PATS[1:]:
                for m in rx.finditer(t):
                    if m.group(1).lower() not in SKIP_USERS:
                        self._add(m.group(1), "user", "<USER>")
            for rx in FSUUID_PATS:
                for m in rx.finditer(t):
                    v = m.group(1)
                    if v.strip("0-") == "":
                        continue
                    self._add(v, "fs-uuid", re.sub(r"[0-9A-Za-z]", "0", v))
            for rx in USB_SERIAL_PATS:
                for m in rx.finditer(t):
                    v = m.group(1).strip()
                    if len(v) >= 4:
                        self._add(v, "usb-serial", "X" * len(v))
            for m in WIN_INST.finditer(t):
                inst = re.sub(r"&[0-9A-Fa-f]{1,3}$", "", m.group(2))
                if "&" in inst or len(inst) < 5 or inst.upper() == "GLOBAL":
                    continue
                self._add(inst, "usb-serial", "X" * len(inst))
            for m in DSN_LINE.finditer(t):
                v = int(m.group(1).replace("-", ""), 16)
                if v not in NO_DSN:
                    self._dsn_text.add(v)

    def _v1(self, m):
        try:
            u = uuid.UUID(m.group(0))
            when = datetime.datetime(1582, 10, 15) + \
                datetime.timedelta(microseconds=u.time // 10)
        except (ValueError, OverflowError):
            return
        node = m.group(1).lower()
        if when < V1_EPOCH or int(node[:2], 16) & 1 or \
                node == "806e6f6e6963" or node.strip("0") == "":
            return
        self.nodes.add(node)

    def finish(self):
        """Call after collect() on every file, before apply()."""
        self.dsn_redact |= {v for v in self._dsn_text
                            if v not in self.dsn_keep}
        self.dsn_redact -= self.dsn_keep
        self._build()

    # ---- application ---------------------------------------------------
    def _build(self):
        """One rule per value: a text regex and its replacement, plus the
        literal forms to replace (same length) in binary files."""
        b, e = r"(?<![0-9A-Za-z])", r"(?![0-9A-Za-z])"
        # (category, text regex, text replacement, literals, end anchor)
        rules = []
        for s, (cat, repl) in sorted(self.literal.items(),
                                     key=lambda x: (-len(x[0]), x[0])):
            core = re.escape(s)
            rx = re.compile(core if cat == "secret" else b + core + e, re.I)
            rules.append((cat, rx, repl, [s], True))
            if "-" in s and cat != "secret":
                # systemd unit names escape '-' as \x2d
                # (dev-disk-by\x2duuid-0123\x2d...).
                esc = s.replace("-", "\\x2d")
                rules.append((cat, re.compile(re.escape(esc) + e, re.I),
                              repl.replace("-", "\\x2d") if cat == "fs-uuid"
                              else repl, [esc], True))
        for v in sorted(self.dsn_redact):
            be = "%016x" % v
            le = struct.pack("<Q", v).hex()
            dashed = "-".join(be[i:i + 2] for i in range(0, 16, 2))
            rules.append(("pcie-dsn", re.compile(b + dashed + e, re.I),
                          "XX-" * 7 + "XX", [dashed], True))
            # Windows instance IDs append the function number: no end anchor.
            rules.append(("pcie-dsn", re.compile(b + be, re.I), "X" * 16,
                          [be], False))
            rules.append(("pcie-dsn", re.compile(b + str(v) + e),
                          "X" * len(str(v)), [str(v)], True))
            hexdump = r"(?:[ \t]|[ \t]*\r?\n[0-9a-fA-F]{2,4}:[ \t])".join(
                le[i:i + 2] for i in range(0, 16, 2))
            rules.append(("pcie-dsn", re.compile(b + hexdump + e, re.I),
                          _hexdump_x, [], True))
        for n in sorted(self.nodes):
            rules.append(("guid-node", re.compile(b + n + e, re.I),
                          "0" * 12, [n], True))
        self.rules = rules
        # Binary files: ASCII and UTF-16LE forms with the same boundaries.
        bin_rules = []
        for cat, _, _, lits, anchored in rules:
            for s in lits:
                if cat == "secret":
                    pa, pw = re.escape(s), re.escape("\0".join(s) + "\0")
                else:
                    pa = b + re.escape(s) + (e if anchored else "")
                    pw = r"(?<![0-9A-Za-z]\x00)" + \
                        re.escape("\0".join(s) + "\0") + \
                        (r"(?![0-9A-Za-z]\x00)" if anchored else "")
                bin_rules.append((cat, re.compile(pa, re.I)))
                bin_rules.append((cat, re.compile(pw, re.I)))
        self.bin_rules = bin_rules
        self.bin_bytes = [("pcie-dsn", struct.pack("<Q", v), b"X" * 8)
                          for v in sorted(self.dsn_redact)] + \
            [("guid-node", bytes.fromhex(n), b"\0" * 6)
             for n in sorted(self.nodes)]

    def apply_text(self, t, counts):
        for cat, rx, repl, _, _ in self.rules:
            t, c = rx.subn(repl if callable(repl) else
                           (lambda m, r=repl: r), t)
            _count(counts, cat, c)
        n = [0]

        def mac(m):
            if m.group(0).lower() in ("00:00:00:00:00:00",
                                      "ff:ff:ff:ff:ff:ff"):
                return m.group(0)
            n[0] += 1
            return "<MAC>"
        t = MAC.sub(mac, t)
        _count(counts, "mac", n[0])
        t, c = SERIAL.subn(r"\1<REDACTED>", t)
        _count(counts, "serial", c)
        return t

    def apply_bin(self, data, counts):
        t = data.decode("latin1")
        for cat, rx in self.bin_rules:
            t, c = rx.subn(lambda m, cat=cat: _same_len(cat, m.group(0)), t)
            _count(counts, cat, c)
        data = t.encode("latin1")
        for cat, pat, rep in self.bin_bytes:
            c = data.count(pat)
            if c:
                data = data.replace(pat, rep)
                _count(counts, cat, c)
        return data

    def apply(self, name, data):
        """Return (new data, {category: count})."""
        counts = {}
        k = kind(data)
        if k == "utf16":
            body = data[2:]
            odd = body[len(body) - (len(body) % 2):]
            t = body[:len(body) - len(odd)].decode("utf-16-le",
                                                    "surrogatepass")
            nt = self.apply_text(t, counts)
            if nt != t:
                data = data[:2] + nt.encode("utf-16-le", "surrogatepass") + \
                    odd
        elif k == "text":
            t = data.decode("latin1")
            nt = self.apply_text(t, counts)
            if nt != t:
                data = nt.encode("latin1")
        else:
            data = self.apply_bin(data, counts)
        return data, counts

    def apply_name(self, name):
        """Same-length scrub of a path (no <...> placeholders in names)."""
        for cat, rx, _, lits, _ in self.rules:
            if lits:
                name = rx.sub(lambda m, cat=cat: _same_len(cat, m.group(0)),
                              name)
        return name


def _count(counts, cat, c):
    if c:
        counts[cat] = counts.get(cat, 0) + c


def _same_len(cat, s):
    if cat in ("fs-uuid", "guid-node"):
        return re.sub(r"\\x2d|[0-9A-Za-z]",
                      lambda m: m.group(0) if len(m.group(0)) > 1 else "0", s)
    return re.sub(r"[^\x00]", "X", s)


def _hexdump_x(m):
    return re.sub(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])", "58",
                  m.group(0))


def format_log(log, title):
    lines = ["# " + title,
             "# replacements per file and category (secrets themselves "
             "not recorded)"]
    for path, counts in log:
        lines.append("%6d  %s  (%s)" % (
            sum(counts.values()), path,
            ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    root = sys.argv[1]
    secrets = []
    if len(sys.argv) == 3:
        with open(sys.argv[2], encoding="utf-8", errors="replace") as f:
            secrets = f.read().splitlines()
    r = Redactor(secrets)
    files = []
    for dirpath, _, names in os.walk(root):
        for name in sorted(names):
            path = os.path.join(dirpath, name)
            if name == "REDACTIONS.txt" or os.path.islink(path):
                continue
            files.append(path)
            with open(path, "rb") as f:
                r.collect(path, f.read())
    r.finish()
    log = []
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
        new, counts = r.apply(path, data)
        if new != data:
            with open(path, "wb") as f:
                f.write(new)
        rel = os.path.relpath(path, root)
        nrel = r.apply_name(rel)
        if nrel != rel:
            os.rename(path, os.path.join(root, nrel))
            counts["path"] = counts.get("path", 0) + 1
        if counts:
            log.append(((nrel if nrel != rel else rel).replace(os.sep, "/"),
                        counts))
    with open(os.path.join(root, "REDACTIONS.txt"), "w") as f:
        f.write(format_log(log, "redact.py"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
