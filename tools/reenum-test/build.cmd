@echo off
rem SPDX-License-Identifier: GPL-2.0-only
rem Copyright (c) 2026 usb4-emu contributors
rem
rem Build reenum.sys (WDM, Win98 SE + Win2000) and cmreenum.exe with the
rem MSVC 6.0 compiler and the Windows 2000 DDK from the xhci98 checkout,
rem run in place. Every output and temp file goes to out\ here.
rem   XHCI98=<path to xhci98 checkout>  (default D:\OneDrive\git-projects\xhci98)
setlocal
if "%XHCI98%"=="" set "XHCI98=D:\OneDrive\git-projects\xhci98"
set "HERE=%~dp0"
set "OUT=%HERE%out"
set "VC=%XHCI98%\tools\MSVC600\VC98"
set "DDK=%XHCI98%\tools\ntddk"
if not exist "%OUT%\tmp" mkdir "%OUT%\tmp"
set "TEMP=%OUT%\tmp"
set "TMP=%OUT%\tmp"
set "PATH=%VC%\Bin;%XHCI98%\tools\MSVC600\Common\MSDev98\Bin;%PATH%"
set "INCLUDE="
set "LIB="
cd /d "%OUT%"

set CDEFS=/D_X86_=1 /Di386=1 /DSTD_CALL /DCONDITION_HANDLING=1 /DNT_UP=1 /DNT_INST=0 /DWIN32=100 /D_NT1X_=100 /DWINNT=1 /D_WIN32_WINNT=0x0500 /DWINVER=0x0500 /DDBG=0 /DFPO=1
cl /nologo /c /Gz /W3 /WX /O1 /Oi- /GF /Gy /Zl /X %CDEFS% /I"%DDK%\inc" /I"%VC%\Include" /Fo"%OUT%\reenum.obj" "%HERE%reenum.c"
if errorlevel 1 exit /b 1
link /nologo /driver /base:0x10000 /align:0x20 /subsystem:native,4.00 /entry:DriverEntry@8 /nodefaultlib /out:"%OUT%\reenum.sys" "%OUT%\reenum.obj" "%DDK%\libfre\i386\wdm.lib"
if errorlevel 1 exit /b 1

cl /nologo /W3 /O1 /X /I"%VC%\Include" /Fo"%OUT%\cmreenum.obj" /Fe"%OUT%\cmreenum.exe" "%HERE%cmreenum.c" /link /libpath:"%VC%\Lib" /subsystem:console,4.0
if errorlevel 1 exit /b 1
dumpbin /imports "%OUT%\reenum.sys" > "%OUT%\reenum-imports.txt"
echo built: %OUT%\reenum.sys %OUT%\cmreenum.exe
