# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 usb4-emu contributors
#
# usb4-emu guest command agent (Windows PowerShell 5.1, runs as SYSTEM).
# Installed to C:\usb4agent\agent.ps1 by setup.ps1 and started at boot by the
# scheduled task "usb4-agent". Host side: scripts/guest.py.
#
# Protocol (every request except GET /ping needs header X-Token: <token>):
#   GET  /ping                      -> {"ok":true,"host":..,"boot":..}
#   POST /exec?timeout=<s>          body = PowerShell script (UTF-8)
#                                   -> {"stdout","stderr","exit","timed_out"}
#   POST /put?path=<guest path>     body = raw file bytes -> {"ok","bytes"}
#   GET  /get?path=<guest path>     -> raw file bytes (404 if missing)
# Requests are served concurrently from a runspace pool, so a long /exec does
# not block /ping or other commands.

param(
    [int]$Port = 8000,
    [string]$TokenFile = 'C:\usb4agent\token.txt',
    [string]$LogFile = 'C:\usb4agent\agent.log',
    [string]$Prefix = ''
)
if (-not $Prefix) { $Prefix = "http://+:$Port/" }

$ErrorActionPreference = 'Continue'
$Token = (Get-Content -Raw -LiteralPath $TokenFile).Trim()

function Write-AgentLog([string]$msg) {
    $line = '{0:o} {1}' -f (Get-Date), $msg
    try { Add-Content -LiteralPath $LogFile -Value $line } catch { }
}

$handler = {
    param($ctx, $Token, $LogFile)

    function Send-Bytes($ctx, [int]$code, [byte[]]$bytes, [string]$type) {
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = $type
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()
    }
    function Send-Json($ctx, [int]$code, $obj) {
        $json = ConvertTo-Json -InputObject $obj -Depth 4 -Compress
        Send-Bytes $ctx $code ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
    }
    function Read-Body($ctx) {
        $ms = New-Object IO.MemoryStream
        $ctx.Request.InputStream.CopyTo($ms)
        return ,$ms.ToArray()
    }

    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath
        $q = $req.QueryString
        Add-Content -LiteralPath $LogFile -Value ('{0:o} {1} {2}' -f (Get-Date), $req.HttpMethod, $req.Url.PathAndQuery) -ErrorAction SilentlyContinue

        if ($path -eq '/ping') {
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            Send-Json $ctx 200 @{ ok = $true; host = $env:COMPUTERNAME; boot = $boot.ToString('o') }
            return
        }
        if ($req.Headers['X-Token'] -ne $Token) {
            Send-Json $ctx 403 @{ error = 'bad token' }
            return
        }

        switch ($path) {
            '/exec' {
                $timeout = 600
                if ($q['timeout']) { $timeout = [int]$q['timeout'] }
                $body = [Text.Encoding]::UTF8.GetString((Read-Body $ctx))
                $tmp = Join-Path $env:TEMP ('usb4exec-' + [guid]::NewGuid().ToString('N') + '.ps1')
                $prefix = "[Console]::OutputEncoding = [Text.Encoding]::UTF8`r`n`$ProgressPreference = 'SilentlyContinue'`r`n"
                [IO.File]::WriteAllText($tmp, $prefix + $body, (New-Object Text.UTF8Encoding $true))

                $psi = New-Object Diagnostics.ProcessStartInfo
                $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$tmp`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardInput = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
                $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
                $p = [Diagnostics.Process]::Start($psi)
                $p.StandardInput.Close()
                $outTask = $p.StandardOutput.ReadToEndAsync()
                $errTask = $p.StandardError.ReadToEndAsync()
                $timedOut = -not $p.WaitForExit($timeout * 1000)
                if ($timedOut) {
                    & taskkill.exe /T /F /PID $p.Id | Out-Null
                    $p.WaitForExit(10000) | Out-Null
                }
                [void]$outTask.Wait(10000); [void]$errTask.Wait(10000)
                $exit = if ($timedOut) { -1 } else { $p.ExitCode }
                $so = if ($outTask.IsCompleted) { $outTask.Result } else { '' }
                $se = if ($errTask.IsCompleted) { $errTask.Result } else { '' }
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                Send-Json $ctx 200 @{ stdout = $so; stderr = $se; exit = $exit; timed_out = $timedOut }
            }
            '/put' {
                $dest = $q['path']
                if (-not $dest) { Send-Json $ctx 400 @{ error = 'path required' }; return }
                $bytes = Read-Body $ctx
                $dir = Split-Path -Parent $dest
                if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                [IO.File]::WriteAllBytes($dest, $bytes)
                Send-Json $ctx 200 @{ ok = $true; bytes = $bytes.Length }
            }
            '/get' {
                $src = $q['path']
                if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
                    Send-Json $ctx 404 @{ error = "not found: $src" }; return
                }
                $fs = [IO.File]::Open($src, 'Open', 'Read', 'ReadWrite')
                try {
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/octet-stream'
                    $ctx.Response.ContentLength64 = $fs.Length
                    $fs.CopyTo($ctx.Response.OutputStream)
                } finally { $fs.Close() }
                $ctx.Response.OutputStream.Close()
            }
            default { Send-Json $ctx 404 @{ error = "unknown endpoint $path" } }
        }
    } catch {
        Add-Content -LiteralPath $LogFile -Value ('{0:o} ERROR {1}' -f (Get-Date), $_) -ErrorAction SilentlyContinue
        try { Send-Json $ctx 500 @{ error = "$_" } } catch { }
    }
}

while ($true) {
    $listener = $null
    $pool = $null
    try {
        $listener = New-Object Net.HttpListener
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
        $pool.Open()
        Write-AgentLog "listening on $Prefix"
        $jobs = New-Object Collections.ArrayList
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($handler).AddArgument($ctx).AddArgument($Token).AddArgument($LogFile)
            [void]$jobs.Add(@{ ps = $ps; h = $ps.BeginInvoke() })
            # Reap finished handlers.
            foreach ($j in @($jobs)) {
                if ($j.h.IsCompleted) {
                    try { $j.ps.EndInvoke($j.h) | Out-Null } catch { }
                    $j.ps.Dispose()
                    $jobs.Remove($j)
                }
            }
        }
    } catch {
        Write-AgentLog "listener error: $_"
    } finally {
        if ($listener) { try { $listener.Close() } catch { } }
        if ($pool) { try { $pool.Close() } catch { } }
    }
    Start-Sleep -Seconds 5
}
