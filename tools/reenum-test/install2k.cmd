@echo off
rem reenum experiment, Windows 2000: copy the driver, merge filter2k.reg.
copy /y d:\reenum.sys %SystemRoot%\system32\drivers\reenum.sys
regedit /s d:\filter2k.reg
echo installed; restart Windows
