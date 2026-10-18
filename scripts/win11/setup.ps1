# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# First-logon setup for the usb4-emu Windows 11 test VM. Run from
# autounattend.xml FirstLogonCommands with -Source <drive>:\usb4 (the vvfat
# install stick). Installs the guest command agent and makes the VM quiet:
# no sleep, no hibernation, no screen-off, no automatic update reboots.

param([Parameter(Mandatory = $true)][string]$Source)

$ErrorActionPreference = 'Continue'
$dst = 'C:\usb4agent'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Start-Transcript -Path "$dst\setup.log" -Append

Copy-Item -Force "$Source\agent.ps1", "$Source\token.txt" $dst
if (Test-Path "$Source\guest-usb4-trace.ps1") { Copy-Item -Force "$Source\guest-usb4-trace.ps1" $dst }

# Agent: scheduled task at boot as SYSTEM, no time limit, restart on failure.
$port = 8000
if (Test-Path "$Source\agent-port.txt") { $port = [int](Get-Content "$Source\agent-port.txt").Trim() }
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $dst\agent.ps1 -Port $port"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'usb4-agent' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force | Out-Null
New-NetFirewallRule -DisplayName 'usb4-agent' -Direction Inbound -Protocol TCP -LocalPort $port `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
Start-ScheduledTask -TaskName 'usb4-agent'
# Keep Defender from scanning agent temp scripts and traces.
Add-MpPreference -ExclusionPath $dst -ErrorAction SilentlyContinue

# Power: high performance, never sleep / hibernate / blank, power button = shut down.
powercfg /setactive SCHEME_MIN
foreach ($s in 'monitor-timeout-ac', 'monitor-timeout-dc', 'standby-timeout-ac', 'standby-timeout-dc',
               'hibernate-timeout-ac', 'hibernate-timeout-dc', 'disk-timeout-ac', 'disk-timeout-dc') {
    powercfg /change $s 0
}
powercfg /hibernate off
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /setactive SCHEME_CURRENT
reg add 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' /v HiberbootEnabled /t REG_DWORD /d 0 /f
# No lock screen / screensaver; system_powerdown must not be vetoed by a lock.
reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' /v NoLockScreen /t REG_DWORD /d 1 /f
reg add 'HKCU\Control Panel\Desktop' /v ScreenSaveActive /t REG_SZ /d 0 /f
reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v shutdownwithoutlogon /t REG_DWORD /d 1 /f

# Windows Update: notify only, never auto-reboot with a user logged on.
$wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
reg add $wu /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg add $wu /v AUOptions /t REG_DWORD /d 2 /f
reg add $wu /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f
reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' /v SetDisableUXWUAccess /t REG_DWORD /d 1 /f

# Autologon forever (the unattend LogonCount counts down).
$wl = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
reg add $wl /v AutoAdminLogon /t REG_SZ /d 1 /f
reg delete $wl /v AutoLogonCount /f 2>$null

# Show the setup is done (the host can also poll the agent).
Set-Content -Path "$dst\setup-done.txt" -Value (Get-Date -Format o)
Stop-Transcript
