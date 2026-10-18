# wmake makefile for USB4CM.EXE (Open Watcom 2.0, 32-bit flat, DOS/32A).
# Build with build.cmd. "system dos32a" embeds the DOS/32A extender as
# the EXE stub, so USB4CM.EXE is one standalone file (same approach as
# xhci98's XHCIQUAL.EXE).
#
# -bt=dos DOS target  -mf flat model  -s no stack checks  -za C89 strict

CC = wcc386
CFLAGS = -bt=dos -mf -q -s -wx -ox -zq
CORE = ..\core

OBJS = usb4cm.obj u4hi.obj u4cm.obj

usb4cm.exe : $(OBJS)
	wlink system dos32a option quiet option map=usb4cm.map name $^@ file { $(OBJS) }

usb4cm.obj : usb4cm.c $(CORE)\usb4cm.h $(CORE)\u4types.h
	$(CC) $(CFLAGS) -i=$(CORE) usb4cm.c

# The core is compiled with -za (strict ANSI C89, no extensions).
u4hi.obj : $(CORE)\u4hi.c $(CORE)\usb4cm.h $(CORE)\u4regs.h $(CORE)\u4types.h
	$(CC) $(CFLAGS) -za -i=$(CORE) -fo=u4hi.obj $(CORE)\u4hi.c

u4cm.obj : $(CORE)\u4cm.c $(CORE)\usb4cm.h $(CORE)\u4regs.h $(CORE)\u4types.h
	$(CC) $(CFLAGS) -za -i=$(CORE) -fo=u4cm.obj $(CORE)\u4cm.c

clean : .SYMBOLIC
	-del *.obj
	-del usb4cm.exe
	-del usb4cm.map
