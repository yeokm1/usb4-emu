/*
 * SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 usb4-emu contributors
 *
 * cmreenum.exe - THROWAWAY EXPERIMENT (mechanism C, the user-mode baseline).
 * Win32 console tool for Windows 98 SE and Windows 2000 using CFGMGR32.
 *
 *   cmreenum list   [prefix]   show the bridge and its children
 *   cmreenum scan   [prefix]   CM_Reenumerate_DevNode(bridge)
 *   cmreenum remove [prefix]   remove every child of the bridge, then scan
 *
 * prefix: device ID prefix of the bridge, default PCI\VEN_1B36&DEV_0001.
 * CFGMGR32 entry points are resolved with GetProcAddress so the same binary
 * runs on both systems (CM_Query_And_Remove_SubTreeA is NT 5 only;
 * CM_Query_Remove_SubTree + CM_Remove_SubTree are used where it is absent).
 */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef DWORD (WINAPI *PLOCATE)(DWORD *, char *, ULONG);
typedef DWORD (WINAPI *PREL)(DWORD *, DWORD, ULONG);
typedef DWORD (WINAPI *PGETID)(DWORD, char *, ULONG, ULONG);
typedef DWORD (WINAPI *P2)(DWORD, ULONG);
typedef DWORD (WINAPI *PQAR)(DWORD, int *, char *, ULONG, ULONG);
typedef DWORD (WINAPI *PSTAT)(ULONG *, ULONG *, DWORD, ULONG);

static PLOCATE pLocate;
static PREL pChild, pSibling;
static PGETID pGetId;
static P2 pReenum, pQRemove, pRemove;
static PQAR pQAR;
static PSTAT pStatus;

static DWORD Find(DWORD dn, const char *prefix, int depth)
{
    char id[256];
    DWORD c, f;
    id[0] = 0;
    if (pGetId(dn, id, sizeof(id), 0) == 0 &&
        _strnicmp(id, prefix, strlen(prefix)) == 0) {
        return dn;
    }
    if (depth > 12 || pChild(&c, dn, 0) != 0) {
        return 0;
    }
    do {
        f = Find(c, prefix, depth + 1);
        if (f) {
            return f;
        }
    } while (pSibling(&c, c, 0) == 0);
    return 0;
}

static void List(DWORD br)
{
    char id[256];
    DWORD c;
    ULONG st, pb;
    int n = 0;
    pGetId(br, id, sizeof(id), 0);
    printf("bridge %s\n", id);
    if (pChild(&c, br, 0) == 0) {
        do {
            id[0] = 0;
            st = pb = 0;
            pGetId(c, id, sizeof(id), 0);
            pStatus(&st, &pb, c, 0);
            printf("  child %s status=%08lX problem=%lu\n", id, st, pb);
            n++;
        } while (pSibling(&c, c, 0) == 0);
    }
    printf("  %d child(ren)\n", n);
}

static void RemoveChildren(DWORD br)
{
    DWORD c, next;
    DWORD r, q;
    char id[256];
    int veto = 0;
    char vname[256];
    if (pChild(&c, br, 0) != 0) {
        printf("no children\n");
        return;
    }
    for (;;) {
        next = 0;
        r = pSibling(&next, c, 0);
        pGetId(c, id, sizeof(id), 0);
        if (pQAR) {
            vname[0] = 0;
            q = pQAR(c, &veto, vname, sizeof(vname), 0x1 /* UI_NOT_OK */);
            printf("CM_Query_And_Remove_SubTree %s -> %lu veto=%d %s\n", id,
                   q, veto, vname);
        } else {
            q = pQRemove(c, 0x1);
            printf("CM_Query_Remove_SubTree %s -> %lu\n", id, q);
            q = pRemove(c, 0x1);
            printf("CM_Remove_SubTree -> %lu\n", q);
        }
        if (r != 0) {
            break;
        }
        c = next;
    }
}

int main(int argc, char **argv)
{
    HMODULE h = LoadLibraryA("cfgmgr32.dll");
    const char *cmd = argc > 1 ? argv[1] : "list";
    const char *prefix = argc > 2 ? argv[2] : "PCI\\VEN_1B36&DEV_0001";
    DWORD root, br;
    DWORD r;

    if (!h) {
        printf("cfgmgr32.dll not loaded (%lu)\n", GetLastError());
        return 2;
    }
    pLocate = (PLOCATE)GetProcAddress(h, "CM_Locate_DevNodeA");
    pChild = (PREL)GetProcAddress(h, "CM_Get_Child");
    pSibling = (PREL)GetProcAddress(h, "CM_Get_Sibling");
    pGetId = (PGETID)GetProcAddress(h, "CM_Get_Device_IDA");
    pReenum = (P2)GetProcAddress(h, "CM_Reenumerate_DevNode");
    pQRemove = (P2)GetProcAddress(h, "CM_Query_Remove_SubTree");
    pRemove = (P2)GetProcAddress(h, "CM_Remove_SubTree");
    pQAR = (PQAR)GetProcAddress(h, "CM_Query_And_Remove_SubTreeA");
    pStatus = (PSTAT)GetProcAddress(h, "CM_Get_DevNode_Status");
    if (!pLocate || !pChild || !pSibling || !pGetId || !pReenum ||
        !pStatus || (!pQAR && (!pQRemove || !pRemove))) {
        printf("missing CFGMGR32 export\n");
        return 2;
    }
    r = pLocate(&root, NULL, 0);
    if (r != 0) {
        printf("CM_Locate_DevNode(root) -> %lu\n", r);
        return 1;
    }
    br = Find(root, prefix, 0);
    if (!br) {
        printf("no devnode with prefix %s\n", prefix);
        return 1;
    }
    if (_stricmp(cmd, "remove") == 0) {
        RemoveChildren(br);
        cmd = "scan";
    }
    if (_stricmp(cmd, "scan") == 0) {
        r = pReenum(br, 0);
        printf("CM_Reenumerate_DevNode -> %lu\n", r);
        Sleep(3000);
    }
    List(br);
    return 0;
}
