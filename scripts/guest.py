#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
"""Host-side client for the usb4-emu Windows guest agent (scripts/win11/agent.ps1).

Usage:
  python scripts/guest.py ping
  python scripts/guest.py wait [--timeout S]          wait until the agent answers
  python scripts/guest.py exec "Get-PnpDevice" [--timeout S]
  python scripts/guest.py exec -f script.ps1 [--timeout S]
  python scripts/guest.py put <local file> <guest path>
  python scripts/guest.py get <guest path> <local file>

exec prints the guest's stdout to stdout and stderr to stderr and exits with
the guest script's exit code (124 on timeout). --json prints the raw reply.

Connection: USB4_GUEST_HOST (default 127.0.0.1), USB4_GUEST_PORT (default from
vms/win11/ports.env AGENT_PORT, else 47110), USB4_GUEST_TOKEN (default the
contents of vms/win11/agent-token).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VMDIR = os.environ.get("VM_DIR") or os.path.join(REPO, "vms", "win11")


def _ports_env():
    env = {}
    try:
        with open(os.path.join(VMDIR, "ports.env")) as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    env[k] = v
    except OSError:
        pass
    return env


def _config():
    host = os.environ.get("USB4_GUEST_HOST", "127.0.0.1")
    port = os.environ.get("USB4_GUEST_PORT") or _ports_env().get("AGENT_PORT", "47110")
    token = os.environ.get("USB4_GUEST_TOKEN")
    if not token:
        try:
            with open(os.path.join(VMDIR, "agent-token")) as f:
                token = f.read().strip()
        except OSError:
            token = ""
    return "http://%s:%s" % (host, port), token


def _request(method, path, query=None, data=None, timeout=60):
    base, token = _config()
    url = base + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Token", token)
    if data is not None:
        req.add_header("Content-Type", "application/octet-stream")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def cmd_ping(_a):
    st, body = _request("GET", "/ping", timeout=10)
    print(body.decode("utf-8"))
    return 0


def cmd_wait(a):
    deadline = time.time() + a.timeout
    while True:
        try:
            st, body = _request("GET", "/ping", timeout=5)
            if st == 200:
                print(body.decode("utf-8"))
                return 0
        except (OSError, urllib.error.URLError):
            pass
        if time.time() > deadline:
            print("guest agent not reachable after %ds" % a.timeout, file=sys.stderr)
            return 1
        time.sleep(3)


def cmd_exec(a):
    if a.file:
        with open(a.file, "rb") as f:
            script = f.read()
    else:
        script = " ".join(a.script).encode("utf-8")
    st, body = _request("POST", "/exec", {"timeout": a.timeout}, script,
                        timeout=a.timeout + 60)
    res = json.loads(body.decode("utf-8"))
    if a.json:
        print(json.dumps(res, indent=1))
    else:
        sys.stdout.write(res.get("stdout") or "")
        sys.stderr.write(res.get("stderr") or "")
    if res.get("timed_out"):
        print("[guest.py] command timed out after %ss" % a.timeout, file=sys.stderr)
        return 124
    code = res.get("exit", 1)
    return code if isinstance(code, int) and 0 <= code < 256 else 1


def cmd_put(a):
    with open(a.local, "rb") as f:
        data = f.read()
    st, body = _request("POST", "/put", {"path": a.remote}, data, timeout=600)
    print(body.decode("utf-8"))
    return 0


def cmd_get(a):
    try:
        st, body = _request("GET", "/get", {"path": a.remote}, timeout=600)
    except urllib.error.HTTPError as e:
        print(e.read().decode("utf-8", "replace"), file=sys.stderr)
        return 1
    with open(a.local, "wb") as f:
        f.write(body)
    print("%d bytes -> %s" % (len(body), a.local))
    return 0


def main():
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding="utf-8", errors="replace")
        except AttributeError:
            pass
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ping").set_defaults(fn=cmd_ping)
    w = sub.add_parser("wait")
    w.add_argument("--timeout", type=int, default=600)
    w.set_defaults(fn=cmd_wait)
    e = sub.add_parser("exec")
    e.add_argument("script", nargs="*")
    e.add_argument("-f", "--file")
    e.add_argument("--timeout", type=int, default=600)
    e.add_argument("--json", action="store_true")
    e.set_defaults(fn=cmd_exec)
    pu = sub.add_parser("put")
    pu.add_argument("local")
    pu.add_argument("remote")
    pu.set_defaults(fn=cmd_put)
    g = sub.add_parser("get")
    g.add_argument("remote")
    g.add_argument("local")
    g.set_defaults(fn=cmd_get)
    a = p.parse_args()
    try:
        sys.exit(a.fn(a))
    except urllib.error.HTTPError as e:
        print("HTTP %d: %s" % (e.code, e.read().decode("utf-8", "replace")), file=sys.stderr)
        sys.exit(2)
    except (OSError, urllib.error.URLError) as e:
        print("guest agent unreachable: %s" % e, file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
