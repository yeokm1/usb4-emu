#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
# Start the experiment's Windows 98 SE overlay (vms/win98-reenum) through
# scripts/run-win98.sh with the transfer disk, the debug console (reenum.sys
# logs on port 0xE9) and tunnel-bridge traces.  QMP 47800, VNC 47801.
#   tools/reenum-test/run98.sh <tag> [extra env for run-win98.sh via env]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
V="$REPO/vms/win98-reenum"
tag="${1:-run}"
w() { cygpath -w "$1"; }
VM_DIR="$V" QMP_PORT=47800 VNC_PORT=47801 "$REPO/scripts/run-win98.sh" \
    -drive "if=ide,index=1,format=raw,file=$(w "$V/xfer.img")" \
    -debugcon "file:$(w "$V/debugcon-$tag.log")" \
    -trace 'usb4_tp*' -trace 'usb4_tb*' -trace 'shpc*' -trace 'pci_nvme_*' \
    -D "$(w "$V/trace-$tag.log")"
