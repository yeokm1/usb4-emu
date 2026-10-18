#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Create (or, with RESET=1, recreate) a throwaway copy-on-write VM that
# boots from the Windows 11 base install without modifying it:
#
#   scripts/win11-overlay.sh win11-cm
#   VM_DIR=vms/win11-cm QMP_PORT=47301 VNC_PORT=47302 AGENT_PORT=47310 \
#       SUP_QMP_PORT=47303 scripts/run-win11.sh ...
#   VM_DIR=vms/win11-cm python scripts/guest.py exec "..."
#   VM_DIR=vms/win11-cm scripts/stop-win11.sh
#
# The base VM (vms/win11) must be stopped while overlays are in use and
# must not be booted itself, or the overlays become inconsistent.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: win11-overlay.sh <name>}"
base="$REPO/vms/win11"
dir="$REPO/vms/$name"
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"
IMG="${QEMU_IMG:-$REPO/vms/qemu-baseline/qemu-img.exe}"
if [ -f "$dir/win11.qcow2" ] && [ "${RESET:-0}" != 1 ]; then
    echo "win11-overlay: $dir exists (RESET=1 to recreate)"; exit 0
fi
mkdir -p "$dir"
rm -f "$dir/win11.qcow2"
"$IMG" create -q -f qcow2 -F qcow2 -b "$(cygpath -w "$base/win11.qcow2")" \
    "$(cygpath -w "$dir/win11.qcow2")"
cp "$base/win11-vars.base-install.fd" "$dir/win11-vars.fd"
cp "$base/agent-token" "$dir/agent-token"
echo "win11-overlay: created $dir"
