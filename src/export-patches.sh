#!/bin/sh
# Export the usb4-emu branch of src/qemu as src/patches/.
# The branch history contains merges of parallel work, which
# format-patch cannot represent, so the series is exported as one
# cumulative diff against the pinned tag (binary-safe, full index).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
TAG=v11.1.2
rm -f "$here"/patches/*.patch
out="$here/patches/0001-usb4-emu.patch"
{
  echo "usb4-emu QEMU changes against $TAG"
  echo "Exported from branch usb4-emu at $(git -C "$here/qemu" rev-parse --short usb4-emu)"
  echo
  git -C "$here/qemu" log --no-merges --format='  %h %s' "$TAG..usb4-emu"
  echo "---"
  git -C "$here/qemu" diff --binary --full-index "$TAG" usb4-emu
} > "$out"
ls -la "$out"
