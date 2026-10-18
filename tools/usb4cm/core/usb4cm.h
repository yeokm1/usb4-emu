/*
 * usb4cm.h - a small, polling, OS-independent USB4 software connection
 * manager core (C89).
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project from the USB4
 * Specification 2.0 ("Spec") and the USB4 Connection Manager Guide 2.0
 * ("Guide"). See tools/usb4cm/README.md for the architecture, the
 * callback contract and what the xhci98 project can lift.
 *
 * The core never touches hardware itself. Everything goes through
 * U4CM_OPS: 32-bit MMIO on BAR0 of the USB4 host interface, one
 * physically contiguous DMA allocation below 4 GB, a delay and a log
 * sink. No interrupts are used: the host interface is driven by polling
 * ring indices and descriptor status (Spec 12.3, 12.4).
 */
#ifndef USB4CM_H
#define USB4CM_H

#include "u4types.h"

/* ------------------------------------------------------------------ */
/* Callback contract                                                    */
/* ------------------------------------------------------------------ */

typedef struct U4CM_OPS {
    void *ctx;                  /* passed back to every callback */

    /* 32-bit read/write of BAR0 at byte offset @off (dword aligned). */
    u32  (*mmio_rd)(void *ctx, u32 off);
    void (*mmio_wr)(void *ctx, u32 off, u32 val);

    /*
     * Allocate @size bytes of zeroed, physically contiguous memory the
     * host interface can DMA to, aligned to @align bytes, with a
     * physical address below 4 GB returned in *@phys. Called once from
     * u4cm_init(); the core never frees it (the caller owns its
     * lifetime and frees it after u4cm_stop()). Returns the CPU pointer,
     * or 0 on failure. The memory must be cache coherent with device
     * DMA (true on every x86 PC this targets).
     */
    void *(*dma_alloc)(void *ctx, u32 size, u32 align, u32 *phys);

    /* Busy-wait at least @us microseconds. Coarser is fine. */
    void (*udelay)(void *ctx, u32 us);

    /*
     * Log one line. @fmt is a printf format using only %lu, %lx, %08lx,
     * %s-free conversions of the four u32 arguments, or %s when the core
     * says so in the format comment. May be 0.
     */
    void (*log)(void *ctx, int level, const char *fmt,
                u32 a, u32 b, u32 c, u32 d);
    /* String log (names read from a DROM). May be 0. */
    void (*logs)(void *ctx, int level, const char *prefix, const char *s);
} U4CM_OPS;

/* Log levels */
#define U4_LOG_ERR   0
#define U4_LOG_INFO  1
#define U4_LOG_DBG   2      /* every control packet */

/* ------------------------------------------------------------------ */
/* Results                                                              */
/* ------------------------------------------------------------------ */

#define U4_OK            0
#define U4_E_TIMEOUT    (-1)    /* no response after all retries */
#define U4_E_NOTIFY     (-2)    /* error notification, see last_event */
#define U4_E_NOMEM      (-3)
#define U4_E_HW         (-4)    /* host interface not usable */
#define U4_E_NODEV      (-5)    /* nothing connected */
#define U4_E_PROTO      (-6)    /* unexpected register contents */
#define U4_E_ROP        (-7)    /* router operation failed */

/* ------------------------------------------------------------------ */
/* State                                                                */
/* ------------------------------------------------------------------ */

#define U4_RING_SIZE      16    /* descriptors per ring 0 direction */
#define U4_BUF_SIZE       256   /* bytes per buffer, max control packet */
#define U4_MAX_PORTS      4     /* host USB4 ports handled */
#define U4_MAX_ADP        64    /* adapter numbers 0..63, Spec 8.2.1 */
#define U4_NAME_LEN       48
#define U4_HP_QUEUE       16

/* A route string as two dwords (Spec 6.4.2.2). Level n is byte n. */
typedef struct U4_ROUTE {
    u32 hi;                     /* bits 55:32, CM bit excluded */
    u32 lo;                     /* bits 31:0 */
} U4_ROUTE;

/* Adapter types, ADP_CS_2 Adapter Type field [23:0] (Spec Table 8-?) */
#define U4_ADP_UNUSED     0x000000UL
#define U4_ADP_LANE       0x000001UL
#define U4_ADP_HI         0x000002UL
#define U4_ADP_PCIE_DOWN  0x100101UL
#define U4_ADP_PCIE_UP    0x100102UL
#define U4_ADP_USB3_DOWN  0x200101UL
#define U4_ADP_USB3_UP    0x200102UL
#define U4_ADP_DP_IN      0x0e0101UL
#define U4_ADP_DP_OUT     0x0e0102UL

typedef struct U4_ADP {
    u32 type;                   /* U4_ADP_* */
    u8 cap_lane;                /* Lane Adapter Capability offset, 0 = none */
    u8 cap_port;                /* USB4 Port Capability offset */
    u8 cap_proto;               /* Adapter Configuration Capability offset */
    u8 pad;
} U4_ADP;

typedef struct U4_ROUTER {
    U4_ROUTE route;
    u8 present;
    u8 depth;
    u8 up_adp;                  /* Upstream Adapter, ROUTER_CS_1 */
    u8 max_adp;                 /* Max Adapter, ROUTER_CS_1 */
    u16 vendor, device;         /* ROUTER_CS_0 */
    u8 usb4_version;            /* ROUTER_CS_4 [31:24] */
    u8 pcie_up;                 /* device: PCIe Upstream adapter number */
    u8 usb3_up;                 /* device: USB3 Upstream adapter number */
    u8 bonded;
    U4_ADP adp[U4_MAX_ADP];
    char vendor_name[U4_NAME_LEN];  /* from the DROM */
    char model_name[U4_NAME_LEN];
} U4_ROUTER;

typedef struct U4_HPEV {
    U4_ROUTE route;
    u8 adp;
    u8 unplug;
} U4_HPEV;

/* One received ring 0 frame, decoded to host-order dwords. */
typedef struct U4_FRAME {
    u8 pdf;
    u8 ndw;                     /* dwords without the CRC */
    u32 dw[U4_BUF_SIZE / 4];
} U4_FRAME;

typedef struct U4CM {
    const U4CM_OPS *ops;

    /* DMA area: TX ring, RX ring, TX buffers, RX buffers */
    u8 *dma;
    u32 dma_phys;
    u8 *tx_ring, *rx_ring, *tx_buf, *rx_buf;
    u32 tx_ring_phys, rx_ring_phys, tx_buf_phys, rx_buf_phys;
    u16 tx_pi;                  /* next TX descriptor to fill */
    u16 rx_next;                /* next RX descriptor to examine */
    u8 seq;                     /* 2-bit sequence number, Spec 6.4.2.3 */
    u8 rings_on;

    /* last error notification event code (Spec Table 6-12) */
    int last_event;

    /* hot plug events received while waiting for responses */
    U4_HPEV hpq[U4_HP_QUEUE];
    unsigned hp_head, hp_tail;

    /* statistics */
    u32 n_tx, n_rx, n_retry, n_crc_err, n_stray;

    /* topology */
    unsigned nports;            /* host USB4 ports found */
    u8 port_lane0[U4_MAX_PORTS + 1];    /* host lane 0 adapter, 1-based */
    u8 port_pcie_down[U4_MAX_PORTS + 1];/* host PCIe Down adapter */
    u8 port_usb3_down[U4_MAX_PORTS + 1];
    U4_ROUTER host;
    U4_ROUTER dev[U4_MAX_PORTS + 1];    /* depth-1 device router per port */
    u8 tunnel_up[U4_MAX_PORTS + 1];
    u8 usb3_up[U4_MAX_PORTS + 1];

    /* tunables (defaults set by u4cm_init) */
    u32 timeout_us;             /* per request attempt */
    unsigned retries;
    u32 connect_wait_us;        /* wait for a device to appear */
} U4CM;

/* ------------------------------------------------------------------ */
/* API                                                                  */
/* ------------------------------------------------------------------ */

/* Host Interface bring-up: reset, ring 0 TX/RX in Raw Mode (Spec 12). */
int u4cm_init(U4CM *cm, const U4CM_OPS *ops);
/* Disable ring 0 again (leaves the fabric state as it is). */
void u4cm_stop(U4CM *cm);

/* Control packet transport (Spec 6.4). @n is in dwords (1..60). */
int u4cm_read(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
              unsigned addr, unsigned n, u32 *buf);
int u4cm_write(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
               unsigned addr, unsigned n, const u32 *buf);

/* Process received frames without a pending request; ack hot plugs. */
void u4cm_poll(U4CM *cm);

/* Host router enumeration and adapter discovery (Guide 3.2.1, 3.2.2). */
int u4cm_host_init(U4CM *cm);
/* Enumerate the device router on host USB4 port @port (1-based). */
int u4cm_connect(U4CM *cm, unsigned port);
/* PCIe tunnel host PCIe Down <-> device PCIe Up (Guide 5.3.1). */
int u4cm_pcie_tunnel(U4CM *cm, unsigned port);
/* USB3 tunnel host USB3 Down <-> device USB3 Up (Guide 5.5.1). */
int u4cm_usb3_tunnel(U4CM *cm, unsigned port);

/* Flags for u4cm_run() */
#define U4_RUN_USB3        0x1  /* also set up USB3 tunnels */
#define U4_RUN_NO_BOND     0x2  /* skip lane bonding */

/*
 * Everything: u4cm_host_init(), then for every host port with a device
 * u4cm_connect() and u4cm_pcie_tunnel(). Returns the number of PCIe
 * tunnels that are up, or a negative error.
 */
int u4cm_run(U4CM *cm, unsigned flags);

/* Helpers exposed for front-ends and tests */
u32 u4cm_crc32c(const u8 *p, unsigned len);
const char *u4cm_strerror(int err);

#endif
