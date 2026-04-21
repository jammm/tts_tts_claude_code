<#
.SYNOPSIS
  Install the local voice plugin for Claude Code on Windows.

.DESCRIPTION
  Copies sources from the workspace into:
    - %USERPROFILE%\.claude\plugins\voice\   (plugin for Claude Code)
    - %LOCALAPPDATA%\voice-plugin\           (PTT daemon)
  Generates run_lemonade.ps1 and run_ptt.ps1 shims with the venv + lemond
  paths baked in, registers two Task Scheduler jobs to start them at logon,
  and merges the permission allowlist into ~/.claude/settings.json.

.PARAMETER VenvPath
  Path to the venv whose Python runs the PTT daemon + plugin scripts.
  Defaults to .\.venv relative to the workspace root.

.PARAMETER LemonadePath
  Path to the folder containing lemond.exe (and resources\). Defaults to
  .\vendor\lemonade-cpp relative to the workspace root.

.PARAMETER RegisterScheduledTasks
  Opt in to Task Scheduler registration (auto-start at logon). Off by default;
  most users will prefer start_services.ps1 / stop_services.ps1 for manual
  control.

.EXAMPLE
  .\installers\install_windows.ps1
  .\installers\install_windows.ps1 -RegisterScheduledTasks
#>

[CmdletBinding()]
param(
    [string]$VenvPath,
    [string]$LemonadePath,
    [switch]$RegisterScheduledTasks
)

$ErrorActionPreference = "Stop"

$WorkspaceRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Write-Host "[install] workspace: $WorkspaceRoot"

if (-not $VenvPath) {
    $VenvPath = Join-Path $WorkspaceRoot ".venv"
}
$VenvPath = (Resolve-Path $VenvPath).Path
$VenvPython = Join-Path $VenvPath "Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    throw "venv python not found at $VenvPython"
}
Write-Host "[install] venv python: $VenvPython"

if (-not $LemonadePath) {
    $LemonadePath = Join-Path $WorkspaceRoot "vendor\lemonade-cpp"
}
$LemonadePath = (Resolve-Path $LemonadePath).Path
$LemondExe = Join-Path $LemonadePath "lemond.exe"
if (-not (Test-Path $LemondExe)) {
    throw "lemond.exe not found at $LemondExe"
}
Write-Host "[install] lemond: $LemondExe"

$PluginDest = Join-Path $env:USERPROFILE ".claude\plugins\voice"
$DaemonDest = Join-Path $env:LOCALAPPDATA "voice-plugin"
$ShimDir    = Join-Path $env:LOCALAPPDATA "voice-plugin"
Write-Host "[install] plugin dest: $PluginDest"
Write-Host "[install] daemon dest: $DaemonDest"

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

# ---------------------------------------------------------------- plugin files
Copy-Tree (Join-Path $WorkspaceRoot "claude-plugin-voice") $PluginDest

# hooks.json has __VENV_PYTHON__ placeholder — rewrite in place.
$HooksJson = Join-Path $PluginDest "hooks\hooks.json"
(Get-Content -Raw $HooksJson).Replace("__VENV_PYTHON__", $VenvPython.Replace("\", "\\")) | Set-Content -Path $HooksJson -NoNewline

# speak.md takes two placeholders: __VENV_PYTHON__ and __PLUGIN_DIR__.
# Claude Code's permission system rejects commands containing variable
# expansions like ${CLAUDE_PLUGIN_DIR}, so we bake the literal path in at
# deploy time.
$SpeakMd = Join-Path $PluginDest "commands\speak.md"
(Get-Content -Raw $SpeakMd).
    Replace("__VENV_PYTHON__", $VenvPython).
    Replace("__PLUGIN_DIR__", $PluginDest.Replace("\", "/")) `
    | Set-Content -Path $SpeakMd -NoNewline

Write-Host "[install] plugin installed"

# ---------------------------------------------------------------- daemon files
Copy-Tree (Join-Path $WorkspaceRoot "ptt") (Join-Path $DaemonDest "ptt")
Write-Host "[install] daemon installed"

# ---------------------------------------------------------------- run shims
# Resolve TheRock ROCm SDK bin dir (inside the venv) if present; used for
# whisper-server's HIP runtime DLLs.
$RocmBin = Join-Path $VenvPath "Lib\site-packages\_rocm_sdk_devel\bin"
if (-not (Test-Path $RocmBin)) { $RocmBin = "" }
$WhisperDir = Join-Path $WorkspaceRoot "vendor\whisper-cpp-rocm"
if (-not (Test-Path $WhisperDir)) { $WhisperDir = "" }

Render-Template `
    (Join-Path $WorkspaceRoot "installers\run_lemonade.ps1.tmpl") `
    (Join-Path $ShimDir "run_lemonade.ps1") `
    @{
        "__LEMOND_EXE__"   = $LemondExe
        "__ROCM_BIN__"     = $RocmBin
        "__WHISPER_DIR__"  = $WhisperDir
    }

Render-Template `
    (Join-Path $WorkspaceRoot "installers\run_ptt.ps1.tmpl") `
    (Join-Path $ShimDir "run_ptt.ps1") `
    @{
        "__VENV_PYTHON__" = $VenvPython
        "__DAEMON_DIR__"  = $DaemonDest
    }

Render-Template `
    (Join-Path $WorkspaceRoot "installers\run_kokoro.ps1.tmpl") `
    (Join-Path $ShimDir "run_kokoro.ps1") `
    @{
        "__VENV_PYTHON__" = $VenvPython
        "__DAEMON_DIR__"  = $DaemonDest
        "__ROCM_BIN__"    = $RocmBin
    }

Write-Host "[install] shims: $ShimDir\run_lemonade.ps1, $ShimDir\run_ptt.ps1"

# ---------------------------------------------------------------- settings.json
$ClaudeSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
$settingsDir = Split-Path -Parent $ClaudeSettings
if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

# Merge permission allowlist AND Stop hook into ~/.claude/settings.json via
# Python (portable JSON handling for PS 5.1 and PS 7+).
#
# Why the Stop hook goes in settings.json even though we also ship it in the
# plugin's hooks/hooks.json: Claude Code's `--plugin-dir` flag loads plugin
# commands and skills but does NOT activate plugin hooks. Only a "real"
# /plugin install wires hooks.json. Since most users will run us via
# --plugin-dir, we inline the hook here so it fires either way.
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

# Legacy patterns from earlier installs — remove so stale entries don't
# accumulate. They used `${CLAUDE_PLUGIN_DIR}` expansion which Claude Code
# now rejects with "Contains expansion".
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

# ---------------------------------------------------------------- scheduled tasks
if ($RegisterScheduledTasks) {
    $LemonadeAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ShimDir\run_lemonade.ps1`""
    $PTTAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ShimDir\run_ptt.ps1`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -StartWhenAvailable

    $KokoroAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ShimDir\run_kokoro.ps1`""

    foreach ($name in @("VoiceLemonade", "VoicePTT", "VoiceKokoro")) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
    }

    Register-ScheduledTask `
        -TaskName "VoiceLemonade" `
        -Action $LemonadeAction `
        -Trigger $Trigger `
        -Settings $Settings `
        -Description "Local Lemonade server (STT whispercpp on ROCm)" | Out-Null

    Register-ScheduledTask `
        -TaskName "VoiceKokoro" `
        -Action $KokoroAction `
        -Trigger $Trigger `
        -Settings $Settings `
        -Description "Kokoro TTS server on ROCm (GPU)" | Out-Null

    Register-ScheduledTask `
        -TaskName "VoicePTT" `
        -Action $PTTAction `
        -Trigger $Trigger `
        -Settings $Settings `
        -Description "Voice PTT + wake-word daemon" | Out-Null

    Write-Host "[install] scheduled tasks registered (auto-start at logon)"
} else {
    Write-Host "[install] Task Scheduler skipped. Use installers\start_services.ps1 to launch on demand."
}

Write-Host "[install] done"
