/*
 * u4cm.c - usb4cm core: connection manager logic.
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project from the USB4
 * Connection Manager Guide 2.0 ("Guide") and the USB4 Specification 2.0
 * ("Spec"). C89. One device router per host USB4 port (depth 1); daisy
 * chains are not walked.
 */
#include "usb4cm.h"
#include "u4regs.h"

static const U4_ROUTE host_route = { 0, 0 };

/* ------------------------------------------------------------------ */
/* Register helpers                                                     */
/* ------------------------------------------------------------------ */

static int rd1(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
               unsigned addr, u32 *v)
{
    return u4cm_read(cm, r, cs, adp, addr, 1, v);
}

static int wr1(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
               unsigned addr, u32 v)
{
    return u4cm_write(cm, r, cs, adp, addr, 1, &v);
}

static int rmw(U4CM *cm, const U4_ROUTE *r, unsigned cs, unsigned adp,
               unsigned addr, u32 clr, u32 set)
{
    u32 v;
    int rc = rd1(cm, r, cs, adp, addr, &v);

    if (rc) {
        return rc;
    }
    return wr1(cm, r, cs, adp, addr, (v & ~clr) | set);
}

static void name_copy(char *dst, const u8 *src, unsigned n)
{
    unsigned i;

    if (n >= U4_NAME_LEN) {
        n = U4_NAME_LEN - 1;
    }
    for (i = 0; i < n && src[i]; i++) {
        dst[i] = (char)src[i];
    }
    dst[i] = 0;
}

static void log_name(U4CM *cm, const char *prefix, const char *s)
{
    if (cm->ops->logs) {
        cm->ops->logs(cm->ops->ctx, U4_LOG_INFO, prefix, s);
    }
}

/* ------------------------------------------------------------------ */
/* Router enumeration (Guide 3.2.1)                                     */
/* ------------------------------------------------------------------ */

/*
 * Write the enumeration fields in a single write of ROUTER_CS_1..4:
 * Depth, TopologyID with TopologyID Valid, and the CM USB4 Version
 * (Guide 3.2.1 step 4, Spec 8.2.1.2 - 8.2.1.5). Then wait for Router
 * Ready in ROUTER_CS_6.
 */
static int enumerate_router(U4CM *cm, U4_ROUTER *rt)
{
    u32 v[8];
    unsigned i;
    int rc;

    rc = u4cm_read(cm, &rt->route, U4_CS_ROUTER, 0, 0, 5, v);
    if (rc) {
        return rc;
    }
    rt->vendor = (u16)(v[0] & 0xffff);
    rt->device = (u16)(v[0] >> 16);
    rt->up_adp = (u8)U4_RTR1_UP_ADP(v[1]);
    rt->max_adp = (u8)U4_RTR1_MAX_ADP(v[1]);
    rt->usb4_version = (u8)(v[4] >> 24);
    if (rt->max_adp >= U4_MAX_ADP) {
        return U4_E_PROTO;
    }
    v[1] = (v[1] & ~U4_RTR1_DEPTH_MASK) |
           ((u32)rt->depth << U4_RTR1_DEPTH_SHIFT);
    v[2] = rt->route.lo;
    v[3] = (rt->route.hi & 0x00ffffffUL) | U4_RTR3_TOPO_VALID;
    v[4] = (v[4] & ~U4_RTR4_CMUV_MASK) | U4_RTR4_CMUV_1_0;
    rc = u4cm_write(cm, &rt->route, U4_CS_ROUTER, 0, 1, 4, &v[1]);
    if (rc) {
        return rc;
    }
    for (i = 0; i < 100; i++) {
        rc = rd1(cm, &rt->route, U4_CS_ROUTER, 0, 6, &v[6]);
        if (rc) {
            return rc;
        }
        if (v[6] & U4_RTR6_RR) {
            break;
        }
        u4cm_delay(cm, 1000);
    }
    if (!(v[6] & U4_RTR6_RR)) {
        u4cm_log(cm, U4_LOG_ERR, "router %06lx%08lx: not ready (CS_6 %08lx)",
                 rt->route.hi, rt->route.lo, v[6], 0);
        return U4_E_TIMEOUT;
    }
    rt->present = 1;
    u4cm_log(cm, U4_LOG_INFO, "router %06lx%08lx: %04lx:%04lx enumerated",
             rt->route.hi, rt->route.lo, rt->vendor, rt->device);
    u4cm_log(cm, U4_LOG_INFO, "  depth %lu, upstream adapter %lu, max "
             "adapter %lu, USB4 version %02lx", rt->depth, rt->up_adp,
             rt->max_adp, rt->usb4_version);
    return U4_OK;
}

/*
 * Adapter discovery (Guide 3.2.2): read ADP_CS_0..5 of every adapter,
 * classify by Adapter Type and walk the capability list for the lane,
 * USB4 port and protocol adapter capabilities (Spec 8.2.2).
 */
static int discover_adapters(U4CM *cm, U4_ROUTER *rt)
{
    unsigned a, n, ptr;
    u32 v[6], h;
    int rc;

    for (a = 1; a <= rt->max_adp; a++) {
        U4_ADP *ad = &rt->adp[a];

        rc = u4cm_read(cm, &rt->route, U4_CS_ADAPTER, a, 0, 6, v);
        if (rc == U4_E_NOTIFY) {
            ad->type = U4_ADP_UNUSED;       /* ERR_ADP: not implemented */
            continue;
        }
        if (rc) {
            return rc;
        }
        ad->type = v[U4_ADP_CS_2] & 0x00ffffffUL;
        ptr = (unsigned)(v[U4_ADP_CS_1] & 0xff);
        for (n = 0; ptr && n < 16; n++) {
            rc = rd1(cm, &rt->route, U4_CS_ADAPTER, a, ptr, &h);
            if (rc) {
                return rc;
            }
            switch ((h >> 8) & 0xff) {
            case U4_CAP_LANE:
                ad->cap_lane = (u8)ptr;
                break;
            case U4_CAP_PORT:
                ad->cap_port = (u8)ptr;
                break;
            case U4_CAP_PROTO:
                ad->cap_proto = (u8)ptr;
                break;
            }
            ptr = (unsigned)(h & 0xff);
        }
        u4cm_log(cm, U4_LOG_DBG, "  adapter %lu type %06lx caps lane %02lx "
                 "proto %02lx", a, ad->type, ad->cap_lane, ad->cap_proto);
    }
    return U4_OK;
}

/* ------------------------------------------------------------------ */
/* Host router (Guide 3.2.1, 3.2.2)                                     */
/* ------------------------------------------------------------------ */

int u4cm_host_init(U4CM *cm)
{
    U4_ROUTER *h = &cm->host;
    unsigned a, npcie = 0, nusb3 = 0;
    int rc;

    h->route = host_route;
    h->depth = 0;
    rc = enumerate_router(cm, h);
    if (rc) {
        u4cm_log(cm, U4_LOG_ERR, "host router enumeration failed: %ld",
                 (u32)rc, 0, 0, 0);
        return rc;
    }
    rc = discover_adapters(cm, h);
    if (rc) {
        return rc;
    }

    /*
     * USB4 ports: a lane adapter with a USB4 Port Capability is lane 0
     * of a port, the next adapter is its lane 1 (Spec 8.2.2.3).
     * The Nth PCIe and USB3 Down adapters are taken to belong to the
     * Nth port. That is a platform property (Guide 5.3); it holds for
     * the usb4-emu model and for the reference designs we know of.
     */
    cm->nports = 0;
    for (a = 1; a <= h->max_adp; a++) {
        U4_ADP *ad = &h->adp[a];

        if (ad->type == U4_ADP_LANE && ad->cap_port &&
            cm->nports < U4_MAX_PORTS) {
            cm->port_lane0[++cm->nports] = (u8)a;
        } else if (ad->type == U4_ADP_PCIE_DOWN && npcie < U4_MAX_PORTS) {
            cm->port_pcie_down[++npcie] = (u8)a;
        } else if (ad->type == U4_ADP_USB3_DOWN && nusb3 < U4_MAX_PORTS) {
            cm->port_usb3_down[++nusb3] = (u8)a;
        }
    }
    for (a = 1; a <= cm->nports; a++) {
        u4cm_log(cm, U4_LOG_INFO, "host USB4 port %lu: lane adapters %lu/%lu,"
                 " PCIe Down %lu", a, cm->port_lane0[a], cm->port_lane0[a] + 1,
                 cm->port_pcie_down[a]);
    }
    if (!cm->nports) {
        return U4_E_PROTO;
    }
    return U4_OK;
}

/* ------------------------------------------------------------------ */
/* DROM via the DROM Read router operation (Spec 8.3.1.2.5, Guide 9.1)  */
/* ------------------------------------------------------------------ */

/*
 * Run one router operation: write data, metadata and opcode with OV in
 * one write of ROUTER_CS_9..26, poll OV clear, read data and metadata.
 */
static int router_op(U4CM *cm, const U4_ROUTE *r, u32 op, u32 *meta,
                     u32 *data)
{
    u32 regs[18];
    unsigned i;
    int rc;

    for (i = 0; i < 16; i++) {
        regs[i] = data ? data[i] : 0;
    }
    regs[16] = *meta;
    regs[17] = op | U4_ROP_VALID;
    rc = u4cm_write(cm, r, U4_CS_ROUTER, 0, U4_RTR_OP_DATA, 18, regs);
    if (rc) {
        return rc;
    }
    for (i = 0; i < 500; i++) {
        rc = rd1(cm, r, U4_CS_ROUTER, 0, U4_RTR_OP_CMD, &regs[17]);
        if (rc) {
            return rc;
        }
        if (!(regs[17] & U4_ROP_VALID)) {
            break;
        }
        u4cm_delay(cm, 1000);
    }
    if ((regs[17] & (U4_ROP_VALID | U4_ROP_NOT_SUPP)) ||
        U4_ROP_STATUS(regs[17])) {
        u4cm_log(cm, U4_LOG_INFO, "router op %02lx: CS_26 %08lx", op,
                 regs[17], 0, 0);
        return U4_E_ROP;
    }
    rc = u4cm_read(cm, r, U4_CS_ROUTER, 0, U4_RTR_OP_DATA, 17, regs);
    if (rc) {
        return rc;
    }
    if (data) {
        for (i = 0; i < 16; i++) {
            data[i] = regs[i];
        }
    }
    *meta = regs[16];
    return U4_OK;
}

/* Read @n dwords (<= 16) of DROM at dword address @dw (Table 8-43). */
static int drom_read(U4CM *cm, const U4_ROUTE *r, unsigned dw, unsigned n,
                     u8 *out)
{
    u32 data[16], meta = ((u32)dw << 2) | ((u32)n << 15);
    unsigned i;
    int rc = router_op(cm, r, U4_ROP_DROM_READ, &meta, data);

    if (rc) {
        return rc;
    }
    for (i = 0; i < 4 * n; i++) {
        out[i] = (u8)(data[i / 4] >> (8 * (i % 4)));
    }
    return U4_OK;
}

/*
 * Read the whole DROM (USB4 DROM, version 3: CRC8, UID, CRC32 over
 * bytes 13.., Version, Data Length; entries from byte 16) and pick out
 * the ASCII vendor (type 1) and model (type 2) generic entries.
 */
static int read_drom(U4CM *cm, U4_ROUTER *rt)
{
    u8 buf[512];
    unsigned len, got, pos;
    u32 crc;
    int rc;

    rc = drom_read(cm, &rt->route, 0, 4, buf);
    if (rc) {
        return rc;
    }
    len = 13 + ((unsigned)buf[14] | (((unsigned)buf[15] & 0x0f) << 8));
    if (len > sizeof(buf) || len < 16) {
        return U4_E_PROTO;
    }
    for (got = 16; got < len; got += 64) {
        unsigned n = (sizeof(buf) - got) / 4;

        rc = drom_read(cm, &rt->route, got / 4, n < 16 ? n : 16, buf + got);
        if (rc) {
            return rc;
        }
    }
    crc = (u32)buf[9] | ((u32)buf[10] << 8) | ((u32)buf[11] << 16) |
          ((u32)buf[12] << 24);
    if (u4cm_crc32c(buf + 13, len - 13) != crc) {
        u4cm_log(cm, U4_LOG_ERR, "DROM CRC32 mismatch (%08lx)", crc, 0, 0,
                 0);
        return U4_E_PROTO;
    }
    u4cm_log(cm, U4_LOG_INFO, "DROM version %lu, %lu bytes, CRC32 ok",
             buf[13], len, 0, 0);
    if (buf[13] != 3) {
        return U4_OK;           /* TB3 layout: names not parsed here */
    }
    for (pos = 16; pos + 2 <= len && buf[pos] >= 2;
         pos += buf[pos]) {
        unsigned elen = buf[pos], type = buf[pos + 1];

        if (pos + elen > len) {
            break;
        }
        if (!(type & 0x80) && (type & 0x3f) == 1) {
            name_copy(rt->vendor_name, buf + pos + 2, elen - 2);
        } else if (!(type & 0x80) && (type & 0x3f) == 2) {
            name_copy(rt->model_name, buf + pos + 2, elen - 2);
        }
    }
    log_name(cm, "  vendor: ", rt->vendor_name);
    log_name(cm, "  model:  ", rt->model_name);
    return U4_OK;
}

/* ------------------------------------------------------------------ */
/* Device router on a host port (Guide 3.1, 3.2)                        */
/* ------------------------------------------------------------------ */

static int lane_state(U4CM *cm, const U4_ROUTE *r, U4_ROUTER *rt,
                      unsigned adp, u32 *lane1)
{
    if (!rt->adp[adp].cap_lane) {
        return U4_E_PROTO;
    }
    return rd1(cm, r, U4_CS_ADAPTER, adp, rt->adp[adp].cap_lane + 1, lane1);
}

/* Lane bonding of a host port and its device router (Guide 7.1). */
static int bond_lanes(U4CM *cm, unsigned port)
{
    U4_ROUTER *h = &cm->host, *d = &cm->dev[port];
    unsigned hl0 = cm->port_lane0[port], dl0 = d->up_adp, i;
    u32 v0, v1;
    int rc;

    rc = lane_state(cm, &h->route, h, hl0, &v0);
    if (rc) {
        return rc;
    }
    if (U4_LANE1_NLW(v0) == 2) {
        d->bonded = 1;
        u4cm_log(cm, U4_LOG_INFO, "port %lu: lanes already bonded", port, 0,
                 0, 0);
        return U4_OK;
    }
    rc = lane_state(cm, &h->route, h, hl0 + 1, &v1);
    if (rc) {
        return rc;
    }
    if (U4_LANE1_STATE(v1) != U4_LANE_STATE_CL0) {
        u4cm_log(cm, U4_LOG_INFO, "port %lu: lane 1 not in CL0 (%lu), "
                 "single lane", port, U4_LANE1_STATE(v1), 0, 0);
        return U4_OK;
    }
    /* Target Link Width = dual on both lanes, both ends (Guide 7.1) */
    for (i = 0; i < 2; i++) {
        rc = rmw(cm, &h->route, U4_CS_ADAPTER, hl0 + i,
                 h->adp[hl0 + i].cap_lane + 1, U4_LANE1_TLW_MASK,
                 U4_LANE1_TLW_DUAL);
        if (!rc) {
            rc = rmw(cm, &d->route, U4_CS_ADAPTER, dl0 + i,
                     d->adp[dl0 + i].cap_lane + 1, U4_LANE1_TLW_MASK,
                     U4_LANE1_TLW_DUAL);
        }
        if (rc) {
            return rc;
        }
    }
    /* Lane Bonding on the host side lane 0 starts the bonding */
    rc = rmw(cm, &h->route, U4_CS_ADAPTER, hl0, h->adp[hl0].cap_lane + 1, 0,
             U4_LANE1_LB);
    if (rc) {
        return rc;
    }
    for (i = 0; i < 200; i++) {
        u4cm_poll(cm);          /* lane 1 reports a hot unplug: ack it */
        rc = lane_state(cm, &h->route, h, hl0, &v0);
        if (rc) {
            return rc;
        }
        if (U4_LANE1_NLW(v0) == 2 && !(v0 & U4_LANE1_LB)) {
            break;
        }
        u4cm_delay(cm, 1000);
    }
    u4cm_poll(cm);
    if (U4_LANE1_NLW(v0) != 2) {
        u4cm_log(cm, U4_LOG_ERR, "port %lu: bonding failed (LANE_CS_1 "
                 "%08lx)", port, v0, 0, 0);
        return U4_E_PROTO;
    }
    d->bonded = 1;
    u4cm_log(cm, U4_LOG_INFO, "port %lu: lanes bonded, x2", port, 0, 0, 0);
    return U4_OK;
}

/* Is a router connected to host port @port (lane 0 in CL0)? */
static int port_connected(U4CM *cm, unsigned port)
{
    U4_ROUTER *h = &cm->host;
    u32 v;

    if (lane_state(cm, &h->route, h, cm->port_lane0[port], &v)) {
        return 0;
    }
    return U4_LANE1_STATE(v) == U4_LANE_STATE_CL0;
}

int u4cm_connect(U4CM *cm, unsigned port)
{
    U4_ROUTER *h = &cm->host, *d;
    unsigned hl0, a, i;
    u32 waited, v;
    int rc = U4_E_NODEV;

    if (port < 1 || port > cm->nports) {
        return U4_E_NODEV;
    }
    d = &cm->dev[port];
    hl0 = cm->port_lane0[port];

    /*
     * A device attached before the CM started produces no hot plug
     * event (Guide 3.1.1), so look at the lane state directly; a hot
     * plug event, which the transport acks, only shortens the wait.
     */
    for (waited = 0; !port_connected(cm, port); waited += 10000) {
        if (waited >= cm->connect_wait_us) {
            u4cm_log(cm, U4_LOG_INFO, "port %lu: nothing connected", port,
                     0, 0, 0);
            return U4_E_NODEV;
        }
        u4cm_poll(cm);
        u4cm_delay(cm, 10000);
    }
    u4cm_poll(cm);

    /*
     * Clear Lock on the Downstream Facing Port lane adapters so control
     * packets pass to the device router (Spec 8.2.2.1 ADP_CS_4, Guide
     * 3.2.1).
     */
    for (a = hl0; a <= hl0 + 1; a++) {
        rc = rd1(cm, &h->route, U4_CS_ADAPTER, a, U4_ADP_CS_4, &v);
        if (!rc && (v & U4_ADP4_LOCK)) {
            rc = wr1(cm, &h->route, U4_CS_ADAPTER, a, U4_ADP_CS_4,
                     v & ~U4_ADP4_LOCK);
        }
        if (rc) {
            return rc;
        }
    }

    /* Route string: one hop out of the host's lane 0 adapter */
    d->route.hi = 0;
    d->route.lo = hl0;
    d->depth = 1;
    for (i = 0; i < 20; i++) {
        rc = enumerate_router(cm, d);
        if (rc != U4_E_TIMEOUT && rc != U4_E_NOTIFY) {
            break;
        }
        u4cm_delay(cm, 50000);  /* router still coming up */
    }
    if (rc) {
        u4cm_log(cm, U4_LOG_ERR, "port %lu: device router enumeration "
                 "failed: %ld", port, (u32)rc, 0, 0);
        return rc;
    }
    rc = discover_adapters(cm, d);
    if (rc) {
        return rc;
    }
    for (a = 1; a <= d->max_adp; a++) {
        if (d->adp[a].type == U4_ADP_PCIE_UP && !d->pcie_up) {
            d->pcie_up = (u8)a;
        } else if (d->adp[a].type == U4_ADP_USB3_UP && !d->usb3_up) {
            d->usb3_up = (u8)a;
        }
    }
    u4cm_log(cm, U4_LOG_INFO, "  PCIe Up adapter %lu, USB3 Up adapter %lu",
             d->pcie_up, d->usb3_up, 0, 0);

    rc = read_drom(cm, d);
    if (rc) {
        u4cm_log(cm, U4_LOG_ERR, "port %lu: DROM read failed (%ld), "
                 "continuing", port, (u32)rc, 0, 0);
    }
    return U4_OK;
}

/*
 * Configuration Valid handshake (Guide 3.2.3, Spec 8.2.1.6): set the
 * tunneling-on bits, then CV, then wait for Configuration Ready.
 */
static int config_valid(U4CM *cm, U4_ROUTER *d, u32 tunnel_on)
{
    unsigned i;
    u32 v;
    int rc;

    rc = rmw(cm, &d->route, U4_CS_ROUTER, 0, 5, 0, tunnel_on);
    if (!rc) {
        rc = rmw(cm, &d->route, U4_CS_ROUTER, 0, 5, 0, U4_RTR5_CV);
    }
    for (i = 0; !rc && i < 500; i++) {
        rc = rd1(cm, &d->route, U4_CS_ROUTER, 0, 6, &v);
        if (!rc && (v & U4_RTR6_CR)) {
            return U4_OK;
        }
        u4cm_delay(cm, 1000);
    }
    return rc ? rc : U4_E_TIMEOUT;
}

/* ------------------------------------------------------------------ */
/* Paths (Guide 5.2.1)                                                  */
/* ------------------------------------------------------------------ */

/*
 * Program the path entry for ingress HopID @hop on adapter @adp: a
 * single read and a single write of both dwords (Guide 5.2.1). The
 * flow control and priority values follow Guide Table 5-2 for PCIe:
 * priority 3, weight 1, IFC on lane adapter ingress, EFC and ESE on
 * protocol adapter ingress. @credits applies to lane ingress only.
 */
static int program_path(U4CM *cm, const U4_ROUTE *r, unsigned adp,
                        unsigned hop, unsigned out_adp, unsigned out_hop,
                        unsigned credits, int lane_ingress)
{
    u32 e[2];
    int rc = u4cm_read(cm, r, U4_CS_PATH, adp, 2 * hop, 2, e);

    if (rc) {
        return rc;
    }
    e[0] &= ~(U4_PATH0_OUT_HOP_MASK | U4_PATH0_OUT_ADP_MASK |
              U4_PATH0_CREDITS_MASK);
    e[0] |= (u32)out_hop | ((u32)out_adp << U4_PATH0_OUT_ADP_SHIFT) |
            U4_PATH0_VALID;
    if (lane_ingress) {
        e[0] |= (u32)credits << U4_PATH0_CREDITS_SHIFT;
    }
    e[1] &= ~(U4_PATH1_WEIGHT_MASK | U4_PATH1_PRIO_MASK | U4_PATH1_IFC |
              U4_PATH1_EFC | U4_PATH1_ISE | U4_PATH1_ESE);
    e[1] |= 1 | (3UL << U4_PATH1_PRIO_SHIFT) |
            (lane_ingress ? U4_PATH1_IFC : (U4_PATH1_EFC | U4_PATH1_ESE));
    return u4cm_write(cm, r, U4_CS_PATH, adp, 2 * hop, 2, e);
}

/*
 * Both directions of a tunnel between host protocol adapter @hp and
 * device protocol adapter @dp over host lane @hl / device lane @dl.
 * Protocol adapters use HopID 8 (Spec 8.2.3: PCIe and USB3 adapters
 * have a single path, HopID 8); the lane HopIDs are @down_hop and @up_hop.
 */
static int program_tunnel_paths(U4CM *cm, unsigned port, unsigned hp,
                                unsigned dp, unsigned down_hop,
                                unsigned up_hop)
{
    U4_ROUTER *h = &cm->host, *d = &cm->dev[port];
    unsigned hl = cm->port_lane0[port], dl = d->up_adp;
    int rc;

    rc = program_path(cm, &h->route, hp, 8, hl, down_hop, 0, 0);
    if (!rc) {
        rc = program_path(cm, &d->route, dl, down_hop, dp, 8, 32, 1);
    }
    if (!rc) {
        rc = program_path(cm, &d->route, dp, 8, dl, up_hop, 0, 0);
    }
    if (!rc) {
        rc = program_path(cm, &h->route, hl, up_hop, hp, 8, 32, 1);
    }
    return rc;
}

/* ------------------------------------------------------------------ */
/* PCIe tunnel (Guide 5.3.1)                                            */
/* ------------------------------------------------------------------ */

int u4cm_pcie_tunnel(U4CM *cm, unsigned port)
{
    U4_ROUTER *h = &cm->host, *d = &cm->dev[port];
    unsigned hp, dp, i;
    u32 v;
    int rc;

    if (port < 1 || port > cm->nports || !d->present) {
        return U4_E_NODEV;
    }
    hp = cm->port_pcie_down[port];
    dp = d->pcie_up;
    if (!hp || !dp || !h->adp[hp].cap_proto || !d->adp[dp].cap_proto) {
        u4cm_log(cm, U4_LOG_ERR, "port %lu: no PCIe adapter pair (%lu, %lu)",
                 port, hp, dp, 0);
        return U4_E_NODEV;
    }
    rc = config_valid(cm, d, U4_RTR5_PTO);
    if (rc) {
        u4cm_log(cm, U4_LOG_ERR, "port %lu: Configuration Ready not set",
                 port, 0, 0, 0);
        return rc;
    }
    rc = program_tunnel_paths(cm, port, hp, dp, 8, 9);
    if (rc) {
        return rc;
    }
    /* Path Enable: device PCIe Up first, then host PCIe Down */
    rc = rmw(cm, &d->route, U4_CS_ADAPTER, dp, d->adp[dp].cap_proto, 0,
             U4_PCIE0_PE);
    if (!rc) {
        rc = rmw(cm, &h->route, U4_CS_ADAPTER, hp, h->adp[hp].cap_proto, 0,
                 U4_PCIE0_PE);
    }
    if (rc) {
        return rc;
    }
    /* Wait for the tunneled PCIe link: LTSSM L0 on the host adapter */
    for (i = 0; i < 1000; i++) {
        rc = rd1(cm, &h->route, U4_CS_ADAPTER, hp, h->adp[hp].cap_proto,
                 &v);
        if (rc) {
            return rc;
        }
        if (U4_PCIE0_LTSSM(v) == U4_LTSSM_L0) {
            break;
        }
        u4cm_delay(cm, 1000);
    }
    cm->tunnel_up[port] = U4_PCIE0_LTSSM(v) == U4_LTSSM_L0;
    u4cm_log(cm, U4_LOG_INFO, "port %lu: PCIe tunnel adapter %lu <-> %lu, "
             "ADP_PCIE_CS_0 %08lx", port, hp, dp, v);
    return cm->tunnel_up[port] ? U4_OK : U4_E_TIMEOUT;
}

/* ------------------------------------------------------------------ */
/* USB3 tunnel (Guide 5.5.1)                                            */
/* ------------------------------------------------------------------ */

int u4cm_usb3_tunnel(U4CM *cm, unsigned port)
{
    U4_ROUTER *h = &cm->host, *d = &cm->dev[port];
    unsigned hp, dp;
    int rc;

    if (port < 1 || port > cm->nports || !d->present) {
        return U4_E_NODEV;
    }
    hp = cm->port_usb3_down[port];
    dp = d->usb3_up;
    if (!hp || !dp || !h->adp[hp].cap_proto || !d->adp[dp].cap_proto) {
        return U4_E_NODEV;
    }
    rc = program_tunnel_paths(cm, port, hp, dp, 10, 11);
    if (!rc) {
        rc = rmw(cm, &h->route, U4_CS_ADAPTER, hp, h->adp[hp].cap_proto, 0,
                 U4_USB3_0_PE | U4_USB3_0_V);
    }
    if (!rc) {
        rc = rmw(cm, &d->route, U4_CS_ADAPTER, dp, d->adp[dp].cap_proto, 0,
                 U4_USB3_0_PE | U4_USB3_0_V);
    }
    if (!rc) {
        rc = rmw(cm, &d->route, U4_CS_ROUTER, 0, 5, 0, U4_RTR5_UTO);
    }
    if (!rc) {
        cm->usb3_up[port] = 1;
        u4cm_log(cm, U4_LOG_INFO, "port %lu: USB3 tunnel adapter %lu <-> "
                 "%lu", port, hp, dp, 0);
    }
    return rc;
}

/* ------------------------------------------------------------------ */
/* Everything                                                           */
/* ------------------------------------------------------------------ */

int u4cm_run(U4CM *cm, unsigned flags)
{
    unsigned p;
    int rc, up = 0;

    rc = u4cm_host_init(cm);
    if (rc) {
        return rc;
    }
    for (p = 1; p <= cm->nports; p++) {
        rc = u4cm_connect(cm, p);
        if (rc) {
            continue;
        }
        if (!(flags & U4_RUN_NO_BOND)) {
            bond_lanes(cm, p);  /* x1 still carries the tunnel */
        }
        rc = u4cm_pcie_tunnel(cm, p);
        if (rc == U4_OK) {
            up++;
        } else {
            u4cm_log(cm, U4_LOG_ERR, "port %lu: PCIe tunnel failed (%ld)",
                     p, (u32)rc, 0, 0);
        }
        if (flags & U4_RUN_USB3) {
            rc = u4cm_usb3_tunnel(cm, p);
            if (rc) {
                u4cm_log(cm, U4_LOG_ERR, "port %lu: USB3 tunnel failed "
                         "(%ld)", p, (u32)rc, 0, 0);
            }
        }
    }
    u4cm_poll(cm);
    return up;
}
