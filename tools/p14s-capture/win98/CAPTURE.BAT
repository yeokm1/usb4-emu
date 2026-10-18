@ECHO OFF
REM SPDX-License-Identifier: GPL-2.0-only
REM usb4-emu P14s capture for Windows 98 SE, in MS-DOS mode or a DOS box.
REM Usage: CAPTURE <folder> [N]    e.g. CAPTURE ON_ON   or   CAPTURE ON_ON N
REM Creates <folder> (DOS 8.3 name: up to 8 letters, digits, _ or -) under
REM the current directory and writes every result into it.
REM N: also run PCIDUMP /N (Thunderbolt NHI register reads, plain MS-DOS
REM mode without EMM386 only) into PCIDUMPN.TXT, after the normal dump.
REM Run from the folder that holds PCIDUMP.COM, e.g. C:\P14SCAP.
REM Read-only: PCI config and NHI register reads, registry export, copies.
IF "%1"=="" GOTO usage
IF NOT EXIST PCIDUMP.COM GOTO nocom
IF EXIST %1\NUL GOTO exists
MD %1
IF NOT EXIST %1\NUL GOTO mdfail
ECHO Capturing into %1 ...
ECHO Run label: %1 > %1\RUN.TXT
ECHO.| DATE >> %1\RUN.TXT
ECHO.| TIME >> %1\RUN.TXT
ECHO Running PCIDUMP (PCI walk, a few seconds)...
PCIDUMP > %1\PCIDUMP.TXT
IF "%2"=="N" GOTO nhi
IF "%2"=="n" GOTO nhi
GOTO nonhi
:nhi
ECHO Running PCIDUMP /N (NHI registers)...
PCIDUMP /N > %1\PCIDUMPN.TXT
:nonhi
VER > %1\VER.TXT
SET > %1\ENV.TXT
MEM /C > %1\MEM.TXT
ECHO Exporting registry HKLM\Enum ...
REGEDIT /E %1\ENUM.REG HKEY_LOCAL_MACHINE\Enum
IF EXIST %1\ENUM.REG GOTO regdone
REM In MS-DOS mode REGEDIT needs the registry file locations.
IF "%windir%"=="" SET windir=C:\WINDOWS
REGEDIT /L:%windir%\SYSTEM.DAT /R:%windir%\USER.DAT /E %1\ENUM.REG HKEY_LOCAL_MACHINE\Enum
:regdone
IF EXIST C:\BOOTLOG.TXT COPY C:\BOOTLOG.TXT %1\BOOTLOG.TXT > NUL
IF EXIST C:\CONFIG.SYS COPY C:\CONFIG.SYS %1\CONFIG.TXT > NUL
IF EXIST C:\AUTOEXEC.BAT COPY C:\AUTOEXEC.BAT %1\AUTOEXEC.TXT > NUL
IF EXIST %windir%\IOS.LOG COPY %windir%\IOS.LOG %1\IOS.LOG > NUL
ECHO.
ECHO Done. All results are in folder %1:
DIR /B %1
ECHO Bring back the whole %1 folder.
GOTO end
:usage
ECHO Usage: CAPTURE folder [N]
ECHO   folder = a new folder name for this run, up to 8 characters,
ECHO   e.g.  CAPTURE ON_ON   or   CAPTURE OFF_OFF   or   CAPTURE ON_ON_NO
ECHO   N = also read the Thunderbolt controller registers (PCIDUMPN.TXT)
GOTO end
:exists
ECHO Folder %1 already exists. Pick a new name so earlier results are kept.
GOTO end
:mdfail
ECHO Could not create folder %1. Use up to 8 letters, digits, _ or -.
GOTO end
:nocom
ECHO PCIDUMP.COM not found. Run this from its folder, or recreate it with
ECHO DEBUG, feeding it MKPCIDMP.SCR as input (see README).
:end
