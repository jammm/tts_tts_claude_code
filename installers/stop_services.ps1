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
    # Walk child processes via WMI so hidden powershell -> lemond /
    # kokoro-hip-server / whisper-server / python chains die too.
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
    # New layout (post-lemondate-split): one "lemond" tree covers STT +
    # HIP Kokoro TTS because lemond spawns whisper-server and kokoro-hip-
    # server as child processes.
    Stop-Tree -RootPid ([int]$recorded.lemond)   -Label "lemond"
    # Legacy keys kept for backwards compat with existing pidfiles from
    # a pre-split install that users may still have on disk.
    Stop-Tree -RootPid ([int]$recorded.lemonade) -Label "lemonade (legacy)"
    Stop-Tree -RootPid ([int]$recorded.kobold)   -Label "kobold (legacy)"
    # Opt-in PyTorch GPU TTS alternatives.
    Stop-Tree -RootPid ([int]$recorded.kokoro)   -Label "kokoro"
    Stop-Tree -RootPid ([int]$recorded.f5)       -Label "f5"
    # PTT daemon.
    Stop-Tree -RootPid ([int]$recorded.ptt)      -Label "ptt"
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Belt-and-braces: find anything that looks like our services regardless
# of pidfile. Covers lemond.exe + its spawned whisper-server.exe /
# kokoro-hip-server.exe children plus the Python TTS / PTT daemons.
Get-Process lemond -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] lemond pid=$($_.Id) killed (orphan)"
}
Get-Process "whisper-server" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] whisper-server pid=$($_.Id) killed (orphan)"
}
Get-Process "kokoro-hip-server" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] kokoro-hip-server pid=$($_.Id) killed (orphan)"
}
Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue `
    | Where-Object { $_.CommandLine -match "ptt_daemon|ptt\.ptt|kokoro_server|f5_tts_server" } `
    | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host "[stop] daemon pid=$($_.ProcessId) killed (orphan)"
    }

Write-Host "[stop] done"
