<#
.SYNOPSIS
  Start the lemond server and the voice PTT daemon on demand.

.DESCRIPTION
  Launches both processes hidden in the background, redirects their
  output to rotating log files under `%LOCALAPPDATA%\voice-plugin\logs\`,
  and writes a pidfile so stop_services.ps1 can find them.

  Backend layout after the lemondate monorepo split:
    - run_lemond.ps1 starts a single lemond.exe from the lemondate build
      tree. lemond internally spawns whisper-server.exe (ROCm GPU STT)
      and kokoro-hip-server.exe (HIP GPU Kokoro TTS) on demand, based on
      env vars run_lemond sets. One shim replaces the old split
      run_lemonade + run_kobold shims.
    - run_ptt.ps1 starts the F9 + wake-word daemon.
    - run_f5.ps1 / run_kokoro.ps1 stay available as A/B fallbacks for
      the PyTorch GPU TTS paths - opt in with VOICE_TTS=f5 or
      VOICE_TTS=kokoro.

  Safe to re-run: if a service is already up it is skipped.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Base    = Join-Path $env:LOCALAPPDATA "voice-plugin"
$ShimDir = Join-Path $Base "shims"
$LogDir  = Join-Path $Base "logs"
$PidFile = Join-Path $Base "services.json"

if (-not (Test-Path $Base))    { throw "voice-plugin not installed; run installers\install_windows.ps1 -LemondatePath <path> first" }
if (-not (Test-Path $ShimDir)) { throw "voice-plugin shims missing at $ShimDir; re-run installers\install_windows.ps1 -LemondatePath <path>" }
if (-not (Test-Path $LogDir))  { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

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

    # Don't use -RedirectStandardOutput/-RedirectStandardError here - those
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

function Wait-ForHealth([string]$url, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-WebRequest -Uri $url -TimeoutSec 1 -UseBasicParsing
            return $true
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

# Locate the lemondate build so we can detect which TTS backend lemond
# will use. run_lemond.ps1 makes the same decision internally; we mirror
# it here for services.json bookkeeping so speak.py / Claude's Stop hook
# know which port the TTS endpoint lives on.
$lemondShim = Join-Path $ShimDir "run_lemond.ps1"
if (-not (Test-Path $lemondShim)) { throw "run_lemond.ps1 missing at $lemondShim - re-run installers\install_windows.ps1 -LemondatePath <path>" }

# Dig @@LEMONDATE_PATH@@ value out of the rendered shim. The installer
# writes the literal path; we read it back so start_services.ps1 doesn't
# need a parameter.
$lemondateBin = $null
$lemondShimText = Get-Content -Raw $lemondShim
$m = [regex]::Match($lemondShimText, '(?m)^\s*\$LemondatePath\s*=\s*"([^"]+)"')
if ($m.Success) { $lemondateBin = Join-Path $m.Groups[1].Value "bin" }

$lemondatKokoroHip = $null
if ($lemondateBin) {
    $candidate = Join-Path $lemondateBin "kokoro-hip-server.exe"
    if (Test-Path $candidate) { $lemondatKokoroHip = $candidate }
}

# 1. lemond (STT + TTS orchestrator)
$lemPid = Start-Service -Name "lemond" -ShimPath $lemondShim -ExistingPid (_get $existing "lemond")
[void](Wait-ForHealth "http://localhost:13305/api/v1/health" 10)

# 2. Optional PyTorch GPU TTS services. The default is lemond's built-in
# backend selection (hip via kokoro-hip-server.exe if it's present,
# otherwise CPU Kokoro inside lemond). VOICE_TTS only has to be set
# for A/B tests against the legacy Python paths:
#   hip|kobold - default, kokoro-hip-server spawned by lemond (:13305)
#   cpu        - lemond's built-in CPU Kokoro                (:13305)
#   f5         - F5-TTS on GPU                                (:13307, eager PyTorch)
#   kokoro     - ROCm PyTorch Kokoro                          (:13306, torch.compile, exp.)
$f5Shim     = Join-Path $ShimDir "run_f5.ps1"
$kokoroShim = Join-Path $ShimDir "run_kokoro.ps1"

if ($env:VOICE_TTS) {
    $ttsBackend = $env:VOICE_TTS.ToLower()
    # Normalize "kobold" (legacy name from before the split) to "hip".
    if ($ttsBackend -eq "kobold") { $ttsBackend = "hip" }
} elseif ($lemondatKokoroHip) {
    $ttsBackend = "hip"
} else {
    $ttsBackend = "cpu"
}

$ttsPid   = 0
$ttsPort  = 13305
$ttsLabel = "lemond (TTS/CPU Kokoro via lemond)"

if ($ttsBackend -eq "kokoro") {
    if (-not (Test-Path $kokoroShim)) { throw "VOICE_TTS=kokoro but run_kokoro.ps1 missing at $kokoroShim" }
    $ttsPid = Start-Service -Name "kokoro" -ShimPath $kokoroShim -ExistingPid (_get $existing "kokoro")
    Write-Host "[start] waiting for kokoro model load + warmup sweep (up to 240s)..."
    [void](Wait-ForHealth "http://localhost:13306/api/v1/health" 240)
    $ttsPort  = 13306
    $ttsLabel = "kokoro (TTS/GPU PyTorch)"
} elseif ($ttsBackend -eq "f5") {
    if (-not (Test-Path $f5Shim)) { throw "VOICE_TTS=f5 but run_f5.ps1 missing at $f5Shim" }
    $ttsPid = Start-Service -Name "f5" -ShimPath $f5Shim -ExistingPid (_get $existing "f5")
    Write-Host "[start] waiting for F5-TTS model load + warmup (up to 120s)..."
    [void](Wait-ForHealth "http://localhost:13307/api/v1/health" 120)
    $ttsPort  = 13307
    $ttsLabel = "f5 (TTS/GPU)"
} elseif ($ttsBackend -eq "hip") {
    # lemond internally spawns kokoro-hip-server.exe and serves /v1/audio
    # /speech on :13305 proxied through its own HTTP layer. No separate
    # process for us to track - the pid under "lemond" covers it.
    $ttsPort  = 13305
    $ttsLabel = "lemond (TTS/HIP Kokoro via kokoro-hip-server.exe)"
}
# "cpu" falls through: lemond on :13305 already serves /audio/speech via
# its built-in kokoros backend, no extra service needed.

# 3. PTT daemon (F9 + wake word)
$pttShim = Join-Path $ShimDir "run_ptt.ps1"
if (-not (Test-Path $pttShim)) { throw "run_ptt.ps1 missing at $pttShim" }
$pttPid = Start-Service -Name "ptt" -ShimPath $pttShim -ExistingPid (_get $existing "ptt")

$state = @{
    lemond      = $lemPid
    ptt         = $pttPid
    tts_backend = $ttsBackend
    tts_port    = $ttsPort
    started_at  = (Get-Date).ToString("o")
}
if ($ttsBackend -eq "kokoro") { $state.kokoro = $ttsPid }
elseif ($ttsBackend -eq "f5") { $state.f5 = $ttsPid }
$state | ConvertTo-Json | Set-Content -Path $PidFile -NoNewline

Write-Host ""
Write-Host "Services up. Health:"
$endpoints = @(@{ name = "lemond (STT + TTS)"; url = "http://localhost:13305/api/v1/health" })
if ($ttsBackend -eq "kokoro" -or $ttsBackend -eq "f5") {
    $endpoints += @{ name = $ttsLabel; url = "http://localhost:$ttsPort/api/v1/health" }
} elseif ($ttsBackend -eq "hip") {
    Write-Host "  tts backend: lemond spawning kokoro-hip-server.exe (HIP Kokoro) on :$ttsPort (/api/v1/audio/speech)"
} else {
    Write-Host "  tts backend: lemond built-in CPU Kokoro (via :13305 /api/v1/audio/speech)"
}
foreach ($endpoint in $endpoints) {
    try {
        $h = Invoke-RestMethod -Uri $endpoint.url -TimeoutSec 2 -UseBasicParsing
        Write-Host ("  " + $endpoint.name + ": " + ($h | ConvertTo-Json -Compress))
    } catch {
        Write-Warning ("  " + $endpoint.name + " probe failed: " + $_)
    }
}
Write-Host ""
Write-Host "Stop with: .\installers\stop_services.ps1"
Write-Host "Logs:      $LogDir"
