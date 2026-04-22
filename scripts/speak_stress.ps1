# speak_stress.ps1 — reproduce the kokoro-hip-server crash the way Claude
# Code triggers it: via the installed speak.py plugin, alternating between
# the Stop-hook path (JSON on stdin) and the /voice:speak positional path.
#
# Each iteration spawns a fresh python speak.py, matching Claude Code's
# short-lived subprocess model. Audio playback is skipped (SPEAK_NO_PLAYBACK=1)
# so we don't waste minutes waiting for sd.wait() per iteration.
#
# Usage:
#   pwsh scripts\speak_stress.ps1                    # default 200 iterations
#   pwsh scripts\speak_stress.ps1 -Count 1000        # longer run
#   pwsh scripts\speak_stress.ps1 -Concurrency 3     # 3 simultaneous speak.py
#
# What we're looking for:
#   - kokoro-hip-server.exe exiting mid-run (lemond logs "Stopping server")
#   - crash log at %LOCALAPPDATA%\voice-plugin\logs\kokoro-hip-crash.log
#   - minidump at the same dir (kokoro-hip-*.dmp)
#
# The script aborts on the FIRST failed speak.py invocation and prints the
# text + last known successful text (the pair usually narrows down which
# input trips the bug).

param(
    [int] $Count = 200,
    [int] $Concurrency = 1,
    [string] $Python = "D:\jam\lemondate\venv\Scripts\python.exe",
    [string] $SpeakPy = "$env:USERPROFILE\.claude\plugins\voice\scripts\speak.py",
    [switch] $StopOnCrash = $true
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Python))  { throw "python not found: $Python" }
if (-not (Test-Path $SpeakPy)) { throw "speak.py not found: $SpeakPy" }

# Realistic Claude-Code-style assistant turns: short acknowledgements,
# medium explanations, longer paragraphs with markdown, code blocks, and
# the unicode-punctuation corner cases we already know bite Kokoro.
$assistantMessages = @(
    "Got it.",
    "Done!",
    "Here's the summary.",
    "That looks correct.",
    "Let me check that file.",
    "The build succeeded - all 332 targets compiled cleanly.",
    "I'll need to refactor ``parse_cli`` first.",
    ("The fix is straightforward " + [char]0x2014 + " we just need to flip the sign on the offset."),
    ("Use ``std::map`` (or " + [char]0x201C + "``std::unordered_map``" + [char]0x201D + " for O(1)) here."),
    "There are three failing tests: test_parser, test_tokenizer, test_runner.",
    ("I counted 1" + [char]0x2013 + "5 edge cases in the phonemizer path."),
    ("The temperature dropped " + [char]0x2212 + "40 degrees overnight."),
    "Still text-only on my end. What's up?",
    ("Still text-only " + [char]0x2014 + " no audio on my end. What's up?"),
    "here - you go",
    "Let's run it through the stress tester once more; I'll grab coffee.",
    "OK... wait... no, really! Are you sure?!",
    "Numbers: 4, 5, 6, and the ratio is 3.14159.",
    "Call 555-1234 or 1-800-555-0199 if you need help.",
    "iPhone iPad macOS iOS - Apple's family.",
    ("Ran the test suite " + [char]0x2014 + " 3 failures, 2 of them flaky " + [char]0x2014 + " retrying now."),
    # Common Claude reply:
    "I've made the requested changes. Let me know if you want me to iterate further.",
    "The implementation matches the spec now. All tests pass locally.",
    "I added tracing to narrow down where the subprocess dies.",
    # Markdown that `clean()` has to strip:
    "See ``docs/README.md`` for the full explanation.",
    "Short header:`nMore text on the next line.",
    "Bulleted: `n- first`n- second`n- third",
    # Pure ASCII punctuation stress:
    "Mix: Q? A! B. C, D; E: F...",
    "and & ampersand + plus = equals < less > greater",
    'mixed "double quotes" and ' + "'single quotes' in one sentence",
    # All caps:
    "CAUTION: DO NOT ENTER.",
    # The exact string that was crashing earlier:
    'Still text-only ' + [char]0x2014 + ' no audio on my end. What''s up?'
)

# Stop-hook payload template. Claude Code writes UTF-8 JSON; we echo it
# in the shape it comes from .claude/settings.json's Stop hook.
function New-HookPayload([string]$text, [string]$transcriptPath = "") {
    return [pscustomobject]@{
        session_id              = [guid]::NewGuid().ToString()
        transcript_path         = $transcriptPath
        last_assistant_message  = $text
        stop_hook_active        = $false
        cwd                     = (Get-Location).Path
    } | ConvertTo-Json -Compress
}

$logDir = "$env:LOCALAPPDATA\voice-plugin\logs"
$crashLog = Join-Path $logDir "kokoro-hip-crash.log"

# Snapshot pre-run state
$preDumps = @()
if (Test-Path $logDir) {
    $preDumps = Get-ChildItem $logDir -Filter "*.dmp" -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name
}
$preCrashLogSize = if (Test-Path $crashLog) { (Get-Item $crashLog).Length } else { 0 }

Write-Host "[stress] python   = $Python"
Write-Host "[stress] speak.py = $SpeakPy"
Write-Host "[stress] corpus   = $($assistantMessages.Count) messages"
Write-Host "[stress] count    = $Count"
Write-Host "[stress] concurrency = $Concurrency"
Write-Host "[stress] log dir  = $logDir"

$env:SPEAK_NO_PLAYBACK = "1"

$success = 0
$fail    = 0
$firstFail = $null
$lastOk   = ""
$startTime = Get-Date

for ($i = 0; $i -lt $Count; $i++) {
    $text = $assistantMessages[$i % $assistantMessages.Count]
    $useHook = ($i % 2 -eq 0)   # alternate Stop-hook and /voice:speak paths

    if ($Concurrency -le 1) {
        # Serial path — simplest, matches one-at-a-time Claude turns.
        try {
            if ($useHook) {
                # Write the JSON to a UTF-8 temp file, then pipe it via cmd.exe.
                # PowerShell's own pipeline mangles non-ASCII bytes; a file +
                # cmd.exe redirect preserves them byte-for-byte.
                $payload = New-HookPayload $text
                $tmp = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
                    $cmd = "`"$Python`" `"$SpeakPy`" --from-hook < `"$tmp`""
                    $out = cmd.exe /c $cmd 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ("speak.py (from-hook) exited " + $LASTEXITCODE + ": " + $out) }
                } finally {
                    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                }
            } else {
                $out = & $Python $SpeakPy $text 2>&1
                if ($LASTEXITCODE -ne 0) { throw ("speak.py (positional) exited " + $LASTEXITCODE + ": " + $out) }
            }
            $success++
            $lastOk = $text
        } catch {
            $fail++
            if (-not $firstFail) {
                $firstFail = @{
                    idx    = $i
                    mode   = if ($useHook) { "from-hook" } else { "positional" }
                    text   = $text
                    error  = $_.ToString()
                    lastOk = $lastOk
                }
                Write-Host ""
                Write-Host "[stress] FAILED at iter=$i mode=$($firstFail.mode)"
                Write-Host "[stress]   text    = $text"
                Write-Host "[stress]   last_ok = $lastOk"
                Write-Host "[stress]   error   = $($firstFail.error.Substring(0,[Math]::Min(200,$firstFail.error.Length)))"
                if ($StopOnCrash) { break }
            }
        }
    } else {
        # Concurrent path — spawn $Concurrency speak.py's in parallel.
        # Matches the occasional case where Claude Code fires rapid
        # back-to-back Stop hooks.
        $jobs = @()
        for ($c = 0; $c -lt $Concurrency; $c++) {
            $t = $assistantMessages[(($i * $Concurrency) + $c) % $assistantMessages.Count]
            $jobs += Start-Job -ScriptBlock {
                param($py, $spk, $text)
                $env:SPEAK_NO_PLAYBACK = "1"
                $out = & $py $spk $text 2>&1
                if ($LASTEXITCODE -ne 0) { throw ("exit " + $LASTEXITCODE + ": " + $out) }
            } -ArgumentList $Python, $SpeakPy, $t
        }
        foreach ($j in $jobs) {
            try {
                Wait-Job $j -Timeout 60 | Out-Null
                Receive-Job $j -ErrorAction Stop | Out-Null
                $success++
            } catch {
                $fail++
                if (-not $firstFail) {
                    $firstFail = @{
                        idx    = $i
                        mode   = "concurrent"
                        text   = "(concurrent batch)"
                        error  = $_.ToString()
                        lastOk = $lastOk
                    }
                    Write-Host ""
                    Write-Host "[stress] FAILED at iter=$i mode=concurrent"
                }
            }
            Remove-Job $j -Force -ErrorAction SilentlyContinue
        }
        $lastOk = "(concurrent batch $i)"
        if ($firstFail -and $StopOnCrash) { break }
    }

    if ($i % 5 -eq 0) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $rps = if ($elapsed -gt 0) { [math]::Round($success / $elapsed, 2) } else { 0 }
        Write-Host -NoNewline "`r[stress] i=$i  ok=$success  fail=$fail  rps=$rps  "
    }
}

Write-Host ""
Write-Host "[stress] ---- summary ----"
Write-Host "[stress]   ok   = $success"
Write-Host "[stress]   fail = $fail"
Write-Host "[stress]   elapsed = $([int]((Get-Date) - $startTime).TotalSeconds)s"
if ($firstFail) {
    Write-Host "[stress]   first_fail_mode = $($firstFail.mode)"
    Write-Host "[stress]   first_fail_text = $($firstFail.text)"
    Write-Host "[stress]   last_ok_before  = $($firstFail.lastOk)"
}

# Diff dumps
if (Test-Path $logDir) {
    $postDumps = Get-ChildItem $logDir -Filter "*.dmp" -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty Name
    $newDumps = $postDumps | Where-Object { $preDumps -notcontains $_ }
    if ($newDumps) {
        Write-Host "[stress]   new minidumps:"
        $newDumps | ForEach-Object { Write-Host "     $_" }
    }
}

# Crash log delta
if (Test-Path $crashLog) {
    $size = (Get-Item $crashLog).Length
    if ($size -gt $preCrashLogSize) {
        Write-Host "[stress] ---- new crash log entries ----"
        Get-Content $crashLog -Tail 40
    }
}

exit ([int]($fail -gt 0))
