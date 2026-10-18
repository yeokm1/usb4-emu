#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
# Make a 32 MiB FAT16 transfer disk (raw, no partition table: superfloppy)
# holding the experiment's binaries and helper files. Needs WSL mtools.
#   tools/reenum-test/mkdisk.sh <image> [extra files...]
set -euo pipefail
export MSYS_NO_PATHCONV=1
here="$(cd "$(dirname "$0")" && pwd)"
img="$1"; shift
wp() { wsl -d Ubuntu-26.04 -- wslpath -a "$(cygpath -m "$1")"; }
rm -f "$img"
W="$(wp "$(dirname "$img")")/$(basename "$img")"
# MBR with one FAT16 (type 06) primary partition at LBA 63, as Windows 98
# and 2000 expect on an IDE fixed disk.
python - "$(cygpath -m "$img")" <<'PY'
import struct, sys
total = 32 * 1024 * 1024 // 512
start, n = 63, total - 63
mbr = bytearray(512)
mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 1, 1, 0, 6, 15, 63, 255, start, n)
mbr[510:512] = bytes([0x55, 0xAA])
with open(sys.argv[1], 'wb') as f:
    f.write(mbr)
    f.truncate(total * 512)
PY
W="$W@@32256"
wsl -d Ubuntu-26.04 -- mformat -i "$W" -T $((65536 - 63)) -h 16 -s 63 -H 63 -v REENUM ::
for f in "$here/out/reenum.sys" "$here/out/cmreenum.exe" "$here"/*.inf "$here"/*.reg "$here"/*.bat "$here"/*.cmd "$@"; do
    [ -f "$f" ] || continue
    wsl -d Ubuntu-26.04 -- mcopy -o -i "$W" "$(wp "$f")" ::
done
wsl -d Ubuntu-26.04 -- mdir -i "$W" ::
