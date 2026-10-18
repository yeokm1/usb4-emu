/*
 * SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 usb4-emu contributors
 *
 * reenum.sys - THROWAWAY EXPERIMENT, not a product driver.
 *
 * Question: can a kernel-mode driver make Windows 98 SE / Windows 2000 SP4
 * enumerate an endpoint that appears behind a PCI-to-PCI bridge (a USB4/TB
 * PCIe tunnel coming up), and drop one that disappears, with no user-mode
 * helper? See docs/REENUM-EXPERIMENT.md.
 *
 * One WDM binary, two roles chosen in AddDevice from the PDO's IDs:
 *   - bridge filter: loaded as an upper filter on a PCI-to-PCI bridge
 *     (compatible ID PCI\CC_0604). Polls the bridge's secondary bus.
 *   - host function driver: loaded on the usb4-host (PCI\VEN_1B36&DEV_00F4),
 *     standing in for the future CM driver. Polls the tunnel bridge's
 *     secondary bus at a configured bus/device.
 * Every 500 ms the secondary bus is scanned through config mechanism #1
 * (vendor ID of function 0 of each device). On a change of the presence
 * mask the configured mechanism runs:
 *   ReenumMode 0  log only
 *   ReenumMode 1  IoInvalidateDeviceRelations(bridge PDO, BusRelations)
 *                 (filter role only)
 *   ReenumMode 2  Windows 98 only: CONFIGMG services through the VMM
 *                 dynalink (INT 20h): Reenumerate_DevNode on the bridge
 *                 devnode, Query_Remove_SubTree + Remove_SubTree on a
 *                 child whose device has vanished.
 * ReenumMode (DWORD) and, for the host role, BridgeBus/BridgeDev (DWORD) are
 * read from the device's hardware key (IoOpenDeviceRegistryKey,
 * PLUGPLAY_REGKEY_DEVICE). Logging goes to the QEMU debug console, port
 * 0xE9 (-debugcon file:...).
 *
 * Config mechanism #1 is used directly with interrupts disabled around the
 * address/data pair (uniprocessor guests); a product driver would use the
 * bus interface instead.
 */
#include <wdm.h>

#define TAG 'nerU'

#define ROLE_FILTER 1
#define ROLE_HOST   2

typedef struct _DEVEXT {
    PDEVICE_OBJECT Self;
    PDEVICE_OBJECT Lower;
    PDEVICE_OBJECT Pdo;
    ULONG Role;
    ULONG Mode;
    ULONG Bus, Dev, Fn;     /* the bridge being watched */
    ULONG LastMask;
    ULONG Ids[32];          /* vendor | device << 16 per device */
    LONG Running;
    KEVENT StopEvt;
    KEVENT DoneEvt;
} DEVEXT, *PDEVEXT;

static BOOLEAN g_Win98;     /* WDM 1.00: Windows 98 (SE) */

/* ---------------------------------------------------------------- log */

static void LogCh(char c)
{
    __asm {
        mov dx, 0E9h
        mov al, c
        out dx, al
    }
}

static void LogS(const char *s)
{
    while (*s) {
        LogCh(*s++);
    }
}

static void LogX(ULONG v)
{
    int i;
    static const char hex[] = "0123456789ABCDEF";
    for (i = 28; i >= 0; i -= 4) {
        LogCh(hex[(v >> i) & 0xF]);
    }
}

static void LogW(const WCHAR *w, ULONG maxch)
{
    ULONG i;
    for (i = 0; i < maxch && w[i]; i++) {
        LogCh((char)(w[i] < 0x80 ? w[i] : '?'));
    }
}

#define LOGP() LogS("[reenum] ")

/* ------------------------------------------------------- config space */

static ULONG CfgRead(ULONG bus, ULONG dev, ULONG fn, ULONG off)
{
    ULONG addr = 0x80000000UL | (bus << 16) | (dev << 11) | (fn << 8) |
                 (off & 0xFC);
    ULONG val;
    __asm {
        pushfd
        cli
        mov dx, 0CF8h
        mov eax, addr
        out dx, eax
        mov dx, 0CFCh
        in eax, dx
        mov val, eax
        popfd
    }
    return val;
}

static ULONG ScanSecondary(PDEVEXT x, ULONG *secOut)
{
    ULONG sec, d, v, mask = 0;
    sec = (CfgRead(x->Bus, x->Dev, x->Fn, 0x18) >> 8) & 0xFF;
    *secOut = sec;
    if (sec == 0 || sec == 0xFF) {
        return 0;
    }
    for (d = 0; d < 32; d++) {
        v = CfgRead(sec, d, 0, 0);
        x->Ids[d] = 0;
        if ((v & 0xFFFF) != 0xFFFF && (v & 0xFFFF) != 0) {
            mask |= 1UL << d;
            x->Ids[d] = v;
        }
    }
    return mask;
}

/* ------------------------------------------------ CONFIGMG (Win98 only) */

/*
 * VMM dynalink: "INT 20h; DD (VxD_ID << 16) | service". Bit 15 of the
 * service word asks VMM for a jump (VxDJmp), so a cdecl call to the thunk
 * reaches the service with the caller's own return address and arguments.
 * VMM patches the 6 bytes into JMP [service] on first use, so the thunk
 * lives in (writable) non-paged pool. CONFIGMG's VxD ID is 0033h and its
 * services are cdecl, returning CONFIGRET in EAX. Service numbers are the
 * Windows 95/98 DDK's CONFIGMG service table order; each one used here is
 * checked at run time (Get_Version, IDs read back) before anything else.
 */
#define CM_VXD_ID              0x0033
#define CMS_Get_Version        0
#define CMS_Locate_DevNode     2
#define CMS_Get_Parent         3
#define CMS_Get_Child          4
#define CMS_Get_Sibling        5
#define CMS_Get_Device_ID      7
#define CMS_Query_Remove_SubTree 12
#define CMS_Remove_SubTree     13
#define CMS_Reenumerate_DevNode 51
#define CMS_Setup_DevNode      52
#define CMS_Get_DevNode_Status 54
#define CMS_MAX                64

typedef ULONG (__cdecl *CMF0)(void);
typedef ULONG (__cdecl *CMF2)(ULONG, ULONG);
typedef ULONG (__cdecl *CMF3)(ULONG, ULONG, ULONG);
typedef ULONG (__cdecl *CMF4)(ULONG, ULONG, ULONG, ULONG);

static PUCHAR g_Thunk[CMS_MAX];

static PVOID CmThunk(ULONG svc)
{
    PUCHAR t = g_Thunk[svc];
    ULONG w;
    if (t) {
        return t;
    }
    t = (PUCHAR)ExAllocatePoolWithTag(NonPagedPool, 16, TAG);
    if (!t) {
        return NULL;
    }
    w = (CM_VXD_ID << 16) | 0x8000 | svc;
    t[0] = 0xCD;
    t[1] = 0x20;
    t[2] = (UCHAR)w;
    t[3] = (UCHAR)(w >> 8);
    t[4] = (UCHAR)(w >> 16);
    t[5] = (UCHAR)(w >> 24);
    t[6] = 0xCC;
    t[7] = 0xCC;
    g_Thunk[svc] = t;
    return t;
}

#define CM0(s)             (((CMF0)CmThunk(s))())
#define CM2(s, a, b)       (((CMF2)CmThunk(s))((ULONG)(a), (ULONG)(b)))
#define CM3(s, a, b, c)    (((CMF3)CmThunk(s))((ULONG)(a), (ULONG)(b), \
                                                (ULONG)(c)))
#define CM4(s, a, b, c, d) (((CMF4)CmThunk(s))((ULONG)(a), (ULONG)(b), \
                                                (ULONG)(c), (ULONG)(d)))

static BOOLEAN g_CmOk;

static ULONG CmDevId(ULONG dn, char *buf, ULONG len)
{
    buf[0] = 0;
    return CM4(CMS_Get_Device_ID, dn, buf, len, 0);
}

static int StrUpEq(char a, char b)
{
    if (a >= 'a' && a <= 'z') a -= 32;
    if (b >= 'a' && b <= 'z') b -= 32;
    return a == b;
}

/* "...\BUS_bb&DEV_dd&FUNC_ff" is Windows 98's PCI instance format. */
static ULONG ParseHexN(const char *p, int n)
{
    ULONG v = 0;
    int i;
    for (i = 0; i < n; i++) {
        char c = p[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else return 0xFFFFFFFF;
    }
    return v;
}

#define ParseHex2(p) ParseHexN((p), 2)

static const char *FindStr(const char *s, const char *pat)
{
    const char *a, *b;
    for (; *s; s++) {
        for (a = s, b = pat; *a && *b && StrUpEq(*a, *b); a++, b++) {
        }
        if (!*b) {
            return s;
        }
    }
    return NULL;
}

static BOOLEAN IdIsBdf(const char *id, ULONG bus, ULONG dev, ULONG fn)
{
    const char *p = FindStr(id, "\\BUS_");
    if (!p || !FindStr(id, "PCI\\")) return FALSE;
    if (ParseHex2(p + 5) != bus) return FALSE;
    p = FindStr(p, "&DEV_");
    if (!p || ParseHex2(p + 5) != dev) return FALSE;
    p = FindStr(p, "&FUNC_");
    if (!p || ParseHex2(p + 6) != fn) return FALSE;
    return TRUE;
}

/* Depth-first walk of the devnode tree for the bridge's PCI instance. */
static ULONG CmFindBdf(ULONG dn, ULONG bus, ULONG dev, ULONG fn, int depth)
{
    char id[200];
    ULONG c, r, found;
    if (CmDevId(dn, id, sizeof(id)) == 0 && IdIsBdf(id, bus, dev, fn)) {
        return dn;
    }
    if (depth > 12) return 0;
    r = CM3(CMS_Get_Child, &c, dn, 0);
    while (r == 0) {
        found = CmFindBdf(c, bus, dev, fn, depth + 1);
        if (found) return found;
        r = CM3(CMS_Get_Sibling, &c, c, 0);
    }
    return 0;
}

static void CmDumpChildren(ULONG dn)
{
    char id[200];
    ULONG c, r, st, pb, n = 0;
    r = CM3(CMS_Get_Child, &c, dn, 0);
    while (r == 0) {
        CmDevId(c, id, sizeof(id));
        st = pb = 0;
        CM4(CMS_Get_DevNode_Status, &st, &pb, c, 0);
        LOGP(); LogS("  child dn="); LogX(c); LogS(" status="); LogX(st);
        LogS(" problem="); LogX(pb); LogS(" "); LogS(id); LogS("\n");
        n++;
        r = CM3(CMS_Get_Sibling, &c, c, 0);
    }
    LOGP(); LogS("  children: "); LogX(n); LogS("\n");
}

static void CmProbe(void)
{
    ULONG v, root = 0, r, c;
    char id[200];
    v = CM0(CMS_Get_Version);
    LOGP(); LogS("CONFIGMG_Get_Version="); LogX(v); LogS("\n");
    if ((v & 0xFF00) != 0x0400) {
        LOGP(); LogS("CONFIGMG version unexpected, CONFIGMG path disabled\n");
        return;
    }
    r = CM3(CMS_Locate_DevNode, &root, NULL, 0);
    CmDevId(root, id, sizeof(id));
    LOGP(); LogS("Locate_DevNode(root) cr="); LogX(r); LogS(" dn=");
    LogX(root); LogS(" id="); LogS(id); LogS("\n");
    r = CM3(CMS_Get_Child, &c, root, 0);
    if (r == 0) {
        CmDevId(c, id, sizeof(id));
        LOGP(); LogS("first child of root: "); LogS(id); LogS("\n");
    }
    g_CmOk = (r == 0);
}

static void CmAct(PDEVEXT x, ULONG oldMask, ULONG newMask)
{
    ULONG root = 0, br, r, c, next, d;
    char id[200];
    const char *p;

    if (!g_CmOk) {
        LOGP(); LogS("CONFIGMG not usable\n");
        return;
    }
    CM3(CMS_Locate_DevNode, &root, NULL, 0);
    br = CmFindBdf(root, x->Bus, x->Dev, x->Fn, 0);
    if (!br) {
        LOGP(); LogS("bridge devnode not found\n");
        return;
    }
    CmDevId(br, id, sizeof(id));
    LOGP(); LogS("bridge devnode "); LogX(br); LogS(" "); LogS(id);
    LogS("\n");
    CmDumpChildren(br);

    /* Removal: children whose PCI device number vanished. */
    if (oldMask & ~newMask) {
        r = CM3(CMS_Get_Child, &c, br, 0);
        while (r == 0) {
            next = 0;
            r = CM3(CMS_Get_Sibling, &next, c, 0);
            CmDevId(c, id, sizeof(id));
            /* Windows 98 names PCI instances in more than one way
             * ("BUS_01&DEV_01&FUNC_00", "082800"), so match the child by
             * PCI\VEN_vvvv&DEV_dddd against what the bus still holds. */
            d = 0;
            p = FindStr(id, "PCI\\VEN_");
            if (p && p[12] == '&') {
                ULONG vid = ParseHexN(p + 8, 4), did = ParseHexN(p + 17, 4);
                ULONG k;
                d = 1;
                for (k = 0; k < 32; k++) {
                    if ((newMask & (1UL << k)) &&
                        x->Ids[k] == (vid | (did << 16))) {
                        d = 0;
                    }
                }
            }
            if (d) {
                ULONG q, m;
                q = CM2(CMS_Query_Remove_SubTree, c, 1 /* UI_NOT_OK */);
                m = CM2(CMS_Remove_SubTree, c, 1 /* UI_NOT_OK */);
                LOGP(); LogS("removed "); LogS(id); LogS(" query cr=");
                LogX(q); LogS(" remove cr="); LogX(m); LogS("\n");
            }
            c = next;
        }
    }
    r = CM2(CMS_Reenumerate_DevNode, br, 0);
    LOGP(); LogS("Reenumerate_DevNode(bridge) cr="); LogX(r); LogS("\n");
}

static void CmDumpBridge(PDEVEXT x)
{
    ULONG root = 0, br;
    if (!g_CmOk) return;
    CM3(CMS_Locate_DevNode, &root, NULL, 0);
    br = CmFindBdf(root, x->Bus, x->Dev, x->Fn, 0);
    if (br) {
        LOGP(); LogS("bridge children 3 s later:\n");
        CmDumpChildren(br);
    }
}

/* ---------------------------------------------------------- thread */

static void Sleep500(PDEVEXT x, LONG ms, BOOLEAN *stop)
{
    LARGE_INTEGER t;
    NTSTATUS s;
    t.QuadPart = Int32x32To64(-10000, ms);
    s = KeWaitForSingleObject(&x->StopEvt, Executive, KernelMode, FALSE, &t);
    *stop = (BOOLEAN)(s == STATUS_SUCCESS);
}

static VOID PollThread(PVOID ctx)
{
    PDEVEXT x = (PDEVEXT)ctx;
    BOOLEAN stop = FALSE;
    ULONG mask, sec;
    int i;

    x->LastMask = ScanSecondary(x, &sec);
    LOGP(); LogS("poll start role="); LogX(x->Role); LogS(" mode=");
    LogX(x->Mode); LogS(" bridge "); LogX(x->Bus); LogS(":"); LogX(x->Dev);
    LogS("."); LogX(x->Fn); LogS(" sec="); LogX(sec); LogS(" mask=");
    LogX(x->LastMask); LogS("\n");
    if (x->Mode == 2 && g_Win98) {
        CmDumpBridge(x);
    }
    for (;;) {
        Sleep500(x, 500, &stop);
        if (stop) break;
        mask = ScanSecondary(x, &sec);
        if (mask == x->LastMask) continue;
        LOGP(); LogS("presence change sec="); LogX(sec); LogS(" ");
        LogX(x->LastMask); LogS(" -> "); LogX(mask); LogS("\n");
        if (x->Mode == 1 && x->Role == ROLE_FILTER) {
            IoInvalidateDeviceRelations(x->Pdo, BusRelations);
            LOGP(); LogS("IoInvalidateDeviceRelations(BusRelations) called\n");
        } else if (x->Mode == 2 && g_Win98) {
            CmAct(x, x->LastMask, mask);
        }
        x->LastMask = mask;
        if (x->Mode == 2 && g_Win98) {
            for (i = 0; i < 6 && !stop; i++) Sleep500(x, 500, &stop);
            if (stop) break;
            CmDumpBridge(x);
        }
    }
    LOGP(); LogS("poll stop\n");
    KeSetEvent(&x->DoneEvt, 0, FALSE);
    PsTerminateSystemThread(STATUS_SUCCESS);
}

static void StartPoll(PDEVEXT x)
{
    HANDLE h;
    NTSTATUS s;
    if (x->Running) return;
    KeInitializeEvent(&x->StopEvt, NotificationEvent, FALSE);
    KeInitializeEvent(&x->DoneEvt, NotificationEvent, FALSE);
    s = PsCreateSystemThread(&h, 0, NULL, NULL, NULL, PollThread, x);
    if (NT_SUCCESS(s)) {
        x->Running = 1;
        ZwClose(h);
    }
    LOGP(); LogS("PsCreateSystemThread st="); LogX(s); LogS("\n");
}

static void StopPoll(PDEVEXT x)
{
    if (!x->Running) return;
    KeSetEvent(&x->StopEvt, 0, FALSE);
    /* Windows 98: wait on an event, not the thread object (xhci98 run-26). */
    KeWaitForSingleObject(&x->DoneEvt, Executive, KernelMode, FALSE, NULL);
    x->Running = 0;
}

/* ------------------------------------------------------------- IRPs */

static NTSTATUS PassThrough(PDEVICE_OBJECT d, PIRP irp)
{
    PDEVEXT x = (PDEVEXT)d->DeviceExtension;
    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(x->Lower, irp);
}

static NTSTATUS Power(PDEVICE_OBJECT d, PIRP irp)
{
    PDEVEXT x = (PDEVEXT)d->DeviceExtension;
    PoStartNextPowerIrp(irp);
    IoSkipCurrentIrpStackLocation(irp);
    return PoCallDriver(x->Lower, irp);
}

static NTSTATUS SyncDone(PDEVICE_OBJECT d, PIRP irp, PVOID ctx)
{
    UNREFERENCED_PARAMETER(d);
    UNREFERENCED_PARAMETER(irp);
    KeSetEvent((PKEVENT)ctx, 0, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}

static NTSTATUS RelDone(PDEVICE_OBJECT d, PIRP irp, PVOID ctx)
{
    PDEVICE_RELATIONS r = (PDEVICE_RELATIONS)irp->IoStatus.Information;
    UNREFERENCED_PARAMETER(d);
    UNREFERENCED_PARAMETER(ctx);
    if (irp->PendingReturned) {
        IoMarkIrpPending(irp);
    }
    LOGP(); LogS("QUERY_DEVICE_RELATIONS(Bus) done st=");
    LogX(irp->IoStatus.Status); LogS(" count=");
    LogX(r ? r->Count : 0xFFFFFFFF); LogS("\n");
    return STATUS_SUCCESS;
}

static NTSTATUS Pnp(PDEVICE_OBJECT d, PIRP irp)
{
    PDEVEXT x = (PDEVEXT)d->DeviceExtension;
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(irp);
    KEVENT ev;
    NTSTATUS s;

    switch (sp->MinorFunction) {
    case IRP_MN_START_DEVICE:
        KeInitializeEvent(&ev, NotificationEvent, FALSE);
        IoCopyCurrentIrpStackLocationToNext(irp);
        IoSetCompletionRoutine(irp, SyncDone, &ev, TRUE, TRUE, TRUE);
        s = IoCallDriver(x->Lower, irp);
        if (s == STATUS_PENDING) {
            KeWaitForSingleObject(&ev, Executive, KernelMode, FALSE, NULL);
        }
        s = irp->IoStatus.Status;
        LOGP(); LogS("START_DEVICE st="); LogX(s); LogS("\n");
        if (NT_SUCCESS(s)) {
            StartPoll(x);
        }
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return s;
    case IRP_MN_QUERY_DEVICE_RELATIONS:
        if (sp->Parameters.QueryDeviceRelations.Type == BusRelations) {
            LOGP(); LogS("QUERY_DEVICE_RELATIONS(Bus) role=");
            LogX(x->Role); LogS("\n");
            IoCopyCurrentIrpStackLocationToNext(irp);
            IoSetCompletionRoutine(irp, RelDone, NULL, TRUE, TRUE, TRUE);
            return IoCallDriver(x->Lower, irp);
        }
        break;
    case IRP_MN_STOP_DEVICE:
    case IRP_MN_SURPRISE_REMOVAL:
        LOGP(); LogS("PnP minor "); LogX(sp->MinorFunction); LogS("\n");
        StopPoll(x);
        break;
    case IRP_MN_REMOVE_DEVICE:
        LOGP(); LogS("REMOVE_DEVICE\n");
        StopPoll(x);
        IoSkipCurrentIrpStackLocation(irp);
        s = IoCallDriver(x->Lower, irp);
        IoDetachDevice(x->Lower);
        IoDeleteDevice(d);
        return s;
    default:
        break;
    }
    IoSkipCurrentIrpStackLocation(irp);
    return IoCallDriver(x->Lower, irp);
}

/* ---------------------------------------------------------- AddDevice */

static BOOLEAN MultiSzHas(const WCHAR *buf, ULONG bytes, const char *pat)
{
    ULONG n = bytes / sizeof(WCHAR), i, j;
    for (i = 0; i < n; i++) {
        for (j = 0; pat[j] && i + j < n; j++) {
            WCHAR c = buf[i + j];
            if (c >= 'a' && c <= 'z') c -= 32;
            if (c != (WCHAR)pat[j]) break;
        }
        if (!pat[j]) return TRUE;
    }
    return FALSE;
}

static ULONG GetProp(PDEVICE_OBJECT pdo, DEVICE_REGISTRY_PROPERTY p,
                     WCHAR *buf, ULONG len)
{
    ULONG got = 0;
    NTSTATUS s;
    buf[0] = 0;
    s = IoGetDeviceProperty(pdo, p, len, buf, &got);
    return NT_SUCCESS(s) ? got : 0;
}

static ULONG RegDword(HANDLE k, PCWSTR name, ULONG def)
{
    UNICODE_STRING u;
    UCHAR b[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + 8];
    PKEY_VALUE_PARTIAL_INFORMATION pi = (PKEY_VALUE_PARTIAL_INFORMATION)b;
    ULONG got = 0;
    RtlInitUnicodeString(&u, name);
    if (NT_SUCCESS(ZwQueryValueKey(k, &u, KeyValuePartialInformation, pi,
                                   sizeof(b), &got)) &&
        pi->DataLength >= 4) {
        return *(ULONG *)pi->Data;
    }
    return def;
}

static NTSTATUS AddDevice(PDRIVER_OBJECT drv, PDEVICE_OBJECT pdo)
{
    WCHAR ids[256];
    ULONG hwLen, cpLen, role, v, got;
    PDEVICE_OBJECT d;
    PDEVEXT x;
    HANDLE k;
    NTSTATUS s;

    hwLen = GetProp(pdo, DevicePropertyHardwareID, ids, sizeof(ids));
    LOGP(); LogS("AddDevice hwid="); LogW(ids, 128); LogS("\n");
    if (MultiSzHas(ids, hwLen, "VEN_1B36&DEV_00F4")) {
        role = ROLE_HOST;
    } else {
        cpLen = GetProp(pdo, DevicePropertyCompatibleIDs, ids, sizeof(ids));
        role = MultiSzHas(ids, cpLen, "PCI\\CC_0604") ? ROLE_FILTER : 0;
    }
    if (!role) {
        LOGP(); LogS("not a PCI-PCI bridge or usb4-host, not attaching\n");
        return STATUS_SUCCESS;
    }
    s = IoCreateDevice(drv, sizeof(DEVEXT), NULL, FILE_DEVICE_UNKNOWN, 0,
                       FALSE, &d);
    if (!NT_SUCCESS(s)) return s;
    x = (PDEVEXT)d->DeviceExtension;
    for (got = 0; got < sizeof(*x); got++) ((PUCHAR)x)[got] = 0;
    x->Self = d;
    x->Pdo = pdo;
    x->Role = role;
    KeInitializeEvent(&x->StopEvt, NotificationEvent, FALSE);
    KeInitializeEvent(&x->DoneEvt, NotificationEvent, FALSE);
    x->Lower = IoAttachDeviceToDeviceStack(d, pdo);
    if (!x->Lower) {
        IoDeleteDevice(d);
        return STATUS_NO_SUCH_DEVICE;
    }
    d->Flags |= x->Lower->Flags & (DO_BUFFERED_IO | DO_DIRECT_IO |
                                   DO_POWER_PAGABLE);
    d->DeviceType = x->Lower->DeviceType;
    d->Characteristics = x->Lower->Characteristics;

    /* Which bridge: the filter's own location if the OS reports it. */
    x->Bus = 0;
    x->Dev = 5;
    x->Fn = 0;
    if (role == ROLE_FILTER) {
        got = 0;
        if (NT_SUCCESS(IoGetDeviceProperty(pdo, DevicePropertyBusNumber, 4,
                                           &v, &got))) {
            x->Bus = v;
            if (NT_SUCCESS(IoGetDeviceProperty(pdo, DevicePropertyAddress, 4,
                                               &v, &got))) {
                x->Dev = v >> 16;
                x->Fn = v & 0xFFFF;
            }
        } else {
            LOGP(); LogS("no DevicePropertyBusNumber, default 00:05.0\n");
        }
    }
    x->Mode = (role == ROLE_FILTER) ? 1 : (g_Win98 ? 2 : 0);
    if (NT_SUCCESS(IoOpenDeviceRegistryKey(pdo, PLUGPLAY_REGKEY_DEVICE,
                                           KEY_READ, &k))) {
        x->Mode = RegDword(k, L"ReenumMode", x->Mode);
        if (role == ROLE_HOST) {
            x->Bus = RegDword(k, L"BridgeBus", x->Bus);
            x->Dev = RegDword(k, L"BridgeDev", x->Dev);
        }
        ZwClose(k);
    }
    LOGP(); LogS("attached role="); LogX(role); LogS(" mode="); LogX(x->Mode);
    LogS(" bridge "); LogX(x->Bus); LogS(":"); LogX(x->Dev); LogS(".");
    LogX(x->Fn); LogS(" lower="); LogX((ULONG)x->Lower); LogS("\n");
    d->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}

static VOID Unload(PDRIVER_OBJECT drv)
{
    UNREFERENCED_PARAMETER(drv);
    LOGP(); LogS("Unload\n");
}

NTSTATUS DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg)
{
    ULONG i;
    g_Win98 = !IoIsWdmVersionAvailable(1, 0x10);
    LOGP(); LogS("DriverEntry win98="); LogX(g_Win98); LogS(" reg=");
    LogW(reg->Buffer, reg->Length / 2); LogS("\n");
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++) {
        drv->MajorFunction[i] = PassThrough;
    }
    drv->MajorFunction[IRP_MJ_PNP] = Pnp;
    drv->MajorFunction[IRP_MJ_POWER] = Power;
    drv->DriverExtension->AddDevice = AddDevice;
    drv->DriverUnload = Unload;
    if (g_Win98) {
        CmProbe();
    }
    return STATUS_SUCCESS;
}
