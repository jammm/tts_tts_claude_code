<#
.SYNOPSIS
  Install the local voice plugin for Claude Code on Windows, on top of a
  lemondate build.

.DESCRIPTION
  Two-repo flow (post-monorepo-split): the C++ servers (lemond.exe,
  whisper-server.exe, kokoro-hip-server.exe), the shared ggml tree, the
  ptt daemon sources, and its venv all live in a lemondate install
  (https://github.com/jammm/lemondate). This installer's only job is to
  deploy the Claude Code plugin on top of that build and render the
  service shims with lemondate's paths baked in.

  What it does:
    - Copies `claude-plugin-voice\` into `%USERPROFILE%\.claude\plugins\voice\`.
    - Merges the Stop hook + `/voice:speak` allowlist into `~\.claude\settings
      .json` via an inline Python merge (preserves existing entries).
    - Renders every `*.ps1.tmpl` in `installers\` into
      `$VoicePluginData\shims\` with `@@LEMONDATE_PATH@@` and
      `@@VOICE_PLUGIN_DATA@@` substituted.
    - Optionally registers Task Scheduler jobs for auto-start at logon.

  What it deliberately does NOT do any more (moved to lemondate):
    - Build lemond.exe / whisper-server.exe / kokoro-hip-server.exe.
    - Invoke tools\build_*.cmd (those were deleted with the submodules).
    - Provision a Python venv in this repo.
    - Download the Kokoro GGUF (now an optional step in lemondate's
      install docs).

.PARAMETER LemondatePath
  Required. Path to a lemondate install tree containing at minimum
  `bin\lemond.exe`, `ptt\ptt_daemon.py`, and `venv\Scripts\python.exe`.
  `bin\whisper-server.exe`, `bin\kokoro-hip-server.exe`, and
  `models\Kokoro_no_espeak_Q4.gguf` are strongly recommended but not
  fatal if missing - lemond falls back to CPU whisper + CPU Kokoro.

.PARAMETER VoicePluginData
  Optional. Where per-user runtime state lives (pidfiles, logs, rendered
  shims). Defaults to `%LOCALAPPDATA%\voice-plugin`.

.PARAMETER RegisterScheduledTasks
  Opt in to Task Scheduler registration (auto-start at logon). Off by
  default; most users will prefer start_services.ps1 / stop_services.ps1
  for manual control.

.EXAMPLE
  .\installers\install_windows.ps1 -LemondatePath d:\jam\lemondate

.EXAMPLE
  .\installers\install_windows.ps1 -LemondatePath d:\jam\lemondate -RegisterScheduledTasks
#>

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string] $LemondatePath,

    [string] $VoicePluginData = (Join-Path $env:LOCALAPPDATA "voice-plugin"),

    [switch] $RegisterScheduledTasks
)

$ErrorActionPreference = "Stop"

$WorkspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Write-Host "[install] workspace:        $WorkspaceRoot"

# ------------------------------------------------------------ lemondate validation
if (-not (Test-Path $LemondatePath)) {
    throw "LemondatePath does not exist: $LemondatePath"
}
$LemondatePath = (Resolve-Path $LemondatePath).Path
Write-Host "[install] lemondate:        $LemondatePath"

# Fail-fast checks for required files.
$required = @{
    "lemond.exe"       = Join-Path $LemondatePath "bin\lemond.exe"
    "ptt_daemon.py"    = Join-Path $LemondatePath "ptt\ptt_daemon.py"
    "venv python"      = Join-Path $LemondatePath "venv\Scripts\python.exe"
}
foreach ($kv in $required.GetEnumerator()) {
    if (-not (Test-Path $kv.Value)) {
        throw "Required lemondate artifact missing: $($kv.Key) expected at $($kv.Value). Build lemondate first (see https://github.com/jammm/lemondate)."
    }
    Write-Host "[install]   found $($kv.Key): $($kv.Value)"
}

# Warn-only checks for optional-but-recommended artifacts.
$optional = @{
    "whisper-server.exe (ROCm STT)"             = Join-Path $LemondatePath "bin\whisper-server.exe"
    "kokoro-hip-server.exe (HIP Kokoro TTS)"    = Join-Path $LemondatePath "bin\kokoro-hip-server.exe"
    "Kokoro_no_espeak_Q4.gguf (HIP Kokoro weights)" = Join-Path $LemondatePath "models\Kokoro_no_espeak_Q4.gguf"
}
foreach ($kv in $optional.GetEnumerator()) {
    if (-not (Test-Path $kv.Value)) {
        Write-Warning "[install] optional lemondate artifact missing: $($kv.Key) at $($kv.Value). lemond will fall back to CPU paths."
    } else {
        Write-Host "[install]   found $($kv.Key): $($kv.Value)"
    }
}

# ------------------------------------------------------------ destination paths
$PluginDest = Join-Path $env:USERPROFILE ".claude\plugins\voice"
$ShimDir    = Join-Path $VoicePluginData "shims"
$VenvPython = Join-Path $LemondatePath "venv\Scripts\python.exe"

Write-Host "[install] plugin dest:      $PluginDest"
Write-Host "[install] voice plugin dir: $VoicePluginData"
Write-Host "[install] shim dir:         $ShimDir"

# ------------------------------------------------------------ helpers
function Copy-Tree {
    param([string]$Src, [string]$Dst)
    if (Test-Path $Dst) { Remove-Item -Recurse -Force $Dst }
    New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    Copy-Item -Path (Join-Path $Src "*") -Destination $Dst -Recurse -Force `
        -Exclude @("__pycache__", "*.pyc")
    Get-ChildItem -Path $Dst -Recurse -Force -Directory -Filter "__pycache__" `
        | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Render-Template {
    param([string]$InPath, [string]$OutPath, [hashtable]$Map)
    $text = Get-Content -Raw -Path $InPath
    foreach ($k in $Map.Keys) {
        $text = $text.Replace($k, $Map[$k])
    }
    $dir = Split-Path -Parent $OutPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $OutPath -Value $text -NoNewline
}

# ------------------------------------------------------------ plugin files
Copy-Tree (Join-Path $WorkspaceRoot "claude-plugin-voice") $PluginDest

# hooks.json has __VENV_PYTHON__ placeholder - rewrite in place so Claude
# Code's plugin host finds the lemondate venv python.
$HooksJson = Join-Path $PluginDest "hooks\hooks.json"
if (Test-Path $HooksJson) {
    (Get-Content -Raw $HooksJson).Replace("__VENV_PYTHON__", $VenvPython.Replace("\", "\\")) | Set-Content -Path $HooksJson -NoNewline
}

# speak.md takes two placeholders: __VENV_PYTHON__ and __PLUGIN_DIR__.
# Claude Code's permission system rejects commands containing variable
# expansions like ${CLAUDE_PLUGIN_DIR}, so we bake the literal path in
# at deploy time.
$SpeakMd = Join-Path $PluginDest "commands\speak.md"
if (Test-Path $SpeakMd) {
    (Get-Content -Raw $SpeakMd).
        Replace("__VENV_PYTHON__", $VenvPython).
        Replace("__PLUGIN_DIR__", $PluginDest.Replace("\", "/")) `
        | Set-Content -Path $SpeakMd -NoNewline
}

Write-Host "[install] plugin installed"

# ------------------------------------------------------------ voice plugin data dir
if (-not (Test-Path $VoicePluginData)) { New-Item -ItemType Directory -Path $VoicePluginData -Force | Out-Null }
if (-not (Test-Path $ShimDir))         { New-Item -ItemType Directory -Path $ShimDir -Force | Out-Null }

# ------------------------------------------------------------ render shims
$templateMap = @{
    "@@LEMONDATE_PATH@@"    = $LemondatePath
    "@@VOICE_PLUGIN_DATA@@" = $VoicePluginData
}

$Templates = Get-ChildItem -Path (Join-Path $WorkspaceRoot "installers") -Filter "*.ps1.tmpl" -File
$RenderedShims = @{}
foreach ($tmpl in $Templates) {
    $outName = $tmpl.Name.Substring(0, $tmpl.Name.Length - ".tmpl".Length)
    $outPath = Join-Path $ShimDir $outName
    Render-Template $tmpl.FullName $outPath $templateMap
    $RenderedShims[$outName] = $outPath
    Write-Host "[install] rendered $outName -> $outPath"
}

# ------------------------------------------------------------ settings.json merge
$ClaudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$settingsDir = Split-Path -Parent $ClaudeSettings
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

# Merge permission allowlist AND Stop hook into ~/.claude/settings.json
# via Python (portable JSON handling across PS 5.1 and PS 7+).
#
# Why the Stop hook goes in settings.json even though we also ship it in
# the plugin's hooks/hooks.json: Claude Code's `--plugin-dir` flag loads
# plugin commands and skills but does NOT activate plugin hooks. Only a
# "real" /plugin install wires hooks.json. Since most users will run us
# via --plugin-dir, we inline the hook here so it fires either way.
$SpeakScript = Join-Path $PluginDest "scripts\speak.py"
$PluginDirFwd = $PluginDest.Replace("\", "/")
$mergeScript = @"
import json, sys
path           = sys.argv[1]
venv_python    = sys.argv[2]
speak_script   = sys.argv[3]
plugin_dir_fwd = sys.argv[4]
speak_cmd = f'& "{venv_python}" "{speak_script}" --from-hook'
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
if not isinstance(data, dict):
    data = {}

perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])

# Legacy patterns from earlier installs - remove so stale entries don't
# accumulate. They used ``${CLAUDE_PLUGIN_DIR}`` expansion which Claude
# Code now rejects with "Contains expansion".
legacy = (
    "Bash(python `${CLAUDE_PLUGIN_DIR}/scripts/*)",
    "Bash(python3 `${CLAUDE_PLUGIN_DIR}/scripts/*)",
)
allow[:] = [e for e in allow if e not in legacy]

# Match the exact command the slash command issues. Wildcard suffix so
# /voice:speak <arbitrary text> stays covered.
speak_allow = f'Bash("{venv_python}" "{plugin_dir_fwd}/scripts/speak.py"*)'
if speak_allow not in allow:
    allow.append(speak_allow)

hooks = data.setdefault("hooks", {})
stop_list = hooks.setdefault("Stop", [])
want = {
    "matcher": "",
    "hooks": [{"type": "command", "shell": "powershell", "command": speak_cmd}],
}
existing_idx = None
for i, entry in enumerate(stop_list):
    inner = entry.get("hooks") or []
    for h in inner:
        if isinstance(h, dict) and "speak.py" in (h.get("command") or ""):
            existing_idx = i
            break
    if existing_idx is not None:
        break
if existing_idx is None:
    stop_list.append(want)
else:
    stop_list[existing_idx] = want

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
"@
$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("merge_settings_" + [Guid]::NewGuid().ToString("N") + ".py")
Set-Content -Path $tempScript -Value $mergeScript -NoNewline
try {
    & $VenvPython $tempScript $ClaudeSettings $VenvPython $SpeakScript $PluginDirFwd
    if ($LASTEXITCODE -ne 0) { throw "settings merge failed" }
} finally {
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
}
Write-Host "[install] settings.json merged"

# ------------------------------------------------------------ scheduled tasks
if ($RegisterScheduledTasks) {
    $lemondShim = $RenderedShims["run_lemond.ps1"]
    $pttShim    = $RenderedShims["run_ptt.ps1"]
    if (-not $lemondShim) { throw "run_lemond.ps1 was not rendered - cannot register VoiceLemond task" }
    if (-not $pttShim)    { throw "run_ptt.ps1 was not rendered - cannot register VoicePTT task" }

    $LemondAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$lemondShim`""
    $PTTAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$pttShim`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable

    # Drop legacy task names from pre-split installs so a re-install
    # doesn't leave orphans pointing at deleted shims.
    foreach ($name in @("VoiceLemonade", "VoiceKobold", "VoiceKokoro", "VoiceLemond", "VoicePTT")) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
    }

    Register-ScheduledTask `
        -TaskName "VoiceLemond" `
        -Action $LemondAction `
        -Trigger $Trigger `
        -Settings $Settings `
        -Description "Local lemond server (STT via whisper-server + TTS via kokoro-hip-server)" | Out-Null

    Register-ScheduledTask `
        -TaskName "VoicePTT" `
        -Action $PTTAction `
        -Trigger $Trigger `
        -Settings $Settings `
        -Description "Voice PTT + wake-word daemon" | Out-Null

    Write-Host "[install] scheduled tasks registered (VoiceLemond, VoicePTT) - auto-start at logon"
} else {
    Write-Host "[install] Task Scheduler skipped. Use installers\start_services.ps1 to launch on demand."
}

Write-Host "[install] done"
