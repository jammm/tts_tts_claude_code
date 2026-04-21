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

# 1. Lemonade (STT)
$lemPid = Start-Service -Name "lemonade" -ShimPath (Join-Path $Base "run_lemonade.ps1") -ExistingPid (_get $existing "lemonade")
[void](Wait-ForHealth "http://localhost:13305/api/v1/health" 8)

# 2. TTS. Default is "cpu" = Lemonade's built-in Kokoro on :13305 (no
# extra process to start). Set VOICE_TTS=f5 for F5-TTS on GPU (:13307,
# pure-eager PyTorch), VOICE_TTS=kokoro for our ROCm PyTorch Kokoro
# service (:13306, torch.compile — experimental), or VOICE_TTS=kobold
# for koboldcpp's HIP build running ttscpp Kokoro on CPU (:13308 —
# fastest cold start, no python in the hot loop).
$ttsBackend = if ($env:VOICE_TTS) { $env:VOICE_TTS.ToLower() } else { "cpu" }
$ttsPid   = 0
$ttsPort  = 13305
$ttsLabel = "lemonade (TTS/CPU Kokoro)"
if ($ttsBackend -eq "kokoro") {
    $ttsPid = Start-Service -Name "kokoro" -ShimPath (Join-Path $Base "run_kokoro.ps1") -ExistingPid (_get $existing "kokoro")
    Write-Host "[start] waiting for kokoro model load + warmup sweep (up to 240s)..."
    [void](Wait-ForHealth "http://localhost:13306/api/v1/health" 240)
    $ttsPort  = 13306
    $ttsLabel = "kokoro (TTS/GPU)"
} elseif ($ttsBackend -eq "f5") {
    $ttsPid = Start-Service -Name "f5" -ShimPath (Join-Path $Base "run_f5.ps1") -ExistingPid (_get $existing "f5")
    Write-Host "[start] waiting for F5-TTS model load + warmup (up to 120s)..."
    [void](Wait-ForHealth "http://localhost:13307/api/v1/health" 120)
    $ttsPort  = 13307
    $ttsLabel = "f5 (TTS/GPU)"
} elseif ($ttsBackend -eq "kobold") {
    $koboldShim = Join-Path $Base "run_kobold.ps1"
    if (-not (Test-Path $koboldShim)) {
        throw "VOICE_TTS=kobold but run_kobold.ps1 missing. Build koboldcpp_hipblas.dll via tools\build_koboldcpp_hip.cmd then rerun installers\install_windows.ps1"
    }
    $ttsPid = Start-Service -Name "kobold" -ShimPath $koboldShim -ExistingPid (_get $existing "kobold")
    Write-Host "[start] waiting for koboldcpp Kokoro load (up to 60s)..."
    # Koboldcpp's root returns 200 with its Kobold UI once the backend
    # loads; there's no dedicated /health endpoint, so we probe / instead.
    [void](Wait-ForHealth "http://localhost:13308/" 60)
    $ttsPort  = 13308
    $ttsLabel = "kobold (TTS/HIP Kokoro)"
}
# "cpu" falls through: lemonade on :13305 already serves /audio/speech
# via kokoro-v1, no extra service needed.

# 3. PTT daemon (F9 + wake word)
$pttPid = Start-Service -Name "ptt" -ShimPath (Join-Path $Base "run_ptt.ps1") -ExistingPid (_get $existing "ptt")

$state = @{ lemonade = $lemPid; ptt = $pttPid; tts_backend = $ttsBackend; started_at = (Get-Date).ToString("o") }
if ($ttsBackend -eq "kokoro") { $state.kokoro = $ttsPid }
elseif ($ttsBackend -eq "f5") { $state.f5 = $ttsPid }
elseif ($ttsBackend -eq "kobold") { $state.kobold = $ttsPid }
$state | ConvertTo-Json | Set-Content -Path $PidFile -NoNewline

Write-Host ""
Write-Host "Services up. Health:"
$endpoints = @(@{ name = "lemonade (STT)"; url = "http://localhost:13305/api/v1/health" })
if ($ttsBackend -eq "kokoro" -or $ttsBackend -eq "f5") {
    $endpoints += @{ name = $ttsLabel; url = "http://localhost:$ttsPort/api/v1/health" }
} elseif ($ttsBackend -eq "kobold") {
    # Koboldcpp has no /api/v1/health — probe root. If we got here it
    # answered 200 on / already during Wait-ForHealth above.
    Write-Host "  tts backend: koboldcpp HIP Kokoro on :$ttsPort (OpenAI speech API at /v1/audio/speech)"
} else {
    Write-Host "  tts backend: Lemonade CPU Kokoro (via :13305 /api/v1/audio/speech)"
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
