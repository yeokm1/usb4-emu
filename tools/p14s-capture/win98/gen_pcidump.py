#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Yeo Kheng Meng
"""Build PCIDUMP.COM, its listing, and a DEBUG script that recreates it.

PCIDUMP.COM is a tiny read-only DOS program for a 386 or later CPU. It
  * prints the PCI BIOS presence check (INT 1Ah AX=B101h) registers,
  * prints the Windows enhanced-mode check (INT 2Fh AX=1600h), so the
    dump says whether it ran in a Windows DOS box or plain DOS,
  * finds the ACPI RSDP signature in the EBDA and E000-FFFF and prints
    the first 36 bytes of each hit,
  * walks PCI configuration mechanism #1 (ports 0CF8h/0CFCh) over every
    bus/device/function and prints the 256-byte configuration header of
    each present function in the same text format as `lspci -xxx`, so
    `lspci -F PCIDUMP.TXT -vvnn` can decode it on Linux,
  * restores the original 0CF8h value and exits.

It only issues 32-bit OUTs to 0CF8h (the config address latch) and 32-bit
INs from 0CFCh. Byte or word writes to 0CF8h-0CFBh are never issued:
0CF9h is the reset control register on Intel chipsets. MS-DOS DEBUG's
`i`/`o` commands are byte-only, which is why DEBUG alone is not used for
the PCI walk.

The program is defined below as a commented listing with hand-encoded
instruction bytes. `--check-gas AS OBJCOPY` re-assembles the same listing
with GNU as (.code16) and requires a byte-identical result.

Usage:
    gen_pcidump.py [--outdir DIR] [--check-gas AS OBJCOPY]
Writes PCIDUMP.COM, PCIDUMP.LST and MKPCIDMP.SCR into DIR (default: the
directory of this script).
"""

import argparse
import os
import subprocess
import sys
import tempfile

ORG = 0x100
BUFSZ = 1024
IRTBUF = 0x800      # INT 1Ah B10Eh buffer, 128 entries of 16 bytes
NHI_OFFSETS = (0x39640, 0x39864, 0x39904, 0x3990C, 0x39944)
assert all(not 0x37800 <= o < 0x37818 for o in NHI_OFFSETS)


class Asm:
    def __init__(self):
        self.items = []     # (kind, payload, gas, comment)
        self.equs = {}      # name -> (label, offset)

    def equ(self, name, base, offset):
        self.equs[name] = (base, offset)

    def label(self, name):
        self.items.append(("label", name, None, None))

    def i(self, parts, gas, c=""):
        """parts: ints and ('a16', label) absolute 16-bit address refs."""
        self.items.append(("ins", parts, gas, c))

    def jcc(self, cc, target, c=""):
        ops = {"jz": 0x84, "jnz": 0x85, "jb": 0x82, "jbe": 0x86, "ja": 0x87}
        self.items.append(("ins", [0x0F, ops[cc], ("r16", target)],
                           "%s %s" % (cc, target), c))

    def jmp(self, target, c=""):
        self.items.append(("ins", [0xE9, ("r16", target)],
                           "jmp " + target, c))

    def call(self, target, c=""):
        self.items.append(("ins", [0xE8, ("r16", target)],
                           "call " + target, c))

    def db(self, data, c=""):
        self.items.append(("ins", list(data), None, c))

    @staticmethod
    def size(parts):
        return sum(1 if isinstance(p, int) else 2 for p in parts)

    def assemble(self):
        labels, pc = {}, ORG
        for kind, p, _, _ in self.items:
            if kind == "label":
                labels[p] = pc
            else:
                pc += self.size(p)
        for name, (base, off) in self.equs.items():
            labels[name] = labels[base] + off
        out, lst, pc = bytearray(), [], ORG
        for kind, p, gas, c in self.items:
            if kind == "label":
                lst.append("%04X                      %s:" % (pc, p))
                continue
            end = pc + self.size(p)
            b = bytearray()
            for x in p:
                if isinstance(x, int):
                    b.append(x)
                elif x[0] == "a16":
                    b += labels[x[1]].to_bytes(2, "little")
                else:
                    b += ((labels[x[1]] - end) & 0xFFFF).to_bytes(2, "little")
            src = gas.replace("@", "") if gas else "db"
            for k in range(0, max(len(b), 1), 8):
                chunk = " ".join("%02X" % v for v in b[k:k + 8])
                if k == 0:
                    lst.append(("%04X  %-24s     %-34s %s" % (
                        pc + k, chunk, src,
                        ("; " + c) if c else "")).rstrip())
                else:
                    lst.append("%04X  %s" % (pc + k, chunk))
            out += b
            pc = end
        return bytes(out), lst, labels

    def gas_source(self):
        """GNU as source for the same program, for cross-checking."""
        lines = [".code16", "_start:"]
        for name, (base, off) in self.equs.items():
            lines.append(".set %s, %s+%d" % (name, base, off))
        for kind, p, gas, _ in self.items:
            if kind == "label":
                lines.append("%s:" % p)
            elif gas and not any(isinstance(x, tuple) and x[0] == "r16"
                                 for x in p):
                # Absolute refs written as same-section differences so GNU
                # as resolves them without relocations.
                g = gas
                for x in p:
                    if isinstance(x, tuple):
                        g = g.replace("@" + x[1],
                                      "(%s-_start+0x100)" % x[1])
                lines.append("    " + g)
            else:
                for x in p:
                    if isinstance(x, int):
                        lines.append("    .byte 0x%02x" % x)
                    elif x[0] == "r16":
                        lines.append("    .word %s-.-2" % x[1])
                    else:
                        lines.append("    .word %s-_start+0x100" % x[1])
        return "\n".join(lines) + "\n"


def build():
    a = Asm()
    A = lambda name: ("a16", name)  # noqa: E731
    s = lambda name, text: (a.label(name), a.db(text.encode("ascii") + b"\0"))  # noqa: E731

    a.label("start")
    a.i([0xFC], "cld", "string ops count up")
    # --- command line: /N enables the NHI register reads
    a.i([0xBE, 0x81, 0x00], "mov $0x81,%si", "PSP command tail, ends with CR")
    a.i([0x30, 0xE4], "xor %ah,%ah", "AH = 1 after a '/'")
    a.label("argl")
    a.i([0xAC], "lods %ds:(%si),%al")
    a.i([0x3C, 0x0D], "cmp $0x0d,%al")
    a.jcc("jz", "argend")
    a.i([0x3C, 0x2F], "cmp $0x2f,%al", "'/'")
    a.jcc("jnz", "argn")
    a.i([0xB4, 0x01], "mov $1,%ah")
    a.jmp("argl")
    a.label("argn")
    a.i([0x0C, 0x20], "or $0x20,%al", "lower case")
    a.i([0x3C, 0x6E], "cmp $0x6e,%al", "'n'")
    a.jcc("jnz", "argx")
    a.i([0x84, 0xE4], "test %ah,%ah")
    a.jcc("jz", "argx")
    a.i([0xC6, 0x06, A("nflag"), 0x01], "movb $1,@nflag")
    a.label("argx")
    a.i([0x30, 0xE4], "xor %ah,%ah")
    a.jmp("argl")
    a.label("argend")
    a.i([0xBF, A("buf")], "mov $@buf,%di", "DI = output buffer pointer")
    a.i([0xBE, A("s_hdr")], "mov $@s_hdr,%si")
    a.call("puts")

    # --- DOS version and Windows enhanced mode check
    a.i([0xB8, 0x00, 0x30], "mov $0x3000,%ax", "INT 21h AH=30h: DOS version")
    a.i([0xCD, 0x21], "int $0x21")
    a.i([0x50], "push %ax")
    a.i([0xB8, 0x00, 0x16], "mov $0x1600,%ax",
        "INT 2Fh AX=1600h: Windows enhanced mode? AL=major or 0/80h")
    a.i([0xCD, 0x2F], "int $0x2f")
    a.i([0x89, 0xC3], "mov %ax,%bx")
    a.i([0xBE, A("s_dos")], "mov $@s_dos,%si")
    a.call("puts")
    a.i([0x58], "pop %ax")
    a.call("hex16", "AL=major AH=minor")
    a.i([0xBE, A("s_win")], "mov $@s_win,%si")
    a.call("puts")
    a.i([0x89, 0xD8], "mov %bx,%ax")
    a.call("hex16")
    a.call("crlf")

    # --- PCI BIOS installation check
    a.i([0x57], "push %di", "INT 1Ah B101h may use EDI")
    a.i([0x66, 0x31, 0xFF], "xor %edi,%edi", "EDI=0 per PCI BIOS spec")
    a.i([0x66, 0x31, 0xD2], "xor %edx,%edx")
    a.i([0xB8, 0x01, 0xB1], "mov $0xb101,%ax", "PCI BIOS present?")
    a.i([0xCD, 0x1A], "int $0x1a")
    a.i([0x5F], "pop %di")
    a.i([0x9C], "pushf")
    a.i([0x66, 0x52], "push %edx", "EDX = 'PCI ' if present")
    a.i([0x51], "push %cx", "CL = last bus")
    a.i([0x53], "push %bx", "BH.BL = version")
    a.i([0x50], "push %ax", "AH = 0 if present, AL = mechanisms")
    a.i([0xBE, A("s_bios")], "mov $@s_bios,%si")
    a.call("puts")
    for name in ("ax", "bx", "cx"):
        a.i([0x58], "pop %ax")
        a.call("hex16", name)
        a.i([0xBE, A("s_sp")], "mov $@s_sp,%si")
        a.call("puts")
    a.i([0x66, 0x58], "pop %eax")
    a.call("hex32", "edx")
    a.i([0xBE, A("s_fl")], "mov $@s_fl,%si")
    a.call("puts")
    a.i([0x58], "pop %ax")
    a.call("hex16", "flags (bit 0 = CF, set = no PCI BIOS)")
    a.call("crlf")

    # --- ACPI RSDP search: EBDA first KB, then E000:0-F000:FFF0
    a.i([0x31, 0xC0], "xor %ax,%ax")
    a.i([0x8E, 0xE0], "mov %ax,%fs")
    a.i([0x64, 0xA1, 0x0E, 0x04], "mov %fs:0x40e,%ax",
        "EBDA segment from BDA 40:0E")
    a.i([0xB9, 0x40, 0x00], "mov $0x40,%cx", "64 paragraphs = 1 KB")
    a.call("rsdscan")
    a.i([0xB8, 0x00, 0xE0], "mov $0xe000,%ax")
    a.i([0xB9, 0x00, 0x20], "mov $0x2000,%cx", "E0000-FFFFF")
    a.call("rsdscan")

    # --- $PIR table scan: F0000h-FFFFFh on 16-byte boundaries
    a.i([0xB8, 0x00, 0xF0], "mov $0xf000,%ax")
    a.i([0x8E, 0xE0], "mov %ax,%fs")
    a.i([0x31, 0xF6], "xor %si,%si")
    a.label("pirl")
    a.i([0x64, 0x66, 0x81, 0x3C, 0x24, 0x50, 0x49, 0x52], "cmpl $0x52495024,%fs:(%si)", "'$PIR'")
    a.jcc("jnz", "pirn")
    a.call("pirdump")
    a.label("pirn")
    a.i([0x83, 0xC6, 0x10], "add $16,%si")
    a.jcc("jnz", "pirl", "SI wraps to 0 after F000:FFF0")

    # --- INT 1Ah B10Eh: Get PCI Interrupt Routing Options
    a.i([0xC7, 0x06, A("irtreq"), 0x00, 0x08], "movw $0x800,@irtreq", "RouteBuffer: size of our data buffer")
    a.i([0xB8, A("irtbuf")], "mov $@irtbuf,%ax")
    a.i([0xA3, A("irtreqo")], "mov %ax,@irtreqo", "data buffer offset")
    a.i([0x8C, 0x0E, A("irtreqs")], "mov %cs,@irtreqs", "and segment")
    a.i([0x57], "push %di")
    a.i([0x1E], "push %ds")
    a.i([0xBF, A("irtreq")], "mov $@irtreq,%di", "ES:DI = RouteBuffer")
    a.i([0xB8, 0x00, 0xF0], "mov $0xf000,%ax")
    a.i([0x8E, 0xD8], "mov %ax,%ds", "DS = F000h, as the PCI BIOS spec asks")
    a.i([0x31, 0xDB], "xor %bx,%bx")
    a.i([0xB8, 0x0E, 0xB1], "mov $0xb10e,%ax")
    a.i([0xCD, 0x1A], "int $0x1a")
    a.i([0x1F], "pop %ds")
    a.i([0x5F], "pop %di")
    a.i([0x9C], "pushf")
    a.i([0x53], "push %bx", "BX = IRQs dedicated to PCI")
    a.i([0x50], "push %ax", "AH = 0 on success")
    a.i([0x89, 0xC2], "mov %ax,%dx")
    a.i([0xBE, A("s_irt")], "mov $@s_irt,%si")
    a.call("puts")
    a.i([0x58], "pop %ax")
    a.call("hex16")
    a.i([0xBE, A("s_irtbx")], "mov $@s_irtbx,%si")
    a.call("puts")
    a.i([0x58], "pop %ax")
    a.call("hex16")
    a.i([0xBE, A("s_size")], "mov $@s_size,%si")
    a.call("puts")
    a.i([0xA1, A("irtreq")], "mov @irtreq,%ax")
    a.call("hex16")
    a.i([0xBE, A("s_fl")], "mov $@s_fl,%si")
    a.call("puts")
    a.i([0x58], "pop %ax")
    a.call("hex16")
    a.call("crlf")
    a.i([0x84, 0xF6], "test %dh,%dh")
    a.jcc("jnz", "irtdone")
    a.i([0x8B, 0x0E, A("irtreq")], "mov @irtreq,%cx")
    a.i([0x81, 0xF9, 0x00, 0x08], "cmp $0x800,%cx")
    a.jcc("ja", "irtdone")
    a.i([0xC1, 0xE9, 0x04], "shr $4,%cx", "16 bytes per entry, as a $PIR slot entry")
    a.jcc("jz", "irtdone")
    a.i([0xBE, A("irtbuf")], "mov $@irtbuf,%si")
    a.label("irtl")
    a.i([0x56], "push %si")
    a.i([0xBE, A("s_irtl")], "mov $@s_irtl,%si")
    a.call("puts")
    a.i([0x5E], "pop %si")
    a.i([0x89, 0xF0], "mov %si,%ax")
    a.i([0x2D, A("irtbuf")], "sub $@irtbuf,%ax")
    a.call("hex16")
    a.i([0xB0, 0x3A], "mov $0x3a,%al")
    a.call("putc")
    a.i([0xBA, 0x10, 0x00], "mov $16,%dx")
    a.label("irtb")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0xAC], "lods %ds:(%si),%al")
    a.call("hex8")
    a.i([0x4A], "dec %dx")
    a.jcc("jnz", "irtb")
    a.call("crlf")
    a.i([0x49], "dec %cx")
    a.jcc("jnz", "irtl")
    a.label("irtdone")
    a.i([0x80, 0x3E, A("nflag"), 0x00], "cmpb $0,@nflag")
    a.jcc("jz", "nonote")
    a.i([0xBE, A("s_non")], "mov $@s_non,%si")
    a.call("puts")
    a.label("nonote")
    a.call("crlf")

    # --- save 0CF8h
    a.i([0xBA, 0xF8, 0x0C], "mov $0xcf8,%dx")
    a.i([0x66, 0xED], "in (%dx),%eax", "32-bit read of CONFIG_ADDRESS")
    a.i([0x66, 0xA3, A("savecf8")], "mov %eax,@savecf8")
    a.i([0xBE, A("s_cf8")], "mov $@s_cf8,%si")
    a.call("puts")
    a.call("hex32")
    a.call("crlf")
    a.call("crlf")

    # --- PCI walk. EBX = 80000000h | bus<<16 | dev<<11 | func<<8
    a.i([0x66, 0xBB, 0x00, 0x00, 0x00, 0x80], "mov $0x80000000,%ebx",
        "enable bit, bus 0 dev 0 fn 0")
    a.label("scan")
    a.i([0x30, 0xC9], "xor %cl,%cl", "offset 0: vendor/device")
    a.call("cfgrd")
    a.i([0x83, 0xF8, 0xFF], "cmp $0xffff,%ax", "vendor FFFFh = no function")
    a.jcc("jz", "absent")
    a.call("dump")
    a.call("nhichk", "/N: BAR0 registers of a known NHI")
    a.i([0xF6, 0xC7, 0x07], "test $7,%bh", "function number != 0?")
    a.jcc("jnz", "next")
    a.i([0xB1, 0x0C], "mov $0x0c,%cl")
    a.call("cfgrd", "header type is byte 0Eh")
    a.i([0x66, 0xA9, 0x00, 0x00, 0x80, 0x00], "test $0x800000,%eax",
        "bit 7 of header type: multi-function")
    a.jcc("jnz", "next")
    a.jmp("skipdev", "single function: skip fn 1-7")
    a.label("absent")
    a.i([0xF6, 0xC7, 0x07], "test $7,%bh")
    a.jcc("jnz", "next", "absent fn 1-7: try next fn")
    a.label("skipdev")
    a.i([0x80, 0xCF, 0x07], "or $7,%bh", "absent fn 0: skip whole device")
    a.label("next")
    a.i([0x66, 0x81, 0xC3, 0x00, 0x01, 0x00, 0x00], "add $0x100,%ebx")
    a.i([0x66, 0x81, 0xFB, 0x00, 0x00, 0x00, 0x81], "cmp $0x81000000,%ebx",
        "past bus 255?")
    a.jcc("jb", "scan")

    # --- restore 0CF8h, summary, exit
    a.i([0x66, 0xA1, A("savecf8")], "mov @savecf8,%eax")
    a.i([0xBA, 0xF8, 0x0C], "mov $0xcf8,%dx")
    a.i([0x66, 0xEF], "out %eax,(%dx)", "restore CONFIG_ADDRESS")
    a.i([0xBE, A("s_end")], "mov $@s_end,%si")
    a.call("puts")
    a.i([0xA1, A("count")], "mov @count,%ax")
    a.call("hex16")
    a.call("crlf")
    a.call("flush")
    a.i([0xB8, 0x00, 0x4C], "mov $0x4c00,%ax")
    a.i([0xCD, 0x21], "int $0x21", "exit 0")

    # --- cfgrd: EAX = config dword at (EBX | CL). Preserves all else.
    a.label("cfgrd")
    a.i([0x52], "push %dx")
    a.i([0x66, 0x89, 0xD8], "mov %ebx,%eax")
    a.i([0x08, 0xC8], "or %cl,%al", "register offset, dword aligned")
    a.i([0xBA, 0xF8, 0x0C], "mov $0xcf8,%dx")
    a.i([0xFA], "cli")
    a.i([0x66, 0xEF], "out %eax,(%dx)", "32-bit write CONFIG_ADDRESS")
    a.i([0xB2, 0xFC], "mov $0xfc,%dl", "DX = 0CFCh")
    a.i([0x66, 0xED], "in (%dx),%eax", "32-bit read CONFIG_DATA")
    a.i([0xFB], "sti")
    a.i([0x5A], "pop %dx")
    a.i([0xC3], "ret")

    # --- dump: header line and 16 lines of 16 bytes for function EBX.
    a.label("dump")
    a.i([0xFF, 0x06, A("count")], "incw @count")
    a.i([0x66, 0x50], "push %eax", "vendor/device")
    a.i([0x66, 0x89, 0xD8], "mov %ebx,%eax")
    a.i([0x66, 0xC1, 0xE8, 0x10], "shr $16,%eax", "AL = bus")
    a.call("hex8")
    a.i([0xB0, 0x3A], "mov $0x3a,%al", "':'")
    a.call("putc")
    a.i([0x89, 0xD8], "mov %bx,%ax")
    a.i([0xC1, 0xE8, 0x0B], "shr $11,%ax", "AL = device")
    a.call("hex8")
    a.i([0xB0, 0x2E], "mov $0x2e,%al", "'.'")
    a.call("putc")
    a.i([0x88, 0xF8], "mov %bh,%al")
    a.i([0x24, 0x07], "and $7,%al", "function")
    a.i([0x04, 0x30], "add $0x30,%al")
    a.call("putc")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0x66, 0x58], "pop %eax")
    a.call("hex16", "vendor")
    a.i([0xB0, 0x3A], "mov $0x3a,%al")
    a.call("putc")
    a.i([0x66, 0xC1, 0xE8, 0x10], "shr $16,%eax")
    a.call("hex16", "device")
    a.call("crlf")
    a.i([0x30, 0xC9], "xor %cl,%cl", "CL = config offset")
    a.label("dline")
    a.i([0x88, 0xC8], "mov %cl,%al")
    a.call("hex8", "line offset")
    a.i([0xB0, 0x3A], "mov $0x3a,%al")
    a.call("putc")
    a.label("ddword")
    a.call("cfgrd")
    a.i([0xBD, 0x04, 0x00], "mov $4,%bp", "4 bytes, little endian")
    a.label("dbyte")
    a.i([0x50], "push %ax")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0x58], "pop %ax")
    a.call("hex8")
    a.i([0x66, 0xC1, 0xE8, 0x08], "shr $8,%eax")
    a.i([0x4D], "dec %bp")
    a.jcc("jnz", "dbyte")
    a.i([0x80, 0xC1, 0x04], "add $4,%cl")
    a.i([0xF6, 0xC1, 0x0F], "test $0x0f,%cl")
    a.jcc("jnz", "ddword", "16 bytes per line")
    a.call("crlf")
    a.i([0x08, 0xC9], "or %cl,%cl")
    a.jcc("jnz", "dline", "CL wraps to 0 after 256 bytes")
    a.call("crlf")
    a.i([0xC3], "ret")

    # --- rsdscan: AX = first segment, CX = paragraphs. Uses FS, SI.
    a.label("rsdscan")
    a.i([0x8E, 0xE0], "mov %ax,%fs")
    a.i([0x64, 0x66, 0x81, 0x3E, 0x00, 0x00, 0x52, 0x53, 0x44, 0x20],
        "cmpl $0x20445352,%fs:0", "'RSD '")
    a.jcc("jnz", "rsnext")
    a.i([0x64, 0x66, 0x81, 0x3E, 0x04, 0x00, 0x50, 0x54, 0x52, 0x20],
        "cmpl $0x20525450,%fs:4", "'PTR '")
    a.jcc("jnz", "rsnext")
    a.i([0x50], "push %ax")
    a.i([0x51], "push %cx")
    a.i([0xBE, A("s_rsdp")], "mov $@s_rsdp,%si")
    a.call("puts")
    a.call("hex16", "segment; linear = segment * 16")
    a.i([0xB0, 0x3A], "mov $0x3a,%al")
    a.call("putc")
    a.i([0x31, 0xF6], "xor %si,%si")
    a.i([0xB9, 0x24, 0x00], "mov $36,%cx", "ACPI 2.0 RSDP length")
    a.label("rsbyte")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0x64, 0xAC], "lods %fs:(%si),%al")
    a.call("hex8")
    a.i([0x49], "dec %cx")
    a.jcc("jnz", "rsbyte")
    a.call("crlf")
    a.i([0x59], "pop %cx")
    a.i([0x58], "pop %ax")
    a.label("rsnext")
    a.i([0x40], "inc %ax", "next paragraph")
    a.i([0x49], "dec %cx")
    a.jcc("jnz", "rsdscan")
    a.i([0xC3], "ret")

    # --- pirdump: FS:SI = $PIR table. Header line, then 16 bytes per line.
    a.label("pirdump")
    a.i([0x56], "push %si")
    a.i([0x89, 0xF3], "mov %si,%bx", "BX = table offset")
    a.i([0xBE, A("s_pir")], "mov $@s_pir,%si")
    a.call("puts")
    a.i([0x89, 0xD8], "mov %bx,%ax")
    a.call("hex16")
    a.i([0xBE, A("s_size")], "mov $@s_size,%si")
    a.call("puts")
    a.i([0x64, 0x8B, 0x4F, 0x06], "mov %fs:6(%bx),%cx", "table size (header word 6)")
    a.i([0x89, 0xC8], "mov %cx,%ax")
    a.call("hex16")
    a.i([0x83, 0xF9, 0x20], "cmp $32,%cx")
    a.jcc("jb", "pirbad", "smaller than the 32-byte header")
    a.i([0x81, 0xF9, 0x00, 0x10], "cmp $0x1000,%cx")
    a.jcc("ja", "pirbad", "implausibly large")
    a.i([0x30, 0xD2], "xor %dl,%dl")
    a.i([0x89, 0xDE], "mov %bx,%si")
    a.i([0x89, 0xCD], "mov %cx,%bp")
    a.label("pirs")
    a.i([0x64, 0x02, 0x14], "add %fs:(%si),%dl", "checksum: all bytes sum to 0")
    a.i([0x46], "inc %si")
    a.i([0x4D], "dec %bp")
    a.jcc("jnz", "pirs")
    a.i([0xBE, A("s_sum")], "mov $@s_sum,%si")
    a.call("puts")
    a.i([0x88, 0xD0], "mov %dl,%al")
    a.call("hex8")
    a.call("crlf")
    a.i([0x89, 0xDE], "mov %bx,%si")
    a.i([0xC1, 0xE9, 0x04], "shr $4,%cx", "16-byte lines: 2 header lines, then one per slot")
    a.label("pirln")
    a.i([0x56], "push %si")
    a.i([0xBE, A("s_pirl")], "mov $@s_pirl,%si")
    a.call("puts")
    a.i([0x5E], "pop %si")
    a.i([0x89, 0xF0], "mov %si,%ax")
    a.i([0x29, 0xD8], "sub %bx,%ax")
    a.call("hex16", "offset in the table")
    a.i([0xB0, 0x3A], "mov $0x3a,%al")
    a.call("putc")
    a.i([0xBD, 0x10, 0x00], "mov $16,%bp")
    a.label("pirb")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0x64, 0xAC], "lods %fs:(%si),%al")
    a.call("hex8")
    a.i([0x4D], "dec %bp")
    a.jcc("jnz", "pirb")
    a.call("crlf")
    a.i([0x49], "dec %cx")
    a.jcc("jnz", "pirln")
    a.label("pirret")
    a.i([0x5E], "pop %si")
    a.i([0xC3], "ret")
    a.label("pirbad")
    a.i([0xBE, A("s_bad")], "mov $@s_bad,%si")
    a.call("puts")
    a.call("crlf")
    a.jmp("pirret")

    # --- nhichk (/N only): after the dump of function EBX, if it is a known
    # Intel Thunderbolt/USB4 NHI with BAR0 decoded below 4 GB, read the five
    # allow-listed BAR0 dwords in big real mode. Never 37800h-37817h.
    a.label("nhichk")
    a.i([0x66, 0x53], "push %ebx")
    a.i([0x80, 0x3E, A("nflag"), 0x00], "cmpb $0,@nflag")
    a.jcc("jz", "nret")
    a.i([0x30, 0xC9], "xor %cl,%cl")
    a.call("cfgrd")
    a.i([0x3D, 0x86, 0x80], "cmp $0x8086,%ax")
    a.jcc("jnz", "nret")
    a.i([0x66, 0xC1, 0xE8, 0x10], "shr $16,%eax", "AX = device ID")
    a.i([0xBE, A("nhiids")], "mov $@nhiids,%si")
    a.label("nidl")
    a.i([0x83, 0x3C, 0x00], "cmpw $0,(%si)")
    a.jcc("jz", "nret", "not in the table")
    a.i([0x3B, 0x04], "cmp (%si),%ax")
    a.jcc("jz", "nfound")
    a.i([0x83, 0xC6, 0x02], "add $2,%si")
    a.jmp("nidl")
    a.label("nfound")
    a.i([0xB1, 0x04], "mov $4,%cl")
    a.call("cfgrd")
    a.i([0x89, 0xC5], "mov %ax,%bp", "BP = command register")
    a.i([0xB1, 0x10], "mov $0x10,%cl")
    a.call("cfgrd")
    a.i([0x66, 0x89, 0xC2], "mov %eax,%edx", "EDX = BAR0 as programmed")
    a.i([0xBE, A("s_nhi")], "mov $@s_nhi,%si")
    a.call("puts")
    a.i([0x66, 0x89, 0xD0], "mov %edx,%eax")
    a.call("hex32")
    a.i([0xBE, A("s_cmd")], "mov $@s_cmd,%si")
    a.call("puts")
    a.i([0x89, 0xE8], "mov %bp,%ax")
    a.call("hex16")
    a.i([0xBE, A("s_nio")], "mov $@s_nio,%si")
    a.i([0xF6, 0xC2, 0x01], "test $1,%dl")
    a.jcc("jnz", "nmsg", "I/O BAR")
    a.i([0xBE, A("s_ndec")], "mov $@s_ndec,%si")
    a.i([0xF7, 0xC5, 0x02, 0x00], "test $2,%bp")
    a.jcc("jz", "nmsg", "memory decode off")
    a.i([0xBE, A("s_n64")], "mov $@s_n64,%si")
    a.i([0xF6, 0xC2, 0x04], "test $4,%dl")
    a.jcc("jz", "n32")
    a.i([0xB1, 0x14], "mov $0x14,%cl")
    a.call("cfgrd")
    a.i([0x66, 0x09, 0xC0], "or %eax,%eax")
    a.jcc("jnz", "nmsg", "64-bit BAR above 4 GB")
    a.label("n32")
    a.i([0xBE, A("s_nzero")], "mov $@s_nzero,%si")
    a.i([0x66, 0x83, 0xE2, 0xF0], "and $0xfffffff0,%edx")
    a.jcc("jz", "nmsg", "not assigned")
    a.i([0xBE, A("s_nv86")], "mov $@s_nv86,%si")
    a.i([0x0F, 0x01, 0xE0], "smsw %ax")
    a.i([0xA8, 0x01], "test $1,%al")
    a.jcc("jnz", "nmsg", "V86 (EMM386, Windows): no big real mode")
    a.i([0x66, 0x52], "push %edx")
    a.call("a20on")
    a.i([0x66, 0x5A], "pop %edx")
    a.i([0xBE, A("s_na20")], "mov $@s_na20,%si")
    a.i([0x66, 0xF7, 0xC2, 0x00, 0x00, 0x10, 0x00], "test $0x00100000,%edx")
    a.jcc("jz", "nok", "bit 20 clear: A20 state does not matter")
    a.i([0x84, 0xC0], "test %al,%al")
    a.jcc("jz", "nmsg", "A20 could not be enabled")
    a.label("nok")
    a.call("crlf")
    a.call("nread")
    a.call("a20off")
    a.i([0xBE, A("s_nregs")], "mov $@s_nregs,%si")
    a.call("puts")
    a.i([0x31, 0xDB], "xor %bx,%bx")
    a.label("nprl")
    a.i([0xB0, 0x20], "mov $0x20,%al")
    a.call("putc")
    a.i([0x66, 0x8B, 0x87, A("nhioffs")], "mov @nhioffs(%bx),%eax")
    a.call("hex32", "offset")
    a.i([0xB0, 0x3D], "mov $0x3d,%al", "'='")
    a.call("putc")
    a.i([0x66, 0x8B, 0x87, A("nhival")], "mov @nhival(%bx),%eax")
    a.call("hex32")
    a.i([0x83, 0xC3, 0x04], "add $4,%bx")
    a.i([0x83, 0xFB, 0x14], "cmp $20,%bx")
    a.jcc("jb", "nprl")
    a.call("crlf")
    a.call("crlf")
    a.jmp("nret")
    a.label("nmsg")
    a.call("puts")
    a.call("crlf")
    a.call("crlf")
    a.label("nret")
    a.i([0x66, 0x5B], "pop %ebx")
    a.i([0xC3], "ret")
    # nread: EDX = BAR0 base. FS gets a 4 GB limit, then five 32-bit loads.
    a.label("nread")
    a.i([0x66, 0x31, 0xC0], "xor %eax,%eax")
    a.i([0x8C, 0xC8], "mov %cs,%ax")
    a.i([0x66, 0xC1, 0xE0, 0x04], "shl $4,%eax")
    a.i([0x66, 0x31, 0xC9], "xor %ecx,%ecx")
    a.i([0xB9, A("gdt")], "mov $@gdt,%cx")
    a.i([0x66, 0x01, 0xC8], "add %ecx,%eax", "linear address of the GDT")
    a.i([0x66, 0xA3, A("gdtb")], "mov %eax,@gdtb")
    a.i([0x31, 0xDB], "xor %bx,%bx")
    a.i([0xFA], "cli")
    a.i([0x0F, 0x01, 0x16, A("gdtr")], "lgdt @gdtr")
    a.i([0x0F, 0x20, 0xC0], "mov %cr0,%eax")
    a.i([0x0C, 0x01], "or $1,%al", "protected mode")
    a.i([0x0F, 0x22, 0xC0], "mov %eax,%cr0")
    a.i([0xEB, 0x00], "jmp .+2")
    a.i([0xB9, 0x08, 0x00], "mov $8,%cx")
    a.i([0x8E, 0xE1], "mov %cx,%fs", "flat data descriptor: base 0, limit 4 GB")
    a.i([0x24, 0xFE], "and $0xfe,%al", "back to real mode, FS keeps its limit")
    a.i([0x0F, 0x22, 0xC0], "mov %eax,%cr0")
    a.i([0xEB, 0x00], "jmp .+2")
    a.i([0x31, 0xC9], "xor %cx,%cx")
    a.i([0x8E, 0xE1], "mov %cx,%fs")
    a.label("nrl")
    a.i([0x66, 0x89, 0xD6], "mov %edx,%esi")
    a.i([0x66, 0x03, 0xB7, A("nhioffs")], "add @nhioffs(%bx),%esi")
    a.i([0x64, 0x67, 0x66, 0x8B, 0x06], "addr32 mov %fs:(%esi),%eax", "one aligned 32-bit load")
    a.i([0x66, 0x89, 0x87, A("nhival")], "mov %eax,@nhival(%bx)")
    a.i([0x83, 0xC3, 0x04], "add $4,%bx")
    a.i([0x83, 0xFB, 0x14], "cmp $20,%bx")
    a.jcc("jb", "nrl")
    a.i([0xFB], "sti")
    a.i([0xC3], "ret")
    # a20on: AL = 1 if the XMS driver enabled A20 (local enable, undone by a20off)
    a.label("a20on")
    a.i([0xC6, 0x06, A("a20"), 0x00], "movb $0,@a20")
    a.i([0x06], "push %es")
    a.i([0x53], "push %bx")
    a.i([0xB8, 0x00, 0x43], "mov $0x4300,%ax")
    a.i([0xCD, 0x2F], "int $0x2f", "XMS driver installed?")
    a.i([0x3C, 0x80], "cmp $0x80,%al")
    a.jcc("jnz", "a20t")
    a.i([0xB8, 0x10, 0x43], "mov $0x4310,%ax")
    a.i([0xCD, 0x2F], "int $0x2f", "ES:BX = XMS entry")
    a.i([0x89, 0x1E, A("xms")], "mov %bx,@xms")
    a.i([0x8C, 0x06, A("xmss")], "mov %es,@xmss")
    a.i([0xB4, 0x05], "mov $0x05,%ah", "local enable A20")
    a.i([0xFF, 0x1E, A("xms")], "lcall *@xms")
    a.i([0x83, 0xF8, 0x01], "cmp $1,%ax")
    # XMS present but the local enable failed (seen on the P14s Gen 1,
    # whose HIMEM reports no HMA): A20 may still be on (many chipsets keep
    # it on), so fall back to the wrap test instead of giving up.
    a.jcc("jnz", "a20t", "local enable failed: test the wrap")
    a.i([0xC6, 0x06, A("a20"), 0x01], "movb $1,@a20")
    a.label("a20x")
    a.i([0x5B], "pop %bx")
    a.i([0x07], "pop %es")
    a.i([0xA0, A("a20")], "mov @a20,%al")
    a.i([0xC3], "ret")
    # a20t: no XMS, or its local enable failed. Read-only test: if 0000:0000 and FFFF:0010 (1 MB) hold
    # the same 64 bytes, addresses wrap and A20 is off.
    a.label("a20t")
    a.i([0x1E], "push %ds")
    a.i([0x56], "push %si")
    a.i([0x57], "push %di")
    a.i([0x51], "push %cx")
    a.i([0x31, 0xC0], "xor %ax,%ax")
    a.i([0x8E, 0xD8], "mov %ax,%ds")
    a.i([0x31, 0xF6], "xor %si,%si")
    a.i([0xB8, 0xFF, 0xFF], "mov $0xffff,%ax")
    a.i([0x8E, 0xC0], "mov %ax,%es")
    a.i([0xBF, 0x10, 0x00], "mov $0x10,%di")
    a.i([0xB9, 0x20, 0x00], "mov $32,%cx")
    a.i([0xF3, 0xA7], "repe cmpsw")
    a.i([0x59], "pop %cx")
    a.i([0x5F], "pop %di")
    a.i([0x5E], "pop %si")
    a.i([0x1F], "pop %ds")
    a.jcc("jz", "a20x", "identical: A20 off")
    a.i([0x5B], "pop %bx")
    a.i([0x07], "pop %es")
    a.i([0xB0, 0x01], "mov $1,%al", "A20 already on, nothing to undo")
    a.i([0xC3], "ret")
    a.label("a20off")
    a.i([0x80, 0x3E, A("a20"), 0x00], "cmpb $0,@a20")
    a.jcc("jz", "a20r")
    a.i([0x53], "push %bx")
    a.i([0xB4, 0x06], "mov $0x06,%ah", "local disable A20")
    a.i([0xFF, 0x1E, A("xms")], "lcall *@xms")
    a.i([0x5B], "pop %bx")
    a.label("a20r")
    a.i([0xC3], "ret")

    # --- output helpers. putc appends AL to the buffer at DI.
    a.label("hex32")
    a.i([0x66, 0x50], "push %eax")
    a.i([0x66, 0xC1, 0xE8, 0x10], "shr $16,%eax")
    a.call("hex16")
    a.i([0x66, 0x58], "pop %eax")
    a.label("hex16")
    a.i([0x50], "push %ax", "hex32 falls through to here")
    a.i([0x88, 0xE0], "mov %ah,%al")
    a.call("hex8")
    a.i([0x58], "pop %ax")
    a.label("hex8")
    a.i([0x50], "push %ax", "hex16 falls through to here")
    a.i([0x50], "push %ax")
    a.i([0xC0, 0xE8, 0x04], "shr $4,%al")
    a.call("nib")
    a.i([0x58], "pop %ax")
    a.i([0x24, 0x0F], "and $0x0f,%al")
    a.call("nib")
    a.i([0x58], "pop %ax")
    a.i([0xC3], "ret")
    a.label("nib")
    a.i([0x04, 0x30], "add $0x30,%al")
    a.i([0x3C, 0x39], "cmp $0x39,%al")
    a.jcc("jbe", "putc")
    a.i([0x04, 0x27], "add $0x27,%al", "'a'-'9'-1, lower case like lspci")
    a.label("putc")
    a.i([0xAA], "stos %al,%es:(%di)")
    a.i([0x81, 0xFF, A("bufend")], "cmp $@bufend,%di")
    a.jcc("jb", "pret")
    a.call("flush")
    a.label("pret")
    a.i([0xC3], "ret")
    a.label("crlf")
    a.i([0xB0, 0x0D], "mov $0x0d,%al")
    a.call("putc")
    a.i([0xB0, 0x0A], "mov $0x0a,%al")
    a.jmp("putc")
    a.label("puts")
    a.i([0xAC], "lods %ds:(%si),%al")
    a.i([0x08, 0xC0], "or %al,%al")
    a.jcc("jz", "pret")
    a.call("putc")
    a.jmp("puts")
    a.label("flush")
    a.i([0x50], "push %ax", "write buffer to stdout (handle 1)")
    a.i([0x53], "push %bx")
    a.i([0x51], "push %cx")
    a.i([0x52], "push %dx")
    a.i([0x89, 0xF9], "mov %di,%cx")
    a.i([0xBA, A("buf")], "mov $@buf,%dx")
    a.i([0x29, 0xD1], "sub %dx,%cx")
    a.jcc("jz", "fl_done")
    a.i([0xBB, 0x01, 0x00], "mov $1,%bx")
    a.i([0xB4, 0x40], "mov $0x40,%ah", "INT 21h AH=40h write")
    a.i([0xCD, 0x21], "int $0x21")
    a.label("fl_done")
    a.i([0xBF, A("buf")], "mov $@buf,%di")
    a.i([0x5A], "pop %dx")
    a.i([0x59], "pop %cx")
    a.i([0x5B], "pop %bx")
    a.i([0x58], "pop %ax")
    a.i([0xC3], "ret")

    # --- data
    s("s_hdr", "# PCIDUMP 1.2 (usb4-emu tools/p14s-capture/win98): "
               "PCI mechanism #1, 256 bytes per function\r\n"
               "# Decode on Linux: lspci -F PCIDUMP.TXT -vvnn\r\n")
    s("s_dos", "# DOS version AH.AL=")
    s("s_win", " INT2F/1600 AX=")
    s("s_bios", "# PCI BIOS B101: ax=")
    s("s_sp", " ")
    s("s_fl", " flags=")
    s("s_rsdp", "# RSDP at segment ")
    s("s_cf8", "# CF8 before walk=")
    s("s_end", "# end. functions found=")
    s("s_pir", "# $PIR at F000:")
    s("s_size", " size=")
    s("s_sum", " checksum(00=ok)=")
    s("s_bad", " bad size, not dumped")
    s("s_pirl", "# PIR ")
    s("s_irt", "# PCI BIOS B10E: ax=")
    s("s_irtbx", " bx(PCI-only IRQs)=")
    s("s_irtl", "# IRT ")
    s("s_non", "# /N: NHI BAR0 reads on")
    s("s_nhi", "# NHI BAR0=")
    s("s_cmd", " cmd=")
    s("s_nio", " I/O BAR, not read")
    s("s_ndec", " memory decode off, not read")
    s("s_n64", " above 4 GB, not read")
    s("s_nzero", " not assigned, not read")
    s("s_nv86", " V86 mode (EMM386 or Windows), not read")
    s("s_na20", " A20 off (XMS local enable failed or no XMS, addresses wrap), not read")
    s("s_nregs", "# NHI regs:")
    # Intel NHI device IDs (Alpine, Titan, Maple Ridge; Ice, Tiger, Alder
    # Lake), 0-terminated. Only these get BAR0 reads under /N.
    a.label("nhiids")
    for d in (0x1575, 0x1577, 0x15BF, 0x15D2, 0x15D9, 0x15E8, 0x15EB,
              0x1134, 0x1137, 0x8A0D, 0x8A17, 0x9A1B, 0x9A1D, 0x463E,
              0x466D, 0):
        a.db(d.to_bytes(2, "little"))
    # The only BAR0 offsets /N reads (README: never 37800h-37817h).
    a.label("nhioffs")
    for o in NHI_OFFSETS:
        a.db(o.to_bytes(4, "little"))
    a.label("nhival")
    a.db([0] * 4 * len(NHI_OFFSETS))
    # Flat 4 GB data descriptor for big real mode (selector 8).
    a.label("gdt")
    a.db([0] * 8 + [0xFF, 0xFF, 0, 0, 0, 0x92, 0xCF, 0])
    a.label("gdtr")
    a.db([15, 0, 0, 0, 0, 0])
    a.equ("gdtb", "gdtr", 2)
    a.label("xms")
    a.db([0, 0, 0, 0])
    a.equ("xmss", "xms", 2)
    a.label("irtreq")
    a.db([0] * 6)
    a.equ("irtreqo", "irtreq", 2)
    a.equ("irtreqs", "irtreq", 4)
    a.label("nflag")
    a.db([0])
    a.label("a20")
    a.db([0])
    a.label("savecf8")
    a.db([0, 0, 0, 0])
    a.label("count")
    a.db([0, 0])
    a.label("buf")
    a.equ("bufend", "buf", BUFSZ)
    # INT 1Ah B10Eh data buffer (IRTBUF bytes) right after the output buffer.
    a.equ("irtbuf", "buf", BUFSZ)
    # The buffer itself lives past the end of the file; a .COM gets a
    # full 64 KB segment, so only the label addresses are needed.
    return a


def debug_script(com):
    """MS-DOS DEBUG input that writes PCIDUMP.COM."""
    out = ["n PCIDUMP.COM"]
    for k in range(0, len(com), 16):
        out.append("e %04X %s" % (ORG + k, " ".join("%02X" % b
                                                   for b in com[k:k + 16])))
    out += ["r bx", "0", "r cx", "%04X" % len(com), "w", "q", ""]
    return "\r\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--check-gas", nargs=2, metavar=("AS", "OBJCOPY"))
    args = ap.parse_args()

    a = build()
    com, lst, labels = a.assemble()
    with open(os.path.join(args.outdir, "PCIDUMP.COM"), "wb") as f:
        f.write(com)
    with open(os.path.join(args.outdir, "PCIDUMP.LST"), "w", newline="\r\n") as f:
        f.write("; PCIDUMP.COM listing, generated by gen_pcidump.py. "
                "%d bytes, ORG 100h.\n; Source column is GNU as AT&T "
                "syntax (.code16); --check-gas verifies the bytes.\n"
                % len(com))
        f.write("\n".join(lst) + "\n")
    with open(os.path.join(args.outdir, "MKPCIDMP.SCR"), "w", newline="") as f:
        f.write(debug_script(com))
    print("PCIDUMP.COM %d bytes, buffer %04X-%04X" %
          (len(com), labels["buf"], labels["bufend"]))

    if args.check_gas:
        asm, objcopy = args.check_gas
        src = a.gas_source()
        with tempfile.TemporaryDirectory() as td:
            s = os.path.join(td, "p.s")
            o = os.path.join(td, "p.o")
            b = os.path.join(td, "p.bin")
            with open(s, "w") as f:
                f.write(src)
            subprocess.check_call([asm, "-o", o, s])
            subprocess.check_call([objcopy, "-O", "binary", "-j", ".text", o, b])
            with open(b, "rb") as f:
                ref = f.read()
        if ref[:len(com)] != com or any(x != 0x90 for x in ref[len(com):]):
            for k, (x, y) in enumerate(zip(com, ref)):
                if x != y:
                    sys.exit("GNU as mismatch at %04X: ours %02X gas %02X" %
                             (ORG + k, x, y))
            sys.exit("GNU as mismatch in length: ours %d gas %d" %
                     (len(com), len(ref)))
        print("GNU as cross-check: identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
