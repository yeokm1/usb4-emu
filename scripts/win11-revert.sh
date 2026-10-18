#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Revert the Windows 11 test VM to a snapshot (default: base-install):
# applies the internal qcow2 snapshot and restores the matching OVMF vars.
#
#   scripts/win11-revert.sh [snapshot-name]
#
# The VM must be stopped (scripts/stop-win11.sh). To make a new snapshot:
#   SAVE=1 scripts/win11-revert.sh <name>   (VM stopped; creates instead)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="$REPO/vms/win11"
SNAP="${1:-base-install}"
IMG="$REPO/vms/qemu-baseline/qemu-img.exe"
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"

if [ -f "$VM/qemu.pid" ]; then
    pid="$(tr -dc '0-9' < "$VM/qemu.pid")"
    if [ -n "$pid" ] && tasklist //FI "PID eq $pid" //FO CSV //NH 2>/dev/null | grep -qi qemu-system; then
        echo "win11-revert: VM is running (PID $pid); run scripts/stop-win11.sh first" >&2
        exit 1
    fi
fi

DISK="$(cygpath -w "$VM/win11.qcow2")"
if [ "${SAVE:-0}" = 1 ]; then
    "$IMG" snapshot -c "$SNAP" "$DISK"
    cp "$VM/win11-vars.fd" "$VM/win11-vars.$SNAP.fd"
    echo "win11-revert: created snapshot $SNAP"
else
    [ -f "$VM/win11-vars.$SNAP.fd" ] || { echo "win11-revert: $VM/win11-vars.$SNAP.fd missing" >&2; exit 1; }
    "$IMG" snapshot -a "$SNAP" "$DISK"
    cp "$VM/win11-vars.$SNAP.fd" "$VM/win11-vars.fd"
    echo "win11-revert: reverted to $SNAP"
fi
"$IMG" snapshot -l "$DISK"
