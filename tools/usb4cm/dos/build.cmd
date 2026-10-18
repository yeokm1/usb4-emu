@echo off
rem build.cmd - build USB4CM.EXE with Open Watcom 2.0 (default C:\WATCOM).
rem Outputs (objects, USB4CM.EXE, USB4CM.MAP) stay in this directory.
rem The DOS tool needs the DOS headers (%WATCOM%\H), so the environment
rem is set locally here.

setlocal
if "%WATCOM%"=="" set WATCOM=C:\WATCOM
rem BINW holds dos32a.exe, which wlink embeds as the EXE stub
set PATH=%WATCOM%\BINNT64;%WATCOM%\BINNT;%WATCOM%\BINW;%PATH%
set INCLUDE=%WATCOM%\H

cd /d "%~dp0"
wmake -h %*
if errorlevel 1 exit /b 1
echo Built USB4CM.EXE (standalone, DOS/32A extender embedded as the stub).
endlocal
