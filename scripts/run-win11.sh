#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Boot the Windows 11 test VM (vms/win11) headless in the background.
#
#   scripts/run-win11.sh [extra QEMU args...]
#
# Extra arguments are appended to the QEMU command line, e.g.
#   scripts/run-win11.sh -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
#       -device usb4-host,... -trace 'usb4_*' -D vms/win11/usb4-trace.log
#
# Environment:
#   QEMU          qemu-system-x86_64.exe (default vms/qemu-baseline/qemu-system-x86_64.exe)
#   QEMU_DATADIR  firmware/ROM dir for -L (default: <QEMU dir>/share or <QEMU dir>/pc-bios)
#   ACCEL         default "whpx"
#   CPU           default "max"
#   SMP, MEM      default 4, 8G
#   NET_RESTRICT  "on" (default: guest has no internet; hostfwd still works) or "off"
#   QMP_PORT, VNC_PORT, AGENT_PORT   default 47101, 47102, 47110 (127.0.0.1 only)
#
# Writes vms/win11/qemu.pid (QEMU's Windows PID), vms/win11/ports.env,
# vms/win11/qemu.log (stdout/stderr) and vms/win11/serial.log.
# Stop with scripts/stop-win11.sh.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_DIR:-$REPO/vms/win11}"
BASE="$REPO/vms/qemu-baseline"

QEMU="${QEMU:-$BASE/qemu-system-x86_64.exe}"
QDIR="$(cd "$(dirname "$QEMU")" && pwd)"
if [ -z "${QEMU_DATADIR:-}" ]; then
    if [ -d "$QDIR/share" ] && [ -f "$QDIR/share/kvmvapic.bin" ]; then
        QEMU_DATADIR="$QDIR/share"
    elif [ -d "$QDIR/pc-bios" ]; then
        QEMU_DATADIR="$QDIR/pc-bios"
    else
        QEMU_DATADIR="$BASE/share"
    fi
fi
OVMF_CODE="${OVMF_CODE:-$BASE/share/edk2-x86_64-code.fd}"
OVMF_VARS="$VM/win11-vars.fd"
DISK="$VM/win11.qcow2"
ACCEL="${ACCEL:-whpx}"
CPU="${CPU:-max}"
SMP="${SMP:-4}"
MEM="${MEM:-8G}"
NET_RESTRICT="${NET_RESTRICT:-on}"
QMP_PORT="${QMP_PORT:-47101}"
VNC_PORT="${VNC_PORT:-47102}"
AGENT_PORT="${AGENT_PORT:-47110}"
SUP_QMP_PORT="${SUP_QMP_PORT:-47103}"
GUEST_AGENT_PORT=8000
PIDFILE="$VM/qemu.pid"

# MSYS2 UCRT64 runtime DLLs for our QEMU build.
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"

winpid_alive() {
    # True if Windows PID $1 is a running qemu-system process.
    tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | grep -qi 'qemu-system'
}

SUPPID="$VM/supervisor.pid"
if [ -f "$SUPPID" ]; then
    sp="$(tr -dc '0-9' < "$SUPPID")"
    if [ -n "$sp" ] && tasklist //FI "PID eq $sp" //FO CSV //NH 2>/dev/null | grep -qi 'python'; then
        echo "run-win11: supervisor already running (PID $sp, $SUPPID)" >&2
        exit 1
    fi
    rm -f "$SUPPID"
fi
if [ -f "$PIDFILE" ]; then
    oldpid="$(tr -dc '0-9' < "$PIDFILE")"
    if [ -n "$oldpid" ] && winpid_alive "$oldpid"; then
        echo "run-win11: VM already running (PID $oldpid, $PIDFILE)" >&2
        exit 1
    fi
    rm -f "$PIDFILE"
fi
[ -f "$DISK" ] || { echo "run-win11: $DISK missing (run scripts/win11-install.sh)" >&2; exit 1; }
[ -f "$OVMF_VARS" ] || { echo "run-win11: $OVMF_VARS missing" >&2; exit 1; }

w() { cygpath -w "$1"; }

cat > "$VM/ports.env" <<EOF
QMP_PORT=$QMP_PORT
VNC_PORT=$VNC_PORT
AGENT_PORT=$AGENT_PORT
SUP_QMP_PORT=$SUP_QMP_PORT
EOF

args=(
    -name win11-usb4
    -machine q35 -accel "$ACCEL"
    -cpu "$CPU" -smp "$SMP" -m "$MEM"
    -L "$(w "$QEMU_DATADIR")"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(w "$OVMF_CODE")"
    -drive "if=pflash,format=raw,unit=1,file=$(w "$OVMF_VARS")"
    -drive "if=none,id=sysdisk,format=qcow2,file=$(w "$DISK"),discard=unmap,detect-zeroes=unmap"
    -device ide-hd,drive=sysdisk,bus=ide.0
    -netdev "user,id=net0,restrict=$NET_RESTRICT,hostfwd=tcp:127.0.0.1:$AGENT_PORT-:$GUEST_AGENT_PORT"
    -device e1000e,netdev=net0,romfile=
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0
    -display none -vga std
    -vnc "127.0.0.1:$((VNC_PORT - 5900))"
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off"
    -serial "file:$(w "$VM/serial.log")"
    -pidfile "$(w "$PIDFILE")"
    -rtc base=utc
)

echo "$QEMU ${args[*]} $*" > "$VM/qemu.cmdline"
# Guest resets do not work in place under WHPX on this host, so QEMU runs
# with -no-reboot under a supervisor that relaunches it on reset (see
# scripts/vm_supervisor.py). The QEMU PID therefore changes on every guest
# reboot; qemu.pid always holds the current one.
: > "$VM/qemu.log"
nohup python "$(w "$REPO/scripts/vm_supervisor.py")" --vmdir "$(w "$VM")" \
    --qmp-port "$SUP_QMP_PORT" -- "$(w "$QEMU")" "${args[@]}" "$@" \
    >"$VM/supervisor.out" 2>&1 < /dev/null &
disown

for _ in $(seq 1 40); do
    if [ -s "$PIDFILE" ]; then
        pid="$(tr -dc '0-9' < "$PIDFILE")"
        if winpid_alive "$pid"; then
            echo "run-win11: started PID $pid (QMP $QMP_PORT, VNC 127.0.0.1:$VNC_PORT, agent $AGENT_PORT)"
            exit 0
        fi
    fi
    sleep 0.5
done
echo "run-win11: QEMU did not start; see $VM/qemu.log:" >&2
cat "$VM/qemu.log" >&2
exit 1
