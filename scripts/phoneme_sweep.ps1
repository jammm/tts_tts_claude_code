# phoneme_sweep.ps1 -- bulk phonemize a big battery of English words against
# the running kokoro-hip-server /phonemize endpoint, then manually (i.e. by
# eyeball) flag outputs that look broken. Writes a CSV so we can diff
# before/after a phonemizer change.
#
# Usage (services must be up):
#   pwsh scripts\phoneme_sweep.ps1                   # writes scripts/phoneme_sweep.csv
#   pwsh scripts\phoneme_sweep.ps1 -Port 8002
#
# The battery tries to cover:
#   - -es plural on every common root-ending pattern (-ss, -sh, -ch, -x, -z,
#     -se, -ze, -ce, -ge) with varied stem vowels
#   - 3rd person singular verbs (-s, -es)
#   - past tense (-ed) on verbs ending in various sounds
#   - gerunds (-ing)
#   - comparatives/superlatives (-er, -est)
#   - common polysyllabic words that upstream phonemizers historically
#     struggle with (words with silent letters, shifting stress, latinate
#     roots)
#
# Heuristics for "looks broken" (eyeball, not automated):
#   * output length << 0.5 * input length (typical IPA is ~1.0-1.5 chars/graph)
#   * repeated phoneme at end (e.g. "ss", "zz") which is never a valid
#     English ending
#   * middle consonants cluster that has no vowel between them and the
#     English root would have one

param(
    [int] $Port = 8002,
    [string] $OutCsv = (Join-Path $PSScriptRoot "phoneme_sweep.csv")
)

$ErrorActionPreference = 'Stop'

# Dynamically discover the kokoro-hip-server port if the default isn't
# listening — lemond assigns from a pool (8001..8004 in my observations).
function Find-KokoroPort {
    foreach ($p in 8001..8010) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/health" -TimeoutSec 1 -ErrorAction Stop
            if ($r.StatusCode -eq 200 -and $r.Content -match '^ok') { return $p }
        } catch { }
    }
    return $null
}

if (-not (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    $found = Find-KokoroPort
    if (-not $found) { throw "kokoro-hip-server is not listening on any of 8001-8010. Is lemond/TTS running?" }
    Write-Host "[sweep] auto-detected kokoro-hip-server port: $found"
    $Port = $found
}

function Phon([string]$txt) {
    $body = @{ input = $txt } | ConvertTo-Json -Compress
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
        $resp = & curl.exe -s -X POST -H 'Content-Type: application/json' `
            --data-binary ('@' + $tmp) --max-time 10 `
            "http://127.0.0.1:$Port/phonemize" 2>$null
        if (-not $resp) { return $null }
        return ($resp | ConvertFrom-Json).phonemes
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------ battery
$battery = @()

# -ss -> -sses plurals
$battery += @('pass','passes','boss','bosses','loss','losses','toss','tosses',
              'miss','misses','mess','messes','mass','masses','kiss','kisses',
              'fuss','fusses','cross','crosses','glass','glasses','class','classes')

# -se -> -ses plurals / 3sg
$battery += @('response','responses','pause','pauses','rose','roses','nose','noses',
              'lose','loses','close','closes','use','uses','chose','chooses',
              'house','houses','expense','expenses','sense','senses','cause','causes',
              'raise','raises','rise','rises','phase','phases','case','cases')

# -ze / -ce
$battery += @('size','sizes','gaze','gazes','price','prices','chance','chances',
              'place','places','face','faces','voice','voices')

# -ge -> -ges
$battery += @('page','pages','cage','cages','bridge','bridges','judge','judges',
              'range','ranges','age','ages','stage','stages','message','messages')

# -sh -> -shes
$battery += @('dish','dishes','wish','wishes','push','pushes','brush','brushes',
              'flash','flashes','wash','washes')

# -ch -> -ches
$battery += @('watch','watches','church','churches','lunch','lunches',
              'teach','teaches','catch','catches','match','matches')

# -x -> -xes
$battery += @('box','boxes','fox','foxes','tax','taxes','fix','fixes','mix','mixes')

# -y -> -ies plurals
$battery += @('country','countries','story','stories','city','cities','fly','flies',
              'body','bodies','hobby','hobbies')

# 3sg on consonant-final verbs
$battery += @('run','runs','walk','walks','think','thinks','stop','stops',
              'send','sends','lift','lifts','grab','grabs','read','reads',
              'write','writes','find','finds','build','builds','send','sends',
              'respond','responds','suspend','suspends','intend','intends')

# -ed past tense
$battery += @('walked','talked','stopped','dropped','added','started','ended',
              'crashed','tested','responded','suspended','intended','processed')

# -ing gerunds
$battery += @('running','walking','stopping','dropping','adding','starting',
              'responding','suspending','processing','missing','passing',
              'crossing','chosing','choosing')

# Comparative/superlative
$battery += @('bigger','biggest','faster','fastest','nicer','nicest','busier','busiest')

# Polysyllabic / historically-tricky
$battery += @('recognize','recognizes','organize','organizes','emphasize','emphasizes',
              'summarize','summarizes','separate','separates','operate','operates',
              'generate','generates','navigate','navigates','communicate','communicates',
              'algorithm','algorithms','configuration','configurations',
              'implementation','implementations','documentation','documentations')

# Abstract / -tion nouns that Claude Code tends to use
$battery += @('function','functions','position','positions','solution','solutions',
              'station','stations','motion','motions','nation','nations',
              'mission','missions','session','sessions','session','compression',
              'decision','decisions','revision','revisions','television','television')

# Common Claude Code words
$battery += @('debug','debugs','commit','commits','branch','branches','refactor','refactors',
              'rebase','rebases','merge','merges','compile','compiles','lint','lints',
              'assert','asserts','implement','implements','iterate','iterates',
              'parse','parses','consume','consumes','produce','produces',
              'query','queries','update','updates','trigger','triggers',
              'kernel','kernels','buffer','buffers','stride','strides',
              'tensor','tensors','model','models','batch','batches',
              'prompt','prompts','response','responses','message','messages')

$battery = $battery | Sort-Object -Unique

Write-Host "[sweep] words: $($battery.Count)"
Write-Host "[sweep] endpoint: http://127.0.0.1:$Port/phonemize"
Write-Host "[sweep] output: $OutCsv"

$rows = New-Object System.Collections.Generic.List[PSCustomObject]
$suspects = New-Object System.Collections.Generic.List[PSCustomObject]

foreach ($word in $battery) {
    $p = Phon $word
    if (-not $p) { Write-Host "  FAIL: $word"; continue }
    $suspect = $false
    # Suspect heuristics:
    #   * output has trailing `zz` / `ss` / `tt` / `dd` (doubled fricatives
    #     at end are never legitimate English)
    #   * output < 0.4 * input length (ratio based on observed ranges)
    #   * output contains `ˈɛs` at end of a longer word whose root doesn't
    #     obviously map to that vowel (catches the bsˈɛs pattern)
    if ($p -match 'zz$|ss$') { $suspect = $true }
    if ($word.Length -ge 5 -and $p.Length -lt [math]::Floor($word.Length * 0.4)) { $suspect = $true }
    if ($word -match '^[^aeiou]+[aeiou]+[^aeiou]+' -and $p -match 'sˈɛs$' -and $word -notlike '*less' -and $word -notlike '*ness') { $suspect = $true }
    $row = [PSCustomObject]@{
        word     = $word
        phonemes = $p
        n_in     = $word.Length
        n_out    = $p.Length
        suspect  = [int]$suspect
    }
    $rows.Add($row)
    if ($suspect) {
        $suspects.Add($row)
        Write-Host ("  SUSPECT  {0,-20} -> {1}" -f $word, $p)
    }
}

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "[sweep] wrote $($rows.Count) rows to $OutCsv"
Write-Host "[sweep] flagged $($suspects.Count) suspects"
