/*
 * u4hi.c - usb4cm core: host interface ring 0 and the control packet
 * transport, by polling.
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project from the USB4
 * Specification 2.0 sections 6.4 (control packets), 12.3 (transmit),
 * 12.4 (receive) and 12.6 (host interface registers). C89.
 */
#include "usb4cm.h"
#include "u4regs.h"

/* ------------------------------------------------------------------ */
/* Small helpers                                                        */
/* ------------------------------------------------------------------ */

static void u4_memzero(volatile u8 *p, unsigned n)
{
    while (n--) {
        *p++ = 0;
    }
}

/* Descriptors are little-endian (Spec 12.3.1). */
static void st_le32(volatile u8 *p, u32 v)
{
    p[0] = (u8)v;
    p[1] = (u8)(v >> 8);
    p[2] = (u8)(v >> 16);
    p[3] = (u8)(v >> 24);
}

static u32 ld_le32(const volatile u8 *p)
{
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) |
           ((u32)p[3] << 24);
}

/* Control packets are big-endian dwords in the buffer (Spec 12.1.1). */
static void st_be32(volatile u8 *p, u32 v)
{
    p[0] = (u8)(v >> 24);
    p[1] = (u8)(v >> 16);
    p[2] = (u8)(v >> 8);
    p[3] = (u8)v;
}

static u32 ld_be32(const volatile u8 *p)
{
    return ((u32)p[0] << 24) | ((u32)p[1] << 16) | ((u32)p[2] << 8) |
           (u32)p[3];
}

#define RD(cm, off)     ((cm)->ops->mmio_rd((cm)->ops->ctx, (off)))
#define WR(cm, off, v)  ((cm)->ops->mmio_wr((cm)->ops->ctx, (off), (v)))

void u4cm_log(U4CM *cm, int lvl, const char *fmt, u32 a, u32 b, u32 c,
              u32 d)
{
    if (cm->ops && cm->ops->log) {
        cm->ops->log(cm->ops->ctx, lvl, fmt, a, b, c, d);
    }
}

void u4cm_delay(U4CM *cm, u32 us)
{
    cm->ops->udelay(cm->ops->ctx, us);
}

/*
 * CRC32C (Castagnoli, reflected polynomial 0x82F63B78), initial value
 * and final XOR 0xFFFFFFFF, as Spec 6.4.1 requires for control packets.
 * Spec Appendix A.2 gives the test vectors the host test checks. Bitwise
 * on purpose: no 1 KB table in a driver's non-paged data.
 */
u32 u4cm_crc32c(const u8 *p, unsigned len)
{
    u32 crc = 0xffffffffUL;
    unsigned i, k;

    for (i = 0; i < len; i++) {
        crc ^= p[i];
        for (k = 0; k < 8; k++) {
            crc = (crc >> 1) ^ (0x82f63b78UL & (0UL - (crc & 1)));
        }
    }
    return crc ^ 0xffffffffUL;
}

const char *u4cm_strerror(int err)
{
    switch (err) {
    case U4_OK: return "ok";
    case U4_E_TIMEOUT: return "timeout";
    case U4_E_NOTIFY: return "error notification";
    case U4_E_NOMEM: return "no DMA memory";
    case U4_E_HW: return "host interface not usable";
    case U4_E_NODEV: return "no device";
    case U4_E_PROTO: return "unexpected register contents";
    case U4_E_ROP: return "router operation failed";
    }
    return "?";
}

/* ------------------------------------------------------------------ */
/* Host interface bring-up (Spec 12.6)                                  */
/* ------------------------------------------------------------------ */

static void u4_rx_post(U4CM *cm, unsigned i)
{
    volatile u8 *d = cm->rx_ring + 16 * i;

    /* Spec 12.4.1: buffer address, RS so the HI writes the status back */
    st_le32(d + 0, cm->rx_buf_phys + U4_BUF_SIZE * i);
    st_le32(d + 4, 0);
    st_le32(d + 8, U4_DESC_RS);
    st_le32(d + 12, 0);
}

int u4cm_init(U4CM *cm, const U4CM_OPS *ops)
{
    u32 caps, size, v;
    unsigned i;

    u4_memzero((volatile u8 *)cm, sizeof(*cm));
    cm->ops = ops;
    cm->timeout_us = 50000;
    cm->retries = 3;
    cm->connect_wait_us = 2000000UL;

    caps = RD(cm, U4_HI_CAPS);
    if (caps == 0xffffffffUL || (caps & 0x7ff) == 0) {
        u4cm_log(cm, U4_LOG_ERR, "HI capabilities %08lx: BAR0 not decoding",
                 caps, 0, 0, 0);
        return U4_E_HW;
    }
    u4cm_log(cm, U4_LOG_INFO, "host interface: %lu paths, version %lu",
             caps & 0x7ff, (caps >> 16) & 0xff, 0, 0);

    /*
     * Host Interface Reset (Spec 12.6.3.1.3): every HI register back to
     * default, rings disabled. The fabric (router config) is untouched.
     * The bit is self-clearing; wait for it.
     */
    WR(cm, U4_HI_RESET, 1);
    for (i = 0; i < 100 && (RD(cm, U4_HI_RESET) & 1); i++) {
        u4cm_delay(cm, 1000);
    }
    if (RD(cm, U4_HI_RESET) & 1) {
        u4cm_log(cm, U4_LOG_ERR, "host interface reset did not complete",
                 0, 0, 0, 0);
        return U4_E_HW;
    }

    /* One DMA block: two rings of 16-byte descriptors, two buffer sets */
    size = 2 * 16 * U4_RING_SIZE + 2 * U4_BUF_SIZE * U4_RING_SIZE;
    cm->dma = (u8 *)ops->dma_alloc(ops->ctx, size, 256, &cm->dma_phys);
    if (!cm->dma) {
        return U4_E_NOMEM;
    }
    u4_memzero(cm->dma, size);
    cm->tx_ring = cm->dma;
    cm->rx_ring = cm->tx_ring + 16 * U4_RING_SIZE;
    cm->tx_buf = cm->rx_ring + 16 * U4_RING_SIZE;
    cm->rx_buf = cm->tx_buf + U4_BUF_SIZE * U4_RING_SIZE;
    cm->tx_ring_phys = cm->dma_phys;
    cm->rx_ring_phys = cm->tx_ring_phys + 16 * U4_RING_SIZE;
    cm->tx_buf_phys = cm->rx_ring_phys + 16 * U4_RING_SIZE;
    cm->rx_buf_phys = cm->tx_buf_phys + U4_BUF_SIZE * U4_RING_SIZE;

    /* Interrupts stay masked: this CM polls (Spec 12.6.3.4.4 IMR = 0) */
    WR(cm, U4_IMC, 0xffffffffUL);
    WR(cm, U4_IMC + 4, 0xffffffffUL);

    /* TX ring 0 (Spec 12.6.3.2): base, size, then Valid + Raw Mode */
    WR(cm, U4_TX_RING(0) + U4_RING_BASE_LO, cm->tx_ring_phys);
    WR(cm, U4_TX_RING(0) + U4_RING_BASE_HI, 0);
    WR(cm, U4_TX_RING(0) + U4_RING_SIZE_REG, U4_RING_SIZE);
    WR(cm, U4_TX_CTRL(0), U4_RING_VALID | U4_RING_RAW);

    /*
     * RX ring 0 (Spec 12.6.3.3): Data Buffer Size [27:16], every PDF
     * accepted for SOF and EOF, then post all but one descriptor. The
     * HI owns descriptors from the Producer Index up to, not including,
     * the Consumer Index (Spec 12.4.2).
     */
    for (i = 0; i < U4_RING_SIZE; i++) {
        u4_rx_post(cm, i);
    }
    WR(cm, U4_RX_RING(0) + U4_RING_BASE_LO, cm->rx_ring_phys);
    WR(cm, U4_RX_RING(0) + U4_RING_BASE_HI, 0);
    WR(cm, U4_RX_RING(0) + U4_RING_SIZE_REG,
       U4_RING_SIZE | ((u32)U4_BUF_SIZE << 16));
    WR(cm, U4_RX_PDF(0), 0xffffffffUL);
    WR(cm, U4_RX_CTRL(0), U4_RING_VALID | U4_RING_RAW);
    WR(cm, U4_RX_RING(0) + U4_RING_INDEX, U4_RING_SIZE - 1);
    cm->tx_pi = 0;
    cm->rx_next = 0;
    cm->rings_on = 1;

    v = RD(cm, U4_TX_RING(0) + U4_RING_INDEX);
    if (v != 0) {
        u4cm_log(cm, U4_LOG_ERR, "TX ring 0 index %08lx after setup", v,
                 0, 0, 0);
        return U4_E_HW;
    }
    return U4_OK;
}

void u4cm_stop(U4CM *cm)
{
    if (!cm->rings_on) {
        return;
    }
    WR(cm, U4_TX_CTRL(0), 0);
    WR(cm, U4_RX_CTRL(0), 0);
    cm->rings_on = 0;
}

/* ------------------------------------------------------------------ */
/* Transmit (Spec 12.3)                                                 */
/* ------------------------------------------------------------------ */

/*
 * Send one control packet of @ndw dwords (route string first) with
 * PDF @pdf. Ring 0 is Raw Mode: one descriptor per packet, the HI does
 * not add the CRC, so the CM appends it (Spec 12.3.2.2).
 */
int u4cm_send(U4CM *cm, unsigned pdf, const u32 *dw, unsigned ndw)
{
    unsigned i = cm->tx_pi, n, len = 4 * ndw + 4;
    volatile u8 *buf = cm->tx_buf + U4_BUF_SIZE * i;
    volatile u8 *d = cm->tx_ring + 16 * i;
    u8 tmp[U4_BUF_SIZE];
    u32 crc, idx;

    if (len > U4_BUF_SIZE) {
        return U4_E_PROTO;
    }
    for (n = 0; n < ndw; n++) {
        st_be32(tmp + 4 * n, dw[n]);
    }
    crc = u4cm_crc32c(tmp, 4 * ndw);
    st_be32(tmp + 4 * ndw, crc);
    for (n = 0; n < len; n++) {
        buf[n] = tmp[n];
    }
    st_le32(d + 0, cm->tx_buf_phys + U4_BUF_SIZE * i);
    st_le32(d + 4, 0);
    st_le32(d + 8, (u32)len | ((u32)(pdf & 0xf) << U4_DESC_EOF_SHIFT) |
                   ((u32)(pdf & 0xf) << U4_DESC_SOF_SHIFT) | U4_DESC_RS);
    st_le32(d + 12, 0);

    cm->tx_pi = (u16)((i + 1) % U4_RING_SIZE);
    WR(cm, U4_TX_RING(0) + U4_RING_INDEX, (u32)cm->tx_pi << 16);
    cm->n_tx++;
    u4cm_log(cm, U4_LOG_DBG, "TX pdf %lu %08lx %08lx %08lx", pdf, dw[0],
             dw[1], ndw > 2 ? dw[2] : 0);

    /* Wait for the HI to consume it: Consumer Index or DD (polling). */
    for (n = 0; n < 1000; n++) {
        idx = RD(cm, U4_TX_RING(0) + U4_RING_INDEX);
        if ((idx & 0xffff) == cm->tx_pi ||
            (ld_le32(d + 8) & U4_DESC_DD)) {
            return U4_OK;
        }
        u4cm_delay(cm, 10);
    }
    u4cm_log(cm, U4_LOG_ERR, "TX descriptor %lu not consumed (index %08lx)",
             i, idx, 0, 0);
    return U4_E_HW;
}

/* ------------------------------------------------------------------ */
/* Receive (Spec 12.4)                                                  */
/* ------------------------------------------------------------------ */

/*
 * Fetch the next completed RX descriptor into @f. Returns 1 when a
 * frame was taken, 0 when none is pending. Frames with a bad CRC are
 * counted and dropped (returns 1 with f->ndw = 0).
 */
int u4cm_rx(U4CM *cm, U4_FRAME *f)
{
    unsigned i = cm->rx_next, len, n;
    volatile u8 *d = cm->rx_ring + 16 * i;
    volatile u8 *buf = cm->rx_buf + U4_BUF_SIZE * i;
    u8 tmp[U4_BUF_SIZE];
    u32 dw2 = ld_le32(d + 8);

    if (!(dw2 & U4_DESC_DD)) {
        return 0;
    }
    len = dw2 & 0xfff;
    f->pdf = (u8)((dw2 >> U4_DESC_EOF_SHIFT) & 0xf);
    f->ndw = 0;
    if (len > U4_BUF_SIZE) {
        len = U4_BUF_SIZE;
    }
    for (n = 0; n < len; n++) {
        tmp[n] = buf[n];
    }
    if (len >= 8 && (len & 3) == 0 &&
        u4cm_crc32c(tmp, len - 4) == ld_be32(tmp + len - 4)) {
        f->ndw = (u8)(len / 4 - 1);
        for (n = 0; n < f->ndw; n++) {
            f->dw[n] = ld_be32(tmp + 4 * n);
        }
        cm->n_rx++;
        u4cm_log(cm, U4_LOG_DBG, "RX pdf %lu %08lx %08lx %08lx", f->pdf,
                 f->dw[0], f->ndw > 1 ? f->dw[1] : 0,
                 f->ndw > 2 ? f->dw[2] : 0);
    } else {
        cm->n_crc_err++;
        u4cm_log(cm, U4_LOG_ERR, "RX frame len %lu dw2 %08lx: bad CRC",
                 len, dw2, 0, 0);
    }

    /* Give the descriptor back: the Consumer Index names it (12.4.2) */
    u4_rx_post(cm, i);
    WR(cm, U4_RX_RING(0) + U4_RING_INDEX, i);
    cm->rx_next = (u16)((i + 1) % U4_RING_SIZE);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Notifications and hot plug (Spec 6.4.2.6, 6.8)                       */
/* ------------------------------------------------------------------ */

static void route_of(const U4_FRAME *f, U4_ROUTE *r)
{
    r->hi = f->dw[0] & 0x00ffffffUL;    /* CM bit and reserved masked */
    r->lo = f->dw[1];
}

/*
 * Hot Plug Acknowledgment: a Notification Packet with Event Code
 * HP_ACK, the adapter, and PG = 2 (plug) or 3 (unplug), Spec Table 6-12
 * and 6.8.1.1. Until it arrives the router retransmits the event.
 */
static void u4_hp_ack(U4CM *cm, const U4_ROUTE *r, unsigned adp,
                      unsigned unplug)
{
    u32 dw[3];

    dw[0] = r->hi;
    dw[1] = r->lo;
    dw[2] = U4_EV_HP_ACK | ((u32)(adp & 0x3f) << 8) |
            ((u32)(unplug ? 3 : 2) << 30);
    u4cm_send(cm, U4_PDF_NOTIFY, dw, 3);
}

/*
 * Handle a frame that is not the response being waited for: hot plug
 * events are queued and acknowledged at once, anything else is counted.
 */
void u4cm_unsolicited(U4CM *cm, const U4_FRAME *f)
{
    U4_HPEV *e;
    unsigned k;

    if (f->ndw < 3) {
        return;
    }
    if (f->pdf == U4_PDF_HOTPLUG) {
        U4_ROUTE r;
        unsigned adp = (unsigned)(f->dw[2] & 0x3f);
        unsigned unplug = (unsigned)(f->dw[2] >> 31);

        route_of(f, &r);
        u4_hp_ack(cm, &r, adp, unplug);
        /* Drop retransmitted copies already queued */
        for (k = cm->hp_head; k != cm->hp_tail; k++) {
            e = &cm->hpq[k % U4_HP_QUEUE];
            if (e->route.hi == r.hi && e->route.lo == r.lo &&
                e->adp == adp && e->unplug == unplug) {
                return;
            }
        }
        u4cm_log(cm, U4_LOG_INFO, "hot plug event: unplug %lu route "
                 "%06lx%08lx adapter %lu", (u32)unplug, r.hi, r.lo, adp);
        if (cm->hp_tail - cm->hp_head < U4_HP_QUEUE) {
            e = &cm->hpq[cm->hp_tail % U4_HP_QUEUE];
            e->route = r;
            e->adp = (u8)adp;
            e->unplug = (u8)unplug;
            cm->hp_tail++;
        }
        return;
    }
    cm->n_stray++;
    u4cm_log(cm, U4_LOG_DBG, "unsolicited pdf %lu dw2 %08lx", f->pdf,
             f->dw[2], 0, 0);
}

void u4cm_poll(U4CM *cm)
{
    U4_FRAME f;

    while (u4cm_rx(cm, &f)) {
        if (f.ndw) {
            u4cm_unsolicited(cm, &f);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Read and write requests (Spec 6.4.2.3 - 6.4.2.5)                     */
/* ------------------------------------------------------------------ */

static u32 req_dw2(unsigned addr, unsigned n, unsigned adp, unsigned cs,
                   unsigned seq)
{
    /* Spec Table 6-2: Address[12:0] Size[18:13] Adapter[24:19] CS[26:25]
     * SN[28:27] */
    return ((u32)addr & 0x1fff) | (((u32)n & 0x3f) << 13) |
           (((u32)adp & 0x3f) << 19) | (((u32)cs & 3) << 25) |
           (((u32)seq & 3) << 27);
}

static int u4_xfer(U4CM *cm, unsigned pdf, const U4_ROUTE *r, unsigned cs,
                   unsigned adp, unsigned addr, unsigned n, u32 *buf)
{
    u32 dw[3 + 60], want;
    unsigned ndw = 3, k, attempt;
    U4_FRAME f;
    u32 waited;
    int rc;

    if (n > 60) {
        return U4_E_PROTO;
    }
    for (attempt = 0; attempt <= cm->retries; attempt++) {
        unsigned seq = cm->seq;

        cm->seq = (u8)((cm->seq + 1) & 3);
        dw[0] = r->hi & 0x00ffffffUL;
        dw[1] = r->lo;
        dw[2] = req_dw2(addr, n, adp, cs, seq);
        want = dw[2];
        ndw = 3;
        if (pdf == U4_PDF_WRITE) {
            for (k = 0; k < n; k++) {
                dw[3 + k] = buf[k];
            }
            ndw += n;
        }
        if (attempt) {
            cm->n_retry++;
        }
        rc = u4cm_send(cm, pdf, dw, ndw);
        if (rc) {
            return rc;
        }
        for (waited = 0; waited <= cm->timeout_us;) {
            if (!u4cm_rx(cm, &f)) {
                u4cm_delay(cm, 100);
                waited += 100;
                continue;
            }
            if (f.ndw < 3) {
                continue;
            }
            if (f.pdf == U4_PDF_NOTIFY &&
                (f.dw[2] & 0xff) != U4_EV_HP_ACK &&
                (f.dw[2] & 0xff) < 32) {
                /*
                 * Error Notification (Spec 6.4.2.6, Table 6-12). It
                 * comes from the router that could not deliver or
                 * execute the request, which for ERR_CONN or ERR_LOCK
                 * is an upstream router, so its route is not checked:
                 * this CM has one request outstanding at a time.
                 */
                cm->last_event = (int)(f.dw[2] & 0xff);
                u4cm_log(cm, U4_LOG_DBG, "notification event %lu for "
                         "cs %lu adp %lu addr %lx", (u32)cm->last_event,
                         cs, adp, addr);
                return U4_E_NOTIFY;
            }
            if ((f.dw[0] & 0x00ffffffUL) != (r->hi & 0x00ffffffUL) ||
                f.dw[1] != r->lo || f.pdf != pdf) {
                u4cm_unsolicited(cm, &f);
                continue;
            }
            /*
             * A response echoes Address, Size, CS and SN. Its Adapter
             * field is not compared: for Router CS requests the router
             * reports the adapter the request arrived on (Spec 6.4.2.4).
             */
            if ((f.dw[2] & 0x1e07ffffUL) != (want & 0x1e07ffffUL)) {
                cm->n_stray++;
                continue;       /* stale response of an earlier attempt */
            }
            if (pdf == U4_PDF_READ) {
                if (f.ndw < 3 + n) {
                    return U4_E_PROTO;
                }
                for (k = 0; k < n; k++) {
                    buf[k] = f.dw[3 + k];
                }
            }
            return U4_OK;
        }
        u4cm_log(cm, U4_LOG_INFO, "no response: route %06lx%08lx dw2 %08lx, "
                 "attempt %lu", r->hi, r->lo, want, attempt);
    }
    return U4_E_TIMEOUT;
}

int u4cm_read(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
              unsigned addr, unsigned n, u32 *buf)
{
    return u4_xfer(cm, U4_PDF_READ, r, cs, adp, addr, n, buf);
}

int u4cm_write(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
               unsigned addr, unsigned n, const u32 *buf)
{
    return u4_xfer(cm, U4_PDF_WRITE, r, cs, adp, addr, n, (u32 *)buf);
}
