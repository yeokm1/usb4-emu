#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Run QEMU and turn guest resets into fresh QEMU launches.

Why: under WHPX on the maintainer's host (AMD Ryzen AI MAX+ 395, QEMU
11.1.2 fork) an in-place guest reset does not work: after the reset the boot
CPU spins in early OVMF and, with more than one vCPU, the APs stop with
"WHPX: Unexpected VP exit code 4". Cold starts are fine. So QEMU runs with
-no-reboot, this supervisor watches a private QMP socket for the SHUTDOWN
event and starts QEMU again (same command line) when the reason was a reset.
A guest power-off or a QMP quit ends the supervisor.

  vm_supervisor.py --vmdir DIR --qmp-port P -- qemu-system-x86_64.exe args...

The supervisor appends "-no-reboot" and its own "-qmp tcp:127.0.0.1:P".
It writes DIR/supervisor.pid and logs to DIR/supervisor.log; QEMU output is
appended to DIR/qemu.log. Creating DIR/stop.request suppresses relaunch.
"""
import argparse
import datetime
import json
import os
import socket
import subprocess
import sys
import time

RELAUNCH_REASONS = {"guest-reset", "host-qmp-system-reset", "host-ui"}


def log(vmdir, msg):
    line = "%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg)
    with open(os.path.join(vmdir, "supervisor.log"), "a") as f:
        f.write(line)


def watch_qmp(port, proc):
    """Return the reason of the last SHUTDOWN event (None if none seen)."""
    sock = None
    for _ in range(300):
        if proc.poll() is not None:
            return None
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError:
            time.sleep(0.2)
    if sock is None:
        return None
    sock.settimeout(None)
    f = sock.makefile("rwb")
    reason = None
    try:
        f.readline()
        f.write(b'{"execute":"qmp_capabilities"}\n')
        f.flush()
        for line in f:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("event") == "SHUTDOWN":
                reason = msg.get("data", {}).get("reason")
    except OSError:
        pass
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return reason


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vmdir", required=True)
    ap.add_argument("--qmp-port", type=int, required=True)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    cmd = cmd + ["-no-reboot", "-qmp", "tcp:127.0.0.1:%d,server=on,wait=off" % a.qmp_port]
    stop = os.path.join(a.vmdir, "stop.request")
    with open(os.path.join(a.vmdir, "supervisor.pid"), "w") as f:
        f.write(str(os.getpid()))
    try:
        os.unlink(stop)
    except OSError:
        pass
    boots = 0
    while True:
        boots += 1
        with open(os.path.join(a.vmdir, "qemu.log"), "ab") as out:
            proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT)
        log(a.vmdir, "boot %d: started QEMU pid %d" % (boots, proc.pid))
        reason = watch_qmp(a.qmp_port, proc)
        rc = proc.wait()
        log(a.vmdir, "boot %d: QEMU exited rc=%d shutdown-reason=%s" % (boots, rc, reason))
        if reason in RELAUNCH_REASONS and not os.path.exists(stop):
            time.sleep(1)
            continue
        break
    try:
        os.unlink(os.path.join(a.vmdir, "supervisor.pid"))
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
