<#
.SYNOPSIS
  Remove the local voice plugin installed by install_windows.ps1.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

$PluginDest = Join-Path $env:USERPROFILE ".claude\plugins\voice"
$DaemonDest = Join-Path $env:LOCALAPPDATA "voice-plugin"

foreach ($name in @("VoiceLemond", "VoiceLemonade", "VoiceKobold", "VoiceKokoro", "VoicePTT")) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        try { Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } catch {}
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "[uninstall] removed task $name"
    }
}

foreach ($path in @($PluginDest, $DaemonDest)) {
    if (Test-Path $path) {
        Remove-Item -Recurse -Force $path
        Write-Host "[uninstall] removed $path"
    }
}

Write-Host "[uninstall] done"
Write-Host "[uninstall] note: ~/.claude/settings.json was NOT modified. Remove manually if desired."
