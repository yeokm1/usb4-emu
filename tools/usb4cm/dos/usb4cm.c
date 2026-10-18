/*
 * usb4cm.c - USB4CM.EXE, a DOS front-end for the usb4cm core.
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project. Open Watcom 2.0,
 * 32-bit flat model under the DOS/32A extender (the same approach as
 * xhci98's XHCIQUAL.EXE, no code copied). It
 *
 *   1. finds the USB4 host interface by PCI class 0C0340h through PCI
 *      configuration mechanism #1 (ports CF8h/CFCh),
 *   2. maps BAR0 with DPMI 0800h and enables memory decode and bus
 *      mastering,
 *   3. allocates the ring 0 DMA block in conventional memory (DPMI
 *      0100h), where linear == physical and below 1 MB,
 *   4. runs the core: host router, device router, lane bonding and the
 *      PCIe tunnel, by polling only, and
 *   5. rescans the secondary bus of every PCI-to-PCI bridge until the
 *      NVMe behind the tunnel (1B36:0010) answers.
 *
 * This product uses DOS/32 Advanced DOS Extender technology.
 */
#include <i86.h>
#include <conio.h>
#include <dos.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usb4cm.h"

/* callbacks ignore their context: one host interface per run */
#pragma off (unreferenced)

#define PCI_ADDR    0xcf8
#define PCI_DATA    0xcfc
#define BAR_MAP     0x40000UL       /* the host interface register file */

static int verbose;
static FILE *logf;

/* ------------------------------------------------------------------ */
/* PCI configuration mechanism #1                                       */
/* ------------------------------------------------------------------ */

static u32 cfg_addr(unsigned b, unsigned d, unsigned f, unsigned off)
{
    return 0x80000000UL | ((u32)b << 16) | ((u32)d << 11) |
           ((u32)f << 8) | (off & 0xfc);
}

static u32 pci_rd32(unsigned b, unsigned d, unsigned f, unsigned off)
{
    outpd(PCI_ADDR, cfg_addr(b, d, f, off));
    return inpd(PCI_DATA);
}

static void pci_wr32(unsigned b, unsigned d, unsigned f, unsigned off,
                     u32 v)
{
    outpd(PCI_ADDR, cfg_addr(b, d, f, off));
    outpd(PCI_DATA, v);
}

/* ------------------------------------------------------------------ */
/* DPMI                                                                 */
/* ------------------------------------------------------------------ */

static void *dpmi_map_phys(u32 phys, u32 size)
{
    union REGS r;

    memset(&r, 0, sizeof(r));
    r.w.ax = 0x0800;
    r.w.bx = (unsigned short)(phys >> 16);
    r.w.cx = (unsigned short)(phys & 0xffff);
    r.w.si = (unsigned short)(size >> 16);
    r.w.di = (unsigned short)(size & 0xffff);
    int386(0x31, &r, &r);
    if (r.w.cflag) {
        return 0;
    }
    return (void *)(((u32)r.w.bx << 16) | r.w.cx);
}

/* Conventional memory: flat model, linear == physical below 1 MB */
static void *dos_alloc(u32 bytes, u32 *phys)
{
    union REGS r;

    memset(&r, 0, sizeof(r));
    r.w.ax = 0x0100;
    r.w.bx = (unsigned short)((bytes + 15) >> 4);
    int386(0x31, &r, &r);
    if (r.w.cflag) {
        return 0;
    }
    *phys = (u32)r.w.ax << 4;
    return (void *)*phys;
}

/* ------------------------------------------------------------------ */
/* Core callbacks                                                       */
/* ------------------------------------------------------------------ */

static volatile u8 *bar0;

static u32 cb_rd(void *ctx, u32 off)
{
    return *(volatile u32 *)(bar0 + off);
}

static void cb_wr(void *ctx, u32 off, u32 v)
{
    *(volatile u32 *)(bar0 + off) = v;
}

static void *cb_dma_alloc(void *ctx, u32 size, u32 align, u32 *phys)
{
    u32 raw;
    u8 *p = (u8 *)dos_alloc(size + align, &raw);

    if (!p) {
        return 0;
    }
    *phys = (raw + align - 1) & ~(align - 1);
    memset((void *)*phys, 0, size);
    return (void *)*phys;
}

static void cb_udelay(void *ctx, u32 us)
{
    delay((unsigned)((us + 999) / 1000));
}

static void cb_log(void *ctx, int lvl, const char *fmt, u32 a, u32 b,
                   u32 c, u32 d)
{
    if (lvl == U4_LOG_DBG && !verbose) {
        return;
    }
    printf(lvl == U4_LOG_ERR ? "  ! " : "    ");
    printf(fmt, a, b, c, d);
    printf("\n");
    if (logf) {
        fprintf(logf, lvl == U4_LOG_ERR ? "  ! " : "    ");
        fprintf(logf, fmt, a, b, c, d);
        fprintf(logf, "\n");
    }
}

static void cb_logs(void *ctx, int lvl, const char *pfx, const char *s)
{
    printf("    %s%s\n", pfx, s);
    if (logf) {
        fprintf(logf, "    %s%s\n", pfx, s);
    }
}

static const U4CM_OPS ops = {
    0, cb_rd, cb_wr, cb_dma_alloc, cb_udelay, cb_log, cb_logs
};

/* printf to the screen and the log file */
static void out(const char *fmt, u32 a, u32 b, u32 c, u32 d)
{
    printf(fmt, a, b, c, d);
    if (logf) {
        fprintf(logf, fmt, a, b, c, d);
    }
}

/* ------------------------------------------------------------------ */
/* Finding the host interface and the NVMe                              */
/* ------------------------------------------------------------------ */

static int find_host(unsigned *bus, unsigned *dev, unsigned *fn)
{
    unsigned b, d, f, nf;
    u32 id;

    for (b = 0; b < 256; b++) {
        for (d = 0; d < 32; d++) {
            id = pci_rd32(b, d, 0, 0);
            if ((id & 0xffff) == 0xffff) {
                continue;
            }
            nf = (pci_rd32(b, d, 0, 0x0c) & 0x00800000UL) ? 8 : 1;
            for (f = 0; f < nf; f++) {
                if ((pci_rd32(b, d, f, 0) & 0xffff) == 0xffff) {
                    continue;
                }
                /* Class 0Ch, subclass 03h, prog-if 40h: USB4 host */
                if ((pci_rd32(b, d, f, 0x08) >> 8) == 0x0c0340UL) {
                    *bus = b;
                    *dev = d;
                    *fn = f;
                    return 1;
                }
            }
        }
    }
    return 0;
}

/*
 * Scan the secondary bus of every PCI-to-PCI bridge (header type 1).
 * Returns the number of NVMe controllers (1B36:0010, or class 010802h)
 * seen; prints every function found when @print.
 */
static int scan_bridges(int print)
{
    unsigned b, d, f, sb, sd, sf, nf;
    u32 id, cls;
    int found = 0;

    for (b = 0; b < 256; b++) {
        for (d = 0; d < 32; d++) {
            if ((pci_rd32(b, d, 0, 0) & 0xffff) == 0xffff) {
                continue;
            }
            nf = (pci_rd32(b, d, 0, 0x0c) & 0x00800000UL) ? 8 : 1;
            for (f = 0; f < nf; f++) {
                id = pci_rd32(b, d, f, 0);
                if ((id & 0xffff) == 0xffff ||
                    ((pci_rd32(b, d, f, 0x0c) >> 16) & 0x7f) != 1) {
                    continue;
                }
                sb = (unsigned)((pci_rd32(b, d, f, 0x18) >> 8) & 0xff);
                if (sb == 0 || sb <= b) {
                    continue;
                }
                if (print) {
                    out("  bridge %02lx:%02lx.%lx, secondary bus %02lx:\n",
                        b, d, f, sb);
                }
                for (sd = 0; sd < 32; sd++) {
                    for (sf = 0; sf < 8; sf++) {
                        id = pci_rd32(sb, sd, sf, 0);
                        if ((id & 0xffff) == 0xffff) {
                            if (sf == 0) {
                                break;
                            }
                            continue;
                        }
                        cls = pci_rd32(sb, sd, sf, 0x08) >> 8;
                        if (id == 0x00101b36UL || cls == 0x010802UL) {
                            found++;
                        }
                        if (print) {
                            out("    %02lx:%02lx.%lx", sb, sd, sf, 0);
                            out(" %04lx:%04lx class %06lx", id & 0xffff,
                                id >> 16, cls, 0);
                            out(cls == 0x010802UL ? "  <- NVMe\n" : "\n",
                                0, 0, 0, 0);
                        }
                    }
                }
                if (print) {
                    out("    (bus %02lx scanned)\n", sb, 0, 0, 0);
                }
            }
        }
    }
    return found;
}

/* ------------------------------------------------------------------ */
/* main                                                                 */
/* ------------------------------------------------------------------ */

static U4CM cm;

int main(int argc, char **argv)
{
    unsigned bus, dev, fn, flags = 0, i, wait_s = 10;
    u32 bar_lo, bar_hi = 0, cmd, id;
    int rc, n, nvme = 0;

    for (i = 1; i < (unsigned)argc; i++) {
        if (!stricmp(argv[i], "/USB3")) {
            flags |= U4_RUN_USB3;
        } else if (!stricmp(argv[i], "/NOBOND")) {
            flags |= U4_RUN_NO_BOND;
        } else if (!stricmp(argv[i], "/V")) {
            verbose = 1;
        } else if (!strnicmp(argv[i], "/LOG:", 5)) {
            logf = fopen(argv[i] + 5, "w");
        } else if (!strnicmp(argv[i], "/WAIT:", 6)) {
            wait_s = (unsigned)atoi(argv[i] + 6);
        } else {
            printf("usage: USB4CM [/USB3] [/NOBOND] [/V] [/WAIT:s] "
                   "[/LOG:file]\n");
            return 2;
        }
    }
    out("USB4CM - polling USB4 reference connection manager (usb4-emu)\n",
        0, 0, 0, 0);
    out("This product uses DOS/32 Advanced DOS Extender technology.\n",
        0, 0, 0, 0);

    if (!find_host(&bus, &dev, &fn)) {
        out("No USB4 host interface (class 0C0340) found.\n", 0, 0, 0, 0);
        return 1;
    }
    id = pci_rd32(bus, dev, fn, 0);
    bar_lo = pci_rd32(bus, dev, fn, 0x10);
    if ((bar_lo & 6) == 4) {
        bar_hi = pci_rd32(bus, dev, fn, 0x14);
    }
    out("USB4 host %02lx:%02lx.%lx", bus, dev, fn, 0);
    out(" %04lx:%04lx BAR0 %08lx\n", id & 0xffff, id >> 16, bar_lo, 0);
    if ((bar_lo & 1) || bar_hi || (bar_lo & ~0xfUL) == 0) {
        out("BAR0 is not a mapped 32-bit memory BAR; cannot continue.\n",
            0, 0, 0, 0);
        return 1;
    }
    /* Memory Space and Bus Master Enable (PCI command register) */
    cmd = pci_rd32(bus, dev, fn, 0x04);
    pci_wr32(bus, dev, fn, 0x04, (cmd & 0xffff) | 0x6);
    bar0 = (volatile u8 *)dpmi_map_phys(bar_lo & ~0xfUL, BAR_MAP);
    if (!bar0) {
        out("DPMI could not map BAR0.\n", 0, 0, 0, 0);
        return 1;
    }

    rc = u4cm_init(&cm, &ops);
    if (rc) {
        printf("Host interface init failed: %s\n", u4cm_strerror(rc));
        return 1;
    }
    out("Ring 0 up (DMA block at %08lx). Running the CM...\n", cm.dma_phys,
        0, 0, 0);
    n = u4cm_run(&cm, flags);
    out("\nControl packets: %lu sent, %lu received, %lu retries, %lu CRC "
        "errors\n", cm.n_tx, cm.n_rx, cm.n_retry, cm.n_crc_err);
    if (n < 0) {
        printf("CM failed: %s\n", u4cm_strerror(n));
        u4cm_stop(&cm);
        return 1;
    }
    for (i = 1; i <= cm.nports; i++) {
        out("Port %lu: ", i, 0, 0, 0);
        printf("%s\n", cm.tunnel_up[i] ? "PCIe tunnel UP" :
               cm.dev[i].present ? "device present, PCIe tunnel DOWN" :
               "empty");
        if (logf) {
            fprintf(logf, "%s\n", cm.tunnel_up[i] ? "PCIe tunnel UP" :
                    cm.dev[i].present ? "device present, tunnel DOWN" :
                    "empty");
        }
    }

    /*
     * The endpoint appears behind the tunnel bridge once the tunnel is
     * up. Keep polling the bus (hot plug of the endpoint is asynchronous
     * to this program) and keep answering hot plug events meanwhile.
     */
    if (n > 0) {
        out("Rescanning PCI-to-PCI bridges for the NVMe...\n", 0, 0, 0, 0);
        for (i = 0; i < wait_s * 4; i++) {
            nvme = scan_bridges(0);
            if (nvme) {
                break;
            }
            u4cm_poll(&cm);
            delay(250);
        }
        scan_bridges(1);
        out(nvme ? "NVMe controller found behind the tunnel.\n" :
            "No NVMe controller appeared.\n", 0, 0, 0, 0);
    }
    u4cm_poll(&cm);
    u4cm_stop(&cm);
    if (logf) {
        fclose(logf);
    }
    return n > 0 && nvme ? 0 : 1;
}
