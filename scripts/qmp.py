#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Minimal QMP client for the usb4-emu test VMs (stdlib only).

  python scripts/qmp.py [--port P] cmd <command> ['<json arguments>']
  python scripts/qmp.py [--port P] hmp '<human monitor command>'
  python scripts/qmp.py [--port P] screendump out.png
  python scripts/qmp.py [--port P] sendkey ret [ctrl alt delete ...]
  python scripts/qmp.py [--port P] spamkey <key> <seconds>   (one press/0.5 s)

The port defaults to QMP_PORT from vms/win11/ports.env, else 47101.
"""
import json
import os
import socket
import struct
import sys
import tempfile
import time
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def default_port():
    try:
        with open(os.path.join(os.environ.get("VM_DIR") or os.path.join(REPO, "vms", "win11"), "ports.env")) as f:
            for line in f:
                if line.startswith("QMP_PORT="):
                    return int(line.split("=", 1)[1])
    except OSError:
        pass
    return 47101


class QMP:
    def __init__(self, port, host="127.0.0.1", timeout=10):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.f = self.s.makefile("rwb")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("QMP connection closed")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def cmd(self, name, args=None):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write(json.dumps(req).encode() + b"\n")
        self.f.flush()
        msg = self._read()
        if "error" in msg:
            raise RuntimeError(msg["error"])
        return msg.get("return")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def ppm_to_png(ppm, png):
    with open(ppm, "rb") as f:
        data = f.read()
    # P6 header: magic, width, height, maxval separated by whitespace.
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    pos += 1
    w, h = int(fields[1]), int(fields[2])
    raw = data[pos:pos + w * h * 3]
    rows = b"".join(b"\x00" + raw[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(png, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(rows, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    argv = sys.argv[1:]
    port = default_port()
    if argv[:1] == ["--port"]:
        port = int(argv[1])
        argv = argv[2:]
    if not argv:
        print(__doc__)
        return 2
    q = QMP(port)
    op = argv[0]
    if op == "cmd":
        args = json.loads(argv[2]) if len(argv) > 2 else None
        print(json.dumps(q.cmd(argv[1], args), indent=1))
    elif op == "hmp":
        print(q.cmd("human-monitor-command", {"command-line": argv[1]}))
    elif op == "screendump":
        out = os.path.abspath(argv[1])
        fd, ppm = tempfile.mkstemp(suffix=".ppm")
        os.close(fd)
        q.cmd("screendump", {"filename": ppm})
        ppm_to_png(ppm, out)
        os.unlink(ppm)
        print(out)
    elif op == "sendkey":
        keys = [{"type": "qcode", "data": k} for k in argv[1:]]
        q.cmd("send-key", {"keys": keys})
    elif op == "spamkey":
        end = time.time() + float(argv[2])
        while time.time() < end:
            q.cmd("send-key", {"keys": [{"type": "qcode", "data": argv[1]}]})
            time.sleep(0.5)
    else:
        print(__doc__)
        return 2
    q.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
