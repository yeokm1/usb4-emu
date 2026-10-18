#!/bin/sh
# Configure (first time) and build a QEMU tree. Default tree: src/qemu.
# Usage (from Git Bash):
#   scripts/msys2-shell.sh "/d/.../src/build-qemu.sh [tree-dir] [extra ninja targets]"
# Run through scripts/msys2-shell.sh so the UCRT64 toolchain is used.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
tree="${1:-$here/qemu}"
[ $# -gt 0 ] && shift
cd "$tree"
if [ ! -f build/build.ninja ]; then
  ./configure --target-list=x86_64-softmmu --disable-docs --disable-werror \
    --enable-slirp --enable-whpx --enable-sdl --disable-gtk \
    --prefix="$(pwd)/build/install"
fi
ninja -C build -j "${JOBS:-8}" qemu-system-x86_64.exe qemu-img.exe "$@"
