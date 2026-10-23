#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Boot a Windows 11 overlay headless with the Alpine Ridge firmware-CM
# profile (tb3-alpine-ridge), for the M3 smoke gate and the Windows 11 legs
# of M5-M7 with the pinned Intel Thunderbolt package (docs/ROADMAP.md M0).
# Runs QEMU in the foreground (start it in the background yourself).
#
#   VM_DIR=<dir with win11.qcow2 and win11-vars.fd> scripts/run-win11-ar.sh [QEMU args...]
#
# Environment:
#   USB4_REPO     checkout with vms/qemu-baseline and toolchain/ (default: this one)
#   VM_DIR        overlay directory (required): win11.qcow2, win11-vars.fd;
#                 nvme.qcow2 is created there (256 MiB) if missing
#   QEMU          qemu-system-x86_64.exe (default vms/qemu-baseline/...)
#   ACCEL         default "tcg,thread=multi" (WHPX only for base installs)
#   SMP, MEM      default 4, 4G
#   QMP_PORT, AGENT_PORT   default 47101, 47110 (127.0.0.1 only)
#   TOPOLOGY      bridge (default: NHI and tunnel port on pcie.0) or switch
#                 (the captured 15c0 switch below a root port, ICM-PROTOCOL.md 1)
#   HOST_OPTS     appended to usb4-host (e.g. ",security=none", ",preboot=on")
#   DEV_OPTS      appended to usb4-device (dialect=tb3, the TS3 Plus names)
#   NODEV=1       no device router at power-on
#   DSN           64-bit Device Serial Number for the NHI and switch ports
#                 (R29; default 0x5553423445ab0001, so Windows keeps its
#                 instance IDs and stored approvals across boots)
#   VIRTIO_ISO    a virtio-win ISO to attach as a CD (guest drivers only)
#   VGA           default "std". For Windows S3 use VGA=none and append
#                 "-device virtio-gpu-pci -global ICH9-LPC.disable_s3=0": the basic
#                 display adapter on -vga std disables S3 ("Graphics").
#   Dock (M7):    DEV_OPTS=",dock=on,usb-drive=usbdisk" plus
#                 -blockdev driver=qcow2,node-name=usbdisk,file.driver=file,file.filename=...
#   TRACE_FILE    -D target for the usb4 traces (default $VM_DIR/trace.log)
set -euo pipefail

REPO="${USB4_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"   # vms/, toolchain/
VM="${VM_DIR:?VM_DIR is required}"
BASE="$REPO/vms/qemu-baseline"
QEMU="${QEMU:-$BASE/qemu-system-x86_64.exe}"
SH="$BASE/share"
ACCEL="${ACCEL:-tcg,thread=multi}"
QMP_PORT="${QMP_PORT:-47101}"
AGENT_PORT="${AGENT_PORT:-47110}"
DSN="${DSN:-0x5553423445ab0001}"
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"
w() { cygpath -w "$1"; }

[ -f "$VM/win11.qcow2" ] || { echo "run-win11-ar: $VM/win11.qcow2 missing" >&2; exit 1; }
[ -f "$VM/win11-vars.fd" ] || { echo "run-win11-ar: $VM/win11-vars.fd missing" >&2; exit 1; }
[ -f "$VM/nvme.qcow2" ] || "$(dirname "$QEMU")/qemu-img.exe" create -q -f qcow2 \
    "$(w "$VM/nvme.qcow2")" 256M

TB=()
if [ "${TOPOLOGY:-bridge}" = switch ]; then
    # Root port standing for the PCH's (no DSN), then the 15c0 switch.
    TB=(-device "usb4-tunnel-port,id=tbrp,bus=pcie.0,addr=1c.0,chassis=1,slot=1,usb4-dvsec=off"
        -device "usb4-tb3-usp,id=tbusp,bus=tbrp,dsn-value=$DSN"
        -device "usb4-tb3-dsp,id=tbd0,bus=tbusp,addr=0.0,chassis=2,slot=0,dsn-value=$DSN"
        -device "usb4-tb3-tunnel-dsp,id=tp0,bus=tbusp,addr=1.0,chassis=3,slot=1,dsn-value=$DSN"
        -device "usb4-host,id=u4,bus=tbd0,addr=0.0,tunnel-port=tp0,profile=tb3-alpine-ridge,dsn-value=$DSN${HOST_OPTS:-}")
else
    TB=(-device "usb4-tunnel-port,id=tp0,bus=pcie.0,addr=5.0,chassis=1,slot=1"
        -device "usb4-host,id=u4,bus=pcie.0,addr=4.0,tunnel-port=tp0,profile=tb3-alpine-ridge,dsn-value=$DSN${HOST_OPTS:-}")
fi
TB+=(-drive "if=none,id=nvme0,format=qcow2,file=$(w "$VM/nvme.qcow2")")
[ "${NODEV:-0}" = 1 ] || TB+=(-device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,dialect=tb3,vendor-name=CalDigit,, Inc.,model-name=TS3 Plus${DEV_OPTS:-}")
CD=()
[ -n "${VIRTIO_ISO:-}" ] && CD=(-drive "if=none,id=vcd,media=cdrom,readonly=on,file=$(w "$VIRTIO_ISO")"
                                -device ide-cd,drive=vcd,bus=ide.1)

exec "$QEMU" -name win11-ar \
    -machine q35 -accel "$ACCEL" -cpu "${CPU:-max}" -smp "${SMP:-4}" -m "${MEM:-4G}" \
    -L "$(w "$SH")" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$(w "$SH/edk2-x86_64-code.fd")" \
    -drive "if=pflash,format=raw,unit=1,file=$(w "$VM/win11-vars.fd")" \
    -drive "if=none,id=sysdisk,format=qcow2,file=$(w "$VM/win11.qcow2")" \
    -device ide-hd,drive=sysdisk,bus=ide.0 "${CD[@]}" \
    -netdev "user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:$AGENT_PORT-:8000" \
    -device e1000e,netdev=net0,romfile= \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
    -display none -vga "${VGA:-std}" \
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off" \
    -serial "file:$(w "$VM/serial.log")" -pidfile "$(w "$VM/qemu.pid")" -rtc base=utc \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    "${TB[@]}" \
    -trace "usb4_icm*" -trace "usb4_tp_*" -trace "usb4_tunnel*" \
    -D "$(w "${TRACE_FILE:-$VM/trace.log}")" "$@"
