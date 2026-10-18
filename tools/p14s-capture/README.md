# P14s Gen 1 capture toolkit

Tools that record how the real ThinkPad P14s Gen 1 Thunderbolt 3 controller
(Intel JHL6240 Alpine Ridge LP, NHI 8086:15bf, firmware connection manager "ICM") looks and behaves under
Linux, Windows 11 and Windows 98 SE. The output is the golden data for the
`tb3-alpine-ridge` profile and the provenance for `docs/ICM-PROTOCOL.md`: anything
seen in these captures is tagged `observed` there (observed/inferred rule, `AGENTS.md`).
Results go under `tests/captures/` once reviewed.

All three tools are read-only toward the hardware. See [Safety](#safety).

## What to prepare

- **A Thunderbolt 3 device.** Any TB3 device works; a **TB3 NVMe enclosure** is
  best because it exercises the PCIe tunnel the emulator models. A TB3 dock is
  the next best. Plain USB-C devices do not count. Unmount/eject it before every
  unplug.
- **BIOS settings: write them down, do not change them.** In the ThinkPad setup
  (F1 at boot) under Config > Thunderbolt 3, note:
  - Thunderbolt BIOS Assist Mode (Enabled/Disabled)
  - Wake by Thunderbolt 3
  - Security Level (No Security / User Authorization / Secure Connect /
    Display Port and USB)
  - Support in Pre Boot Environment: Thunderbolt device, and "Thunderbolt(TM)
    device" PXE / boot support
  - Config > Startup: UEFI/Legacy Boot and CSM Support
  - BIOS version (Main page)

  Put these in a `bios-settings.txt` next to the archives you send back. If
  you take a photo instead, crop out the serial number.
- A USB stick with Ventoy and the Kubuntu 26.04 live ISO, plus this folder
  copied onto the stick's data partition (FAT32 or exFAT is fine). Copy the
  files in binary mode: the Linux scripts refuse to run if a copy tool turned
  their line endings into CRLF, and tell you how to fix it.
- A label for each BIOS combination you capture, e.g. `assistOFF_prebootOFF`
  (letters, digits, `_`, `-`, `.`). Pass it with `--label` / `-Label`; it goes
  into the archive name and the manifest, so several runs never collide.

## 1. Linux (most important)

Collects, mapped to ROADMAP M0 "Capture from the P14s Gen 1":

| Output | What | Used for |
|---|---|---|
| `system/` | `uname`, kernel cmdline, `lsmod`, `modinfo thunderbolt`, kernel config USB4/TB bits, boot `dmesg`, boot trace buffer | context |
| `pci/` | `lspci -tv`, `-nnk`, `-nnvvv` for everything, `-xxxx` for every non-network device; for the Thunderbolt complex (NHI, upstream/downstream bridges, TB xHCI, tunnelled devices) `lspci -nnvvvxxxx`, raw `config` (4 KB), sysfs attributes; again with the device attached | PCI identity, bridge topology, M3 tunnel bridge layout |
| `mmio/` | NHI BAR0 registers (see below), the first 256 bytes of the NHI's PCI config space (`.config.bin`, `.config.txt`) and its runtime PM state, at each step and for each NHI; the unbind step dumps only the NHI it just unbound (`<nhi>-2-unbound`), and a label is never reused (a repeat gets `-2`, `-3`) | `REG_FW_STS`, `OUTMAIL_CMD` at idle, ring registers, Intel interrupt control (ARCHITECTURE §3, §4.1); force power, firmware ready and LTR in config space across unbind and suspend |
| `watch/` | with `--watch-mmio`: `<nhi>.tsv`, a few safe NHI registers and the power state sampled every N seconds during each prompt and after the last unplug; `icm-probe.tsv`, how long each `boot_acl` read took during the unplug prompts (every 2 s) and after the last unplug (every 10 s), with "no domain" lines once the controller is gone | when the firmware CM stops answering and when the platform removes the controller (BIOS Assist, `CAPTURE-VS-LINUX.md` C2) |
| `snap-*/sys-bus-thunderbolt/` | every readable attribute of every domain/router: `unique_id` (UUID), `vendor`/`device` names, `authorized`, `security`, `boot_acl`, generation, link speed/width, NVM version | M2 `/sys/bus/thunderbolt` contents |
| `snap-*/debugfs-thunderbolt/` | router config space (`regs`), per-adapter `regs`, `path`, `counters`, DROM if exposed | full host and device router config dumps, device DROM (§4.2 tb3 checklist) |
| `snap-*/boltctl.txt` | `boltctl list --all`, `boltctl domains --verbose` | security level, stored devices |
| `trace-thunderbolt.txt`, `dmesg-live.txt` | thunderbolt tracepoints (every control and ICM packet on ring 0) and dynamic-debug driver log across driver rebind, plug, approve, unplug | `ICM_DRIVER_READY` request/response bytes, device-connected/disconnected events, approve, mailbox use: the ICM wire contract |
| `firmware/` | ACPI tables (`/sys/firmware/acpi/tables`, all SSDTs), `acpidump` if installed, `dmidecode` (serials redacted), names of all EFI variables and copies of Thunderbolt-related ones | `_OSC`/`_DSD`, host DROM EFI variable (§4.2), CSM picture |

Steps:

1. Plug the Thunderbolt device in **before power-on**, then boot the Kubuntu
   live USB ("Try Kubuntu").
2. Strongly recommended: also capture the first driver bind after
   power-on. At the boot menu press `e` on the Kubuntu entry and append to
   the `linux` line:
   `thunderbolt.dyndbg=+p modprobe.blacklist=thunderbolt,typec,typec_ucsi,ucsi_acpi trace_buf_size=64M`
   (then F10/Ctrl-X; with Ventoy, pick the ISO, then the GRUB entry, then
   `e`; on an installed system put it in `GRUB_CMDLINE_LINUX_DEFAULT` in
   `/etc/default/grub` and run `update-grub`). The blacklist keeps the
   Thunderbolt driver from loading at boot. `thunderbolt` alone is not
   enough on machines with UCSI (USB Type-C connector reporting through
   ACPI, e.g. the Framework 13): `typec` depends on `thunderbolt`, so the
   chain `ucsi_acpi` -> `typec_ucsi` -> `typec` loads it anyway. The
   four-module line was confirmed on the Framework 13 on 2026-10-15 (the
   two first-bind captures in `tests/captures/framework13-12th/`); a
   blacklisted module that a machine does not have changes nothing. After
   booting, before running the script, check in Konsole that

   ```sh
   lsmod | grep -E "thunderbolt|typec"
   ```

   prints nothing. If the driver is loaded anyway, the script's warning
   names the modules holding it (`/sys/module/thunderbolt/holders`,
   followed recursively) and prints a blacklist line that includes them.

   The script finds the driver not loaded,
   holds the NHI back (`driver_override`), loads the module, turns the
   tracepoints on and only then binds the driver: the first driver-ready
   handshake and the devices the firmware announces from power-on (with
   their `boot` bit) are traced. `capture.log` then says
   `boot tracing: first-bind`, and the snapshot `snap-2-first-bind` follows.
   (Added 2026-10-15 after that day's boot traces came out empty; used on
   the Framework 13 the same day, not yet tried on the P14s. The bind
   happens when the script runs, not at boot, but it is still the first one
   since power-on.)
   `thunderbolt.dyndbg=+p` adds the driver's debug log of that bind and is
   also the fallback for driver debug messages when the running kernel
   refuses to change dynamic debug (lockdown, see below).

   **Do not rely on `trace_event=thunderbolt:*`** on Ubuntu or any kernel
   where Thunderbolt is a module (`/sys/module/thunderbolt/initstate`
   exists): the option is processed before the module loads, so the kernel
   logs "Failed to enable trace event: thunderbolt:*" and the boot trace
   stays empty (all four P14s runs of 2026-10-15 and the Framework ORICO run
   lost their boot trace this way). It only works with a kernel that has the
   driver built in (`CONFIG_USB4=y`). Newer kernels may also accept
   module events on the command line in the form `trace_event=:mod:thunderbolt`;
   that is untested here, and the script's check below tells whether it
   worked. A `/etc/modprobe.d` option or an initramfs hook cannot help:
   tracepoints can only be enabled after the module is loaded, and the
   driver binds during the load.

   The script checks the result rather than the command line: it counts
   the `tb_*` events in the boot trace buffer and records
   `boot tracing: yes` only if there are some, `first-bind` in the mode
   above, otherwise `no` (with the reason) in `capture.log` and
   `capture-info.txt`. When it is `no` it prints a warning block and waits
   for Enter before going on (Ctrl-C to stop and reboot).
3. Open Konsole, `cd` to this folder on the stick
   (e.g. `cd /media/kubuntu/Ventoy/p14s-capture/linux`) and run it with
   `bash` (FAT32 has no executable bit, so `./capture-linux.sh` does not work):

   ```sh
   sudo bash capture-linux.sh --label assistOFF_prebootOFF
   ```

   It collects everything in a RAM directory (`/tmp/p14s-capture.*`) and
   writes nothing to the stick until the end.

4. Answer the prompts. It will:
   - ask to **unbind and rebind** the thunderbolt driver (Thunderbolt devices
     drop for a few seconds; nothing is mounted on a live system unless you
     mounted it). This records the whole driver-ready handshake.
   - ask you to **unplug**, then **plug** the device. If KDE pops up an
     authorisation prompt, ignore it; the script asks you instead and authorises
     through sysfs so the approve is in the trace.
   - with `--suspend`, after the approve, offer a 15 s suspend-to-idle
     (`rtcwake -m freeze -s 15`); the machine wakes by itself.
   - with `--dp`, ask you to connect a monitor to the dock's
     DisplayPort/HDMI output, then to disconnect it.
   - ask you to **unplug** again. With `--watch-mmio` it then keeps
     sampling for `--watch-tail` seconds (default 90): leave the machine
     alone until it says "watch done".
5. Send `p14s-linux-<date>-<time>[-<label>].tar.gz` and its `.sha256`. The
   last lines of output print their full paths: the directory you ran the
   script from, or `--out DIR`.

Options: `--label TEXT`, `--no-interactive` (no prompts, no plug test, rebind
without asking), `--no-rebind`, `--no-redact`, `--out DIR`, and:

- `--watch-mmio SECONDS` (e.g. `1`): during every prompt, sample the safe
  register set below plus the NHI's `power/runtime_status` and `power_state`
  every SECONDS into `watch/<nhi>.tsv`, with the monotonic clock (the one
  `dmesg` uses), boot time and wall time. During each unplug prompt it also
  reads each domain's `boot_acl` every 2 s (one ICM command on a firmware
  CM; Linux gives up after 20 s), and after the last unplug it keeps
  sampling for `--watch-tail SECONDS` (default 90) with a `boot_acl` read
  every 10 s; each read and its duration go to `watch/icm-probe.tsv`, and a
  "no domain" line is written when there is no domain to read (the
  controller is gone). With BIOS Assist on the controller can disappear
  about 11 s after the first unplug (P14s + ORICO, 2026-10-15), which the
  tail alone never saw.
  Sampling of an NHI stops at the first all-ones read (controller gone),
  after which only its presence in sysfs is polled.
- `--suspend`: one suspend-to-idle with the device attached (asks first).
- `--dp`: the monitor connect/disconnect step.

The archive is safe to store on FAT32 and to unpack on Windows: names
contain no `: * ? " < > | \`, no trailing dots or spaces, no two names in a
folder differ only by case, and there are no symlinks or device files. PCI
addresses become e.g. `0000_00_04.0`. `PATHMAP.tsv` in the archive lists every
renamed (or skipped) path with its original name, and `MANIFEST.txt` holds the
label, boot mode, Secure Boot and lockdown state, and a SHA-256 of every file
under its original name. An archive above 3.9 GB (not expected) is split into
`.tar.gz.001`, `.002`, ...; join them with `cat`.

**Secure Boot and kernel lockdown.** With Secure Boot on, Ubuntu locks the
kernel down. The script records `/sys/kernel/security/lockdown` and warns if
it is not `[none]`: thunderbolt tracepoints, dynamic debug, debugfs register
dumps and the NHI MMIO dump are then refused by the kernel (observed in a VM:
`integrity` refuses the MMIO dump and dynamic debug, `confidentiality` also
tracefs and debugfs). Every such step logs the error and the capture
continues; PCI, sysfs, ACPI and the kernel log are always collected. For a
complete capture, disable Secure Boot in the BIOS temporarily, re-run, and
turn it back on afterwards. A legacy/CSM boot has no Secure Boot and no EFI
variables; that is recorded as "legacy/CSM boot" and is fine.

If the log says "No Thunderbolt NHI visible on PCI": with Thunderbolt BIOS
Assist on, the P14s firmware powers the controller off when nothing is
plugged in (seen in the `ON_ON_NO` capture). Plug the device and run again.
Do not change BIOS settings to force it.

### The NHI register reader

`nhi_mmio_dump.py` maps `/sys/bus/pci/devices/<nhi>/resource0` read-only and
issues one aligned 32-bit read per register. It reads only:

| Range | Registers |
|---|---|
| `0x00000 + 16n`, `0x08000 + 16n` | TX and RX ring base, producer/consumer, size, for n < ring count (from `HOST_CAPS`, max 32) |
| `0x19800 + 32n`, `0x29800 + 32n` (2 dwords) | TX and RX ring options |
| `0x38200`, `0x38204` | interrupt mask |
| `0x38c00`-`0x38c3c`, `0x38c40`-`0x38c50` | interrupt throttling, interrupt vector allocation |
| `0x39640` | host capabilities (ring count) |
| `0x39864` | DMA misc (Intel interrupt auto-clear bit) |
| `0x39900`-`0x3990c` | `INMAIL_DATA`, `INMAIL_CMD`, `0x39908`, `OUTMAIL_CMD` |
| `0x39944` | `REG_FW_STS` |

Never read, even with `--extra`:

| Range | Why |
|---|---|
| `0x37800`-`0x37817` | ring interrupt status: on Intel a read clears the bits it returns, which would steal an interrupt from the running driver; the rest of the block is write-only clear/set registers |
| `0x38208`-`0x38217` | write-only interrupt mask clear/set |
| `0x19400`-`0x197ff` | RX ring status area; behaviour on the Intel controllers undocumented, may be read-to-clear |
| `0x39898` | host interface reset register |

Before reading, the script sets the NHI's `power/control` to `on` so runtime PM
keeps it in D0 (a suspended device reads all ones), records the old value in
`power-control-changes.txt` and restores it at the end, also on Ctrl-C.

`--watch` (used by `--watch-mmio`) reads only `0x39640`, `0x39864`,
`0x39900`-`0x3990c`, `0x39944` and `0x38200`, mapping the file again for
every sample.

## 2. Windows 11

Collects: OS build, BIOS version, model (no serials); every PCI/ACPI/software
device with status and problem codes; full `Get-PnpDeviceProperty` and
`pnputil /enum-devices ... /resources /relations /drivers` for every Thunderbolt
device and PCI bridge; `pnputil /enum-drivers`; signed-driver versions and INF
names for Thunderbolt; service registry keys and `.sys` file versions; the
Thunderbolt Control Center package version; `HKLM\SYSTEM\CurrentControlSet\Enum`
keys (with Device Parameters) of Thunderbolt devices; `HKLM\SOFTWARE\Intel`
Thunderbolt keys; ACPI tables (registry copies including DSDT and the SSDTs,
plus the firmware-table API); memory resources; `setupapi.dev.log`; filtered
System and Kernel-PnP event logs; Intel Thunderbolt log files under
ProgramData; the list of ETW providers, and an ETW trace (Thunderbolt providers
found by name, Kernel-PnP, PCI) across unplug, plug/approve and unplug,
decoded with `tracerpt`.

Used for: Windows driver package pinning (M0), M3 smoke-gate expectations
(which devices, drivers and resources Windows assigns behind the tunnel), and
the ACPI picture under Windows.

Steps:

1. Boot Windows 11 with the Thunderbolt device plugged in.
2. Start **Windows PowerShell as Administrator**, `cd` to the `win11` folder and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   .\capture-win11.ps1 assistOFF_prebootOFF
   ```

3. Follow the three prompts (unplug, plug and approve in Thunderbolt Control
   Center, unplug). Eject the disk before each unplug.
4. Send `p14s-win11-<date>-<time>[-<label>].zip` and its `.sha256`. It
   collects in `%TEMP%` and writes only those two files to the script's
   folder (or `-OutDir`).

Options: `-Label TEXT`, `-NoTrace` (skip ETW and prompts), `-NoRedact`,
`-OutDir E:\path`.

Limits: Windows has no in-box way to read raw PCI config space or NHI registers
without installing a third-party driver, so we do not; the Linux capture covers
both. The Intel driver's own WPP trace GUIDs are not listed by `logman` if it
only uses WPP; then the trace has only the PnP/PCI view, which is still useful.

## 3. Windows 98 SE (CSM boot, no Thunderbolt driver)

The question for xhci98: what does the firmware leave behind when Windows 98
boots through CSM with no Thunderbolt driver? Is the NHI on PCI at all, with
which BARs, command register and power state? What bus numbers and bridge
windows are reserved under the Thunderbolt root port? Is the Thunderbolt xHCI
visible? Is there an ACPI RSDP?

`PCIDUMP.COM` (2211 bytes, 386+) answers that from plain DOS:

- walks PCI configuration mechanism #1 over all 256 buses, 32 devices, 8
  functions, and prints the 256-byte header of every present function in the
  `lspci -xxx` text format (decode later with `lspci -F PCIDUMP.TXT -vvnn`);
- prints the PCI BIOS check (INT 1Ah B101h: mechanisms, version, last bus),
  the DOS version, and whether it ran inside Windows (INT 2Fh 1600h);
- prints every ACPI RSDP found in the EBDA and E0000h-FFFFFh;
- finds the PCI IRQ routing table (`$PIR`, F0000h-FFFFFh on 16-byte
  boundaries), prints its size and checksum (`00` = valid) and the whole
  table as `# PIR` hex lines: the 32-byte header (version, router bus and
  device, exclusive IRQs, compatible router), then one 16-byte line per slot
  (bus, device, INTA#-INTD# link and IRQ bitmap, slot number);
- calls PCI BIOS INT 1Ah B10Eh (Get PCI Interrupt Routing Options) and
  prints the result (`ax`, the IRQs dedicated to PCI in `bx`, the returned
  size) and every returned entry as `# IRT` lines, in the same 16-byte
  format. Windows 98 uses one or the other;
- with `/N` only: for an Intel Thunderbolt/USB4 NHI (`8086:15bf` and the
  other known NHI IDs) whose BAR0 is assigned below 4 GB with memory decode
  on, reads the five dwords at BAR0 + `0x39640`, `0x39864`, `0x39904`,
  `0x3990c`, `0x39944` and prints them as `# NHI regs:`. It needs plain
  real mode: in a Windows DOS box or under EMM386 (V86 mode) it prints
  "V86 mode ..., not read" instead. It switches to protected mode for a
  moment with interrupts off to give FS a 4 GB limit ("big real mode"), and
  enables A20 through HIMEM.SYS if needed (and turns it back off). If there
  is no XMS driver, or its local A20 enable fails (as on the P14s Gen 1,
  whose HIMEM offers no HMA; PCIDUMP 1.1 then refused every BAR0 with bit 20
  set), it tests whether addresses wrap at 1 MB and reads only if they do
  not. It never
  reads the interrupt status block at `0x37800`;
- uses only 32-bit `OUT 0CF8h` / `IN 0CFCh`, restores `0CF8h` afterwards, and
  writes nothing else. It does not read the 4 KB extended config space (not
  reachable by mechanism #1); the Linux capture has that.

MS-DOS `DEBUG` cannot do this itself: its `i`/`o` commands are 8-bit only, and
byte writes near `0CF8h` are dangerous (`0CF9h` is the chipset reset control
register). `PCIDUMP.COM` is built by `gen_pcidump.py` from a commented listing
(`PCIDUMP.LST`), verified byte-for-byte against GNU as, and tested in DOSBox-X.
`MKPCIDMP.SCR` recreates `PCIDUMP.COM` using only DEBUG, if the binary does not
survive the copy.

Steps:

1. Copy the `win98` folder to the P14s, e.g. to `C:\P14SCAP` (a FAT USB stick
   also works if Windows 98 can read it).
2. **Preferred, plain DOS:** Start > Shut Down > **Restart in MS-DOS mode**. Then,
   with a new folder name per run (up to 8 characters, e.g. the BIOS combination):

   ```bat
   C:
   CD \P14SCAP
   CAPTURE ON_ON
   ```

   `CAPTURE.BAT` creates the folder (it refuses an existing name, so earlier
   runs are never overwritten) and writes everything into it: `RUN.TXT` (label,
   date, time), `PCIDUMP.TXT`, `VER`, `SET` and `MEM /C` output, an export of
   `HKEY_LOCAL_MACHINE\Enum` as `ENUM.REG` (the real-mode `REGEDIT /L: /R:`
   form when needed), and copies of `BOOTLOG.TXT`, `CONFIG.SYS`,
   `AUTOEXEC.BAT` and `IOS.LOG` if present. It lists the folder at the end;
   bring back the whole folder. Type `EXIT` to return to Windows.

   **NHI registers (optional):** add `N` after the folder name, e.g.
   `CAPTURE ON_ON N`. After the normal dump it also runs `PCIDUMP /N` into
   `PCIDUMPN.TXT`, which adds the controller's firmware status and
   operating mode as the BIOS leaves them. Only in MS-DOS mode, and only if
   `CONFIG.SYS` does not load EMM386 (otherwise the file says "V86 mode, not
   read" and nothing else changes). If the machine hangs at "Running PCIDUMP
   /N", power it off; `PCIDUMP.TXT` is already written.
3. **Also from Windows:** open an MS-DOS Prompt, `CD \P14SCAP`, run
   `PCIDUMP > PCIDUMPW.TXT`. Comparing the two shows what the Windows 98 PCI
   driver changed (bus numbers, BARs, command bits). The DOS box can race the
   Windows PCI code on `0CF8h`; if the result looks garbled, trust the MS-DOS
   mode run.
4. If `PCIDUMP.COM` is missing or damaged: `DEBUG < MKPCIDMP.SCR` in that folder
   recreates it.
5. Windows 98 GUI extras (optional but helpful):
   - Start > Programs > Accessories > System Tools > **System Information**,
     File > Save, save `P14S.NFO`; also File > Export to `P14S-MSI.TXT`.
   - Device Manager: note any Thunderbolt-related "PCI device" / "Other
     devices" entries with yellow marks; Properties > Resources screenshots or
     notes for them. `ENUM.REG` already holds the same data.
   - Start > Run `REGEDIT`, File > Export, branch `HKEY_LOCAL_MACHINE\Enum\PCI`,
     save `ENUMPCI.REG` (redundant with `ENUM.REG`, use if CAPTURE failed).
6. Bring back every run folder (plus any `.NFO`/`.REG` extras from step 5).

Run it once per BIOS combination, each with its own folder name, e.g.
`CAPTURE OFF_OFF`, `CAPTURE ON_OFF`, `CAPTURE OFF_ON`, `CAPTURE ON_ON`, plus
`CAPTURE ON_ON_NO` with the Thunderbolt device unplugged at power on. Whether
the firmware enumerates the device in CSM mode depends on "Support in Pre Boot
Environment".

## Next capture session: checklist

From `docs/CAPTURE-VS-LINUX.md` §5, most valuable first. Before each Linux
run, check that `capture.log` says `boot tracing: first-bind` (or `yes`
with a built-in driver), not `no`.

1. **P14s + TB3 NVMe enclosure, Linux, Assist off.** Boot with the tracing
   options (step 2), enclosure plugged at power-on. Run
   `sudo bash capture-linux.sh --label assistOFF_prebootOFF_nvme --watch-mmio 1`;
   after the approve, check `/dev/nvme0n1` appears (the script records
   `lsblk`). Repeat with pre-boot on (`--label assistOFF_prebootON_nvme`):
   the device-connected event with `boot` = 1 must be in the trace of the
   first bind.
2. **P14s, Assist on, any TB3 device, Linux.** Tracing options on, device
   plugged at power-on. `sudo bash capture-linux.sh --label
   assistON_prebootOFF --watch-mmio 1 --watch-tail 120`. At the last
   unplug, keep hands off until "watch done": `watch/icm-probe.tsv` shows
   when the firmware stopped answering, `watch/<nhi>.tsv` when the
   controller vanished.
3. **P14s, Windows 98, CSM.** With the dock and without it, Assist off and
   on: `CAPTURE OFF_OFF N`, `CAPTURE ON_ON N`, `CAPTURE ON_ON_NO N`, ... in
   MS-DOS mode without EMM386. Check `PCIDUMP.TXT` has a `# $PIR` line with
   checksum `00` and a `# PCI BIOS B10E` line, and `PCIDUMPN.TXT` a
   `# NHI regs:` line when the controller is present.
4. **ORICO AAGM2-U4 (USB4 NVMe) on the Framework**, Linux, tracing options,
   `--watch-mmio 1 --dp` if a monitor and dock are at hand, plus
   `--suspend`.
5. ~~**ORICO AAGM2-U4 on the P14s**~~ Done 2026-10-15
   (`tests/captures/p14s-gen1/linux-orico-*`,
   `docs/captures/P14S-ORICO-2026-10-15.md`). Worth repeating with the
   first-bind method, so the boot-time events are traced too.
6. **P14s UEFI boot** (BIOS: UEFI only, CSM off; Assist off, pre-boot off),
   Linux with tracing options. Note whether Secure Boot is on; turn it off
   for the run if the script reports lockdown.

Write the BIOS settings of every run into `bios-settings.txt` (see
[What to prepare](#what-to-prepare)).

## Sending results

Put everything in one folder:

```
p14s-captures-<date>/
  bios-settings.txt
  p14s-linux-<date>-<time>-<label>.tar.gz (+ .sha256), one per BIOS combination
  p14s-win11-<date>-<time>-<label>.zip (+ .sha256)
  win98/            PCIDUMP.TXT, PCIDUMPW.TXT, ENUM.REG, ... (with and without device)
```

and send it to the integrator, or commit it to `tests/captures/p14s-gen1/` on a
branch. Do not commit anything you are unsure about; ask first.

## Privacy

- Linux (`linux/redact.py`, runs on the machine): system, board and chassis
  serial numbers, the system UUID and network MAC addresses; the host name
  (`<HOST>`); user names in `/home/...` and `C:\Users\...` paths (`<USER>`);
  filesystem and partition UUIDs (`root=UUID=`, `resume=UUID=`, `PARTUUID=`,
  `/dev/disk/by-uuid/`, systemd's `\x2d`-escaped unit names, ext4 mount
  messages), which become the all-zero UUID; USB serial numbers
  (`SerialNumber:`, lsusb `iSerial`); and the PCIe Device Serial Number of
  every function that is not a Thunderbolt/USB4 controller (usually derived
  from a MAC address) in all its forms: raw `config.bin` bytes (`0x58`),
  `lspci -xxxx` hex (`58`), `lspci -vvv` and sysfs `serial_number`
  (`XX-...`). Text files get placeholders, binary files same-length
  replacements so offsets stay valid. `REDACTIONS.txt` lists the replacements
  per file and category.
- Windows 11: computer name, user name, domain, serials, system UUID and MAC
  addresses are redacted in text files, and the computer, user and domain
  names in the `.etl` trace (its header holds the log file path under
  `C:\Users\<name>`). Not done on the machine: USB serial numbers inside
  instance IDs, MAC-derived PCIe Device Serial Numbers in instance IDs and
  logs, and the MAC address node of device container GUIDs; `scrub.py`
  removes them.
- Windows 98: nothing is redacted on the machine. `ENUM.REG` holds the
  instance IDs of every USB device ever used with that installation, which
  embed their serial numbers; `scrub.py` removes them.
- **On arrival, before committing**, the integrator runs
  `python3 tools/p14s-capture/scrub.py NEW.tar.gz NEW.zip WIN98-FOLDER ...` on
  all new captures together (`--list` first to review what it found; that
  output contains the values). It applies the `redact.py` engine to the
  archives, which are rewritten in place with the same member names and
  order (`REDACTIONS.txt` gets a second section, `MANIFEST.*` and the
  `.sha256` get the new hashes), and to Windows 98 folders in place.
- **Kept on purpose:** Thunderbolt router UUIDs (`unique_id`, `boot_acl`, ICM
  events, DROM UID) and the PCIe Device Serial Number of Thunderbolt
  controller functions, which is derived from the router UID. The emulator needs them to impersonate the controller and
  device faithfully. They identify the Thunderbolt chips, not you. If you
  prefer, say so and we will substitute consistent fake UUIDs before
  committing.
- ACPI `MSDM`/`SLIC` tables (OEM Windows licence key) are never collected.

## Safety

What the tools never do: write PCI config space or NHI registers, read
read-to-clear registers (PCIDUMP `/N` reads five fixed NHI offsets only), touch NVM/firmware images (`nvm_*` attributes are not
read or written, no `fwupd`), change BIOS/UEFI settings or EFI variables, or
install drivers.

What they do change, and why:

| Tool | Change | Undone |
|---|---|---|
| Linux | NHI `power/control` = `on` (keep D0 while reading) | restored at exit |
| Linux | thunderbolt dynamic debug and trace events on, trace buffer 16 MB | restored at exit |
| Linux | mounts debugfs if not mounted | live session only |
| Linux | unbind + bind of the thunderbolt driver (asks first) | driver is rebound |
| Linux | writes `1` to `authorized` of a new device if you answer `y` | unplug |
| Windows 11 | temporary ETW session `p14s-tb` | stopped at the end |
| Linux | `--suspend`: one suspend-to-idle with an RTC wake-up, if you answer `y` | wakes after 15 s |
| Windows 98 | `OUT 0CF8h` (config address latch) | original value restored |
| Windows 98 | `/N` only: CR0 protection-enable bit set and cleared again with interrupts off (big real mode), A20 enabled through HIMEM.SYS | A20 disabled again if PCIDUMP enabled it; FS keeps a 4 GB limit until reboot, which real-mode code does not notice |

## Files

| File | |
|---|---|
| `linux/capture-linux.sh` | Linux collector |
| `linux/nhi_mmio_dump.py` | read-only NHI BAR0 reader; works on any file for testing |
| `linux/redact.py` | redaction pass (also the engine of `scrub.py`) |
| `scrub.py` | host-side scrub of finished archives and Windows 98 folders |
| `linux/pack.py` | FAT32/Windows-safe packing, split, `.sha256` |
| `win11/capture-win11.ps1` | Windows 11 collector |
| `win98/CAPTURE.BAT` | Windows 98 / DOS collector |
| `win98/PCIDUMP.COM` | PCI and RSDP dump program |
| `win98/PCIDUMP.LST` | its listing |
| `win98/MKPCIDMP.SCR` | DEBUG script that recreates `PCIDUMP.COM` |
| `win98/gen_pcidump.py` | builds the three files above; `--check-gas AS OBJCOPY` cross-checks against GNU as |
