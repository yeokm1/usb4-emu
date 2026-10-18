#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Boot the Windows 98 SE legacy test VM (vms/win98) headless in the
# background on the i440FX machine, with the USB4 host and the i440FX
# tunnel bridge attached. See docs/WIN98-TEST.md.
#
#   scripts/run-win98.sh [extra QEMU args...]
#
# Extra arguments are appended to the QEMU command line, e.g.
#   scripts/run-win98.sh -trace 'usb4_*' -D vms/win98/usb4-trace.log
#
# Environment:
#   QEMU          default vms/win98/bin/qemu-system-x86_64.exe
#   QEMU_DATADIR  -L dir (default vms/qemu-baseline/share)
#   ACCEL         default "tcg". whpx aborts ("WHPX: failed to unmap GPA
#                 range") once any PCI-PCI bridge is present; see WIN98-TEST.md
#   CPU           default "pentium3,-apic" (with a local APIC, a guest
#                 restart under TCG hangs at the boot logo; see WIN98-TEST.md)
#   MEM           default 512 (MiB; Windows 98 needs <= 512)
#   VGA           default "cirrus-vga"
#   USB4          "1" (default) attach usb4-host + usb4-tunnel-bridge + usb4-device
#   PROFILE       usb4-host profile (default: none, i.e. usb4-generic;
#                 tb3-titan-ridge also makes the device router dialect=tb3).
#                 With BIOS, tb3-titan-ridge selects the
#                 Titan Ridge 4C switch (usb4-tr-*, 8086:15ea, xHCI 15ec) and
#                 a second tunnel bridge tb1 for Thunderbolt port 2
#                 (docs/ICM-TITAN-RIDGE.md); default tb3-alpine-ridge
#   FORCE_TUNNEL  "1": x-force-tunnel=on (endpoint cold-plugged at power-on)
#   NVME          disk behind the tunnel (default vms/win98/nvme32.qcow2)
#   TUNNEL_UP_AFTER  seconds: bring the tunnel up with QMP qom-set this long
#                 after start, i.e. after SeaBIOS POST but before Windows
#                 enumerates PCI. Then press Refresh in Device Manager
#                 (nvme2k drives the NVMe).
#                 With FORCE_TUNNEL, a pre-boot tunnel (BIOS=*_ON) or
#                 USB_FALLBACK=bot, SeaBIOS serves the disk through INT 13h
#                 at POST. QEMU builds without the usb4-posthang SMM TLB
#                 fix then hang at the Windows 98 logo. This knob avoids
#                 that only when none of those is set; it cannot help with
#                 BIOS=OFF_ON (docs/WIN98-TEST.md, "SMM hang at the boot
#                 logo"). Passing -machine smm=off also avoids the hang,
#                 but Windows can then no longer reach a disk that only
#                 SeaBIOS serves.
#   AUTOENABLE    shpc-autoenable value (default "on")
#   INSTALL_IMG   if set, attach this raw image as the first IDE disk and boot
#                 from it (QuickInstall); win98.qcow2 becomes the second disk
#   BIOS          OFF_OFF | OFF_ON | ON_OFF | ON_ON: P14s "Thunderbolt BIOS
#                 Assist" _ "Support in Pre Boot Environment" on the
#                 tb3-alpine-ridge profile with the captured switch topology
#                 (root bridge, 15c0 switch, NHI, tunnel bridge, xHCI 15c1),
#                 or on tb3-titan-ridge (PROFILE above)
#   DEVICE_AT_BOOT  with BIOS: "1" (default) device router attached at
#                 power-on, "0" nothing attached
#   DEVICE_MODEL  with BIOS: "asm2464" attaches the ORICO's USB4 device router
#                 (ASMedia ASM2464PD) instead of the TB3 dock-style router: it
#                 falls back to USB on the TB xHCI when not approved
#                 (docs/captures/P14S-ORICO-2026-10-15.md). The xHCI is always
#                 created; the model hides it, or shows it without resources,
#                 under Assist as the P14s does (XHCI=0 leaves it out)
#   USB_FALLBACK  with BIOS: usb4-host usb-fallback, the ORICO's USB side:
#                 uas (QEMU default, as captured; xhci98's xhciuas.sys) or
#                 bot (Bulk-Only, for a guest without the UAS driver)
#   ROOT_ADDR     with BIOS: bus 0 slot of the root bridge (default 0x6).
#                 SeaBIOS's $PIR lists only bus 0 slots 1-6, and Windows 98
#                 routes a function hot-added behind the bridges by swizzling
#                 up to a $PIR slot; at an unlisted slot such as 0x1c (the
#                 P14s root port's number) a tunnel brought up after POST
#                 gets Code 29, no IRQ. See docs/WIN98-TEST.md.
#   HOTPLUG       with BIOS: root-hotplug of the root bridge tbrp, none
#                 (default) | restore | acpi: what the guest is told when
#                 the controller tree leaves (qom-set tbrp present false,
#                 or the Assist power-off) and comes back. Needs QEMU
#                 usb4-emu 25fd4eb or later; see docs/XHCI98-HANDOFF.md 6d.
#                 Windows 98 SE in APM mode (this image): restore.
#   REMOVAL_NOTIFY_MS  with HOTPLUG=acpi: power-off to removal notification
#                 (QEMU default 4400)
#   POWER_OFF_MS  with BIOS: usb4-host power-off-delay-ms (Assist: last
#                 device gone to power-off; QEMU default 35000, the ORICO
#                 run on the P14s about 11000)
#   VM_DIR        default vms/win98
#   QMP_PORT, VNC_PORT   default 47400, 47401 (127.0.0.1 only)
#
# Writes vms/win98/qemu.pid, ports.env, qemu.log, qemu.cmdline.
# Stop with scripts/stop-win98.sh. QMP: VM_DIR=vms/win98 python scripts/qmp.py ...
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM_DIR:-$REPO/vms/win98}"
QEMU="${QEMU:-$VM/bin/qemu-system-x86_64.exe}"
QEMU_DATADIR="${QEMU_DATADIR:-$REPO/vms/qemu-baseline/share}"
DISK="$VM/win98.qcow2"
NVME="${NVME:-$VM/nvme32.qcow2}"
ACCEL="${ACCEL:-tcg}"
MEM="${MEM:-512}"
CPU="${CPU:-pentium3,-apic}"
VGA="${VGA:-cirrus-vga}"
USB4="${USB4:-1}"
PROFILE="${PROFILE:-}"
FORCE_TUNNEL="${FORCE_TUNNEL:-0}"
AUTOENABLE="${AUTOENABLE:-on}"
QMP_PORT="${QMP_PORT:-47400}"
VNC_PORT="${VNC_PORT:-47401}"
PIDFILE="$VM/qemu.pid"

export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"

winpid_alive() {
    tasklist //FI "PID eq $1" //FO CSV //NH 2>/dev/null | grep -qi 'qemu-system'
}

if [ -f "$PIDFILE" ]; then
    oldpid="$(tr -dc '0-9' < "$PIDFILE")"
    if [ -n "$oldpid" ] && winpid_alive "$oldpid"; then
        echo "run-win98: VM already running (PID $oldpid, $PIDFILE)" >&2
        exit 1
    fi
    rm -f "$PIDFILE"
fi
[ -f "$DISK" ] || { echo "run-win98: $DISK missing" >&2; exit 1; }

w() { cygpath -w "$1"; }

cat > "$VM/ports.env" <<EOF
QMP_PORT=$QMP_PORT
VNC_PORT=$VNC_PORT
EOF

args=(
    -name win98-usb4
    -machine pc -accel "$ACCEL" -cpu "$CPU" -smp 1 -m "$MEM"
    -L "$(w "$QEMU_DATADIR")"
    -display none -vga none -device "$VGA"
    -vnc "127.0.0.1:$((VNC_PORT - 5900))"
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off"
    -pidfile "$(w "$PIDFILE")"
    -rtc base=localtime
    -nic none
)
if [ -n "${INSTALL_IMG:-}" ]; then
    args+=(
        -drive "if=ide,index=0,format=raw,file=$(w "$INSTALL_IMG")"
        -drive "if=ide,index=1,format=qcow2,file=$(w "$DISK")"
        -boot c
    )
else
    args+=(-drive "if=ide,index=0,format=qcow2,file=$(w "$DISK")")
fi
args+=(-drive "if=ide,index=2,media=cdrom")

if [ "$USB4" = "1" ] && [ -n "${BIOS:-}" ]; then
    # P14s BIOS emulation (tb3-alpine-ridge, captured switch topology):
    # BIOS=<Assist>_<PreBoot>, each ON or OFF, as the capture folders in
    # tests/captures/p14s-gen1/win98/. Assist hides the xHCI 15c1 (the
    # model, via xhci=; shown without resources after a USB fallback) and,
    # with nothing attached, powers the controller down (R27, R30);
    # pre-boot tunnels the boot-ACL device before POST (R25).
    [ -f "$NVME" ] || { echo "run-win98: $NVME missing" >&2; exit 1; }
    case "$BIOS" in
        OFF_OFF|OFF_ON|ON_OFF|ON_ON) ;;
        *) echo "run-win98: BIOS must be OFF_OFF, OFF_ON, ON_OFF or ON_ON" >&2
           exit 1 ;;
    esac
    assist=off; preboot=off
    [ "${BIOS%_*}" = ON ] && assist=on
    [ "${BIOS#*_}" = ON ] && preboot=on
    sw=usb4-tb3; prof=tb3-alpine-ridge
    [ "$PROFILE" = tb3-titan-ridge ] && sw=usb4-tr && prof=tb3-titan-ridge
    host="usb4-host,id=u4,bus=tbd0,addr=0x0,tunnel-port=tb0,msi=off,msix=off"
    [ "$sw" = usb4-tr ] && host="$host,tunnel-port2=tb1"
    host="$host,profile=$prof,bios-assist=$assist,preboot=$preboot"
    # enc0's UUID (serial USB4EMU01 on port 1) is in the boot ACL
    host="$host,boot-acl=203de24d-7c47-f446-ffff-ffffffffffff"
    [ "${XHCI:-1}" = 1 ] && host="$host,xhci=tbxhci"
    [ -n "${USB_FALLBACK:-}" ] && host="$host,usb-fallback=$USB_FALLBACK"
    [ -n "${POWER_OFF_MS:-}" ] && host="$host,power-off-delay-ms=$POWER_OFF_MS"
    # The tree leaving and coming back (QEMU usb4-emu 25fd4eb, ARCHITECTURE.md 4.4a)
    rp="usb4-tunnel-bridge,id=tbrp,bus=pci.0,addr=${ROOT_ADDR:-0x6},chassis_nr=1,msi=off"
    [ -n "${HOTPLUG:-}" ] && rp="$rp,root-hotplug=$HOTPLUG"
    [ -n "${REMOVAL_NOTIFY_MS:-}" ] && rp="$rp,removal-notify-ms=$REMOVAL_NOTIFY_MS"
    devm=",dialect=tb3"
    [ "${DEVICE_MODEL:-}" = asm2464 ] && devm=",dialect=usb4,device-model=asm2464"
    args+=(
        -global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
        -drive "if=none,id=nvme0,format=qcow2,file=$(w "$NVME")"
        -device "$rp"
        -device "$sw-pci-bridge,id=tbusp,bus=tbrp,addr=0x1,chassis_nr=2,shpc=off,msi=off"
        -device "$sw-pci-bridge,id=tbd0,bus=tbusp,addr=0x0,chassis_nr=3,shpc=off,msi=off"
        -device "$sw-tunnel-bridge,id=tb0,bus=tbusp,addr=0x1,chassis_nr=4,shpc-autoenable=$AUTOENABLE,msi=off"
        -device "$sw-pci-bridge,id=tbd2,bus=tbusp,addr=0x2,chassis_nr=5,shpc=off,msi=off"
    )
    [ "$sw" = usb4-tr ] && args+=(
        -device "$sw-tunnel-bridge,id=tb1,bus=tbusp,addr=0x4,chassis_nr=6,shpc-autoenable=$AUTOENABLE,msi=off")
    args+=(-device "$host")
    [ "${XHCI:-1}" = 1 ] && args+=(-device "$sw-xhci,id=tbxhci,bus=tbd2,addr=0x0,msi=off,msix=off")
    [ "${DEVICE_AT_BOOT:-1}" = 1 ] && args+=(
        -device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01$devm")
elif [ "$USB4" = "1" ]; then
    [ -f "$NVME" ] || { echo "run-win98: $NVME missing" >&2; exit 1; }
    tb="usb4-tunnel-bridge,id=tb0,bus=pci.0,addr=0x5,chassis_nr=1"
    tb="$tb,shpc-autoenable=$AUTOENABLE,msi=off"
    [ "$FORCE_TUNNEL" = "1" ] && tb="$tb,x-force-tunnel=on,nvme-drive=nvme0,nvme-serial=USB4EMU01"
    host="usb4-host,id=u4,bus=pci.0,addr=0x4,tunnel-port=tb0,msi=off,msix=off"
    [ -n "$PROFILE" ] && host="$host,profile=$PROFILE"
    dialect=
    # tb3-titan-ridge: a TB3 device router (tb3-alpine-ridge keeps its
    # historical usb4-dialect router here; BIOS mode uses dialect=tb3)
    [ "$PROFILE" = tb3-titan-ridge ] && dialect=",dialect=tb3"
    args+=(
        -global PIIX4_PM.acpi-pci-hotplug-with-bridge-support=off
        -drive "if=none,id=nvme0,format=qcow2,file=$(w "$NVME")"
        -device "$tb"
        -device "$host"
        -device "usb4-device,id=enc0,bus=u4.0,port=1,drive=nvme0,serial=USB4EMU01$dialect"
    )
fi

echo "$QEMU ${args[*]} $*" > "$VM/qemu.cmdline"
nohup "$QEMU" "${args[@]}" "$@" > "$VM/qemu.log" 2>&1 < /dev/null &
disown

for _ in $(seq 1 40); do
    if [ -s "$PIDFILE" ]; then
        pid="$(tr -dc '0-9' < "$PIDFILE")"
        if winpid_alive "$pid"; then
            if [ -n "${TUNNEL_UP_AFTER:-}" ]; then
                (sleep "$TUNNEL_UP_AFTER"; VM_DIR="$VM" python "$(w "$REPO/scripts/qmp.py")"                     --port "$QMP_PORT" cmd qom-set                     '{"path":"/machine/peripheral/tb0","property":"tunnel","value":"up"}'                     > "$VM/tunnel-up.log" 2>&1) < /dev/null &
                disown
            fi
            echo "run-win98: started PID $pid (QMP $QMP_PORT, VNC 127.0.0.1:$VNC_PORT)"
            exit 0
        fi
    fi
    sleep 0.5
done
echo "run-win98: QEMU did not start; see $VM/qemu.log:" >&2
cat "$VM/qemu.log" >&2
exit 1
