# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Yeo Kheng Meng
#
# Thunderbolt 3 (Alpine Ridge LP) capture under Windows 11 for the usb4-emu
# project. Run in an elevated Windows PowerShell:
#
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\capture-win11.ps1 assistOFF_prebootOFF
#   .\capture-win11.ps1 [-Label assistOFF_prebootOFF] [-OutDir E:\] [-NoTrace] [-NoRedact]
#
# Collects in %TEMP%; only p14s-win11-<date>-<time>[-<label>].zip and its
# .sha256 are written to -OutDir (default: this script's folder).
#
# Read-only except for: one temporary ETW trace session (stopped at the end)
# and the output folder. It never writes device registers, driver settings,
# firmware or BIOS settings. See ..\README.md.

[CmdletBinding()]
param(
    # The label may also be given as the first plain argument:
    #   .\capture-win11.ps1 assistOFF_prebootOFF
    [Parameter(Position = 0)]
    [ValidatePattern('^[A-Za-z0-9_.-]*$')]
    [string]$Label = '',
    [Parameter(Position = 1)]
    [string]$OutDir = $PSScriptRoot,
    [switch]$NoTrace,
    [switch]$NoRedact
)

$ErrorActionPreference = 'Continue'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'Run this from an elevated (Administrator) PowerShell.'
    exit 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = (Resolve-Path $OutDir).Path
$name = "p14s-win11-$stamp"
if ($Label) { $name += "-$Label" }
$O = Join-Path $env:TEMP $name
New-Item -ItemType Directory -Force $O | Out-Null
Start-Transcript -Path (Join-Path $O 'capture-transcript.txt') | Out-Null

function Save($name, $obj) {
    $p = Join-Path $O $name
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    $obj | Out-File -FilePath $p -Encoding utf8 -Width 400
}
function SaveJson($name, $obj) {
    $p = Join-Path $O $name
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    $obj | ConvertTo-Json -Depth 6 | Out-File -FilePath $p -Encoding utf8
}
function RunCmd($name, [string]$exe, [string[]]$cmdArgs) {
    $p = Join-Path $O $name
    New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
    "# $exe $($cmdArgs -join ' ')" | Out-File -FilePath $p -Encoding utf8 -Append
    & $exe @cmdArgs 2>&1 | Out-File -FilePath $p -Encoding utf8 -Append -Width 400
}
function Step($t) { Write-Host "`n=== $t" -ForegroundColor Cyan }

$tbPattern = 'thunderbolt|usb4|\btbt|nhi|VEN_8086&DEV_(15E[7-9A-F]|15D[2-4]|15B[56]|157[5-8]|15C0|15BF|15D9|15DA|15DB|15DC|15DD|15DE|15EF|15F0|8A0D|8A17|9A1[BDF]|9A21)'

# 1. System identity (no serial numbers or UUIDs).
Step 'System'
Save 'system/os.txt' (Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture | Format-List | Out-String)
Save 'system/bios.txt' (Get-CimInstance Win32_BIOS |
    Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate, BIOSVersion, SMBIOSMajorVersion, SMBIOSMinorVersion |
    Format-List | Out-String)
Save 'system/model.txt' (Get-CimInstance Win32_ComputerSystemProduct |
    Select-Object Vendor, Name, Version | Format-List | Out-String)
RunCmd 'system/secureboot.txt' 'powershell.exe' @('-NoProfile', '-Command', 'Confirm-SecureBootUEFI')
Save 'system/devicesecurity-kernel-dma.txt' (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
    -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue | Format-List | Out-String)

# 2. PnP devices.
Step 'PnP devices'
$all = Get-PnpDevice -ErrorAction SilentlyContinue
$keepBus = '^(PCI|ACPI|ACPI_HAL|ROOT|SWD|PCIE|TBT|THUNDERBOLT|USB4|HTREE|SW)\\'
$listed = $all | Where-Object { $_.InstanceId -match $keepBus -or "$($_.FriendlyName) $($_.Class)" -match $tbPattern }
Save 'pnp/devices-pci-acpi-tb.txt' ($listed | Sort-Object InstanceId |
    Select-Object Status, Present, Class, FriendlyName, InstanceId, Problem, ConfigManagerErrorCode |
    Format-Table -AutoSize | Out-String -Width 400)
$tb = $all | Where-Object {
    "$($_.FriendlyName) $($_.Class) $($_.InstanceId) $($_.HardwareID -join ' ') $($_.Service)" -match $tbPattern
}
$pciBridges = $all | Where-Object { $_.InstanceId -like 'PCI\*' -and $_.Class -eq 'System' }
$set = @($tb) + @($pciBridges) | Sort-Object InstanceId -Unique
Save 'pnp/tb-devices-summary.txt' ($tb | Select-Object Status, Class, FriendlyName, InstanceId, Service |
    Format-Table -AutoSize | Out-String -Width 400)
$i = 0
foreach ($d in $set) {
    $i++
    $props = Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
        Select-Object KeyName, Type, Data
    $safe = ($d.InstanceId -replace '[\\&:/]', '_')
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    Save "pnp/props/$('{0:D3}' -f $i)-$safe.txt" (
        "InstanceId: $($d.InstanceId)`r`n" +
        ($props | Format-Table -AutoSize -Wrap | Out-String -Width 600))
    RunCmd "pnp/pnputil/$('{0:D3}' -f $i)-$safe.txt" 'pnputil.exe' @('/enum-devices', '/instanceid', $d.InstanceId, '/resources', '/relations', '/drivers')
}
RunCmd 'pnp/pnputil-enum-pci.txt' 'pnputil.exe' @('/enum-devices', '/bus', 'PCI', '/deviceids', '/relations', '/drivers')
RunCmd 'pnp/pnputil-enum-problem.txt' 'pnputil.exe' @('/enum-devices', '/problem')
Save 'pnp/allocated-memory.txt' (Get-CimInstance Win32_DeviceMemoryAddress |
    Select-Object StartingAddress, EndingAddress, Name | Format-Table -AutoSize | Out-String -Width 300)
Save 'pnp/allocated-resources.txt' (Get-CimInstance Win32_PnPAllocatedResource |
    Select-Object @{n = 'Resource'; e = { $_.Antecedent.ToString() } }, @{n = 'Device'; e = { $_.Dependent.ToString() } } |
    Where-Object { $_.Device -match 'PCI' } | Format-Table -AutoSize | Out-String -Width 500)

# 3. Drivers, services, software.
Step 'Drivers and services'
RunCmd 'drivers/pnputil-enum-drivers.txt' 'pnputil.exe' @('/enum-drivers')
Save 'drivers/signed-drivers-tb.txt' (Get-CimInstance Win32_PnPSignedDriver |
    Where-Object { "$($_.DeviceName) $($_.HardWareID) $($_.InfName) $($_.Description)" -match $tbPattern } |
    Select-Object DeviceName, DeviceID, HardWareID, DriverProviderName, DriverVersion, DriverDate, InfName, Signer |
    Format-List | Out-String -Width 300)
$svcs = Get-CimInstance Win32_SystemDriver
$svcs += Get-CimInstance Win32_Service
$tbSvcs = $svcs | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match 'thunderbolt|(^|\W)tbt|usb4|\bnhi' }
$tbSvcs += $svcs | Where-Object { $_.Name -in @('pci', 'pcw', 'ACPI') }
Save 'drivers/services-tb.txt' ($tbSvcs | Select-Object Name, DisplayName, State, StartMode, PathName |
    Format-List | Out-String -Width 300)
foreach ($s in $tbSvcs) {
    RunCmd "registry/services/$($s.Name).reg.txt" 'reg.exe' @('query', "HKLM\SYSTEM\CurrentControlSet\Services\$($s.Name)", '/s')
    $img = "$($s.PathName)" -replace '^\\\?\?\\', '' -replace '^\\SystemRoot', $env:SystemRoot -replace '"', ''
    $img = ($img -split ' -| /')[0].Trim()
    if ($img -and (Test-Path $img)) {
        Save "drivers/files/$($s.Name).txt" ((Get-Item $img).VersionInfo | Format-List * | Out-String)
    }
}
Save 'drivers/appx-tb.txt' (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'thunderbolt' } | Select-Object Name, Version, Publisher | Format-List | Out-String)
Save 'drivers/programs-tb.txt' (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { "$($_.DisplayName) $($_.Publisher)" -match 'thunderbolt|intel' } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Format-Table -AutoSize | Out-String -Width 300)

# 4. Registry: device instance keys (incl. Device Parameters) and Intel TB keys.
Step 'Registry'
$n = 0
foreach ($d in $tb) {
    $n++
    RunCmd "registry/enum/$('{0:D3}' -f $n).txt" 'reg.exe' @('query', "HKLM\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)", '/s')
}
foreach ($k in @('HKLM\SOFTWARE\Intel\Thunderbolt', 'HKLM\SOFTWARE\Intel\ThunderboltService',
        'HKLM\SOFTWARE\WOW6432Node\Intel\Thunderbolt', 'HKLM\SYSTEM\CurrentControlSet\Control\Pnp',
        'HKLM\SYSTEM\CurrentControlSet\Control\PnP\Pci')) {
    RunCmd "registry/$($k -replace '[\\ ]', '_').txt" 'reg.exe' @('query', $k, '/s')
}
Get-ChildItem 'HKLM:\SOFTWARE\Intel' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name | Out-File (Join-Path $O 'registry/intel-subkeys.txt') -Encoding utf8

# 5. ACPI tables: registry copies and the firmware table API.
Step 'ACPI tables'
$acpiDir = Join-Path $O 'acpi'
New-Item -ItemType Directory -Force $acpiDir | Out-Null
$skipSig = '^(MSDM|SLIC)$'   # OEM Windows licence tables: never collected
Get-ChildItem 'HKLM:\HARDWARE\ACPI' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $key = $_
    foreach ($vn in $key.GetValueNames()) {
        $v = $key.GetValue($vn)
        if ($v -is [byte[]]) {
            $rel = ($key.Name -replace '^HKEY_LOCAL_MACHINE\\HARDWARE\\ACPI\\', '') -replace '[\\ ]', '_'
            if ($rel -match '^(MSDM|SLIC)') { continue }
            [IO.File]::WriteAllBytes((Join-Path $acpiDir "reg-$rel-$vn.bin"), $v)
        }
    }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class P14sFw {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint EnumSystemFirmwareTables(uint provider, byte[] buf, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buf, uint size);
}
'@ -ErrorAction SilentlyContinue
$ACPI = [uint32]0x41435049
$len = [P14sFw]::EnumSystemFirmwareTables($ACPI, $null, 0)
$ids = New-Object byte[] $len
[void][P14sFw]::EnumSystemFirmwareTables($ACPI, $ids, $len)
$seen = @{}
for ($k = 0; $k + 4 -le $len; $k += 4) {
    $sig = [Text.Encoding]::ASCII.GetString($ids, $k, 4)
    if ($sig -match $skipSig) { "skipped $sig (OEM licence)" | Out-File (Join-Path $acpiDir 'SKIPPED.txt') -Append; continue }
    $seen[$sig] = 1 + [int]$seen[$sig]
    if ($seen[$sig] -gt 1) { continue }   # the API only returns the first instance
    $tid = [BitConverter]::ToUInt32($ids, $k)
    $sz = [P14sFw]::GetSystemFirmwareTable($ACPI, $tid, $null, 0)
    if ($sz -eq 0) { continue }
    $buf = New-Object byte[] $sz
    [void][P14sFw]::GetSystemFirmwareTable($ACPI, $tid, $buf, $sz)
    [IO.File]::WriteAllBytes((Join-Path $acpiDir "fw-$sig-$($seen[$sig]).bin"), $buf)
}
"fw-*.bin come from GetSystemFirmwareTable, which returns only the first table of a repeated signature (SSDT). reg-*.bin come from HKLM\HARDWARE\ACPI, which also holds DSDT and the SSDTs (as SSDx keys). The Linux capture has every table." |
    Out-File (Join-Path $acpiDir 'README.txt') -Encoding utf8

# 6. Logs.
Step 'Logs'
Copy-Item "$env:SystemRoot\INF\setupapi.dev.log" (Join-Path $O 'logs-setupapi.dev.log') -ErrorAction SilentlyContinue
$since = (Get-Date).AddDays(-7)
foreach ($ln in @('System', 'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-Kernel-PnP/Device Management',
        'Microsoft-Windows-DeviceSetupManager/Admin')) {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = $ln; StartTime = $since } -ErrorAction SilentlyContinue
    if ($ln -eq 'System') {
        $ev = $ev | Where-Object { "$($_.ProviderName) $($_.Message)" -match 'thunderbolt|tbt|usb4|pci|Kernel-PnP|nvme|stornvme|DeviceSetup' }
    }
    Save "logs/events-$($ln -replace '[/ ]', '_').txt" ($ev |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message | Format-List | Out-String -Width 400)
}
Get-ChildItem "$env:ProgramData\Intel", "$env:ProgramData\Thunderbolt*" -Recurse -Include *.log, *.txt -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'thunderbolt|tbt' -and $_.Length -lt 20MB } | ForEach-Object {
        $dst = Join-Path $O ('logs/intel/' + ($_.FullName.Substring(3) -replace '[\\:]', '_'))
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item $_.FullName $dst
    }

# 7. ETW: discover Thunderbolt providers, trace a plug/unplug.
Step 'ETW providers'
RunCmd 'etw/providers-all.txt' 'logman.exe' @('query', 'providers')
$provLines = Get-Content (Join-Path $O 'etw/providers-all.txt') | Where-Object { $_ -match 'thunderbolt|(^|\W)tbt|usb4|\bnhi' }
Save 'etw/providers-tb.txt' $provLines
if (-not $NoTrace) {
    $guids = @()
    foreach ($l in $provLines) { if ($l -match '(\{[0-9A-Fa-f-]{36}\})') { $guids += $matches[1] } }
    $guids += '{9C205A39-1250-487D-ABD7-E831C6290539}'  # Microsoft-Windows-Kernel-PnP
    $guids += '{47711976-08C7-44EF-8FA2-082DA6A30A30}'  # PCI bus driver (WPP)
    $guids += '{505A6797-992E-43E6-B84E-235E41E3FD82}'  # USB4 host router (WPP)
    $guids += '{575BA31F-2B45-58C2-64FD-F5DC757B6137}'  # USB4 host router (TraceLogging)
    $pf = Join-Path $O 'etw/providers-used.txt'
    $guids | Sort-Object -Unique | ForEach-Object { "$_ 0xffffffffffffffff 0xff" } | Out-File $pf -Encoding ascii
    $etl = Join-Path $O 'etw/p14s-tb.etl'
    & logman.exe stop p14s-tb -ets 2>&1 | Out-Null
    & logman.exe create trace p14s-tb -ets -o $etl -pf $pf -bs 1024 -nb 64 256 -mode Sequential -max 512 2>&1 |
        Out-File (Join-Path $O 'etw/logman.txt') -Append
    Write-Host ''
    Write-Host '>>> ETW trace running.' -ForegroundColor Yellow
    Read-Host '>>> If a Thunderbolt device is plugged in, safely remove/eject and UNPLUG it now, wait 10 s, then press Enter'
    Read-Host '>>> PLUG the Thunderbolt 3 device in, approve it in Thunderbolt Control Center if asked, wait until it works, then press Enter'
    Save 'pnp/tb-devices-with-device.txt' (Get-PnpDevice -PresentOnly | Where-Object {
            "$($_.FriendlyName) $($_.Class) $($_.InstanceId)" -match $tbPattern -or $_.InstanceId -like 'PCI\*' } |
        Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize | Out-String -Width 400)
    Save 'pnp/disks-with-device.txt' (Get-PnpDevice -PresentOnly -Class DiskDrive, SCSIAdapter -ErrorAction SilentlyContinue |
        Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize | Out-String -Width 400)
    Read-Host '>>> Safely remove/eject the device, UNPLUG it, wait 10 s, then press Enter'
    & logman.exe stop p14s-tb -ets 2>&1 | Out-File (Join-Path $O 'etw/logman.txt') -Append
    if (Test-Path $etl) {
        & tracerpt.exe $etl -o (Join-Path $O 'etw/p14s-tb.xml') -of XML -summary (Join-Path $O 'etw/summary.txt') -y 2>&1 |
            Out-File (Join-Path $O 'etw/tracerpt.txt')
    }
}

Stop-Transcript | Out-Null

# 8. Redaction of computer name, user name, serials, UUID in text files.
if (-not $NoRedact) {
    Step 'Redacting'
    $secrets = @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN,
        (Get-CimInstance Win32_BIOS).SerialNumber,
        (Get-CimInstance Win32_ComputerSystemProduct).IdentifyingNumber,
        (Get-CimInstance Win32_ComputerSystemProduct).UUID,
        (Get-CimInstance Win32_BaseBoard).SerialNumber) |
        Where-Object { $_ -and $_.Length -ge 4 -and $_ -notmatch '^(None|Default string|To be filled by O\.E\.M\.)$' } |
        Sort-Object Length -Descending -Unique
    $macs = Get-CimInstance Win32_NetworkAdapter | Where-Object MACAddress | ForEach-Object { $_.MACAddress }
    foreach ($f in Get-ChildItem $O -Recurse -File -Include *.txt, *.xml, *.log, *.json) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $enc = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { [Text.Encoding]::Unicode } else { New-Object Text.UTF8Encoding $true }
        $t = $enc.GetString($bytes)
        $orig = $t
        foreach ($s in $secrets) { $t = $t -ireplace [regex]::Escape($s), '<REDACTED>' }
        foreach ($m in $macs) { $t = $t -ireplace [regex]::Escape($m), '<MAC>' -ireplace [regex]::Escape(($m -replace ':', '-')), '<MAC>' }
        if ($t -ne $orig) { [IO.File]::WriteAllText($f.FullName, $t, $enc) }
    }
    # The .etl holds the log file path (C:\Users\<name>\...) as UTF-16: same-length X,
    # ASCII and UTF-16LE forms of the computer, user and domain names.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $names = @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN) | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object Length -Descending -Unique
    foreach ($f in Get-ChildItem $O -Recurse -File -Include *.etl) {
        $t = $latin1.GetString([IO.File]::ReadAllBytes($f.FullName))
        $orig = $t
        foreach ($s in $names) {
            foreach ($v in @($s, (($s.ToCharArray() | ForEach-Object { "$_`0" }) -join ''))) {
                $t = $t -ireplace [regex]::Escape($v), ($v -replace '[^\x00]', 'X')
            }
        }
        if ($t -ne $orig) { [IO.File]::WriteAllBytes($f.FullName, $latin1.GetBytes($t)) }
    }
    'Redacted in text files: computer name, user name, domain, BIOS/board/system serials, system UUID, NIC MACs. In .etl files: computer, user and domain names (same-length X). Not redacted here (run tools/p14s-capture/scrub.py on arrival): USB serials in instance IDs, MAC-derived PCIe Device Serial Numbers, device container GUID nodes, ACPI .bin files.' |
        Out-File (Join-Path $O 'REDACTIONS.txt') -Encoding utf8
}

$manifest = Get-ChildItem $O -Recurse -File | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash)  $($_.Path.Substring($O.Length + 1))" }
@("label: $(if ($Label) { $Label } else { 'none' })", "date: $stamp") + $manifest |
    Out-File (Join-Path $O 'MANIFEST.sha256') -Encoding ascii
$zip = Join-Path $OutDir "$name.zip"
Compress-Archive -Path $O -DestinationPath $zip -Force
"$((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower())  $name.zip" |
    Out-File "$zip.sha256" -Encoding ascii
Remove-Item -Recurse -Force $O
Write-Host "`nDONE. Send these files:`n  $zip`n  $zip.sha256" -ForegroundColor Green
