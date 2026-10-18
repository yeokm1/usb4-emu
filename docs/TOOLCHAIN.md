# Toolchain

QEMU builds only with GCC or Clang (C11 with GNU extensions); MSVC is not supported. On
Windows the supported host toolchain is MSYS2 with the MinGW-w64 UCRT64 environment plus
Meson, Ninja and Python 3.

This repository carries a self-contained copy of that toolchain in `toolchain/msys64/`.
The folder is git-ignored but is meant to travel with the working copy (for example by
OneDrive sync), so nothing in it or in the wrapper scripts depends on an absolute path.
MSYS2 is relocatable: everything is resolved relative to the `msys64` root.

## Using it

```
scripts\msys2-shell.cmd                     # interactive UCRT64 shell, cwd preserved
scripts\msys2-shell.cmd gcc --version       # run one command
scripts/msys2-shell.sh ninja -C build       # same from Git Bash
```

The wrappers set `MSYSTEM=UCRT64`, `CHERE_INVOKING=1` and `MSYS2_PATH_TYPE=minimal`, so
the host's `PATH` does not leak in and builds are reproducible on any machine the folder
is copied to.

## What is installed

Base MSYS2 plus these packages, all for UCRT64 unless noted:

- `base-devel`, `git` (MSYS)
- `mingw-w64-ucrt-x86_64-toolchain` (GCC, binutils, make, gdb)
- `meson`, `ninja`, `python`, `pkgconf`
- QEMU dependencies: `glib2`, `pixman`, `zlib`, `zstd`, `SDL2`, `gtk3`, `libslirp`, `libusb`

Exact versions are whatever `pacman -Q` reports inside the shell; record them in a
milestone note when a QEMU build is pinned.

## Rebuilding the folder

If `toolchain/msys64` is missing or broken, from Git Bash in the repo root:

```sh
mkdir -p toolchain && cd toolchain
curl -L -o msys2-base.sfx.exe \
  https://github.com/msys2/msys2-installer/releases/latest/download/msys2-base-x86_64-latest.sfx.exe
./msys2-base.sfx.exe -y -o"$(cygpath -w "$PWD")"
cd msys64
export MSYSTEM=UCRT64 CHERE_INVOKING=1 MSYS2_PATH_TYPE=minimal
./usr/bin/bash -lc true                       # first-run initialisation
./usr/bin/bash -lc 'pacman -Syuu --noconfirm' # run twice: core update, then the rest
./usr/bin/bash -lc 'pacman -Syuu --noconfirm'
./usr/bin/bash -lc 'pacman -S --needed --noconfirm base-devel git \
  mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-glib2 mingw-w64-ucrt-x86_64-pixman \
  mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-pkgconf mingw-w64-ucrt-x86_64-SDL2 mingw-w64-ucrt-x86_64-gtk3 \
  mingw-w64-ucrt-x86_64-libslirp mingw-w64-ucrt-x86_64-libusb mingw-w64-ucrt-x86_64-zlib \
  mingw-w64-ucrt-x86_64-zstd'
./usr/bin/bash -lc 'pacman -Scc --noconfirm'  # drop the package cache
```

## Caveats for a synced copy

- The tree is a few GB and tens of thousands of small files. OneDrive copes, but the
  first sync is slow, and "Files On-Demand" must be off for the folder or executables
  will be placeholders.
- Do not run two shells from two synced copies against the same `build/` directory.
- `pacman` writes into the tree, so run it in one copy, let the sync finish, then use the
  other copy.
