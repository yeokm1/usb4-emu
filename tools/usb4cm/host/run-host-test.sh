#!/bin/sh
# Build the usb4cm core strictly as C89 and run it against the usb4-emu
# fabric model with the MSYS2 UCRT64 gcc and glib:
#   scripts/msys2-shell.sh "/d/.../tools/usb4cm/host/run-host-test.sh"
# Copyright (c) 2026 usb4-emu contributors. SPDX-License-Identifier: GPL-2.0-only
set -e
here="$(cd "$(dirname "$0")" && pwd)"
core="$here/../core"
qemu="${QEMU_SRC:-$here/../../../src/qemu}"
out="${OUT:-$here/build}"
mkdir -p "$out/trace"

# The core must stay plain C89 (MSVC 6.0, Open Watcom): check it here.
for f in u4hi u4cm; do
    gcc -std=c89 -pedantic -Wall -Wextra -Werror -Wdeclaration-after-statement \
        -O1 -c "$core/$f.c" -o "$out/$f.o"
done

python3 "$qemu/tests/usb4/gen-trace-stub.py" "$qemu/hw/usb4/trace-events" \
    "$out/trace/trace-hw_usb4.h"
gcc -std=gnu11 -O1 -g -Wall -Wextra -Wno-unused-parameter \
    -Wno-sign-compare -Wno-missing-field-initializers \
    -I"$qemu/tests/usb4/stub" -I"$out" -I"$qemu/include" -I"$qemu" \
    -I"$qemu/hw/usb4" -I"$core" \
    $(pkg-config --cflags glib-2.0) \
    "$here/cm-host-test.c" "$out/u4hi.o" "$out/u4cm.o" \
    "$qemu/hw/usb4/usb4-ctl.c" "$qemu/hw/usb4/usb4-fabric.c" \
    "$qemu/hw/usb4/usb4-router.c" "$qemu/hw/usb4/usb4-router-tb3.c" \
    "$qemu/hw/usb4/usb4-drom.c" \
    "$qemu/hw/usb4/usb4-tunnel.c" "$qemu/hw/usb4/usb4-fabric-usb3.c" \
    $(pkg-config --libs glib-2.0) -o "$out/cm-host-test"
"$out/cm-host-test"
