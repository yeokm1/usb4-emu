#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
# Start the experiment's Windows 2000 SP4 overlay (vms/win2k-reenum, over
# vms/win2k/win2k-xonly.qcow2) on i440FX with the usb4 generic profile and
# the SHPC tunnel bridge.  Machine flags follow the xhci98 project's
# Windows 2000 xHCI-only VM (pc,acpi=off, pentium3,-apic: Standard PC HAL).
# QMP 47810, VNC 127.0.0.1:47811.  The guest keyboard is US-Dvorak
# (typekeys.py --dvorak).
#   tools/reenum-test/run2k.sh <tag>        TOPO=ar for the Alpine Ridge tree
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
V="$REPO/vms/win2k-reenum"
tag="${1:-run}"
w() { cygpath -w "$1"; }
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"
args=(
  -name w2k-reenum -machine pc,acpi=off -accel tcg -cpu pentium3,-apic -m 256
  -L "$(w "$REPO/vms/qemu-baseline/share")"
  -display none -vga cirrus -vnc 127.0.0.1:$((47811 - 5900))
  -qmp tcp:127.0.0.1:47810,server=on,wait=off
  -pidfile "$(w "$V/qemu.pid")" -rtc base=localtime -net none
  -drive "if=ide,index=0,format=qcow2,file=$(w "$V/w2k.qcow2")"
  -drive "if=ide,index=1,format=raw,file=$(w "$V/xfer.img")"
  -global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
  -drive "if=none,id=nvme0,format=qcow2,file=$(w "$V/nvme.qcow2")"
  -debugcon "file:$(w "$V/debugcon-$tag.log")"
  -trace 'usb4_tp*' -trace 'usb4_tb*' -trace 'shpc*' -trace 'pci_nvme_*'
  -D "$(w "$V/trace-$tag.log")"
)
if [ "${TOPO:-}" = ar ]; then
  host="usb4-host,id=u4,bus=tbd0,addr=0x0,tunnel-port=tb0,msi=off,msix=off"
  host="$host,profile=tb3-alpine-ridge"
  args+=(
  -device "usb4-tunnel-bridge,id=tbrp,bus=pci.0,addr=0x1c,chassis_nr=1,msi=off"
  -device "usb4-tb3-pci-bridge,id=tbusp,bus=tbrp,addr=0x1,chassis_nr=2,shpc=off,msi=off"
  -device "usb4-tb3-pci-bridge,id=tbd0,bus=tbusp,addr=0x0,chassis_nr=3,shpc=off,msi=off"
  -device "usb4-tb3-tunnel-bridge,id=tb0,bus=tbusp,addr=0x1,chassis_nr=4,shpc-autoenable=on,msi=off"
  -device "usb4-tb3-pci-bridge,id=tbd2,bus=tbusp,addr=0x2,chassis_nr=5,shpc=off,msi=off"
  -device "$host"
  -device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01,dialect=tb3")
else
  args+=(
  -device "usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1,shpc-autoenable=on,msi=off"
  -device "usb4-host,id=u4,bus=pci.0,addr=0x4,tunnel-port=tb0,msi=off,msix=off"
  -device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01")
fi
echo "${QEMU:-$V/bin/qemu-system-x86_64.exe} ${args[*]}" > "$V/qemu.cmdline"
nohup "${QEMU:-$V/bin/qemu-system-x86_64.exe}" "${args[@]}" > "$V/qemu-$tag.out" 2>&1 < /dev/null &
disown
sleep 3
echo "started PID $(cat "$V/qemu.pid" 2>/dev/null)"
