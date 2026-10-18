/*
 * u4types.h - fixed-width types for the usb4cm core (C89).
 *
 * Copyright (c) 2026 usb4-emu contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Written from scratch for the usb4-emu project. No <stdint.h>: MSVC 6.0
 * does not have it. Every supported compiler (MSVC 6.0 x86, Open Watcom
 * 386, MinGW gcc, 32- or 64-bit Windows) has a 32-bit long, which is
 * what xhci98's ULONG relies on too. A driver that already has the DDK
 * types may define U4_HAVE_TYPES and supply u8/u16/u32 itself.
 *
 * No 64-bit types are used anywhere in the core: route strings are kept
 * as a high/low pair of u32 (Spec 2.0 section 6.4.2.2, the route string
 * is 56 bits on the wire anyway) and DMA addresses are 32-bit.
 */
#ifndef U4TYPES_H
#define U4TYPES_H

#ifndef U4_HAVE_TYPES
typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;
#endif

/* Compile-time check that u32 really is 32 bits (C89 has no static_assert). */
typedef char u4_u32_is_32_bits[(sizeof(u32) == 4) ? 1 : -1];

#endif
