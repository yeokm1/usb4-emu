@echo off
rem reenum experiment: copy the driver and merge one .reg (Windows 98 SE)
copy d:\reenum.sys c:\windows\system32\drivers\reenum.sys
if not "%1"=="" regedit /s d:\%1.reg
