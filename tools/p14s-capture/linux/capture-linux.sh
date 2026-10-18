#!/bin/bash
if grep -q $'\r' "$0" 2>/dev/null; then echo "ERROR: $0 has Windows (CRLF) line endings; copy it again in binary mode or run: sed -i 's/\r$//' $0" >&2; exit 1; fi #
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Yeo Kheng Meng
#
# Thunderbolt 3 / USB4 capture for the usb4-emu project (written for the
# P14s Gen 1, Alpine Ridge LP with firmware CM; works on any Linux host).
# Run from a Linux live USB as root, also from a FAT32 stick (no exec bit
# needed):   sudo bash capture-linux.sh [options]
#
# Options:
#   --out DIR          where the final archive goes (default: the directory
#                      the script was started from)
#   --label TEXT       BIOS combination or other tag, e.g. assistOFF_prebootOFF
#                      (letters, digits, '_', '-', '.'); goes into the archive
#                      name and MANIFEST.txt
#   --no-interactive   skip the plug/approve/unplug prompts
#   --no-rebind        skip the driver unbind/rebind step
#   --no-redact        keep serials, MACs and the system UUID
#   --watch-mmio SECS  during every prompt, sample a few safe NHI registers
#                      and the NHI power state every SECS seconds; after the
#                      last unplug keep sampling (and probe the firmware CM
#                      with boot_acl reads) for --watch-tail seconds
#   --watch-tail SECS  length of that final watch (default 90)
#   --suspend          after the approve step, offer a 15 s suspend-to-idle
#                      (rtcwake -m freeze) with tracing on
#   --dp               after the approve step, ask for a monitor to be
#                      connected to the dock and disconnected again
#
# Boot-time tracing: when thunderbolt is a module (Ubuntu and most
# distributions), trace_event=thunderbolt:* on the kernel command line
# cannot work (the events do not exist yet when it is parsed: "Failed to
# enable trace event"). Instead add to the kernel command line
#   thunderbolt.dyndbg=+p modprobe.blacklist=thunderbolt,typec,typec_ucsi,ucsi_acpi trace_buf_size=64M
# (typec depends on thunderbolt, so on machines with UCSI the chain
# ucsi_acpi -> typec_ucsi -> typec loads thunderbolt despite blacklisting
# thunderbolt alone; seen on the Framework 13, 2026-10-15; the script
# names the modules that hold it when that happens).
# The script then finds the driver not loaded, loads it with the NHI held
# back (driver_override), turns tracing on and binds it: the first bind
# after power-on, with the firmware state the BIOS left, is traced
# ("boot tracing: first-bind"). With a built-in driver use
#   thunderbolt.dyndbg=+p trace_event=thunderbolt:* trace_buf_size=64M
# The script checks that the boot trace really holds thunderbolt events and
# warns before the first prompt when neither method is in effect.
#
# Everything is collected in a RAM directory (mktemp -d under /tmp); only
# the final archive p14s-linux-<date>-<time>[-<label>].tar.gz and its .sha256
# are written to the output directory. Names inside the archive are made
# FAT32/Windows-safe (PATHMAP.tsv maps them back to the original names).
#
# What it changes, all restored or harmless (see README.md "Safety"):
#   * NHI power/control is set to "on" to keep the NHI in D0, then restored.
#   * thunderbolt dynamic debug (+p) and thunderbolt trace events are turned
#     on, then restored. If the kernel refuses (lockdown, tracefs missing)
#     it is logged and the capture continues with dmesg only.
#   * debugfs is mounted if it is not already.
#   * the thunderbolt driver is unbound from and rebound to the NHI once
#     (asks first), which briefly disconnects Thunderbolt devices.
#   * if you answer "y" when asked, a newly plugged device is authorised by
#     writing 1 to its sysfs "authorized" file (what boltctl does).
#   * --suspend: one suspend-to-idle with an RTC wake-up, if you answer "y".
# It never writes device registers, NVM, firmware or firmware settings.

set -u
umask 022

OUT_PARENT=$(pwd)
INTERACTIVE=1
REBIND=1
REDACT=1
LABEL=
WATCH=
WATCH_TAIL=90
SUSPEND=0
DP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT_PARENT=${2:?--out needs a directory}; shift ;;
	--label) LABEL=${2:?--label needs a value}; shift ;;
	--no-interactive) INTERACTIVE=0 ;;
	--no-rebind) REBIND=0 ;;
	--no-redact) REDACT=0 ;;
	--watch-mmio) WATCH=${2:?--watch-mmio needs seconds}; shift ;;
	--watch-tail) WATCH_TAIL=${2:?--watch-tail needs seconds}; shift ;;
	--suspend) SUSPEND=1 ;;
	--dp) DP=1 ;;
	-h|--help) sed -n '3,/^# It never writes/p' "$0"; exit 0 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

case "$LABEL" in
*[!A-Za-z0-9_.-]*) echo "--label may only use letters, digits, '_', '-' and '.'" >&2; exit 2 ;;
esac
case "$WATCH" in
*[!0-9.]*|.*) echo "--watch-mmio needs a number of seconds, e.g. 2" >&2; exit 2 ;;
esac
case "$WATCH_TAIL" in
''|*[!0-9]*) echo "--watch-tail needs a whole number of seconds" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: sudo bash $0" >&2
	exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
for f in nhi_mmio_dump.py redact.py pack.py; do
	if [ ! -r "$HERE/$f" ]; then
		echo "ERROR: helper $HERE/$f is missing; copy the whole linux folder." >&2
		exit 1
	fi
	if grep -q $'\r' "$HERE/$f"; then
		echo "ERROR: $HERE/$f has Windows (CRLF) line endings; copy it again in binary mode or run: sed -i 's/\\r\$//' $HERE/$f" >&2
		exit 1
	fi
done
PY=$(command -v python3 || true)
if [ -z "$PY" ]; then
	echo "ERROR: python3 not found (needed for the register dump and packing)." >&2
	exit 1
fi
OUT_PARENT=$(cd "$OUT_PARENT" 2>/dev/null && pwd) || {
	echo "ERROR: output directory does not exist" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
NAME=p14s-linux-$STAMP${LABEL:+-$LABEL}
WORK=$(mktemp -d /tmp/p14s-capture.XXXXXX) || exit 1
O=$WORK/$NAME
mkdir -p "$O" || exit 1
LOG=$O/capture.log
TRACEFS=/sys/kernel/tracing
DEBUGFS=/sys/kernel/debug
PCIDEV=/sys/bus/pci/devices
TBDEV=/sys/bus/thunderbolt/devices

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# try_write VALUE FILE: write, log the error text on failure, never abort.
try_write() {
	local err
	if err=$( { printf '%s\n' "$1" >"$2"; } 2>&1 ); then
		return 0
	fi
	log "WARNING: could not write '$1' to $2: ${err##*: }"
	return 1
}

# run FILE CMD...: run with a timeout, stdout+stderr to FILE, never abort.
run() {
	local f=$O/$1; shift
	mkdir -p "$(dirname "$f")"
	{ echo "# \$ $*"; timeout 60 "$@" 2>&1; echo "# exit $?"; } >>"$f"
}

# have CMD: command exists
have() { command -v "$1" >/dev/null 2>&1; }

pause() {
	[ "$INTERACTIVE" = 1 ] || return 0
	printf '\n>>> %s\n    Press Enter when done.' "$1"
	read -r _ </dev/tty
}

ask() {
	[ "$INTERACTIVE" = 1 ] || return 1
	local a
	printf '\n>>> %s [y/N] ' "$1"
	read -r a </dev/tty
	case "$a" in y|Y|yes) return 0 ;; esac
	return 1
}

# copy_tree SRC DST: cat every readable regular file, skipping secrets and
# files whose read has side effects or is huge.
copy_tree() {
	local src=$1 dst=$2 f rel
	[ -d "$src" ] || return 0
	# No -L: sysfs symlinks (subsystem, driver, device) would loop.
	find "$src" -maxdepth 4 -type f 2>/dev/null | sort | while read -r f; do
		rel=${f#"$src"/}
		case "$rel" in
		*/key|key) continue ;;           # authorisation key (secure mode)
		*nvm_active*|*nvm_non_active*|*/nvmem) continue ;; # NVM images
		*/margining/*|margining/*) continue ;;  # receiver margining
		esac
		[ -r "$f" ] || continue
		mkdir -p "$dst/$(dirname "$rel")"
		timeout 20 cat "$f" >"$dst/$rel" 2>"$dst/$rel.err" ||
			echo "read failed" >>"$dst/$rel.err"
		[ -s "$dst/$rel.err" ] || rm -f "$dst/$rel.err"
	done
}

# ---------------------------------------------------------------- helpers

# Intel Thunderbolt 3 PCI device IDs we know about (Alpine Ridge, Titan
# Ridge, Ice/Tiger Lake). Only used to pick out devices; the driver
# binding and class codes are checked as well.
TB_IDS="1575 1576 1577 1578 15b5 15b6 15bf 15c0 15d2 15d3 15d4 15d9 15da 15db 15dc 15dd 15de 15e7 15e8 15e9 15ea 15eb 15ec 15ef 15f0 8a0d 8a17 9a1b 9a1d 9a1f 9a21"

# NHI: bound to thunderbolt, or USB4 host interface class 0C0340, or an
# Intel TB3 NHI (class 088000, "system peripheral") with a known ID, which
# also matches a Titan Ridge whose driver is not bound.
find_nhis() {
	local d drv cls ven dev
	for d in "$PCIDEV"/*; do
		ven=$(cat "$d/vendor") dev=$(cat "$d/device") cls=$(cat "$d/class")
		drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
		if [ "$drv" = thunderbolt ] || [ "$cls" = 0x0c0340 ] ||
		   { [ "$ven" = 0x8086 ] && [ "$cls" = 0x088000 ] &&
		     case " $TB_IDS " in *" ${dev#0x} "*) true ;; *) false ;; esac; }; then
			basename "$d"
		fi
	done
}

# Modules that hold thunderbolt loaded, directly or through another module
# (e.g. typec, then typec_ucsi and ucsi_acpi), from /sys/module/*/holders.
tb_holders() {
	local todo m h seen=""
	todo=thunderbolt
	while [ -n "$todo" ]; do
		m=${todo%% *}
		case "$todo" in *" "*) todo=${todo#* } ;; *) todo="" ;; esac
		for h in /sys/module/"$m"/holders/*; do
			[ -e "$h" ] || continue
			h=${h##*/}
			case " $seen " in *" $h "*) continue ;; esac
			seen="${seen:+$seen }$h"
			todo="${todo:+$todo }$h"
		done
	done
	echo "$seen"
}

# The Thunderbolt PCI complex: every device below the root port above the
# NHI; the PCIe ports the driver linked to the NHI (device links created
# from ACPI _DSD "usb4-host-interface", e.g. integrated or USB4 hosts whose
# tunnel root ports are not below the NHI) and everything below them; plus
# every Intel device with a known TB ID.
find_tb_complex() {
	local nhi p rp d
	for nhi in $NHIS; do
		p=$(readlink -f "$PCIDEV/$nhi")
		rp=$(echo "$p" | sed -E 's#^(/sys/devices/pci[^/]+/[^/]+)(/.*)?$#\1#')
		for d in "$rp" "$PCIDEV/$nhi"/consumer:pci:*; do
			[ -e "$d" ] || continue
			case "$d" in
			*/consumer:pci:*) d=$(readlink -f "$PCIDEV/${d##*/consumer:pci:}") ;;
			esac
			find "$d" -name config -path '*/[0-9a-f]*:*' 2>/dev/null |
				xargs -r -n1 dirname | xargs -r -n1 basename
		done
	done
	for d in "$PCIDEV"/*; do
		[ "$(cat "$d/vendor")" = 0x8086 ] || continue
		case " $TB_IDS " in *" $(sed 's/0x//' "$d/device") "*) basename "$d" ;; esac
	done
}

dump_pci_dev() {	# dump_pci_dev BDF DIR
	local b=$1 dir=$2 f
	mkdir -p "$dir/$b"
	run "${dir#"$O"/}/$b/lspci.txt" lspci -s "$b" -nnvvvxxxx
	cp "$PCIDEV/$b/config" "$dir/$b/config.bin" 2>/dev/null
	for f in "$PCIDEV/$b"/* "$PCIDEV/$b"/power/*; do
		[ -f "$f" ] && [ -r "$f" ] || continue
		case "$(basename "$f")" in
		config|rom|resource[0-9]*|remove|rescan|reset*|new_id|remove_id|bind|unbind) continue ;;
		esac
		echo "$(basename "$f"): $(timeout 5 cat "$f" 2>&1 | tr '\n' ' ')"
	done >"$dir/$b/sysfs-attrs.txt"
}

# mmio_dump LABEL [NHI...]: BAR0 dump, the first 256 bytes of PCI config
# space and the power state of each NHI (default: all of $NHIS), as
# mmio/<nhi>-<label>.*. A label already used for that NHI gets a -2, -3...
# suffix, so no dump is ever overwritten.
mmio_dump() {
	local label=$1 nhi l n
	shift
	mkdir -p "$O/mmio"
	for nhi in ${*:-$NHIS}; do
		[ -e "$PCIDEV/$nhi" ] || continue
		l=$label n=1
		while [ -e "$O/mmio/$nhi-$l.power_state" ] || [ -e "$O/mmio/$nhi-$l.txt" ]; do
			n=$((n + 1)) l=$label-$n
		done
		cat "$PCIDEV/$nhi/power/runtime_status" >"$O/mmio/$nhi-$l.runtime_status" 2>&1
		cat "$PCIDEV/$nhi/power_state" >"$O/mmio/$nhi-$l.power_state" 2>&1
		# Read-only, 256 bytes: header, force power, LTR, firmware-ready
		# words (CAPTURE-VS-LINUX.md ADL-3 to ADL-6).
		dd if="$PCIDEV/$nhi/config" of="$O/mmio/$nhi-$l.config.bin" bs=256 count=1 2>/dev/null ||
			log "WARNING: config space of $nhi ($l) not readable"
		lspci -s "$nhi" -xxx >"$O/mmio/$nhi-$l.config.txt" 2>&1
		if [ -e "$PCIDEV/$nhi/resource0" ]; then
			"$PY" "$HERE/nhi_mmio_dump.py" "$PCIDEV/$nhi/resource0" \
				--label "$l" --out "$O/mmio/$nhi-$l" >>"$LOG" 2>&1 &&
				log "MMIO dump $nhi ($l): $(grep -E '^0x399(0c|44)' "$O/mmio/$nhi-$l.txt" | tr '\n' ' ')" ||
				log "WARNING: MMIO dump of $nhi ($l) failed: $(tail -1 "$O/mmio/$nhi-$l.txt" 2>/dev/null)"
		fi
	done
}

# watch_start LABEL / watch_stop: with --watch-mmio, one background sampler
# per NHI (nhi_mmio_dump.py --watch, read-only, safe registers only) writing
# watch/<nhi>.tsv; each sampler ends by itself when its NHI disappears.
WATCH_PIDS=
PROBE_PID=
watch_start() {
	local nhi
	[ -n "$WATCH" ] || return 0
	mkdir -p "$O/watch"
	for nhi in $(find_nhis | sort -u); do
		[ -e "$PCIDEV/$nhi/resource0" ] || continue
		"$PY" "$HERE/nhi_mmio_dump.py" "$PCIDEV/$nhi/resource0" \
			--watch "$WATCH" --watch-max 7200 --label "$1" \
			--out "$O/watch/$nhi" >>"$LOG" 2>&1 &
		WATCH_PIDS="$WATCH_PIDS $!"
	done
	log "watching NHI registers every ${WATCH}s ($1)"
}
watch_stop() {
	local p
	if [ -n "$PROBE_PID" ]; then
		kill "$PROBE_PID" 2>/dev/null
		wait "$PROBE_PID" 2>/dev/null
		PROBE_PID=
	fi
	[ -n "$WATCH_PIDS" ] || return 0
	for p in $WATCH_PIDS; do kill "$p" 2>/dev/null; done
	wait $WATCH_PIDS 2>/dev/null
	WATCH_PIDS=
}

# wpause LABEL MESSAGE: pause, with the register watch running meanwhile.
wpause() {
	watch_start "$1"
	# Unplug steps: also probe the firmware CM every 2 s. With BIOS Assist
	# on the controller can vanish about 11 s after the FIRST unplug
	# (P14s + ORICO, 2026-10-15), long before the tail watch starts.
	case "$1" in
	*unplug*)
		if [ -n "$WATCH" ]; then
			icm_probe 100000 2 "$1" &
			PROBE_PID=$!
		fi
		;;
	esac
	pause "$2"
	watch_stop
}

# icm_probe SECONDS INTERVAL STEP: read every domain's boot_acl every
# INTERVAL s (on a firmware CM each read is one ICM boot-ACL command; the
# client gives up after four 5 s timeouts) and log how long each took, so
# the window in which the firmware stops answering is measured
# (CAPTURE-VS-LINUX.md C2). A line "no domain" is written when no domain
# exists (controller gone), so the file always shows what happened. Runs
# during the unplug prompts (INTERVAL 2) and the tail after the last unplug.
# Read-only.
icm_probe() {
	local end=$((SECONDS + $1)) d t0 t1 rc n err=$O/watch/icm-probe.$3.err
	mkdir -p "$O/watch"
	[ -s "$O/watch/icm-probe.tsv" ] ||
		printf '# start\tend\tdomain\tresult\tstderr\tstep\n' >"$O/watch/icm-probe.tsv"
	while [ "$SECONDS" -lt "$end" ]; do
		n=0
		for d in "$TBDEV"/domain*; do
			[ -r "$d/boot_acl" ] || continue
			n=1
			t0=$(cut -d' ' -f1 /proc/uptime)
			timeout 30 cat "$d/boot_acl" >/dev/null 2>"$err"
			rc=$?
			t1=$(cut -d' ' -f1 /proc/uptime)
			printf '%s\t%s\t%s\texit %s\t%s\t%s\n' "$t0" "$t1" "$(basename "$d")" "$rc" \
				"$(tr '\n' ' ' <"$err")" "$3" >>"$O/watch/icm-probe.tsv"
		done
		[ "$n" = 1 ] || printf '%s\t-\t-\tno domain\t\t%s\n' \
			"$(cut -d' ' -f1 /proc/uptime)" "$3" >>"$O/watch/icm-probe.tsv"
		sleep "$2"
	done
	rm -f "$err"
}

snapshot() {	# snapshot LABEL: thunderbolt sysfs, debugfs, bolt, MMIO
	local s=$O/snap-$1
	log "snapshot $1"
	mkdir -p "$s"
	if [ -d "$TBDEV" ]; then
		for d in "$TBDEV"/*; do
			[ -e "$d" ] || continue
			copy_tree "$(readlink -f "$d")" "$s/sys-bus-thunderbolt/$(basename "$d")"
		done
		ls -la "$TBDEV/" >"$s/sys-bus-thunderbolt.ls" 2>&1
		for d in "$TBDEV"/*; do
			echo "$(basename "$d") -> $(readlink -f "$d")"
		done >"$s/sys-bus-thunderbolt.links"
	fi
	if [ "$DEBUGFS_OK" = 1 ]; then
		copy_tree "$DEBUGFS/thunderbolt" "$s/debugfs-thunderbolt"
	fi
	if have boltctl; then
		run "snap-$1/boltctl.txt" boltctl list --all
		run "snap-$1/boltctl.txt" boltctl domains --verbose
	fi
	if have tblist; then
		run "snap-$1/tbtools.txt" tblist
	fi
	run "snap-$1/lspci-tv.txt" lspci -tvnn
	mmio_dump "$1"
}

# ---------------------------------------------------------------- start

log "usb4-emu P14s capture ${LABEL:+label $LABEL, }working in $O (RAM)"
log "kernel $(uname -r); interactive=$INTERACTIVE rebind=$REBIND redact=$REDACT"

# Boot mode and kernel lockdown decide what can be captured.
if [ -d /sys/firmware/efi ]; then
	BOOTMODE=UEFI
	SB=unknown
	have mokutil && SB=$(mokutil --sb-state 2>&1 | head -1)
else
	BOOTMODE="legacy/CSM boot"
	SB="n/a (legacy boot)"
fi
LOCKDOWN=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo "unknown (no /sys/kernel/security/lockdown)")
# Boot-time tracing (README step 2): the driver-ready handshake and the
# events before the first prompt are only seen with it.
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
BT_DYNDBG=no BT_TRACE=no BT_BUF=no
case " $CMDLINE " in *" thunderbolt.dyndbg="*) BT_DYNDBG=yes ;; esac
case " $CMDLINE " in *" trace_event="*thunderbolt*) BT_TRACE=yes ;; esac
case " $CMDLINE " in *" trace_buf_size="*) BT_BUF=yes ;; esac
BT_HOLD=no
case " $CMDLINE " in *" modprobe.blacklist="*thunderbolt*) BT_HOLD=yes ;; esac
# write_capture_info: called once the boot trace has been checked.
write_capture_info() {
{
	echo "label: ${LABEL:-none}"
	echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
	echo "kernel: $(uname -r)"
	echo "boot mode: $BOOTMODE"
	echo "secure boot: $SB"
	echo "lockdown: $LOCKDOWN"
	echo "boot tracing: $BOOT_TRACING (thunderbolt.dyndbg: $BT_DYNDBG, trace_event=thunderbolt: $BT_TRACE, modprobe.blacklist=thunderbolt: $BT_HOLD, trace_buf_size: $BT_BUF; driver $TB_MOD; boot trace events: $TB_BOOT_EV)"
	echo "options: interactive=$INTERACTIVE rebind=$REBIND redact=$REDACT watch-mmio=${WATCH:-off} watch-tail=$WATCH_TAIL suspend=$SUSPEND dp=$DP"
} >"$O/capture-info.txt"
}
log "boot mode: $BOOTMODE; secure boot: $SB; lockdown: $LOCKDOWN"
case "$LOCKDOWN" in
*"[none]"*|unknown*) ;;
*)
	log "WARNING: kernel lockdown is active ($LOCKDOWN)."
	log "WARNING: thunderbolt tracepoints, dynamic debug, debugfs register"
	log "WARNING: dumps and the NHI MMIO dump will probably be missing. The"
	log "WARNING: rest (PCI, sysfs, ACPI, dmesg) is still"
	log "WARNING: captured. For a complete capture, disable Secure Boot in the"
	log "WARNING: BIOS temporarily, re-run, then turn Secure Boot back on."
	;;
esac

# 1. System basics. Save the boot-time logs before we change anything.
run system/uname.txt uname -a
run system/cmdline.txt cat /proc/cmdline
run system/os-release.txt cat /etc/os-release
run system/lsmod.txt lsmod
run system/modinfo-thunderbolt.txt modinfo thunderbolt
run system/modinfo-thunderbolt.txt modinfo thunderbolt_net
run system/dmesg-boot.txt dmesg -T
run system/dmesg-boot-raw.txt dmesg
run system/journal-kernel-boot.txt journalctl -k -b --no-pager
for c in /boot/config-"$(uname -r)" /proc/config.gz; do
	[ -r "$c" ] || continue
	{ echo "# $c"; zcat -f "$c" | grep -E 'USB4|THUNDERBOLT|_TB_|INTEL_WMI_THUNDERBOLT|HOTPLUG_PCI|PCIE_DPC|IOMMU|DEBUG_FS|DYNAMIC_DEBUG|TRACING|EFIVAR|LOCK_DOWN'; } >>"$O/system/kconfig.txt"
done
run system/cpuinfo.txt grep -m1 "model name" /proc/cpuinfo
run system/iomem.txt cat /proc/iomem
run system/interrupts.txt cat /proc/interrupts
run system/mounts.txt cat /proc/mounts
# Intel WMI Thunderbolt force-power interface (listed only, never written).
run system/wmi-thunderbolt.txt sh -c 'ls -la /sys/bus/wmi/devices/86CCFD48-205E-4A77-9C48-2021CBEDE341* 2>&1'
if ! mountpoint -q "$TRACEFS" 2>/dev/null; then
	if err=$(mount -t tracefs nodev "$TRACEFS" 2>&1); then
		log "mounted tracefs"
	else
		log "WARNING: tracefs not mounted and mount failed: $err"
	fi
fi
TB_BOOT_EV=0
if [ -r "$TRACEFS/trace" ]; then
	cp "$TRACEFS/trace" "$O/system/trace-boot.txt" 2>/dev/null
	TB_BOOT_EV=$(grep -cE ' tb_[a-z_]+: ' "$O/system/trace-boot.txt" 2>/dev/null)
	TB_BOOT_EV=${TB_BOOT_EV:-0}
	log "boot trace buffer: $TB_BOOT_EV thunderbolt events (tb_*)"
fi
# Is the driver built in, a loaded module, or not loaded (held back with
# modprobe.blacklist=thunderbolt for a traced first bind)?
if [ -e /sys/module/thunderbolt/initstate ]; then
	TB_MOD=module
elif [ -d /sys/module/thunderbolt ]; then
	TB_MOD=built-in
else
	TB_MOD="not loaded"
fi
FIRST_BIND=0
if [ "$TB_MOD" = "not loaded" ] && [ -n "$(find_nhis)" ]; then
	FIRST_BIND=1
	BOOT_TRACING=first-bind
elif [ "$TB_BOOT_EV" -gt 0 ]; then
	BOOT_TRACING=yes
elif [ "$BT_TRACE" = yes ]; then
	BOOT_TRACING="no (trace_event= was given but the boot trace holds no thunderbolt events)"
else
	BOOT_TRACING=no
fi
write_capture_info
log "boot tracing: $BOOT_TRACING (thunderbolt.dyndbg=$BT_DYNDBG trace_event=$BT_TRACE modprobe.blacklist=$BT_HOLD trace_buf_size=$BT_BUF; driver $TB_MOD)"
case "$BOOT_TRACING" in
yes|first-bind)
	[ "$BT_DYNDBG" = yes ] ||
		log "note: thunderbolt.dyndbg=+p on the kernel command line adds the driver's debug log of the first bind"
	;;
*)
	log "WARNING: ************************************************************"
	log "WARNING: Boot-time Thunderbolt tracing is OFF. The firmware's first"
	log "WARNING: messages (driver ready, devices present at boot) are lost."
	if [ "$TB_MOD" = module ] && [ "$BT_TRACE" = yes ]; then
		log "WARNING: trace_event=thunderbolt:* cannot work here: thunderbolt is a"
		log "WARNING: module, its events do not exist when the option is parsed."
	fi
	BL_SUGGEST=thunderbolt,typec,typec_ucsi,ucsi_acpi
	if [ "$TB_MOD" != "not loaded" ] && [ "$BT_HOLD" = yes ]; then
		TB_HOLDERS=$(tb_holders)
		log "WARNING: thunderbolt is loaded although modprobe.blacklist=thunderbolt"
		log "WARNING: is set: a module that depends on it pulled it in."
		log "WARNING: Modules holding it (/sys/module/thunderbolt/holders, recursively): ${TB_HOLDERS:-none listed}"
		log "WARNING: (with UCSI, e.g. Framework 13: ucsi_acpi -> typec_ucsi -> typec)."
		log "WARNING: Blacklist them as well."
		for m in $TB_HOLDERS; do
			case ",$BL_SUGGEST," in *",$m,"*) ;; *) BL_SUGGEST="$BL_SUGGEST,$m" ;; esac
		done
	fi
	log "WARNING: For a complete capture reboot, press 'e' at the boot menu and"
	log "WARNING: append to the 'linux' line:"
	log "WARNING:   thunderbolt.dyndbg=+p modprobe.blacklist=$BL_SUGGEST trace_buf_size=64M"
	log "WARNING: and check after boot that 'lsmod | grep -E \"thunderbolt|typec\"' prints nothing."
	log "WARNING: The script then loads the driver itself with tracing on."
	log "WARNING: ************************************************************"
	pause "Boot-time tracing is missing (see above). Press Enter to continue anyway, or Ctrl-C to stop and reboot with it."
	;;
esac
for p in /sys/module/thunderbolt/parameters/*; do
	[ -r "$p" ] && echo "$(basename "$p")=$(cat "$p")"
done >"$O/system/thunderbolt-params.txt" 2>&1

# 2. PCI.
run pci/lspci-tv.txt lspci -tvnn
run pci/lspci-nn.txt lspci -nnk
run pci/lspci-vvv-all.txt lspci -nnvvv
# Full hex for every device except network controllers (their PCIe Device
# Serial Number is usually derived from the MAC address).
for b in $(lspci -n | awk '{print $1}'); do
	b=0000:$b
	case "$(cat "$PCIDEV/$b/class")" in 0x02*|0x0d*) continue ;; esac
	run pci/lspci-xxxx-all.txt lspci -s "$b" -nnvvvxxxx
done

NHIS=$(find_nhis | sort -u | tr '\n' ' ')
log "NHI candidates: ${NHIS:-none}"
if [ -z "$NHIS" ]; then
	log "No Thunderbolt NHI visible on PCI. With Thunderbolt BIOS Assist on"
	log "this is normal when no Thunderbolt device is attached: the firmware"
	log "powers the controller down. Plug a Thunderbolt device and rerun."
fi
TBC=$(find_tb_complex | sort -u | tr '\n' ' ')
log "Thunderbolt PCI complex: ${TBC:-none}"
for b in $TBC; do dump_pci_dev "$b" "$O/pci/tb-complex"; done

# Keep the NHI in D0 for the rest of the capture, remember old setting.
declare -A OLD_PM
keep_d0() {	# keep_d0 NHI WHY
	local nhi=$1
	[ -n "${OLD_PM[$nhi]+x}" ] && return 0
	OLD_PM[$nhi]=$(cat "$PCIDEV/$nhi/power/control" 2>/dev/null)
	echo "$nhi power/control was ${OLD_PM[$nhi]}, runtime_status $(cat "$PCIDEV/$nhi/power/runtime_status" 2>/dev/null)" >>"$O/power-control-changes.txt"
	if try_write on "$PCIDEV/$nhi/power/control"; then
		echo "$nhi power/control set to on$2" >>"$O/power-control-changes.txt"
	else
		OLD_PM[$nhi]=		# nothing to restore
	fi
}
for nhi in $NHIS; do keep_d0 "$nhi" ""; done
sleep 1

# 3. Firmware tables and identity.
mkdir -p "$O/firmware/acpi"
if have acpidump; then
	run firmware/acpidump.txt acpidump
fi
for t in /sys/firmware/acpi/tables/* /sys/firmware/acpi/tables/dynamic/*; do
	[ -f "$t" ] || continue
	case "$(basename "$t")" in
	MSDM*|SLIC*) echo "skipped $(basename "$t") (OEM Windows licence)" >>"$O/firmware/acpi/SKIPPED.txt"; continue ;;
	esac
	case "$t" in */dynamic/*) n=dynamic-$(basename "$t") ;; *) n=$(basename "$t") ;; esac
	cp "$t" "$O/firmware/acpi/$n.bin" 2>/dev/null
done
if have dmidecode; then
	run firmware/dmidecode.txt dmidecode -t bios -t system -t baseboard -t chassis
fi
EFIV=/sys/firmware/efi/efivars
if [ -d "$EFIV" ]; then
	ls "$EFIV" >"$O/firmware/efivars-all-names.txt" 2>&1
	mkdir -p "$O/firmware/efivars-tb"
	for v in "$EFIV"/*; do
		case "$(basename "$v")" in
		*[Tt]hunderbolt*|*[Tt]bt*|*TBT*|*Usb4*|*USB4*|*Drom*|*DROM*)
			cp "$v" "$O/firmware/efivars-tb/$(basename "$v").bin" 2>/dev/null ;;
		esac
	done
else
	echo "$BOOTMODE: no EFI variables ($EFIV absent)" >"$O/firmware/efivars-all-names.txt"
fi

# 4. debugfs and first snapshot.
DEBUGFS_OK=0
if mountpoint -q "$DEBUGFS" 2>/dev/null; then
	DEBUGFS_OK=1
elif err=$(mount -t debugfs none "$DEBUGFS" 2>&1); then
	DEBUGFS_OK=1
	log "mounted debugfs"
else
	log "WARNING: debugfs not mounted and mount failed: $err (no register dumps)"
fi
if [ "$DEBUGFS_OK" = 1 ] && [ ! -d "$DEBUGFS/thunderbolt" ]; then
	log "WARNING: $DEBUGFS/thunderbolt not present (lockdown, or kernel without debugfs support)"
fi
snapshot 1-initial

# 4b. First-bind mode (driver not loaded at boot, modprobe.blacklist):
# keep the NHIs away from the driver with driver_override, load the module
# so its trace events exist, and bind after tracing is on (step 5b).
HELD=
if [ "$FIRST_BIND" = 1 ]; then
	for nhi in $NHIS; do
		try_write usb4emu-hold "$PCIDEV/$nhi/driver_override" && HELD="$HELD $nhi"
	done
	if modprobe thunderbolt 2>>"$LOG"; then
		log "thunderbolt module loaded,${HELD:- no NHI} held back"
	else
		log "WARNING: modprobe thunderbolt failed; first bind not traced"
	fi
elif [ "$TB_MOD" = "not loaded" ]; then
	# Held back but no NHI yet (BIOS Assist on, nothing attached): load the
	# driver now so its trace events exist and a later plug is handled.
	modprobe thunderbolt 2>>"$LOG" && log "thunderbolt module loaded (no NHI present to hold back)"
fi

# 5. Tracing and dynamic debug. Every write is checked; on failure we fall
# back to the kernel log (dmesg -w), which is always captured.
DDC=$DEBUGFS/dynamic_debug/control
TRACE_ON=0 TRACE_PID= DMESG_PID= DDC_ON=0
OLD_BUF= BUF_CHANGED=0 OLD_TON= TON_CHANGED=0 EV_CHANGED=0
if [ -d "$TRACEFS/events/thunderbolt" ]; then
	ls "$TRACEFS/events/thunderbolt" >"$O/trace-events-available.txt" 2>&1
	OLD_TON=$(cat "$TRACEFS/tracing_on" 2>/dev/null)
	# buffer_size_kb reads e.g. "7 (expanded: 1408)" before first use.
	OLD_BUF=$(awk '{print $1; exit}' "$TRACEFS/buffer_size_kb" 2>/dev/null)
	if try_write 0 "$TRACEFS/tracing_on"; then
		[ "$OLD_TON" != 0 ] && TON_CHANGED=1
		try_write 16384 "$TRACEFS/buffer_size_kb" && BUF_CHANGED=1
		try_write "" "$TRACEFS/trace"
		if try_write 1 "$TRACEFS/events/thunderbolt/enable"; then
			EV_CHANGED=1
			if try_write 1 "$TRACEFS/tracing_on"; then
				TON_CHANGED=1
				cat "$TRACEFS/trace_pipe" >"$O/trace-thunderbolt.txt" 2>&1 &
				TRACE_PID=$!
				TRACE_ON=1
				log "thunderbolt trace events enabled"
			fi
		fi
	fi
	[ "$TRACE_ON" = 1 ] || log "WARNING: thunderbolt trace events unavailable; relying on dmesg"
else
	log "no $TRACEFS/events/thunderbolt (tracefs missing, locked down, or kernel without thunderbolt tracepoints); relying on dmesg"
fi
if [ -e "$DDC" ]; then
	if try_write 'module thunderbolt +p' "$DDC"; then
		DDC_ON=1
		log "dynamic debug on for thunderbolt"
		grep thunderbolt "$DDC" >"$O/dyndbg-sites.txt" 2>/dev/null
	fi
else
	log "no $DDC; add thunderbolt.dyndbg=+p to the kernel command line for driver debug messages"
fi
dmesg -w >"$O/dmesg-live.txt" 2>&1 &
DMESG_PID=$!

# release_held: give held NHIs back to the driver (first-bind mode).
release_held() {
	local nhi
	for nhi in $HELD; do
		try_write "" "$PCIDEV/$nhi/driver_override"
		[ -e /sys/bus/pci/drivers/thunderbolt/"$nhi" ] ||
			try_write "$nhi" /sys/bus/pci/drivers/thunderbolt/bind
	done
	HELD=
}

# reassert_d0 WHY: the driver's probe re-allows runtime PM, which resets
# power/control to "auto" (seen after the rebind on 2026-10-15); set "on"
# again for every NHI whose setting we changed.
reassert_d0() {
	local nhi
	for nhi in "${!OLD_PM[@]}"; do
		[ -n "${OLD_PM[$nhi]}" ] || continue
		[ "$(cat "$PCIDEV/$nhi/power/control" 2>/dev/null)" = on ] && continue
		try_write on "$PCIDEV/$nhi/power/control" &&
			echo "$nhi power/control set to on again$1" >>"$O/power-control-changes.txt"
	done
}

CLEANED=0
cleanup() {
	[ "$CLEANED" = 1 ] && return
	CLEANED=1
	log "restoring settings"
	release_held
	[ "$DDC_ON" = 1 ] && try_write 'module thunderbolt -p' "$DDC"
	[ "$EV_CHANGED" = 1 ] && try_write 0 "$TRACEFS/events/thunderbolt/enable"
	[ -n "$TRACE_PID" ] && kill "$TRACE_PID" 2>/dev/null
	[ "$TON_CHANGED" = 1 ] && [ -n "$OLD_TON" ] && try_write "$OLD_TON" "$TRACEFS/tracing_on"
	[ "$BUF_CHANGED" = 1 ] && [ -n "$OLD_BUF" ] && try_write "$OLD_BUF" "$TRACEFS/buffer_size_kb"
	[ -n "$DMESG_PID" ] && kill "$DMESG_PID" 2>/dev/null
	watch_stop
	for nhi in "${!OLD_PM[@]}"; do
		[ -n "${OLD_PM[$nhi]}" ] || continue
		try_write "${OLD_PM[$nhi]}" "$PCIDEV/$nhi/power/control" &&
			echo "$nhi power/control restored to ${OLD_PM[$nhi]}" >>"$O/power-control-changes.txt"
	done
	wait 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 5b. First bind after power-on (first-bind mode only).
if [ -n "$HELD" ]; then
	log "first bind of thunderbolt after power-on:$HELD"
	release_held
	sleep 10
	reassert_d0 " (after the first bind)"
	snapshot 2-first-bind
fi

# 6. Driver rebind: produces the full driver-ready handshake in the trace.
if [ "$REBIND" = 1 ] && [ -n "$NHIS" ]; then
	if [ "$INTERACTIVE" = 0 ] || ask "Unbind and rebind the thunderbolt driver now? Thunderbolt devices disconnect for a few seconds (unmount any Thunderbolt disk first)."; then
		for nhi in $NHIS; do
			if [ -e /sys/bus/pci/drivers/thunderbolt/"$nhi" ]; then
				log "unbinding thunderbolt from $nhi"
				try_write "$nhi" /sys/bus/pci/drivers/thunderbolt/unbind
				sleep 3
				# Only this NHI: with two NHIs a dump of all would
				# record the other one still bound.
				mmio_dump 2-unbound "$nhi"
				log "binding thunderbolt to $nhi"
				try_write "$nhi" /sys/bus/pci/drivers/thunderbolt/bind
			else
				log "$nhi not bound to thunderbolt; trying modprobe"
				modprobe thunderbolt
			fi
		done
		sleep 10
		reassert_d0 " (after the rebind)"
		snapshot 3-after-rebind
	fi
fi

# 7. Plug, approve, unplug.
if [ "$INTERACTIVE" = 1 ]; then
	wpause 4-unplug "If a Thunderbolt device is plugged in, UNPLUG it now (unmount it first) and wait 10 seconds."
	snapshot 4-unplugged
	NHIS=$(find_nhis | sort -u | tr '\n' ' ')
	wpause 5-plug "PLUG the Thunderbolt device in now and wait about 15 seconds. Do NOT approve any desktop prompt yet. A USB4 device (e.g. an ASMedia NVMe enclosure) on a Thunderbolt 3 host that is not approved within about 9 s falls back to USB: for those press Enter as soon as it is plugged."
	NHIS=$(find_nhis | sort -u | tr '\n' ' ')
	for nhi in $NHIS; do keep_d0 "$nhi" " (appeared after plug)"; done
	snapshot 5-plugged
	for d in "$TBDEV"/*; do
		[ -f "$d/authorized" ] || continue
		[ "$(cat "$d/authorized")" = 0 ] || continue
		if ask "Device $(basename "$d") ($(cat "$d/vendor_name" 2>/dev/null) $(cat "$d/device_name" 2>/dev/null)) is not authorised. Authorise it now (writes 1 to $d/authorized)?"; then
			log "authorising $(basename "$d")"
			try_write 1 "$d/authorized"
		fi
	done
	sleep 10
	snapshot 6-approved
	TBC=$(find_tb_complex | sort -u | tr '\n' ' ')
	for b in $TBC; do dump_pci_dev "$b" "$O/pci/tb-complex-with-device"; done
	run pci/lspci-tv-with-device.txt lspci -tvnn
	run pci/nvme-with-device.txt sh -c 'ls -l /dev/nvme* ; lsblk -o NAME,SIZE,MODEL,TRAN'
	# Optional: system suspend (s2idle) with the device attached.
	if [ "$SUSPEND" = 1 ]; then
		if ! have rtcwake; then
			log "WARNING: --suspend: rtcwake not found (util-linux); skipped"
		elif ask "Suspend to idle for 15 seconds now (the screen goes dark, the machine wakes by itself)?"; then
			cat /sys/power/state >"$O/system/power-state-before-suspend.txt" 2>&1
			cat /sys/power/mem_sleep >>"$O/system/power-state-before-suspend.txt" 2>&1
			watch_start 6-suspend
			log "suspending: rtcwake -m freeze -s 15"
			run system/rtcwake.txt rtcwake -m freeze -s 15
			log "resumed"
			sleep 10
			watch_stop
			snapshot 6s-after-suspend
		fi
	fi
	# Optional: DisplayPort tunnel through the dock.
	if [ "$DP" = 1 ]; then
		wpause 6-dp "CONNECT a monitor to the dock's DisplayPort/HDMI output now and wait until it shows a picture (about 15 seconds)."
		snapshot 6d-dp-connected
		run snap-6d-dp-connected/drm-status.txt sh -c 'for c in /sys/class/drm/card*-*; do echo "$c $(cat "$c/status" 2>&1) $(cat "$c/enabled" 2>&1)"; done'
		wpause 6-dp-off "DISCONNECT the monitor from the dock now and wait 10 seconds."
		snapshot 6e-dp-disconnected
	fi
	wpause 7-unplug "UNMOUNT any filesystem on the device, then UNPLUG the Thunderbolt device and wait 10 seconds."
	if [ -n "$WATCH" ]; then
		# BIOS Assist on: the firmware may stop answering and the platform
		# may remove the whole controller about 35 s after the last device
		# left (CAPTURE-VS-LINUX.md C2). Measure both.
		log "watching for ${WATCH_TAIL}s after the unplug (registers and firmware CM answers); do not touch the machine"
		watch_start 7-tail
		icm_probe "$WATCH_TAIL" 10 7-tail
		watch_stop
		log "watch done; NHIs now: $(find_nhis | sort -u | tr '\n' ' ')"
	fi
	snapshot 7-unplugged-again
fi

# 8. Finish.
sleep 2
cleanup
trap - EXIT
trap - INT TERM
dmesg -T >"$O/dmesg-final.txt" 2>&1
[ -r "$TRACEFS/trace" ] && cp "$TRACEFS/trace" "$O/trace-final-buffer.txt" 2>/dev/null

if [ "$REDACT" = 1 ]; then
	SEC=$(mktemp)
	if have dmidecode; then
		for k in system-serial-number system-uuid baseboard-serial-number chassis-serial-number; do
			dmidecode -s "$k" 2>/dev/null
		done >>"$SEC"
	fi
	cat /sys/class/net/*/address 2>/dev/null | grep -vx '00:00:00:00:00:00' >>"$SEC"
	"$PY" "$HERE/redact.py" "$O" "$SEC" && log "redaction done" ||
		log "WARNING: redaction failed"
	rm -f "$SEC"
fi

cp "$0" "$O/capture-linux.sh.used" 2>/dev/null
{
	echo "# usb4-emu P14s Linux capture"
	cat "$O/capture-info.txt"
	echo "# sha256 of every file, original names (see PATHMAP.tsv for the names in this archive)"
	( cd "$O" && find . -type f ! -name MANIFEST.txt -exec sha256sum {} + | sort -k2 )
} >"$O/MANIFEST.txt" 2>/dev/null

# Pack in RAM with FAT32/Windows-safe names, then copy only the archive
# (split below 4 GB if ever needed) and its .sha256 to the output directory.
log "packing (log ends here; the archive holds everything above)"
if "$PY" "$HERE/pack.py" "$O" "$OUT_PARENT" "$NAME"; then
	rm -rf "$WORK"
else
	echo "ERROR: packing failed; the raw capture is still in $O" >&2
	exit 1
fi
