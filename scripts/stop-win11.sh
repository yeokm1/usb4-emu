#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Cleanly shut down the Windows 11 test VM started by scripts/run-win11.sh:
# ACPI power button (QMP system_powerdown), wait up to TIMEOUT seconds
# (default 180), then QMP quit, then (only if still alive) kill that PID.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_DIR:-$REPO/vms/win11}"
PIDFILE="$VM/qemu.pid"
TIMEOUT="${TIMEOUT:-180}"
QMP="python $REPO/scripts/qmp.py"

alive() { tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | grep -qi 'qemu-system'; }

[ -f "$PIDFILE" ] || { echo "stop-win11: no $PIDFILE, nothing to stop"; exit 0; }
pid="$(tr -dc '0-9' < "$PIDFILE")"
if [ -z "$pid" ] || ! alive "$pid"; then
    echo "stop-win11: PID ${pid:-?} not running"; rm -f "$PIDFILE"; exit 0
fi

touch "$VM/stop.request"
echo "stop-win11: system_powerdown (PID $pid), waiting up to ${TIMEOUT}s"
$QMP cmd system_powerdown >/dev/null 2>&1
for _ in $(seq 1 "$TIMEOUT"); do
    alive "$pid" || { echo "stop-win11: guest powered off"; rm -f "$PIDFILE"; exit 0; }
    sleep 1
done
echo "stop-win11: timeout, sending quit"
$QMP cmd quit >/dev/null 2>&1
for _ in $(seq 1 15); do
    alive "$pid" || { rm -f "$PIDFILE"; exit 0; }
    sleep 1
done
echo "stop-win11: still alive, killing PID $pid"
taskkill //F //PID "$pid" >/dev/null
[ -f "$VM/supervisor.pid" ] && taskkill //F //PID "$(tr -dc '0-9' < "$VM/supervisor.pid")" >/dev/null 2>&1
rm -f "$VM/supervisor.pid"
rm -f "$PIDFILE"
exit 1
