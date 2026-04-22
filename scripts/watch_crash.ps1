# watch_crash.ps1 — poll every 2s and print any new activity in the
# kokoro-hip-server ecosystem. Run this in a second terminal (or let
# the agent drive it) while the user exercises /voice:speak, Stop
# hooks, PTT, etc. until something crashes.
#
# Triggers on:
#   - new .dmp file in %LOCALAPPDATA%\voice-plugin\logs
#   - new entries in kokoro-hip-crash.log
#   - new "Stopping server", "CRASH", "exit code", error lines in the
#     most recent lemond-*.log
#   - kokoro-hip-server.exe PID changing (= respawn = crash)

param(
    [int] $IntervalSec = 2,
    [int] $MaxMinutes = 60
)

$ErrorActionPreference = 'Continue'
$logDir = "$env:LOCALAPPDATA\voice-plugin\logs"

function Get-LatestLemondLog {
    Get-ChildItem $logDir -Filter 'lemond-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-KokoroPid {
    (Get-Process kokoro-hip-server -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty Id)
}

$start = Get-Date
$crashLog = Join-Path $logDir 'kokoro-hip-crash.log'

$seenDumps   = @{}
foreach ($d in (Get-ChildItem $logDir -Filter '*.dmp' -ErrorAction SilentlyContinue)) {
    $seenDumps[$d.Name] = $true
}
$prevCrashSize = if (Test-Path $crashLog) { (Get-Item $crashLog).Length } else { 0 }
$prevKokoroPid = Get-KokoroPid
$lemondLog = Get-LatestLemondLog
$prevLemondLen = if ($lemondLog) { (Get-Item $lemondLog.FullName).Length } else { 0 }
$prevLemondFile = if ($lemondLog) { $lemondLog.Name } else { $null }

Write-Host ""
Write-Host "[watch] monitoring $logDir"
Write-Host "[watch] kokoro-hip-server pid=$prevKokoroPid  lemond log=$prevLemondFile"
Write-Host "[watch] poll every ${IntervalSec}s  (ctrl-c to stop, auto-exit after ${MaxMinutes}m)"
Write-Host "[watch] ---- go reproduce the crash ----"
Write-Host ""

$deadline = $start.AddMinutes($MaxMinutes)

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSec

    # Did a new lemond log rotate in?
    $cur = Get-LatestLemondLog
    if ($cur -and $cur.Name -ne $prevLemondFile) {
        Write-Host "[watch] new lemond log started: $($cur.Name)"
        $prevLemondFile = $cur.Name
        $prevLemondLen  = 0
    }

    # New bytes in the current lemond log
    if ($cur) {
        $curLen = (Get-Item $cur.FullName).Length
        if ($curLen -gt $prevLemondLen) {
            $fs = [System.IO.File]::Open(
                $cur.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            try {
                $fs.Position = $prevLemondLen
                $sr = New-Object System.IO.StreamReader($fs)
                $chunk = $sr.ReadToEnd()
                $sr.Dispose()
            } finally {
                $fs.Dispose()
            }
            $prevLemondLen = $curLen

            foreach ($line in ($chunk -split "`r?`n")) {
                if (-not $line) { continue }
                if ($line -match 'Stopping server|CRASH|exit code|exception|load failed|WrappedServer.*terminated|failed to start|evicting all models|process has terminated') {
                    Write-Host "[watch] !! $line"
                }
                if ($line -match 'kokoro-hip-server CRASH|SIGABRT|SIGSEGV|std::terminate') {
                    Write-Host "[watch] !! child CRASH: $line"
                }
            }
        }
    }

    # Crash log growth
    if (Test-Path $crashLog) {
        $curSize = (Get-Item $crashLog).Length
        if ($curSize -gt $prevCrashSize) {
            Write-Host "[watch] ==== NEW CRASH LOG ENTRY ===="
            $fs = [System.IO.File]::Open(
                $crashLog,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite)
            try {
                $fs.Position = $prevCrashSize
                $sr = New-Object System.IO.StreamReader($fs)
                Write-Host $sr.ReadToEnd()
                $sr.Dispose()
            } finally {
                $fs.Dispose()
            }
            Write-Host "[watch] ============================="
            $prevCrashSize = $curSize
        }
    }

    # New minidumps
    $curDumps = Get-ChildItem $logDir -Filter '*.dmp' -ErrorAction SilentlyContinue
    foreach ($d in $curDumps) {
        if (-not $seenDumps[$d.Name]) {
            Write-Host "[watch] NEW MINIDUMP: $($d.FullName) ($($d.Length) bytes)"
            $seenDumps[$d.Name] = $true
        }
    }

    # PID change -> respawn -> crash
    $nowPid = Get-KokoroPid
    if ($nowPid -ne $prevKokoroPid) {
        if ($prevKokoroPid) {
            Write-Host "[watch] kokoro-hip-server PID changed: $prevKokoroPid -> $nowPid  (crash + respawn?)"
        } else {
            Write-Host "[watch] kokoro-hip-server PID appeared: $nowPid"
        }
        $prevKokoroPid = $nowPid
    }
}

Write-Host "[watch] monitor ended after $MaxMinutes minutes"
