/*
 * cm-host-test.c - run the usb4cm core against the usb4-emu fabric model
 * on the build host.
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * The core's MMIO callbacks are backed by a tiny host interface shim
 * that implements ring 0 TX/RX the way Spec 12.3/12.4 describes (Raw
 * Mode, descriptors and buffers in a fake physical memory arena) and
 * hands frames to usb4_fabric_tx_frame(); the fabric answers through
 * usb4_host_rx_frame(). The neighbours of the fabric are the same kind
 * of fakes as in src/qemu/tests/usb4/fabric-test.c.
 *
 * Build and run: tools/usb4cm/host/run-host-test.sh (MSYS2 gcc + glib).
 * USB4CM_DEBUG=1 prints every control packet, USB4_TRACE=1 the fabric
 * trace events.
 */
#include "qemu/osdep.h"
#include "hw/usb4/usb4-fabric-int.h"
#include "usb4cm.h"

int usb4_test_trace;
static int failures, checks;
static int debug;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); \
    } \
} while (0)

/* ------------------------------------------------------------------ */
/* Fakes for the neighbours of the fabric (as in fabric-test.c)         */
/* ------------------------------------------------------------------ */

struct USB4Device {
    const char *serial;
    void *router;
    unsigned ndfp;
    int tp;
    USB4Dialect dialect;
};

static int fake_host;
static int fake_tp[3];
static USB4TunnelState tp_state[3];
static int tp_calls[3];
static int u3_calls;
static USB4TunnelState u3_state;

void usb4_icm_hotplug(USB4ICM *icm, USB4Router *r, unsigned adapter,
                      bool unplug)
{
    CHECK(0, "ICM hot plug without an ICM");
}

void usb4_icm_reset(USB4ICM *icm)
{
    CHECK(0, "ICM reset without an ICM");
}

USB4Fabric *usb4_host_get_fabric(USB4Host *h)
{
    return NULL;
}

USB4TunnelPort *usb4_host_get_port_tunnel(USB4Host *h, unsigned port)
{
    return port == 1 || port == 2 ? (USB4TunnelPort *)&fake_tp[port] : NULL;
}

USB4TunnelPort *usb4_device_get_pcie_down_target(USB4Device *d,
                                                 unsigned dport)
{
    return (USB4TunnelPort *)&d->tp;
}

uint16_t usb4_device_pcie_down_rid(USB4Device *d, unsigned dport)
{
    return 0x0300 | dport;
}

unsigned usb4_device_downstream_ports(USB4Device *d)
{
    return d->ndfp;
}

const char *usb4_device_vendor_name(USB4Device *d)
{
    return "QEMU";
}

const char *usb4_device_model_name(USB4Device *d)
{
    return "USB4 NVMe Enclosure";
}

void usb4_tunnel_port_set_state(USB4TunnelPort *p, USB4Device *dev,
                                USB4TunnelState st, USB4TunnelReason why)
{
    for (int i = 1; i <= 2; i++) {
        if (p == (USB4TunnelPort *)&fake_tp[i]) {
            tp_state[i] = st;
            tp_calls[i]++;
            printf("  [model] port %d PCIe tunnel %s (reason %d)\n", i,
                   st == USB4_TUNNEL_UP ? "UP" : "DOWN", why);
        }
    }
}

void usb4_device_usb3_tunnel(USB4Device *d, USB4TunnelState st,
                             USB4TunnelReason why)
{
    u3_calls++;
    u3_state = st;
    printf("  [model] USB3 tunnel %s\n", st == USB4_TUNNEL_UP ? "UP" : "DOWN");
}

USB4Dialect usb4_device_dialect(USB4Device *d)
{
    return d->dialect;
}

const char *usb4_device_nvme_drive(USB4Device *d)
{
    return "disk0";
}

const char *usb4_device_nvme_serial(USB4Device *d)
{
    return d->serial;
}

void *usb4_device_get_router(USB4Device *d)
{
    return d->router;
}

void usb4_device_set_router(USB4Device *d, void *router)
{
    d->router = router;
}

/* Fake virtual clock and timers, advanced by the core's udelay() */
struct USB4Timer {
    USB4TimerCB *cb;
    void *opaque;
    bool armed;
    int64_t deadline;
};

static int64_t now_ms;
#define MAX_TIMERS 32
static USB4Timer *timers[MAX_TIMERS];

USB4Timer *usb4_timer_new(USB4TimerCB *cb, void *opaque)
{
    USB4Timer *t = g_new0(USB4Timer, 1);

    t->cb = cb;
    t->opaque = opaque;
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!timers[i]) {
            timers[i] = t;
            return t;
        }
    }
    abort();
}

void usb4_timer_mod_ms(USB4Timer *t, int64_t ms)
{
    t->armed = true;
    t->deadline = now_ms + ms;
}

void usb4_timer_del(USB4Timer *t)
{
    t->armed = false;
}

void usb4_timer_free(USB4Timer *t)
{
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (timers[i] == t) {
            timers[i] = NULL;
        }
    }
    g_free(t);
}

int64_t usb4_clock_ns(void)
{
    return now_ms * 1000000;
}

static void advance_ms(void)
{
    now_ms++;
    for (int i = 0; i < MAX_TIMERS; i++) {
        USB4Timer *t = timers[i];
        if (t && t->armed && t->deadline <= now_ms) {
            t->armed = false;
            t->cb(t->opaque);
        }
    }
}

/* ------------------------------------------------------------------ */
/* Host interface shim: ring 0 only (Spec 12.3, 12.4, 12.6)             */
/* ------------------------------------------------------------------ */

#define ARENA_PHYS  0x00100000u
#define ARENA_SIZE  0x10000u
static uint8_t arena[ARENA_SIZE];
static uint32_t arena_used;
static USB4Fabric *fab;

static struct {
    uint32_t base, size, pi, ci, ctrl, bufsz;
} txr, rxr;
static GQueue rx_fifo;
static uint32_t n_mmio;

typedef struct { uint8_t pdf; uint16_t len; uint8_t d[256]; } ShimFrame;

static uint8_t *phys(uint32_t pa, uint32_t len)
{
    CHECK(pa >= ARENA_PHYS && pa + len <= ARENA_PHYS + ARENA_SIZE,
          "DMA outside the arena: %08x+%u", pa, len);
    return arena + (pa - ARENA_PHYS);
}

static void shim_rx_flush(void)
{
    ShimFrame *f;

    while (rxr.ctrl >> 31 && rxr.size && rxr.pi != rxr.ci &&
           (f = g_queue_pop_head(&rx_fifo))) {
        uint8_t *d = phys(rxr.base + 16 * rxr.pi, 16);
        uint32_t ba = usb4_ld_le32(d);
        uint32_t bs = rxr.bufsz ? rxr.bufsz : 4096;

        CHECK(f->len <= bs, "RX buffer too small");
        memcpy(phys(ba, f->len), f->d, f->len);
        CHECK(usb4_ld_le32(d + 8) & (1u << 22), "RX descriptor without RS");
        usb4_st_le32(d + 8, f->len | (f->pdf << 12) | (1u << 21) |
                     (1u << 22));
        rxr.pi = (rxr.pi + 1) % rxr.size;
        g_free(f);
    }
}

void usb4_host_rx_frame(USB4Host *h, uint8_t pdf, const uint8_t *frame,
                        size_t len)
{
    ShimFrame *f;

    CHECK(usb4_ctl_frame_crc_ok(frame, len), "rx frame CRC");
    if (!(rxr.ctrl >> 31)) {
        return;                 /* 12.4.2: disabled ring discards */
    }
    f = g_new0(ShimFrame, 1);
    f->pdf = pdf;
    f->len = len;
    memcpy(f->d, frame, len);
    g_queue_push_tail(&rx_fifo, f);
    shim_rx_flush();
}

static void shim_tx_kick(void)
{
    while (txr.ctrl >> 31 && txr.size && txr.ci != txr.pi) {
        uint8_t *d = phys(txr.base + 16 * txr.ci, 16);
        uint32_t dw2 = usb4_ld_le32(d + 8);
        uint32_t len = dw2 & 0xfff;
        uint8_t buf[256];

        CHECK(len && len <= 256, "TX len %u", len);
        CHECK(((dw2 >> 12) & 0xf) == ((dw2 >> 16) & 0xf), "SOF != EOF PDF");
        memcpy(buf, phys(usb4_ld_le32(d), len), len);
        if (dw2 & (1u << 22)) {
            usb4_st_le32(d + 8, dw2 | (1u << 21));
        }
        txr.ci = (txr.ci + 1) % txr.size;
        usb4_fabric_tx_frame(fab, (dw2 >> 12) & 0xf, buf, len);
    }
}

static u32 shim_rd(void *ctx, u32 off)
{
    n_mmio++;
    switch (off) {
    case 0x39640: return 16 | (1u << 16);           /* HI caps */
    case 0x00008: return (txr.pi << 16) | txr.ci;
    case 0x08008: return (rxr.pi << 16) | rxr.ci;
    case 0x0000c: return txr.size;
    case 0x0800c: return rxr.size | (rxr.bufsz << 16);
    case 0x19800: return txr.ctrl;
    case 0x29800: return rxr.ctrl;
    }
    return 0;
}

static void shim_wr(void *ctx, u32 off, u32 v)
{
    ShimFrame *f;

    n_mmio++;
    switch (off) {
    case 0x39858:                                   /* HI reset */
        if (v & 1) {
            memset(&txr, 0, sizeof(txr));
            memset(&rxr, 0, sizeof(rxr));
            while ((f = g_queue_pop_head(&rx_fifo))) {
                g_free(f);
            }
            usb4_fabric_host_reset(fab);
        }
        break;
    case 0x00000: txr.base = v & ~0xfu; txr.pi = txr.ci = 0; break;
    case 0x08000: rxr.base = v & ~0xfu; rxr.pi = rxr.ci = 0; break;
    case 0x00004: case 0x08004: CHECK(v == 0, "64-bit ring base"); break;
    case 0x0000c: txr.size = v & 0xffff; txr.pi = txr.ci = 0; break;
    case 0x0800c:
        rxr.size = v & 0xffff;
        rxr.bufsz = (v >> 16) & 0xfff;
        rxr.pi = rxr.ci = 0;
        break;
    case 0x00008:
        txr.pi = v >> 16;
        CHECK(txr.pi < txr.size, "TX producer %u", txr.pi);
        shim_tx_kick();
        break;
    case 0x08008:
        rxr.ci = v & 0xffff;
        CHECK(rxr.ci < rxr.size, "RX consumer %u", rxr.ci);
        shim_rx_flush();
        break;
    case 0x19800:
        txr.ctrl = v;
        CHECK(!(v >> 31) || (v & (1u << 30)), "TX ring 0 not Raw Mode");
        shim_tx_kick();
        break;
    case 0x29800:
        rxr.ctrl = v;
        if (!(v >> 31)) {
            rxr.pi = rxr.ci = 0;
            while ((f = g_queue_pop_head(&rx_fifo))) {
                g_free(f);
            }
        }
        shim_rx_flush();
        break;
    }
}

static void *shim_dma_alloc(void *ctx, u32 size, u32 align, u32 *pa)
{
    uint32_t off = (arena_used + align - 1) & ~(align - 1);

    if (off + size > ARENA_SIZE) {
        return NULL;
    }
    arena_used = off + size;
    *pa = ARENA_PHYS + off;
    memset(arena + off, 0, size);
    return arena + off;
}

static uint32_t us_acc;

static void shim_udelay(void *ctx, u32 us)
{
    us_acc += us;
    while (us_acc >= 1000) {
        us_acc -= 1000;
        advance_ms();
    }
}

static void shim_log(void *ctx, int lvl, const char *fmt, u32 a, u32 b,
                     u32 c, u32 d)
{
    if (lvl == U4_LOG_DBG && !debug) {
        return;
    }
    printf("  [cm] ");
    printf(fmt, a, b, c, d);
    putchar('\n');
}

static void shim_logs(void *ctx, int lvl, const char *pfx, const char *s)
{
    printf("  [cm] %s%s\n", pfx, s);
}

static const U4CM_OPS ops = {
    NULL, shim_rd, shim_wr, shim_dma_alloc, shim_udelay, shim_log, shim_logs
};

/* ------------------------------------------------------------------ */
/* Tests                                                                */
/* ------------------------------------------------------------------ */

static void new_fabric(void)
{
    USB4FabricConfig cfg = {
        .profile = USB4_PROFILE_USB4_GENERIC, .dialect = USB4_DIALECT_USB4,
        .router_vendor_id = 0x46f4, .router_device_id = 0x4040,
        .num_usb4_ports = 2,
    };

    if (fab) {
        usb4_fabric_free(fab);
    }
    fab = usb4_fabric_new((USB4Host *)&fake_host, &cfg);
    memset(&txr, 0, sizeof(txr));
    memset(&rxr, 0, sizeof(rxr));
    memset(tp_state, 0, sizeof(tp_state));
    memset(tp_calls, 0, sizeof(tp_calls));
    arena_used = 0;
}

static void test_crc(void)
{
    /* Spec Appendix A.2 Table A-1 */
    static const uint8_t ex1[] = { 0, 0, 0, 0, 0, 0, 0, 0,
                                   0x04, 0x00, 0x20, 0x00 };
    static const uint8_t ex2[] = { 0x80, 0, 0, 0, 0, 0, 0, 0,
                                   0x04, 0x28, 0x20, 0x00,
                                   0x15, 0x78, 0x80, 0x86 };

    CHECK(u4cm_crc32c(ex1, 12) == 0x2FC967ACu, "A.2 example 1");
    CHECK(u4cm_crc32c(ex2, 16) == 0x5A9B0181u, "A.2 example 2");
}

static USB4Device dev1 = { .serial = "USB4EMU01" };
static USB4Device dev2 = { .serial = "USB4EMU02" };

/* Device attached at power-on, as in the Windows 98 VM (Guide 3.1.1) */
static void test_boot_attached(void)
{
    static U4CM cm;
    int n;

    printf("== device attached before the CM starts\n");
    new_fabric();
    CHECK(usb4_fabric_attach(fab, 1, &dev1, NULL), "attach");
    CHECK(u4cm_init(&cm, &ops) == U4_OK, "init");
    n = u4cm_run(&cm, 0);
    CHECK(n == 1, "tunnels up %d", n);
    CHECK(usb4_fabric_tunnel_state(fab, 1) == USB4_TUNNEL_UP,
          "fabric tunnel state");
    CHECK(tp_state[1] == USB4_TUNNEL_UP && tp_calls[1] == 1,
          "one UP transition (%d calls)", tp_calls[1]);
    CHECK(usb4_fabric_tunnel_state(fab, 2) == USB4_TUNNEL_DOWN, "port 2");
    CHECK(cm.dev[1].bonded, "bonded");
    CHECK(!strcmp(cm.dev[1].vendor_name, "QEMU") &&
          !strcmp(cm.dev[1].model_name, "USB4 NVMe Enclosure"), "DROM names");
    CHECK(cm.n_crc_err == 0, "no CRC errors");
    printf("   %lu TX, %lu RX, %lu retries, %u MMIO accesses\n", cm.n_tx,
           cm.n_rx, cm.n_retry, n_mmio);

    /* Running again over the same fabric keeps the tunnel up */
    printf("== second run over a configured fabric\n");
    CHECK(u4cm_init(&cm, &ops) == U4_OK, "re-init");
    n = u4cm_run(&cm, 0);
    CHECK(n == 1, "tunnels up on re-run %d", n);
    CHECK(tp_calls[1] == 1 && tp_state[1] == USB4_TUNNEL_UP,
          "no transition on re-run (%d)", tp_calls[1]);
    u4cm_stop(&cm);
}

/* Both ports, USB3 tunnel too; port 2 hot plugged after host init */
static void test_two_ports_usb3(void)
{
    static U4CM cm;
    int n;

    printf("== two ports, USB3, port 2 plugged after host enumeration\n");
    new_fabric();
    u3_calls = 0;
    CHECK(usb4_fabric_attach(fab, 1, &dev1, NULL), "attach 1");
    CHECK(u4cm_init(&cm, &ops) == U4_OK, "init");
    CHECK(u4cm_host_init(&cm) == U4_OK, "host init");
    CHECK(cm.nports == 2, "ports %u", cm.nports);
    CHECK(usb4_fabric_attach(fab, 2, &dev2, NULL), "attach 2");
    n = u4cm_run(&cm, U4_RUN_USB3);
    CHECK(n == 2, "tunnels up %d", n);
    CHECK(usb4_fabric_tunnel_state(fab, 1) == USB4_TUNNEL_UP &&
          usb4_fabric_tunnel_state(fab, 2) == USB4_TUNNEL_UP, "both up");
    CHECK(u3_state == USB4_TUNNEL_UP && cm.usb3_up[1] && cm.usb3_up[2],
          "USB3 up");
    CHECK(cm.hp_tail >= 2, "hot plug events seen %u", cm.hp_tail);
    /* Unacknowledged hot plug events would be retransmitted: none left */
    shim_udelay(NULL, 200000);
    u4cm_poll(&cm);
    {
        unsigned before = cm.hp_tail;
        shim_udelay(NULL, 200000);
        u4cm_poll(&cm);
        CHECK(cm.hp_tail == before, "retransmitted hot plug events");
    }
    u4cm_stop(&cm);
}

static void test_empty(void)
{
    static U4CM cm;

    printf("== nothing attached\n");
    new_fabric();
    CHECK(u4cm_init(&cm, &ops) == U4_OK, "init");
    cm.connect_wait_us = 100000;
    CHECK(u4cm_run(&cm, 0) == 0, "no tunnels");
}

int main(int argc, char **argv)
{
    usb4_test_trace = getenv("USB4_TRACE") != NULL;
    debug = getenv("USB4CM_DEBUG") != NULL;
    g_queue_init(&rx_fifo);
    test_crc();
    test_boot_attached();
    test_two_ports_usb3();
    test_empty();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
