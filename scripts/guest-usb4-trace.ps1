# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# USB4 connection-manager tracing helper for the Windows 11 test guest.
# Run inside the guest (as admin/SYSTEM, e.g. through the agent):
#
#   python scripts/guest.py exec "C:\usb4agent\guest-usb4-trace.ps1 start"
#   ... reproduce ...
#   python scripts/guest.py exec "C:\usb4agent\guest-usb4-trace.ps1 collect"
#   python scripts/guest.py get C:\usb4agent\traces\usb4-latest.zip usb4.zip
#
# Actions:
#   start      start a real-time ETW session "usb4emu" to an .etl file
#   stop       stop the session
#   collect    stop (if running) + gather the .etl, a TraceLogging decode,
#              PnP/device state, event logs and setupapi log into a zip
#   bootstart  register the same session as an autologger, so it starts at
#              the next boot (for enumeration problems during boot)
#   bootstop   stop and unregister the autologger
#   status     show session state
#
# Providers (see docs/WINDOWS-DEBUG.md for where these come from):
#   USB4 host router WPP     {505A6797-992E-43E6-B84E-235E41E3FD82}
#   USB4 device router WPP   {1B502FCB-68CD-4407-A59E-1EAF8AB9EA26}
#   USB4 host router TLG     {575BA31F-2B45-58C2-64FD-F5DC757B6137}
#   USB4 device router TLG   {AE795D36-2B11-5EFB-C7E0-5D552BC55D6C}
#   PCI bus driver WPP       {47711976-08C7-44EF-8FA2-082DA6A30A30}
#   Microsoft-Windows-Kernel-PnP
# WPP messages need the driver's TMF/PDB to decode; the TraceLogging rundown
# events (router, port and adapter information) are self-describing and are
# decoded into the zip with tracerpt.

param(
    [Parameter(Position = 0)][ValidateSet('start', 'stop', 'collect', 'bootstart', 'bootstop', 'status')]
    [string]$Action = 'status',
    [string]$OutDir = 'C:\usb4agent\traces'
)

$ErrorActionPreference = 'Continue'
$Session = 'usb4emu'
$Providers = @(
    '{505A6797-992E-43E6-B84E-235E41E3FD82}',
    '{1B502FCB-68CD-4407-A59E-1EAF8AB9EA26}',
    '{575BA31F-2B45-58C2-64FD-F5DC757B6137}',
    '{AE795D36-2B11-5EFB-C7E0-5D552BC55D6C}',
    '{47711976-08C7-44EF-8FA2-082DA6A30A30}',
    'Microsoft-Windows-Kernel-PnP'
)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Etl = Join-Path $OutDir 'usb4emu.etl'
$BootEtl = Join-Path $OutDir 'usb4emu-boot.etl'

function Start-Usb4Session([string]$name, [string]$etl, [string]$extra) {
    & logman.exe create trace $name -o $etl -bs 1024 -nb 64 512 -mode Sequential -max 512 $extra.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Out-Host
    foreach ($p in $Providers) {
        & logman.exe update trace $name -p $p 0xFFFFFFFFFFFFFFFF 0xFF $extra.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | Out-Host
    }
}

switch ($Action) {
    'start' {
        & logman.exe stop $Session -ets 2>$null | Out-Null
        Remove-Item -Force $Etl -ErrorAction SilentlyContinue
        Start-Usb4Session $Session $Etl '-ets'
        & logman.exe query $Session -ets | Out-Host
    }
    'stop' {
        & logman.exe stop $Session -ets | Out-Host
    }
    'bootstart' {
        & logman.exe delete "autosession\$Session" 2>$null | Out-Null
        Start-Usb4Session "autosession\$Session" $BootEtl ''
        # "logman update" on an autologger drops the directory of -o; set it back.
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$Session" -Name FileName -Value $BootEtl
        Write-Output "Autologger registered; reboot to start tracing into $BootEtl"
    }
    'bootstop' {
        & logman.exe stop $Session -ets 2>$null | Out-Null
        & logman.exe delete "autosession\$Session" | Out-Host
    }
    'status' {
        & logman.exe query -ets | Select-String -Pattern $Session, 'Data Collector Set' | Out-Host
        & logman.exe query "autosession\$Session" 2>$null | Out-Host
    }
    'collect' {
        & logman.exe stop $Session -ets 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dir = Join-Path $OutDir "usb4-$stamp"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($f in $Etl, $BootEtl) {
            if (Test-Path $f) {
                Copy-Item $f $dir
                $base = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($f))
                & tracerpt.exe $f -o "$base.xml" -of XML -summary "$base-summary.txt" -y | Out-Null
            }
        }
        # Device and driver state.
        Get-PnpDevice | Sort-Object Class, FriendlyName |
            Format-Table -AutoSize Status, Class, FriendlyName, InstanceId | Out-String -Width 400 |
            Set-Content (Join-Path $dir 'pnp-devices.txt')
        Get-PnpDevice | Where-Object { $_.InstanceId -match 'USB4|PCI\\VEN_8086|NVME|SCSI' -or $_.Class -match 'USB4|SCSIAdapter|DiskDrive' } |
            ForEach-Object {
                "=== $($_.InstanceId) [$($_.Status)] $($_.FriendlyName)"
                Get-PnpDeviceProperty -InstanceId $_.InstanceId -ErrorAction SilentlyContinue |
                    Where-Object { $_.Data -ne $null } | Format-Table -AutoSize KeyName, Data | Out-String -Width 400
            } | Set-Content (Join-Path $dir 'pnp-usb4-props.txt')
        & pnputil.exe /enum-devices /problem /drivers 2>&1 | Set-Content (Join-Path $dir 'pnputil-problem.txt')
        & pnputil.exe /enum-devices /bus PCI /drivers 2>&1 | Set-Content (Join-Path $dir 'pnputil-pci.txt')
        Get-Disk -ErrorAction SilentlyContinue | Format-List * | Out-String -Width 300 |
            Set-Content (Join-Path $dir 'disks.txt')
        # Event logs: System, PnP configuration, and anything USB4-named.
        $since = (Get-Date).AddHours(-6)
        $logs = @('System', 'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-Kernel-PnP/Device Management')
        $logs += (Get-WinEvent -ListLog *USB4* -ErrorAction SilentlyContinue).LogName
        foreach ($l in $logs | Where-Object { $_ }) {
            $safe = ($l -replace '[\\/ ]', '_')
            Get-WinEvent -FilterHashtable @{ LogName = $l; StartTime = $since } -ErrorAction SilentlyContinue |
                Format-List TimeCreated, Id, ProviderName, LevelDisplayName, Message | Out-String -Width 300 |
                Set-Content (Join-Path $dir "evt-$safe.txt")
        }
        Copy-Item "$env:SystemRoot\INF\setupapi.dev.log" $dir -ErrorAction SilentlyContinue
        $zip = Join-Path $OutDir "usb4-$stamp.zip"
        Compress-Archive -Path "$dir\*" -DestinationPath $zip -Force
        Copy-Item $zip (Join-Path $OutDir 'usb4-latest.zip') -Force
        Write-Output $zip
    }
}
