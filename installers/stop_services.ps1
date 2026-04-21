<#
.SYNOPSIS
  Stop the voice services started by start_services.ps1.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

$Base = Join-Path $env:LOCALAPPDATA "voice-plugin"
$PidFile = Join-Path $Base "services.json"

function Stop-Tree {
    param([int]$RootPid, [string]$Label)
    if (-not $RootPid) { return }
    $proc = Get-Process -Id $RootPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "[stop] $Label pid=$RootPid (not running)"
        return
    }
    # Walk child processes via WMI so hidden powershell -> lemond/python chains die too.
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $RootPid" -ErrorAction SilentlyContinue
    foreach ($c in $children) {
        Stop-Tree -RootPid $c.ProcessId -Label "$Label child"
    }
    Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] $Label pid=$RootPid killed"
}

$recorded = $null
if (Test-Path $PidFile) {
    try { $recorded = Get-Content -Raw $PidFile | ConvertFrom-Json } catch {}
}
if ($recorded) {
    Stop-Tree -RootPid ([int]$recorded.lemonade) -Label "lemonade"
    Stop-Tree -RootPid ([int]$recorded.kokoro)   -Label "kokoro"
    Stop-Tree -RootPid ([int]$recorded.f5)       -Label "f5"
    Stop-Tree -RootPid ([int]$recorded.ptt)      -Label "ptt"
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Belt-and-braces: find anything that looks like our services regardless of pidfile.
Get-Process lemond -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] lemond pid=$($_.Id) killed (orphan)"
}
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue `
    | Where-Object { $_.CommandLine -match "ptt_daemon|ptt\.ptt|kokoro_server|f5_tts_server" } `
    | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[stop] daemon pid=$($_.ProcessId) killed (orphan)"
    }

Write-Host "[stop] done"
