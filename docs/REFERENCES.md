# Reference material

`docs/references/` is git-ignored. It holds third-party specs and sources used while
designing the emulator. The pins below are the committed record; the commands in
"Re-fetch" reproduce the same snapshot from a fresh checkout.

## Pins

| Source | Pin |
|---|---|
| USB-IF bundle | `https://www.usb.org/sites/default/files/USB4%20Specification%20November%202025.zip` |
| Linux | commit `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` |
| FreeBSD | commit `ac64294143ffea63c7dedf9a1859f88342bd998a` |
| Intel tbtools | commit `aa0b1be590443d7074e799ebd6c72e308c5bdd02` |
| Microsoft pages | mutable web pages, fetched 2026-10-13; not reproducible, re-fetch gives the current text |

| Folder | What | Source | Pinned |
|---|---|---|---|
| `references/usb-if/` | USB4 Specification 2.0, Connection Manager Guide 2.0, DROM spec, DVSEC 1.0, Inter-Domain Service spec, TMU-disabled ECN (all PDF) | https://www.usb.org/document-library/usb4r-specification-v20 (zip "USB4 Specification November 2025") | November 2025 release, URL in `SOURCE_URL.txt` |
| `references/linux-thunderbolt/` | `drivers_thunderbolt/` (copy of `drivers/thunderbolt/`), `include/thunderbolt.h`, `Documentation/` (admin guide, sysfs ABI), `COPYING` | https://github.com/torvalds/linux | commit in `COMMIT.txt` |
| `references/freebsd-thunderbolt/` | `sys_dev_thunderbolt/` (copy of `sys/dev/thunderbolt/`): NHI, control packets, router config, host-side CM (`hcm.c`); no ICM code | https://github.com/freebsd/freebsd-src | commit in `COMMIT.txt` |
| `references/tbtools/` | `registers.json`, `control.json`, `xdomain.json`, `usb4.rs`, `drom.rs`, `tunnel.rs`, `README.md`, `LICENSE` | https://github.com/intel/tbtools | commit in `COMMIT.txt` |
| `references/microsoft/` | Windows USB4 design guidelines: overview, design details, ACPI requirements, power management, `_DSD` for PCIe root ports, converted to plain text | https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/universal-serial-bus-4 | fetched 2026-10-13 |

Not fetched because not public: Intel NHI datasheets, PCI-SIG class code document, Thunderbolt 3
host/device register documentation, Intel ICM firmware documentation. The Linux driver
(`nhi_regs.h`, `tb_regs.h`, `icm.c`, `lc.c`, `eeprom.c`) is the only open description of those.
What the Linux driver distinguishes per host and device controller generation, and what is modelled, is catalogued in `CONTROLLER-CATALOG.md`.

## Licences

| Reference | Licence | Use in this repo |
|---|---|---|
| USB-IF specs | USB-IF adopter terms, documents only | Cite sections. Facts, not text. |
| FreeBSD `sys/dev/thunderbolt` | BSD-2-Clause | Code-level reference. May be adapted. Adapted files retain the original copyright, conditions and disclaimer and are listed in `NOTICE`. |
| Intel tbtools | MIT | Code-level reference. `registers.json` may feed generated tables; generated files carry the tbtools copyright and permission notice and are listed in `NOTICE`. |
| Linux `drivers/thunderbolt` | GPL-2.0-only | May be adapted under GPL-2.0-only with attribution: adapted files keep the Linux copyright lines, name the source file and are listed in `NOTICE` with the pinned commit (`AGENTS.md` "Licence rules"). Behaviour seen only in Linux stays `inferred` until a capture confirms it. The only open ICM reference. |
| Microsoft guidelines | Microsoft docs terms | Cite. |

## Re-fetch

Run from `docs/references/` on a fresh checkout. Each block recreates the flattened
layout at the pinned revision, replacing any previous copy, then removes the temporary
clone. The pins are taken from the table above, not from the ignored tree.

```sh
LINUX_REV=24a19b953e2a3d0ea5a8c4951a0ab8f32720c907
FREEBSD_REV=ac64294143ffea63c7dedf9a1859f88342bd998a
TBTOOLS_REV=aa0b1be590443d7074e799ebd6c72e308c5bdd02
USBIF_URL="https://www.usb.org/sites/default/files/USB4%20Specification%20November%202025.zip"

# USB-IF bundle (about 43 MB); extract only the PDFs listed above
mkdir -p usb-if && echo "$USBIF_URL" > usb-if/SOURCE_URL.txt
curl -L -A Mozilla/5.0 -o usb4.zip "$USBIF_URL"
P="USB4 Specification November 2025"
unzip -j -o usb4.zip \
  "$P/USB4 Specification 2.0 November 2025 - CLEAN.pdf" \
  "$P/USB4 Connection Manager Guide 2.0 November 2025.pdf" \
  "$P/USB4 DROM Specification November 2025.pdf" \
  "$P/USB4 DVSEC Version 1.0.pdf" \
  "$P/USB4 Inter-Domain Service Specification 2.0 November 2025.pdf" \
  "$P/USB4 V2 ECN/USB4 2.0 ECN - Configuration and Behavior When TMU is Disabled.pdf" \
  -d usb-if && rm usb4.zip

# Linux thunderbolt driver at the pinned commit
git clone --filter=blob:none --sparse --no-checkout https://github.com/torvalds/linux _linux
git -C _linux sparse-checkout set --no-cone drivers/thunderbolt \
  Documentation/admin-guide/thunderbolt.rst Documentation/ABI/testing/sysfs-bus-thunderbolt \
  include/linux/thunderbolt.h COPYING
git -C _linux checkout "$LINUX_REV"
rm -rf linux-thunderbolt
mkdir -p linux-thunderbolt/Documentation linux-thunderbolt/include
git -C _linux log -1 --format='%H %cd' > linux-thunderbolt/COMMIT.txt
cp -r _linux/drivers/thunderbolt linux-thunderbolt/drivers_thunderbolt
cp _linux/Documentation/admin-guide/thunderbolt.rst \
   _linux/Documentation/ABI/testing/sysfs-bus-thunderbolt linux-thunderbolt/Documentation/
cp _linux/include/linux/thunderbolt.h linux-thunderbolt/include/
cp _linux/COPYING linux-thunderbolt/
rm -rf _linux

# FreeBSD thunderbolt driver at the pinned commit
git clone --filter=blob:none --sparse --no-checkout https://github.com/freebsd/freebsd-src _fbsd
git -C _fbsd sparse-checkout set --no-cone sys/dev/thunderbolt
git -C _fbsd checkout "$FREEBSD_REV"
rm -rf freebsd-thunderbolt && mkdir -p freebsd-thunderbolt
git -C _fbsd log -1 --format='%H %cd' > freebsd-thunderbolt/COMMIT.txt
cp -r _fbsd/sys/dev/thunderbolt freebsd-thunderbolt/sys_dev_thunderbolt
rm -rf _fbsd

# Intel tbtools register database at the pinned commit
git clone https://github.com/intel/tbtools _tbtools && git -C _tbtools checkout "$TBTOOLS_REV"
rm -rf tbtools && mkdir -p tbtools
git -C _tbtools log -1 --format='%H %cd' > tbtools/COMMIT.txt
cp _tbtools/src/data/registers.json _tbtools/src/data/control.json _tbtools/src/data/xdomain.json \
   _tbtools/src/usb4.rs _tbtools/src/drom.rs _tbtools/src/tunnel.rs \
   _tbtools/README.md _tbtools/LICENSE tbtools/
rm -rf _tbtools

# Microsoft pages (mutable; the result is today's text, not the 2026-10-13 snapshot)
mkdir -p microsoft && for u in \
  windows-hardware/design/component-guidelines/universal-serial-bus-4 \
  windows-hardware/design/component-guidelines/usb4-design-details-and-general-requirements \
  windows-hardware/design/component-guidelines/usb4-acpi-requirements \
  windows-hardware/design/component-guidelines/usb4-power-management-requirements \
  windows-hardware/drivers/pci/dsd-for-pcie-root-ports; do
  curl -sL -A Mozilla/5.0 "https://learn.microsoft.com/en-us/$u" -o "microsoft/$(basename $u).html"
done
# then strip each page to its <main> element as plain text (any HTML-to-text tool) and delete the .html
```
