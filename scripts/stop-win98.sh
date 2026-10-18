#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Stop the Windows 98 VM started by scripts/run-win98.sh. Windows 98 on
# i440FX does not reliably honour the ACPI power button, so by default this
# sends QMP system_powerdown, waits TIMEOUT seconds (default 60), then QMP
# quit, then (only if still alive) kills that PID. Shut Windows down from the
# Start menu first if you care about a clean FAT (avoids ScanDisk at boot).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_DIR:-$REPO/vms/win98}"
PIDFILE="$VM/qemu.pid"
TIMEOUT="${TIMEOUT:-60}"
QMP="python $REPO/scripts/qmp.py"
export VM_DIR="$VM"

alive() { tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | grep -qi 'qemu-system'; }

[ -f "$PIDFILE" ] || { echo "stop-win98: no $PIDFILE, nothing to stop"; exit 0; }
pid="$(tr -dc '0-9' < "$PIDFILE")"
if [ -z "$pid" ] || ! alive "$pid"; then
    echo "stop-win98: PID ${pid:-?} not running"; rm -f "$PIDFILE"; exit 0
fi

echo "stop-win98: system_powerdown (PID $pid), waiting up to ${TIMEOUT}s"
$QMP cmd system_powerdown >/dev/null 2>&1
for _ in $(seq 1 "$TIMEOUT"); do
    alive "$pid" || { echo "stop-win98: guest powered off"; rm -f "$PIDFILE"; exit 0; }
    sleep 1
done
echo "stop-win98: timeout, sending quit"
$QMP cmd quit >/dev/null 2>&1
for _ in $(seq 1 15); do
    alive "$pid" || { rm -f "$PIDFILE"; exit 0; }
    sleep 1
done
echo "stop-win98: still alive, killing PID $pid"
taskkill //F //PID "$pid" >/dev/null
rm -f "$PIDFILE"
