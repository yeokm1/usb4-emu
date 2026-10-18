/*
 * u4regs.h - register offsets and fields used by the usb4cm core.
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project. Host interface layout
 * from USB4 Specification 2.0 section 12.6; router, adapter and path
 * configuration spaces from section 8 (field positions cross-checked
 * against tbtools registers.json). C89, no bitfields: dwords plus
 * shift/mask macros, as in xhci98.
 */
#ifndef U4REGS_H
#define U4REGS_H

/* ------------------------------------------------------------------ */
/* Host interface BAR0 (Spec 12.6)                                      */
/* ------------------------------------------------------------------ */

#define U4_TX_RING(n)       (0x00000UL + 0x10UL * (n))  /* 12.6.3.2 */
#define U4_RX_RING(n)       (0x08000UL + 0x10UL * (n))  /* 12.6.3.3 */
#define U4_RING_BASE_LO     0x0
#define U4_RING_BASE_HI     0x4
#define U4_RING_INDEX       0x8     /* TX: Producer [31:16] RW, Consumer RO
                                     * RX: Consumer [15:0] RW, Producer RO */
#define U4_RING_SIZE_REG    0xc     /* Ring Size [15:0], RX Data Buffer
                                     * Size [27:16] (0 = 4096) */
#define U4_TX_CTRL(n)       (0x19800UL + 0x20UL * (n))
#define U4_RX_CTRL(n)       (0x29800UL + 0x20UL * (n))
#define U4_RX_PDF(n)        (0x29804UL + 0x20UL * (n))
#define U4_RING_VALID       0x80000000UL
#define U4_RING_RAW         0x40000000UL
#define U4_ISR              0x37800UL   /* 12.6.3.4.1 */
#define U4_IMC              0x38208UL   /* 12.6.3.4.5 */
#define U4_HI_CAPS          0x39640UL   /* 12.6.3.1.1 Total Paths [10:0] */
#define U4_HI_RESET         0x39858UL   /* 12.6.3.1.3 bit 0 */
#define U4_HI_CONTROL       0x39864UL   /* 12.6.3.1.4 */
#define U4_HR_RESET         0x39898UL   /* 12.6.3.1.2 bit 0 */

/* Ring descriptor DW2 (Spec 12.3.1, 12.4.1) */
#define U4_DESC_EOF_SHIFT   12
#define U4_DESC_SOF_SHIFT   16
#define U4_DESC_CRC_ERR     0x00100000UL
#define U4_DESC_DD          0x00200000UL
#define U4_DESC_RS          0x00400000UL
#define U4_DESC_IE          0x00800000UL

/* ------------------------------------------------------------------ */
/* Control packets (Spec 6.4)                                           */
/* ------------------------------------------------------------------ */

#define U4_PDF_READ         1
#define U4_PDF_WRITE        2
#define U4_PDF_NOTIFY       3
#define U4_PDF_NOTIFY_ACK   4
#define U4_PDF_HOTPLUG      5

#define U4_CS_PATH          0
#define U4_CS_ADAPTER       1
#define U4_CS_ROUTER        2

/* Notification Event Codes, Spec Table 6-12 */
#define U4_EV_ERR_CONN      0
#define U4_EV_ERR_LINK      1
#define U4_EV_ERR_ADDR      2
#define U4_EV_ERR_ADP       4
#define U4_EV_HP_ACK        7
#define U4_EV_ERR_ENUM      8
#define U4_EV_ERR_NUA       9
#define U4_EV_ERR_LEN       11
#define U4_EV_ERR_LOCK      15

/* ------------------------------------------------------------------ */
/* Router configuration space (Spec 8.2.1.x)                            */
/* ------------------------------------------------------------------ */

/* ROUTER_CS_1 */
#define U4_RTR1_NEXT_CAP(v)     ((unsigned)((v) & 0xff))
#define U4_RTR1_UP_ADP(v)       ((unsigned)(((v) >> 8) & 0x3f))
#define U4_RTR1_MAX_ADP(v)      ((unsigned)(((v) >> 14) & 0x3f))
#define U4_RTR1_DEPTH_SHIFT     20
#define U4_RTR1_DEPTH_MASK      (7UL << 20)
/* ROUTER_CS_3 */
#define U4_RTR3_TOPO_VALID      0x80000000UL
/* ROUTER_CS_4: Notification Timeout [7:0], CMUV [15:8], USB4 Ver [31:24] */
#define U4_RTR4_CMUV_MASK       0x0000ff00UL
#define U4_RTR4_CMUV_1_0        0x00001000UL
/* ROUTER_CS_5 */
#define U4_RTR5_PTO             0x01000000UL    /* PCIe Tunneling On */
#define U4_RTR5_UTO             0x02000000UL    /* USB3 Tunneling On */
#define U4_RTR5_CV              0x80000000UL    /* Configuration Valid */
/* ROUTER_CS_6 */
#define U4_RTR6_RR              0x01000000UL    /* Router Ready */
#define U4_RTR6_CR              0x02000000UL    /* Configuration Ready */

/* Router operations, ROUTER_CS_9..26 (Spec 8.3.1, Guide 9.1) */
#define U4_RTR_OP_DATA          9       /* 16 dwords */
#define U4_RTR_OP_META          25
#define U4_RTR_OP_CMD           26
#define U4_ROP_VALID            0x80000000UL    /* OV */
#define U4_ROP_NOT_SUPP         0x40000000UL    /* ONS */
#define U4_ROP_STATUS(v)        ((unsigned)(((v) >> 24) & 0x3f))
#define U4_ROP_DROM_READ        0x24

/* ------------------------------------------------------------------ */
/* Adapter configuration space (Spec 8.2.2)                             */
/* ------------------------------------------------------------------ */

#define U4_ADP_CS_1             1   /* Next Capability Pointer [7:0] */
#define U4_ADP_CS_2             2   /* Adapter Type [23:0] */
#define U4_ADP_CS_4             4
#define U4_ADP4_PLUGGED         0x40000000UL
#define U4_ADP4_LOCK            0x80000000UL

/* Capability IDs (Spec Table 8-?) */
#define U4_CAP_LANE             0x01
#define U4_CAP_TMU              0x03
#define U4_CAP_PROTO            0x04    /* adapter configuration capability */
#define U4_CAP_VSEC             0x05
#define U4_CAP_PORT             0x06

/* Lane Adapter Capability: LANE_ADP_CS_1 at cap + 1 (Spec 8.2.2.3) */
#define U4_LANE1_TLW_MASK       (3UL << 4)      /* Target Link Width */
#define U4_LANE1_TLW_DUAL       (3UL << 4)
#define U4_LANE1_LB             0x00008000UL    /* Lane Bonding */
#define U4_LANE1_NLW(v)         ((unsigned)(((v) >> 20) & 0x3f))
#define U4_LANE1_STATE(v)       ((unsigned)(((v) >> 26) & 0xf))
#define U4_LANE_STATE_CL0       2
#define U4_LANE_STATE_CLD       7

/* PCIe adapter: ADP_PCIE_CS_0 at cap + 0 (Spec 8.2.2.6) */
#define U4_PCIE0_LINK_UP        0x00010000UL
#define U4_PCIE0_LTSSM(v)       ((unsigned)(((v) >> 25) & 0xf))
#define U4_PCIE0_PE             0x80000000UL    /* Path Enable */
#define U4_LTSSM_L0             6

/* USB3 adapter: ADP_USB3_GX_CS_0 at cap + 0 (Spec 8.2.2.7) */
#define U4_USB3_0_V             0x40000000UL    /* Valid */
#define U4_USB3_0_PE            0x80000000UL    /* Path Enable */

/* ------------------------------------------------------------------ */
/* Path configuration space: 2 dwords per HopID (Spec 8.2.3)            */
/* ------------------------------------------------------------------ */

#define U4_PATH0_OUT_HOP_MASK   0x7fUL
#define U4_PATH0_OUT_ADP_SHIFT  11
#define U4_PATH0_OUT_ADP_MASK   (0x3fUL << 11)
#define U4_PATH0_CREDITS_SHIFT  17
#define U4_PATH0_CREDITS_MASK   (0x7fUL << 17)
#define U4_PATH0_VALID          0x80000000UL
#define U4_PATH1_WEIGHT_MASK    0xfUL
#define U4_PATH1_PRIO_SHIFT     8
#define U4_PATH1_PRIO_MASK      (7UL << 8)
#define U4_PATH1_IFC            0x01000000UL
#define U4_PATH1_EFC            0x02000000UL
#define U4_PATH1_ISE            0x04000000UL
#define U4_PATH1_ESE            0x08000000UL

/* Internal helpers shared between the core files */
#include "usb4cm.h"
void u4cm_log(U4CM *cm, int lvl, const char *fmt, u32 a, u32 b, u32 c,
              u32 d);
void u4cm_delay(U4CM *cm, u32 us);
int u4cm_send(U4CM *cm, unsigned pdf, const u32 *dw, unsigned ndw);
int u4cm_rx(U4CM *cm, U4_FRAME *f);
void u4cm_unsolicited(U4CM *cm, const U4_FRAME *f);

#endif
