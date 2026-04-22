# tts_stress.ps1 — hammer lemond's Kokoro TTS endpoint with a varied
# corpus until the kokoro-hip-server.exe subprocess crashes. Prints a
# rolling status line; on crash, dumps the last successful request, the
# first failing request, and any new files in $logDir / $dumpDir.
#
# Usage:
#   pwsh -File scripts\tts_stress.ps1              # 500 iterations
#   pwsh -File scripts\tts_stress.ps1 -Count 2000  # longer run
#   pwsh -File scripts\tts_stress.ps1 -Count 5000 -StopOnCrash:$false
#
# Invariants:
#   - Runs against http://127.0.0.1:13305 (lemond's port, already
#     set up by start_services.ps1).
#   - Does NOT start/stop lemond itself. Caller is expected to have
#     services running. On crash we just stop and let WER /
#     KOKORO_HIP_CRASH_LOG do their job.

param(
    [int] $Count = 500,
    [string] $Base = 'http://127.0.0.1:13305',
    [switch] $StopOnCrash = $true,
    [int] $DelayMs = 100
)

$ErrorActionPreference = 'Stop'

# Varied corpus designed to trip punctuation / unicode / length paths
# that a normal demo run wouldn't. Keep these short so we get many
# iterations per minute.
$samples = @(
    "Hello world.",
    "here - you go",
    "Still text-only no audio on my end. What's up?",
    "Still text-only - no audio on my end. What's up?",
    "Still text-only -- no audio on my end. What's up?",
    # Unicode em-dash (U+2014):
    ("Still text-only " + [char]0x2014 + " no audio on my end. What's up?"),
    # En-dash (U+2013):
    ("A range of 1" + [char]0x2013 + "5 items"),
    # Smart quotes (U+2018 / U+2019 / U+201C / U+201D):
    ("The " + [char]0x201C + "curly" + [char]0x201D + " case " + [char]0x2019 + "s tricky."),
    # Horizontal bar (U+2015):
    ("Strikethrough " + [char]0x2015 + " yes please."),
    # Minus sign (U+2212):
    ("Temperature dropped " + [char]0x2212 + "40 degrees."),
    "Short.",
    "A",
    "Yo",
    "OK.",
    "1 2 3",
    "Numbers: 4, 5, 6.",
    "tab`tseparated`tvalues",
    "Multiple    spaces    between    words.",
    "Ending with dash-",
    "-Starting with dash",
    "It's a don't care kind of isn't test.",
    "Question?",
    "Exclamation! Really!!",
    "Mix: Q? A! B. C, D; E:",
    "semicolon;test",
    "colon:test",
    "newline`nsplit",
    "carriage`rreturn",
    "parenthesis (in the middle) of a sentence",
    "square [brackets] around text",
    "curly {braces} too",
    "backslash\\nottabnottermbackslash",
    "forward/slash/path",
    "and & ampersand",
    "double ""quotes"" inline",
    "single 'quotes' inline",
    "mix 'of' ""both""",
    "percent 50% and 99.9%",
    "hash #tag #test",
    "at @mention",
    "url style https://example.com/path?x=1",
    "The quick brown fox jumps over the lazy dog.",
    "She sells seashells by the seashore.",
    "Peter Piper picked a peck of pickled peppers.",
    "How much wood would a woodchuck chuck if a woodchuck could chuck wood?",
    # Longer sentence to exercise the 512-char warm path:
    ("The " + ("quick brown fox " * 10) + "jumps over the lazy dog."),
    # Lots of punctuation in a row:
    "OK... wait... no, really! Are you sure?! Because I'm not...",
    "e.g., i.e., etc., vs., cf.",
    "It was the best of times; it was the worst of times.",
    "She said, 'hello,' and he said, 'hi.'",
    # Numerics that trip phonemizer:
    "The year 2026 saw temperatures of 40.5 degrees.",
    "Call 555-1234 or 1-800-555-0199.",
    # All caps:
    "CAUTION: DO NOT ENTER.",
    # Mixed case:
    "iPhone iPad macOS iOS",
    # Accented chars ASCII round-tripped (should be normalised):
    "cafe resume naive",
    # Ellipsis char (U+2026):
    ("wait" + [char]0x2026 + "what?")
)

$logDir  = "$env:LOCALAPPDATA\voice-plugin\logs"
$dumpDir = $logDir # same place where run_lemond.ps1 points KOKORO_HIP_CRASH_DUMP_DIR

$startTime = Get-Date
$preCrashLog = Get-ChildItem $logDir -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.log','.dmp' } |
               Select-Object -ExpandProperty Name

Write-Host "[stress] hammering $Base/api/v1/audio/speech with $Count requests"
Write-Host "[stress] log dir: $logDir"
Write-Host "[stress] samples in corpus: $($samples.Count)"

$success = 0
$fail    = 0
$firstFail = $null
$lastOk = $null

for ($i = 0; $i -lt $Count; $i++) {
    $text  = $samples[$i % $samples.Count]
    $body  = @{
        model = 'kokoro-v1'
        voice = 'af_bella'
        input = $text
    } | ConvertTo-Json -Compress

    try {
        $resp = Invoke-WebRequest -Uri "$Base/api/v1/audio/speech" `
            -Method Post -ContentType 'application/json' `
            -Body $body -TimeoutSec 30 -ErrorAction Stop
        $success++
        $lastOk = $text
    } catch {
        $fail++
        if (-not $firstFail) {
            $firstFail = @{
                idx    = $i
                text   = $text
                body   = $body
                error  = $_.Exception.Message
                lastOk = $lastOk
            }
            Write-Host ""
            Write-Host "[stress] FAILED at iter=$i ($($_.Exception.Message))"
            Write-Host "[stress]   text=$text"
            Write-Host "[stress]   last_ok=$lastOk"
            if ($StopOnCrash) {
                break
            }
        }
    }

    if ($i % 10 -eq 0) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $rps = if ($elapsed -gt 0) { [math]::Round($i / $elapsed, 2) } else { 0 }
        Write-Host -NoNewline "`r[stress] i=$i  ok=$success  fail=$fail  rps=$rps  "
    }

    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}

Write-Host ""
Write-Host "[stress] ---- summary ----"
Write-Host "[stress]   ok   = $success"
Write-Host "[stress]   fail = $fail"
Write-Host "[stress]   elapsed = $([int]((Get-Date) - $startTime).TotalSeconds)s"
if ($firstFail) {
    Write-Host "[stress]   first_fail_text    = $($firstFail.text)"
    Write-Host "[stress]   first_fail_body    = $($firstFail.body)"
    Write-Host "[stress]   last_ok_before     = $($firstFail.lastOk)"
}

$postCrashLog = Get-ChildItem $logDir -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.log','.dmp' } |
                Select-Object -ExpandProperty Name
$newFiles = Compare-Object $preCrashLog $postCrashLog -PassThru |
            Where-Object { $_.SideIndicator -ne '<=' }
if ($newFiles) {
    Write-Host "[stress]   new files in logs:"
    $newFiles | ForEach-Object { Write-Host "     - $_" }
}

# Crash log tail (if present)
$crash = Join-Path $logDir 'kokoro-hip-crash.log'
if (Test-Path $crash) {
    Write-Host "[stress] ---- kokoro-hip-crash.log (tail) ----"
    Get-Content $crash -Tail 40
}

exit ([int]($fail -gt 0))
