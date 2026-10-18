#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# Create vms/win11 and start a fully unattended Windows 11 install.
#
#   ISO=D:/isos/Windows11_....iso scripts/win11-install.sh
#
# Creates win11.qcow2 (80G) and win11-vars.fd, builds the answer-file stick
# (vms/win11/media, exposed read-only to the guest as a vvfat USB disk) and
# boots run-win11.sh with the ISO attached, pressing Enter at the
# "Press any key to boot from CD" prompt. Progress: scripts/qmp.py screendump.
# When the guest agent answers (scripts/guest.py wait) setup is done.
# Set FORCE=1 to wipe an existing VM.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="$REPO/vms/win11"
BASE="$REPO/vms/qemu-baseline"
ISO="${ISO:-D:/isos/Windows11_Client_x64_en-us_26300_9457.iso}"
GUEST_USER="${GUEST_USER:-usb4}"
GUEST_PASSWORD="${GUEST_PASSWORD:-usb4}"
export PATH="$REPO/toolchain/msys64/ucrt64/bin:$PATH"

mkdir -p "$VM"
if [ -f "$VM/win11.qcow2" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "win11-install: $VM/win11.qcow2 exists; set FORCE=1 to recreate" >&2
    exit 1
fi
rm -f "$VM/win11.qcow2"
"$BASE/qemu-img.exe" create -f qcow2 "$(cygpath -w "$VM/win11.qcow2")" 80G
cp "$BASE/share/edk2-i386-vars.fd" "$VM/win11-vars.fd"

[ -f "$VM/agent-token" ] || python -c "import secrets;print(secrets.token_hex(16))" > "$VM/agent-token"

MEDIA="$VM/media"
rm -rf "$MEDIA"
mkdir -p "$MEDIA/usb4"
sed -e "s/@USER@/$GUEST_USER/g" -e "s/@PASSWORD@/$GUEST_PASSWORD/g" \
    "$REPO/scripts/win11/autounattend.xml.in" > "$MEDIA/autounattend.xml"
cp "$REPO/scripts/win11/setup.ps1" "$REPO/scripts/win11/agent.ps1" "$MEDIA/usb4/"
cp "$REPO/scripts/guest-usb4-trace.ps1" "$MEDIA/usb4/" 2>/dev/null || true
tr -d '\r\n' < "$VM/agent-token" > "$MEDIA/usb4/token.txt"
echo 8000 > "$MEDIA/usb4/agent-port.txt"

"$REPO/scripts/run-win11.sh" \
    -drive "if=none,id=instcd,media=cdrom,readonly=on,file=$(cygpath -w "$ISO")" \
    -device ide-cd,drive=instcd,bus=ide.1 \
    -drive "if=none,id=ustick,format=raw,readonly=on,file=fat:ro:$(cygpath -w "$MEDIA")" \
    -device usb-storage,drive=ustick,bus=xhci.0,removable=on \
    "$@"

# Answer the CD boot prompt.
python "$REPO/scripts/qmp.py" spamkey ret 12
echo "win11-install: install running. Watch: python scripts/qmp.py screendump x.png;" \
     "done when: python scripts/guest.py wait"
