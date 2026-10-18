#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Boot a Windows 11 overlay VM (default vms/win11-cm) with the usb4-generic
# host, a tunnel port and one device router carrying an NVMe drive.
# Uses a copy of the freshly built QEMU so rebuilding is not blocked.
#   scripts/run-cm-test.sh [extra qemu args]
# Trace: vms/<vm>/usb4-trace.log
# Env: VM_NAME (overlay dir under vms/, default win11-cm), BUILD_EXE (QEMU to
# copy, default src/qemu/build), QMP_PORT/VNC_PORT/SUP_QMP_PORT/AGENT_PORT,
# IOMMU=1 (adds intel-iommu; needs NO_TUNNEL=1), NO_TUNNEL=1, NO_DEVICE=1,
# PORT2=0 (no second tunnel port / device router), NO_DEVICE2=1 (port 2 empty),
# DOCK=1 (port 1 device router is a dock: switch + NVMe + NIC + xHCI/USB disk),
# USB3=1 (USB disk behind the port 1 device router over a USB3 tunnel),
# CHAIN=1 (port 1: enc0 with a downstream port and enc2 daisy-chained below it),
# PROFILE (default usb4-generic; tb3-alpine-ridge or tb3-titan-ridge give the
# Intel firmware-CM host with dialect=tb3 device routers, for the Intel
# Thunderbolt driver package; tb3-alpine-ridge has one port, so PORT2 defaults
# to 0 there; DOCK, CHAIN and USB3 are usb4-generic only).
# The guest must have test-signing enabled (bcdedit /set testsigning on):
# Windows' USB4 host router driver refuses host routers it has not been
# validated with unless test-signing is on (see docs/WINDOWS-DEBUG.md).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${VM_NAME:-win11-cm}"
export VM_DIR="$REPO/vms/$NAME"
"$REPO/scripts/win11-overlay.sh" "$NAME" >/dev/null
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"
BIN="$VM_DIR/bin"
mkdir -p "$BIN"
cp "${BUILD_EXE:-$REPO/src/qemu/build/qemu-system-x86_64.exe}" "$BIN/"
[ -f "$VM_DIR/nvme.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q \
    -f qcow2 "$(cygpath -w "$VM_DIR/nvme.qcow2")" 4G
export QEMU="$BIN/qemu-system-x86_64.exe"
export QEMU_DATADIR="$REPO/vms/qemu-baseline/share"
export QMP_PORT="${QMP_PORT:-47301}" VNC_PORT="${VNC_PORT:-47302}"
export SUP_QMP_PORT="${SUP_QMP_PORT:-47303}" AGENT_PORT="${AGENT_PORT:-47310}"
w() { cygpath -w "$1"; }
DEV=(
    ${IOMMU:+-device intel-iommu,intremap=off}
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
)
PROFILE="${PROFILE:-}"
HP=""
DL=""
case "$PROFILE" in
    "") ;;
    tb3-alpine-ridge) HP=",profile=$PROFILE"; DL=",dialect=tb3"; PORT2="${PORT2:-0}" ;;
    tb3-titan-ridge) HP=",profile=$PROFILE"; DL=",dialect=tb3" ;;
    *) HP=",profile=$PROFILE" ;;
esac
PORT2="${PORT2:-1}"
if [ "${NO_TUNNEL:-0}" != 1 ]; then
    DEV+=(-device "usb4-tunnel-port,id=tp0,bus=pcie.0,addr=5.0,chassis=1,slot=1")
    if [ "$PORT2" = 1 ]; then
        # USB4 port 2 gets its own tunnel root port.
        DEV+=(-device "usb4-tunnel-port,id=tp1,bus=pcie.0,addr=6.0,chassis=2,slot=2,usb4-port=1")
        DEV+=(-device "usb4-host,id=u4,bus=pcie.0,addr=4.0,tunnel-port=tp0,tunnel-port2=tp1$HP")
    else
        DEV+=(-device "usb4-host,id=u4,bus=pcie.0,addr=4.0,tunnel-port=tp0$HP")
    fi
else
    DEV+=(-device "usb4-host,id=u4,bus=pcie.0,addr=4.0$HP")
fi
DEV+=(
    -drive "if=none,id=nvme0,format=qcow2,file=$(w "$VM_DIR/nvme.qcow2")"
)
ENC0_EXTRA=""
if [ "${USB3:-0}" = 1 ]; then
    # USB3 tunnel: a USB disk on a dedicated xHCI port that is only attached
    # while the CM has a USB3 tunnel up to the port 1 device router.
    [ -f "$VM_DIR/ustor.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM_DIR/ustor.qcow2")" 256M
    DEV+=(-device "qemu-xhci,id=u4x,bus=pcie.0,addr=7.0")
    DEV+=(-drive "if=none,id=ustor,format=qcow2,file=$(w "$VM_DIR/ustor.qcow2")")
    DEV+=(-device "usb-storage,id=ustor0,bus=u4x.0,port=1,drive=ustor,serial=USB3EMU01")
    DEV+=(-global usb4-host.usb3-xhci=u4x -global usb4-host.usb3-port1=1)
    ENC0_EXTRA=",usb3-dev=ustor0"
fi
if [ "${NO_DEVICE:-0}" = 1 ]; then
    :
elif [ "${CHAIN:-0}" = 1 ]; then
    # Daisy chain on port 1: enc0 has one downstream USB4 port, enc2 hangs off it.
    [ -f "$VM_DIR/nvme3.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM_DIR/nvme3.qcow2")" 1G
    DEV+=(-device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,downstream-ports=1$ENC0_EXTRA")
    DEV+=(-drive "if=none,id=nvme3,format=qcow2,file=$(w "$VM_DIR/nvme3.qcow2")")
    DEV+=(-device "usb4-device,id=enc2,bus=u4.0,parent=enc0,port=1,drive=nvme3,serial=USB4EMU03")
elif [ "${DOCK:-0}" = 1 ]; then
    # Dock on port 1: PCIe switch with NVMe, e1000e and qemu-xhci + usb-storage.
    # usb-drive must be a -blockdev node (a -drive is auto-deleted on unplug).
    [ -f "$VM_DIR/usbdisk.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM_DIR/usbdisk.qcow2")" 256M
    DEV+=(-blockdev "driver=qcow2,node-name=usbdisk,file.driver=file,file.filename=$(w "$VM_DIR/usbdisk.qcow2")")
    DEV+=(-netdev "user,id=docknet,restrict=on")
    DEV+=(-device "usb4-device,id=enc0,bus=u4.0,port=1,dock=on,drive=nvme0,serial=USB4EMU01,nic-netdev=docknet,usb-drive=usbdisk$ENC0_EXTRA")
else
    DEV+=(-device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01$DL$ENC0_EXTRA")
fi
if [ "$PORT2" = 1 ] && [ "${NO_TUNNEL:-0}" != 1 ]; then
    [ -f "$VM_DIR/nvme2.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM_DIR/nvme2.qcow2")" 2G
    DEV+=(-drive "if=none,id=nvme1,format=qcow2,file=$(w "$VM_DIR/nvme2.qcow2")")
    if [ "${NO_DEVICE2:-0}" != 1 ]; then
        DEV+=(-device "usb4-device,id=enc1,bus=u4.0,port=2,drive=nvme1,serial=USB4EMU02$DL")
    fi
fi
exec "$REPO/scripts/run-win11.sh" "${DEV[@]}" \
    -trace "usb4_*" -D "$(w "$VM_DIR/usb4-trace.log")" "$@"
