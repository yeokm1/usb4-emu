#!/bin/sh
# Same as msys2-shell.cmd, for use from Git Bash or another POSIX shell on Windows.
REPO=$(cd "$(dirname "$0")/.." && pwd)
export MSYSTEM=UCRT64 CHERE_INVOKING=1 MSYS2_PATH_TYPE=minimal
BASH="$REPO/toolchain/msys64/usr/bin/bash.exe"
[ -x "$BASH" ] || { echo "toolchain/msys64 is missing. See docs/TOOLCHAIN.md." >&2; exit 1; }
if [ $# -eq 0 ]; then exec "$BASH" --login -i; else exec "$BASH" --login -c "$*"; fi
