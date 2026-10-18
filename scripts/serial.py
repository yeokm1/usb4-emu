#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Tiny expect-style client for a QEMU `-serial tcp:...,server=on` console.

  python scripts/serial.py [--port P] login [timeout]     Kubuntu live: log in, sudo -i
  python scripts/serial.py [--port P] read <seconds>      dump console output
  python scripts/serial.py [--port P] send '<text>'       type a line
  python scripts/serial.py [--port P] run '<cmd>' [timeout]
      Run a shell command at a logged-in shell prompt and print its output.
      Output is delimited by a unique marker, so it waits exactly as long as
      the command takes (default timeout 120 s).

The port defaults to SERIAL_PORT or 47351. Output while no client is
connected is lost, which is fine for a shell.
"""
import os
import re
import socket
import sys
import time


def connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(0.5)
    return s


def drain(s, seconds, until=None):
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d:
                break
            buf += d
            if until and until in buf:
                break
        except socket.timeout:
            pass
    return buf


def main():
    args = sys.argv[1:]
    port = int(os.environ.get("SERIAL_PORT", "47351"))
    if args[:1] == ["--port"]:
        port = int(args[1])
        args = args[2:]
    s = connect(port)
    out = sys.stdout.buffer
    if args[0] == "login":
        # Kubuntu live: wait for the getty, log in as the passwordless
        # live user, become root and quieten the shell.
        buf = b""
        end = time.time() + float(args[1] if len(args) > 1 else 300)
        while time.time() < end and b"login:" not in buf[-200:]:
            buf += drain(s, 5)
            if b"login:" not in buf[-200:]:
                s.sendall(b"\r")
        for line, wait in ((b"kubuntu", 8), (b"sudo -i", 3),
                           (b'export TERM=dumb PS1="# "; unset PROMPT_COMMAND;'
                            b' bind "set enable-bracketed-paste off";'
                            b' dmesg -n 1', 2)):
            s.sendall(line + b"\r")
            drain(s, wait)
        out.write(b"logged in\n" if b"login:" in buf else b"no login prompt\n")
    elif args[0] == "read":
        out.write(drain(s, float(args[1])))
    elif args[0] == "send":
        s.sendall(args[1].encode() + b"\r")
        out.write(drain(s, 2))
    elif args[0] == "run":
        timeout = float(args[2]) if len(args) > 2 else 120
        tag = "@@%d@@" % int(time.time() * 1000)
        drain(s, 0.3)
        # The marker is split so the echoed command line does not match.
        cmd = "stty -echo cols 250 2>/dev/null; %s; echo '%s'\"END\"" % (
            args[1], tag)
        s.sendall(cmd.encode() + b"\r")
        buf = drain(s, timeout, (tag + "END").encode())
        text = buf.decode("utf-8", "replace")
        # Strip OSC (e.g. systemd 3008 shell markers) and bracketed paste.
        text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b\[\?2004[hl]",
                      "", text)
        i = text.find(tag + "END")
        if i >= 0:
            text = text[:i]
        # Drop the echoed command line if the terminal echoed it anyway.
        lines = text.replace("\r", "").split("\n")
        if lines and "stty -echo" in lines[0]:
            lines = lines[1:]
        out.write("\n".join(lines).encode())
        if i < 0:
            out.write(b"\n[serial.py: timed out]\n")
    out.flush()


if __name__ == "__main__":
    main()
