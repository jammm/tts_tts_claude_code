<#
.SYNOPSIS
  Start the Lemonade server and the voice PTT daemon on demand.

.DESCRIPTION
  Launches both processes hidden in the background, redirects their output
  to rotating log files under %LOCALAPPDATA%\voice-plugin\logs\, and writes a
  pidfile so stop_services.ps1 can find them.

  Safe to re-run: if a service is already up it is skipped.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Base = Join-Path $env:LOCALAPPDATA "voice-plugin"
$LogDir = Join-Path $Base "logs"
$PidFile = Join-Path $Base "services.json"

if (-not (Test-Path $Base))   { throw "voice-plugin not installed; run installers\install_windows.ps1 first" }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Test-ProcessAlive {
    param([int]$ProcId)
    if (-not $ProcId) { return $false }
    return [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue)
}

function Start-Service {
    param(
        [string]$Name,
        [string]$ShimPath,
        [int]$ExistingPid
    )
    if (Test-ProcessAlive -ProcId $ExistingPid) {
        Write-Host "[start] $Name already running (pid=$ExistingPid)"
        return $ExistingPid
    }
    if (-not (Test-Path $ShimPath)) { throw "shim not found: $ShimPath" }

    # Don't use -RedirectStandardOutput/-RedirectStandardError here — those
    # make Start-Process hold handles that keep THIS script from returning.
    # The shim scripts redirect their own output to $LogDir instead.
    $proc = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $ShimPath) `
        -WindowStyle Hidden `
        -PassThru

    Write-Host "[start] $Name pid=$($proc.Id)"
    return $proc.Id
}

$existing = @{}
if (Test-Path $PidFile) {
    try { $existing = Get-Content -Raw $PidFile | ConvertFrom-Json } catch {}
}
function _get($obj, $key) {
    if ($null -eq $obj) { return 0 }
    if ($obj -is [hashtable]) { return [int]($obj[$key]) }
    $m = $obj.PSObject.Properties[$key]
    if ($m) { return [int]$m.Value } else { return 0 }
}

$lemPid = Start-Service -Name "lemonade" -ShimPath (Join-Path $Base "run_lemonade.ps1") -ExistingPid (_get $existing "lemonade")

# Give lemond a moment to bind before firing the PTT daemon that talks to it.
$deadline = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline) {
    try {
        $null = Invoke-WebRequest -Uri "http://localhost:13305/api/v1/health" -TimeoutSec 1 -UseBasicParsing
        break
    } catch {
        Start-Sleep -Milliseconds 200
    }
}

$pttPid = Start-Service -Name "ptt" -ShimPath (Join-Path $Base "run_ptt.ps1") -ExistingPid (_get $existing "ptt")

@{ lemonade = $lemPid; ptt = $pttPid; started_at = (Get-Date).ToString("o") } | ConvertTo-Json | Set-Content -Path $PidFile -NoNewline

Write-Host ""
Write-Host "Services up. Health:"
try {
    $h = Invoke-RestMethod -Uri "http://localhost:13305/api/v1/health" -TimeoutSec 2 -UseBasicParsing
    $h | ConvertTo-Json -Compress | Write-Host
} catch {
    Write-Warning "health probe failed: $_"
}
Write-Host ""
Write-Host "Stop with: .\installers\stop_services.ps1"
Write-Host "Logs:      $LogDir"
