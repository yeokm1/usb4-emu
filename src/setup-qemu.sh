#!/bin/sh
# Recreate src/qemu: clone the pinned upstream tag and apply src/patches.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
TAG=v11.1.2
[ -d "$here/qemu/.git" ] && { echo "src/qemu already exists" >&2; exit 1; }
git clone --depth 1 --branch "$TAG" https://gitlab.com/qemu-project/qemu.git "$here/qemu"
cd "$here/qemu"
git config core.autocrlf false
git checkout -b usb4-emu
git apply --index "$here"/patches/0001-usb4-emu.patch
git -c user.name=usb4-emu -c user.email=usb4-emu@localhost commit -q -m "usb4-emu changes (from src/patches)"
