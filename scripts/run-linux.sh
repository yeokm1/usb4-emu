#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Boot an unmodified Kubuntu live ISO against the usb4-generic host (one
# USB4 port, tunnel port tp0, device router enc0 with an NVMe drive), with
# the guest console on a TCP serial port. See docs/LINUX-TEST.md.
#   scripts/run-linux.sh [extra qemu args]       (runs in the foreground)
# Env: ISO (default D:/isos/kubuntu-26.04.1-desktop-amd64.iso), BUILD_EXE,
# ACCEL (whpx), MEM (4G), QMP_PORT (47350), SERIAL_PORT (47351),
# NO_DEVICE=1 (start with the USB4 port empty), APPEND (extra kernel args),
# OVMF=1 (UEFI firmware instead of SeaBIOS; vars in vms/linux/ovmf-vars.fd),
# PROFILE (usb4-generic, or tb3-alpine-ridge / tb3-titan-ridge: Intel firmware
# CM profiles with a dialect=tb3 device router; tb3-titan-ridge is the 4C part
# with two Thunderbolt ports, each with its own tunnel port, tp0 and tp1, see
# docs/ICM-TITAN-RIDGE.md), DEVICE2=1 (tb3-titan-ridge: a second device router
# on port 2, NVMe vms/linux/nvme2.qcow2), HOST_OPTS (extra usb4-host
# properties, e.g. ",security=none,rtd3=on"), VM_DIR (default vms/linux, for
# parallel runs).
# HOST_MODEL=asm4242 (usb4-generic): the ASMedia ASM4242 preset of AM5 X870
# boards (docs/USB4-HOSTS.md 5, public sources only), two USB4 ports with
# tunnel ports tp0 and tp1; DEVICE2=1 adds a device router on port 2. With
# TOPOLOGY=switch (the default for it) the public AM5 layout: root port ->
# 1b21:2421 -> DSPs 0/1 tunnels, 2 xHCI 1b21:2426, 3 NHI 1b21:2425; the root
# port pads ASM_BUS_RESERVE buses (100) and ASM_MEM_RESERVE MMIO (64M); the
# tunnel DSPs carry the USB4 _DSD. TOPOLOGY=bridge puts the NHI, two tunnel
# root ports and the xHCI on pcie.0 instead, as for the other host models.
# DEVICE_MODEL=asm2464 (usb4-generic): the device routers are the captured
# ASMedia ASM2464PD of the ORICO AAGM2-U4 enclosure
# (docs/captures/ORICO-ASM2464.md); pair it with HOST_OPTS=,host-model=intel-adl
# to reproduce the captured Framework 13 + ORICO setup. On tb3-alpine-ridge
# (e.g. with BIOS=...) it is the ORICO behind the P14s's firmware CM
# (docs/captures/P14S-ORICO-2026-10-15.md): the device router is announced as
# a USB4 router and, if nobody approves it in time, falls back to USB on the
# TB xHCI. In BIOS mode it also gets the observed approve timing (link up
# 89 ms, response 383 ms) and power-off delay (11 s); OBSERVED=0 leaves them
# out.
# The kernel and initrd are extracted from the ISO's casper/ directory into
# vms/linux/boot; the ISO itself stays read-only as a CD-ROM.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_DIR:-$REPO/vms/linux}"
# BIOS=<Assist>_<PreBoot> (OFF_OFF, OFF_ON, ON_OFF, ON_ON): the P14s BIOS
# options on tb3-alpine-ridge (or PROFILE=tb3-titan-ridge) with the switch
# topology (as run-win98.sh); DEVICE_AT_BOOT=0 starts with nothing attached.
# The TB xHCI is always created (XHCI=0 leaves it out) and named to the host
# with xhci=tbxhci: the model hides it, or shows it without resources, under
# BIOS Assist as the P14s does (ICM-PROTOCOL.md 12.3, 13.1).
if [ -n "${BIOS:-}" ]; then
    case "${PROFILE:-}" in
        tb3-titan-ridge) ;;
        *) PROFILE=tb3-alpine-ridge ;;
    esac
    TOPOLOGY=switch
    case "$BIOS" in
        OFF_OFF|OFF_ON|ON_OFF|ON_ON) ;;
        *) echo "run-linux: BIOS must be OFF_OFF, OFF_ON, ON_OFF or ON_ON" >&2
           exit 1 ;;
    esac
    a=off; p=off
    [ "${BIOS%_*}" = ON ] && a=on
    [ "${BIOS#*_}" = ON ] && p=on
    X=
    [ "${XHCI:-1}" = 1 ] && X=",xhci=tbxhci"
    [ "${DEVICE_MODEL:-}" = asm2464 ] && [ "${OBSERVED:-1}" = 1 ] &&
        X="$X,approve-link-ms=89,approve-resp-ms=383,power-off-delay-usb4-ms=11000"
    HOST_OPTS=",bios-assist=$a,preboot=$p,boot-acl=203de24d-7c47-f446-ffff-ffffffffffff$X${HOST_OPTS:-}"
    [ "${DEVICE_AT_BOOT:-1}" = 0 ] && NO_DEVICE=1
fi
PROFILE="${PROFILE:-usb4-generic}"
DIALECT=
TR=0
case "$PROFILE" in
    tb3-alpine-ridge) DIALECT=",dialect=tb3" ;;
    tb3-titan-ridge) DIALECT=",dialect=tb3"; TR=1 ;;
esac
ISO="${ISO:-/d/isos/kubuntu-26.04.1-desktop-amd64.iso}"
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"
w() { cygpath -w "$1"; }
mkdir -p "$VM/bin" "$VM/boot"
cp "${BUILD_EXE:-$REPO/src/qemu/build/qemu-system-x86_64.exe}" "$VM/bin/"
if [ ! -f "$VM/boot/vmlinuz" ]; then
    (cd "$VM/boot" && 7z e -y "$(w "$ISO")" 'casper\vmlinuz' 'casper\initrd' >/dev/null)
fi
[ -f "$VM/nvme.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q \
    -f qcow2 "$(w "$VM/nvme.qcow2")" 2G
# the ASM2464 is a USB4 router, also behind a TB3 host
[ "${DEVICE_MODEL:-}" = asm2464 ] && DIALECT=",dialect=usb4"
[ -n "${DEVICE_MODEL:-}" ] && DIALECT="$DIALECT,device-model=$DEVICE_MODEL"
DEV=(-device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01$DIALECT")
[ "${NO_DEVICE:-0}" = 1 ] && DEV=()
if [ "$TR" = 1 ] && [ "${DEVICE2:-0}" = 1 ]; then
    [ -f "$VM/nvme2.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM/nvme2.qcow2")" 1G
    DEV+=(-drive "if=none,id=nvme1,format=qcow2,file=$(w "$VM/nvme2.qcow2")"
          -device "usb4-device,id=enc1,bus=u4.0,port=2,drive=nvme1,serial=USB4EMU02$DIALECT")
fi
# TOPOLOGY=bridge (default): tunnel root port and NHI on pcie.0.
# TOPOLOGY=switch (tb3 profiles only): the captured Alpine Ridge PCIe
# switch below a root port, DSPs for the NHI, the tunnel slot and the
# integrated xHCI 8086:15c1 (ICM-PROTOCOL.md 1); XHCI=0 leaves it out.
# tb3-titan-ridge: the same with the Titan Ridge 4C IDs (usb4-tr-*, 15ea,
# xHCI 15ec) and a second tunnel DSP at 4.0 for port 2 (inferred layout).
ASM=0
[ "${HOST_MODEL:-}" = asm4242 ] && ASM=1 && PROFILE=usb4-generic && DIALECT=
if [ "$ASM" = 1 ] && [ "${DEVICE2:-0}" = 1 ]; then
    [ -f "$VM/nvme2.qcow2" ] || "$REPO/vms/qemu-baseline/qemu-img.exe" create -q         -f qcow2 "$(w "$VM/nvme2.qcow2")" 1G
    DEV+=(-drive "if=none,id=nvme1,format=qcow2,file=$(w "$VM/nvme2.qcow2")"
          -device "usb4-device,id=enc1,bus=u4.0,port=2,drive=nvme1,serial=USB4EMU02${DEVICE_MODEL:+,device-model=$DEVICE_MODEL}")
fi
HOST="id=u4,tunnel-port=tp0,profile=$PROFILE${HOST_OPTS:-}"
[ "$TR" = 1 ] && HOST="id=u4,tunnel-port=tp0,tunnel-port2=tp1,profile=$PROFILE${HOST_OPTS:-}"
[ "$ASM" = 1 ] && HOST="id=u4,tunnel-port=tp0,tunnel-port2=tp1,profile=usb4-generic,host-model=asm4242${HOST_OPTS:-}"
SW=usb4-tb3
[ "$TR" = 1 ] && SW=usb4-tr
if [ "$ASM" = 1 ] && [ "${TOPOLOGY:-switch}" = switch ]; then
    TB=(-device "pcie-root-port,id=asmrp,bus=pcie.0,addr=3.0,chassis=1,slot=1,bus-reserve=${ASM_BUS_RESERVE:-100},mem-reserve=${ASM_MEM_RESERVE:-64M}"
        -device "usb4-asm-usp,id=asmusp,bus=asmrp"
        -device "usb4-asm-tunnel-dsp,id=tp0,bus=asmusp,addr=0.0,chassis=2,slot=0"
        -device "usb4-asm-tunnel-dsp,id=tp1,bus=asmusp,addr=1.0,chassis=3,slot=1,usb4-port=1"
        -device "usb4-asm-dsp,id=asmd2,bus=asmusp,addr=2.0,chassis=4,slot=2"
        -device "usb4-asm-dsp,id=asmd3,bus=asmusp,addr=3.0,chassis=5,slot=3"
        -device "usb4-asm-xhci,id=asmxhci,bus=asmd2,addr=0.0,p2=2,p3=2"
        -device "usb4-host,bus=asmd3,addr=0.0,$HOST")
elif [ "$ASM" = 1 ]; then
    TB=(-device "usb4-tunnel-port,id=tp0,bus=pcie.0,addr=5.0,chassis=1,slot=1"
        -device "usb4-tunnel-port,id=tp1,bus=pcie.0,addr=6.0,chassis=2,slot=2,usb4-port=1"
        -device "usb4-asm-xhci,id=asmxhci,bus=pcie.0,addr=7.0,p2=2,p3=2"
        -device "usb4-host,bus=pcie.0,addr=4.0,$HOST")
elif [ "${TOPOLOGY:-bridge}" = switch ]; then
    # The root port is a gated usb4-tunnel-port: the power domain that
    # BIOS Assist turns off when nothing is attached (R27).
    TB=(-device "usb4-tunnel-port,id=tbrp,bus=pcie.0,addr=1c.0,chassis=1,slot=1,usb4-dvsec=off"
        -device "$SW-usp,id=tbusp,bus=tbrp"
        -device "$SW-dsp,id=tbd0,bus=tbusp,addr=0.0,chassis=2,slot=0"
        -device "$SW-tunnel-dsp,id=tp0,bus=tbusp,addr=1.0,chassis=3,slot=1"
        -device "$SW-dsp,id=tbd2,bus=tbusp,addr=2.0,chassis=4,slot=2")
    [ "$TR" = 1 ] && TB+=(-device "$SW-tunnel-dsp,id=tp1,bus=tbusp,addr=4.0,chassis=5,slot=4")
    TB+=(-device "usb4-host,bus=tbd0,addr=0.0,$HOST")
    [ "${XHCI:-1}" = 1 ] && TB+=(-device "$SW-xhci,id=tbxhci,bus=tbd2,addr=0.0")
else
    TB=(-device "usb4-tunnel-port,id=tp0,bus=pcie.0,addr=5.0,chassis=1,slot=1")
    [ "$TR" = 1 ] && TB+=(-device "usb4-tunnel-port,id=tp1,bus=pcie.0,addr=6.0,chassis=2,slot=2")
    TB+=(-device "usb4-host,bus=pcie.0,addr=4.0,$HOST")
fi
FW=()
if [ "${OVMF:-0}" = 1 ]; then
    SHARE="$REPO/vms/qemu-baseline/share"
    [ -f "$VM/ovmf-vars.fd" ] || cp "$SHARE/edk2-i386-vars.fd" "$VM/ovmf-vars.fd"
    FW=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$(w "$SHARE/edk2-x86_64-code.fd")"
        -drive "if=pflash,format=raw,unit=1,file=$(w "$VM/ovmf-vars.fd")")
fi
exec "$VM/bin/qemu-system-x86_64.exe" -name linux-usb4 \
    -machine q35 -accel "${ACCEL:-whpx}" -cpu max -smp 4 -m "${MEM:-4G}" \
    -L "$(w "$REPO/vms/qemu-baseline/share")" "${FW[@]}" \
    -kernel "$(w "$VM/boot/vmlinuz")" -initrd "$(w "$VM/boot/initrd")" \
    -append "boot=casper console=tty0 console=ttyS0,115200 systemd.unit=multi-user.target thunderbolt.dyndbg=+p ${APPEND:-}" \
    -drive "if=none,id=cd0,media=cdrom,readonly=on,file=$(w "$ISO")" \
    -device ide-cd,drive=cd0,bus=ide.0 \
    -display none -vga std -pidfile "$(w "$VM/qemu.pid")" \
    -qmp "tcp:127.0.0.1:${QMP_PORT:-47350},server=on,wait=off" \
    -serial "tcp:127.0.0.1:${SERIAL_PORT:-47351},server=on,wait=off" \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    "${TB[@]}" \
    -drive "if=none,id=nvme0,format=qcow2,file=$(w "$VM/nvme.qcow2")" \
    "${DEV[@]}" \
    -trace "usb4_*" -D "$(w "$VM/usb4-trace.log")" "$@"
