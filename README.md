# Local Voice I/O for Claude Code — Windows + AMD ROCm

Local STT, wake word, and TTS for [Claude Code](https://docs.claude.com/en/docs/claude-code) on Windows 11. Everything runs on your own machine — no cloud.

- **STT (hold-F9 or wake-word) on the GPU** via our ROCm build of whisper.cpp (Whisper-Large-v3-Turbo, ~27× real-time on a 9070 XT with gfx1201).
- **Wake word ("hey halo" by default)** — no custom keyword-spotter. Every energy-gated speech burst gets transcribed by Whisper; the transcript is typed only if it starts with the configured wake phrase. Changing the wake phrase is a single env var.
- **TTS via Lemonade's bundled CPU Kokoro** by default. A pure-eager-PyTorch GPU backend ([F5-TTS on ROCm](#optional-f5-tts-on-gpu)) is available opt-in via `VOICE_TTS=f5`.
- **F9 push-to-talk** via [pynput](https://pynput.readthedocs.io/).
- **Focus gated to Claude Code** — F9 and wake only fire when the foreground window hosts a `claude.exe` process (or a terminal that has `claude` running alongside). Transcriptions never accidentally land in the wrong app.
- **Auto-submit** — the daemon presses Enter after typing the transcription so Claude starts processing the moment you stop talking. Set `PTT_AUTO_SUBMIT=0` to review before sending.

Based on [`PLAN.md`](PLAN.md), with Windows/ROCm-specific adjustments documented at the bottom.

## For AI agents working in this repo

If you're another Claude agent picking up this codebase, read this whole section before touching anything — the short version of how the pieces fit together:

- **Three things run on localhost**: `lemond.exe` (port 13305, STT+CPU TTS), optionally the F5-TTS service (port 13307, GPU TTS), and the `ptt_daemon` Python process (no port; F9 + wake word + typing). Lemonade is always required. F5 is opt-in. The PTT daemon is always required.
- **Code lives in four places:**
  - `ptt/` — the PTT daemon (wake detection, recording, transcription, typing) and the optional `kokoro_server.py` / `f5_tts_server.py` GPU TTS services.
  - `claude-plugin-voice/` — the Claude Code plugin (Stop hook that speaks replies, `/voice:speak` slash command).
  - `installers/` — PowerShell scripts that deploy code from `ptt/` + `claude-plugin-voice/` into `%LOCALAPPDATA%\voice-plugin\` and `~/.claude/plugins/voice\`, plus `run_*.ps1.tmpl` shims that start the services.
  - `tools/` + `deps/` + `vendor/` — build scripts and compiled binaries for the ROCm Whisper / Lemonade C++ servers.
- **The config file is the contract.** `ptt/config.py` is the single source of truth for tunables. If you're adjusting behavior, go through env vars declared in there. Don't hard-code values in other files.
- **Do not restart services in the middle of debugging unless necessary.** Services run in the background and log to `%LOCALAPPDATA%\voice-plugin\logs\`. Tail those files before killing anything. The PID file at `%LOCALAPPDATA%\voice-plugin\services.json` tracks which process is which; `stop_services.ps1` expects it.
- **The repo is a git clone at `d:\jam\demos` and a GitHub remote at `origin`**. Submodules under `deps/` pin specific upstream commits — don't update them casually.
- **`PLAN.md` is the original design doc. Don't edit it.** It's the aspirational starting point; this README is what actually got built.
- **Don't assume a specific GPU.** The 9070 XT (gfx1201) is the dev machine, but the target test platform is Strix Halo (gfx1151, Radeon 8060S iGPU). Anything that relies on 9070 XT-only ROCm features is a bug.

## Repo layout

```
.
├── PLAN.md                       original design doc (historical)
├── README.md                     this file
├── requirements.txt              Python deps (PTT daemon + plugin)
├── ptt/                          daemon + optional GPU TTS services
│   ├── config.py                 env-driven knobs (WAKE_PHRASE, etc.)
│   ├── ptt_daemon.py             entry point: F9 hook + wake listener
│   ├── whisper_wake_listener.py  energy-VAD + Whisper wake-phrase check
│   ├── recorder.py               capture -> POST to whisper -> type
│   ├── window_check.py           focus gate (claude.exe under foreground?)
│   ├── f5_tts_server.py          opt-in GPU TTS service (port 13307)
│   └── kokoro_server.py          experimental GPU Kokoro (port 13306)
├── claude-plugin-voice/          Claude Code plugin
│   ├── .claude-plugin/plugin.json
│   ├── commands/speak.md         /voice:speak slash command
│   ├── hooks/hooks.json          Stop hook (inline-copied to settings.json)
│   └── scripts/speak.py          fetches WAV from TTS, plays via sounddevice
├── installers/
│   ├── install_windows.ps1       deploys plugin + daemon + merges settings.json
│   ├── start_services.ps1        launches lemonade + optional TTS + PTT
│   ├── stop_services.ps1         kills all by pidfile + orphan walk
│   ├── uninstall_windows.ps1
│   └── run_{lemonade,kokoro,f5,ptt}.ps1.tmpl   service launch shims
├── tools/
│   ├── build_lemonade_cpp.cmd    builds lemond.exe (Lemonade C++ server)
│   └── build_whisper_hip.cmd     builds whisper-server.exe (ROCm/gfx1201)
└── deps/                         git submodules
    ├── lemonade/                 lemonade-sdk/lemonade (tag v10.2.0)
    ├── whisper.cpp/              ggml-org/whisper.cpp
    └── llama.cpp/                ggml-org/llama.cpp (ggml overlay source)

# gitignored, generated by bootstrap/build:
.venv/                            Python 3.12 venv: TheRock ROCm torch, f5-tts, etc.
vendor/lemonade-cpp/              lemond.exe + resources/
vendor/whisper-cpp-rocm/          whisper-server.exe + ggml-hip.dll + ROCm DLLs
%LOCALAPPDATA%/voice-plugin/      installed daemon + run_*.ps1 shims + logs/
~/.claude/plugins/voice/          installed Claude Code plugin
~/.claude/settings.json           merged by install_windows.ps1 (hook + allowlist)
```

### Services and ports

| service       | port  | what it serves                                      | backend                                                |
|---------------|------:|-----------------------------------------------------|--------------------------------------------------------|
| `lemond`      | 13305 | `/api/v1/audio/transcriptions` + `/audio/speech`    | ROCm whisper.cpp (our build) + CPU Kokoro TTS          |
| `f5_tts`      | 13307 | `/api/v1/audio/speech` (opt-in)                     | F5-TTS (DiT + Vocos) in pure eager PyTorch on ROCm     |
| `kokoro_server` | 13306 | `/api/v1/audio/speech` (experimental)              | hexgrad/Kokoro-82M with `torch.compile(backend=eager)` |
| `ptt_daemon`  | —     | F9 hotkey + Whisper-wake + recorder + typer         | pynput + sounddevice + HTTP to lemond                   |

Default runtime is just `lemond` + `ptt_daemon`. F5 and Kokoro-GPU are opt-in via `VOICE_TTS=f5` or `VOICE_TTS=kokoro`.

## Prerequisites

- Windows 11, AMD Radeon RX 9000-series or Ryzen AI Max+ / Strix Halo (gfx120X / gfx1151)
- Python 3.12 on `PATH` as `py -3.12`
- Visual Studio 2022 Community (Desktop C++ workload) — needed to build `lemond.exe` and `whisper-server.exe`
- CMake 3.28+
- Git
- Claude Code CLI (`claude`)

## Bootstrap on a fresh clone

```powershell
# 1. Source + submodules
git clone https://github.com/jammm/tts_tts_claude_code.git
cd tts_tts_claude_code
git submodule update --init --recursive

# 2. Python venv + base deps
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install --upgrade pip
pip install -r requirements.txt

# 3. TheRock ROCm PyTorch (torch + HIP SDK for gfx120X / gfx1151).
# For Strix Halo, swap "gfx120X-all" for "gfx1151" in the index URL.
pip install --index-url https://rocm.nightlies.amd.com/v2/gfx120X-all/ torch "rocm[libraries,devel]"
rocm-sdk init        # extracts the ROCm runtime into the venv (~1.3 GB)

# 4. Build the two C++ binaries (~3-4 min total on a warm box)
.\tools\build_lemonade_cpp.cmd
.\tools\build_whisper_hip.cmd

# 5. Pull the Whisper STT model into Lemonade's cache
.\vendor\lemonade-cpp\lemond.exe          # leave running in this shell
.\vendor\lemonade-cpp\lemonade.exe pull Whisper-Large-v3-Turbo
# (Whisper-Small works too if you want ~3x faster but noticeably less
# accurate STT. Override with WHISPER_MODEL env var.)
# Ctrl-C the lemond above — start_services.ps1 launches it properly later.

# 6. Deploy plugin + daemon + settings.json hook
.\installers\install_windows.ps1

# 7. Launch services
.\installers\start_services.ps1
```

After step 7 you have `lemond` (STT+TTS) + `ptt_daemon` running. F9 push-to-talk and "hey halo" wake-word are both armed.

```powershell
claude --plugin-dir "$env:USERPROFILE\.claude\plugins\voice"
```

The Stop hook is also merged into `~/.claude/settings.json` by the installer, so it fires without `--plugin-dir` too.

## Running the services

```powershell
.\installers\start_services.ps1     # launches whatever VOICE_TTS asks for
.\installers\stop_services.ps1      # kills all by pidfile + orphan walk
```

- All processes run hidden; stdout/stderr goes to `%LOCALAPPDATA%\voice-plugin\logs\<name>-<timestamp>.log`. Tail those to debug anything weird.
- `%LOCALAPPDATA%\voice-plugin\services.json` records PIDs so `stop_services.ps1` can find them across shells.
- Re-running `start_services.ps1` is safe — it skips any service whose recorded PID is still alive.

### Switching TTS backends

```powershell
# Default: Lemonade CPU Kokoro (already running as part of lemond)
.\installers\stop_services.ps1 && .\installers\start_services.ps1

# F5-TTS on GPU (pure eager, consistent 300-900 ms/sentence)
$env:VOICE_TTS = "f5"
.\installers\stop_services.ps1 && .\installers\start_services.ps1

# Experimental: our torch.compile-based Kokoro on GPU
$env:VOICE_TTS = "kokoro"
.\installers\stop_services.ps1 && .\installers\start_services.ps1
```

`speak.py` picks the server based on `TTS_URL` env var (defaults to `http://127.0.0.1:13305`). If you flip `VOICE_TTS=f5` you also want `TTS_URL=http://127.0.0.1:13307` in the shell where you run `claude`:

```powershell
$env:VOICE_TTS = "f5"; .\installers\stop_services.ps1; .\installers\start_services.ps1
$env:TTS_URL = "http://127.0.0.1:13307"
claude --plugin-dir "$env:USERPROFILE\.claude\plugins\voice"
```

### Running the daemon interactively

```powershell
.\installers\stop_services.ps1
.\.venv\Scripts\Activate.ps1
$env:PYTHONPATH = "."
python -m ptt.ptt_daemon --verbose
# F9 + "hey halo" both armed. Ctrl-C to stop.
# Useful flags: --no-wake, --no-ptt
```

### Checking status

```powershell
Invoke-RestMethod http://127.0.0.1:13305/api/v1/health    # lemonade (STT + CPU TTS)
# If VOICE_TTS=f5:
Invoke-RestMethod http://127.0.0.1:13307/api/v1/health    # F5-TTS
# Processes:
Get-CimInstance Win32_Process -Filter "Name='python.exe'" `
    | Where-Object CommandLine -match "ptt_daemon|f5_tts_server|kokoro_server" `
    | Select-Object ProcessId, CommandLine
```

### Auto-start at logon (optional)

```powershell
.\installers\install_windows.ps1 -RegisterScheduledTasks
Start-ScheduledTask VoiceLemonade
Start-ScheduledTask VoicePTT
```

`uninstall_windows.ps1` removes them.

## Key configuration

All tunables are env vars read by `ptt/config.py` (daemon) or the TTS servers. Set them in the shell before `start_services.ps1`.

**Wake phrase** — the big one. Default matches "hey halo" plus common Whisper mishearings ("hello", "hallo", "hailo", etc.). Change via `WAKE_PHRASE` (full regex, must match at the start of the transcript):

```powershell
# "hey claude"
$env:WAKE_PHRASE = "^\s*(?:hey[,\s]+|ok[,\s]+)?claude[\s,.:;!?-]*"
# "computer,"
$env:WAKE_PHRASE = "^\s*computer[\s,.:;!?-]*"
```

**STT model** — Whisper-Large-v3-Turbo by default for accuracy. Override:

```powershell
$env:WHISPER_MODEL = "Whisper-Small"   # faster, less accurate
$env:WHISPER_MODEL = "Whisper-Medium"  # middle ground
```

**STT hints** — the daemon passes `language=en` and a short context prompt ("The user is talking to an AI coding assistant...") to bias Whisper toward technical vocabulary. Override with `WHISPER_LANGUAGE=""` / `WHISPER_PROMPT=""` to disable either.

**Auto-submit** — Enter is pressed after typing. `PTT_AUTO_SUBMIT=0` to disable.

**Energy threshold** for wake capture — `EOU_ENERGY_THRESHOLD` (int16 RMS, default 450). Lower = more sensitive.

**F5-TTS** (when `VOICE_TTS=f5`): `F5_NFE=32` (default, 16 and 8 trade quality for speed), `F5_SPEED=1.15`, `F5_TAIL_PAD_MS=180`, `F5_REF_AUDIO`, `F5_REF_TEXT`. See `ptt/f5_tts_server.py` docstring.

## Interactive test checklist

After `start_services.ps1`:

1. **STT smoke** — hold F9, speak a sentence, release. Transcription should type + submit within ~1-2 s of release.
2. **Wake word** — say *"hey halo, what is the current time"*. The daemon records until ~800 ms of silence, strips `"hey halo"`, types `what is the current time` + Enter.
3. **Stop hook (TTS)**:
   ```powershell
   $null | claude --plugin-dir "$env:USERPROFILE\.claude\plugins\voice" -p "Say hi in five words"
   ```
   After the text prints, Kokoro speaks it through your speakers.
4. **`/voice:speak`** — inside `claude`, `/voice:speak Hello from the voice plugin.`
5. **Feedback-loop guard** — say "hey halo" *while* TTS is speaking. The wake listener ignores it (speak.py holds `tts_active.lock` during playback). After playback ends, wake fires normally.
6. **Focus gate** — run `claude` in a terminal, then Alt-Tab to another window (browser, text editor). Say "hey halo, test". Nothing happens because the focus check fails. Refocus the terminal, repeat — now it fires.

## Troubleshooting

- **F9 does nothing.** `Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object CommandLine -match ptt_daemon`. If empty, run `.\installers\start_services.ps1`. If it keeps dying, run interactively (see above) to see the traceback.
- **Wake word misses on clean utterances.** Speak a touch more clearly or check the log:
  ```powershell
  Get-Content "$env:LOCALAPPDATA\voice-plugin\logs\ptt-*.log" -Tail 5 -Wait
  ```
  Every attempt logs `whisper: <ms> -> '<transcript>'` — if you see the transcript and the regex just didn't match, widen `WAKE_PHRASE`. If you see `no speech detected` / no transcript lines at all, `EOU_ENERGY_THRESHOLD` is too high; drop it (default 450 → try 300).
- **Wake word fires on random conversation.** The regex is anchored at the start (`^`), so this shouldn't happen — if it does, the transcript is genuinely starting with something that matches. Tighten `WAKE_PHRASE`: e.g., require `hey\s+halo` (no "hey" optionality, no close phonetic variants).
- **STT mis-transcribes ("current time" → "occurrent time").** You're probably on Whisper-Small. Pull Whisper-Large-v3-Turbo (see bootstrap step 5) and set `$env:WHISPER_MODEL = "Whisper-Large-v3-Turbo"`.
- **STT text lands in the wrong window.** Don't Alt-Tab while transcribing. The focus gate re-checks right before typing and will drop the transcript if focus has drifted, but brief overlaps can still sneak through.
- **Stop hook doesn't fire in Claude Code.** `--plugin-dir` loads commands but doesn't activate plugin hooks in current Claude Code. The installer inlines the same hook into `~/.claude/settings.json` so it fires regardless. If it still doesn't: `Get-Content ~/.claude/settings.json | Select-String "speak.py"` — the inline Stop hook should be there. If not, re-run `installers\install_windows.ps1`.
- **`speak.py` takes ~2 s of HTTP connect time per turn.** Make sure `TTS_URL` uses `127.0.0.1`, not `localhost`. Windows tries IPv6 first and eats ~2 s on the fallback for short-lived connections.
- **TTS plays nothing.** Check the `speak.py` audit log in `%LOCALAPPDATA%\voice-plugin\logs\speak.log` and Lemonade's logs. Common causes: no default audio output device, or `TTS_URL` pointing at a service that isn't running.
- **F5-TTS takes minutes to start the first time.** It downloads ~2 GB of weights from HuggingFace on first launch (Vocos + F5-TTS Base). Subsequent starts are ~5 s.

## Architecture decisions / trade-offs

- **Whisper-based wake word instead of a keyword-spotter.** The original design used openWakeWord ("hey jarvis"), but that limited us to its 5 pre-trained phrases unless we trained a custom model. Reusing the Whisper STT we already run — transcribe each energy-gated speech burst, regex-match the transcript — lets us change the wake phrase to anything with one env var. Cost: one Whisper call per utterance vs. openWakeWord's per-frame inference, but Whisper only runs when someone's actually speaking, so amortized load is modest.
- **Lemonade CPU Kokoro as default TTS.** It's already running for STT, so there's zero additional service to start. Latency is a few hundred ms per sentence on a modern CPU, which is fine for Claude Code's typical reply length. F5-TTS on GPU is faster for long outputs and available opt-in.
- **F5-TTS over our custom `kokoro_server` as the GPU TTS.** F5 is pure eager PyTorch — no `torch.compile`, no Dynamo shape guards, so no per-sentence-shape recompile cliffs. Our Kokoro service still exists (`ptt/kokoro_server.py`) for experimentation but isn't default.
- **Focus gate.** F9 and wake only fire when a `claude.exe` process lives under the foreground window (or when a known terminal-hosting process like Windows Terminal is focused and `claude` is running anywhere on the system). The recorder re-checks just before typing to handle focus drift during Whisper's round-trip.
- **Stop hook lives in `~/.claude/settings.json`, not just `hooks/hooks.json`.** Claude Code's `--plugin-dir` loads plugin commands but not plugin hooks. The installer merges the Stop hook inline so it fires in both `--plugin-dir` and `/plugin install` modes.
- **Venv at workspace root (`.\.venv`).** The installer bakes the venv Python path into the shims, so the daemon always uses the right interpreter.
- **Flash attention disabled at runtime.** `whispercpp.args=-nfa` in Lemonade's config — the rocWMMA FA path produces garbled output on gfx1201 today. Non-FA ROCm is still 24× faster than CPU so we live with it.

## Build / runtime notes

- **CMake on Windows 11 misreads `CMAKE_SYSTEM_VERSION` as 6.2** with recent Windows SDKs via `cpp-httplib`. Both our build scripts pass `-DCMAKE_SYSTEM_VERSION="10.0.26100.0"` explicitly.
- **whisper.cpp + amdclang-cl.** Must use amdclang-cl from TheRock (`%VENV%\Lib\site-packages\_rocm_sdk_devel\lib\llvm\bin\amdclang-cl.exe`) for both C and CXX to match compiler families. Mixing with hipcc (GNU-driver) trips CMake's same-family check.
- **ggml overlay** happens automatically on each `build_whisper_hip.cmd` run: it `xcopy`s `deps/llama.cpp/ggml/` onto `deps/whisper.cpp/ggml/`. No submodule files get committed; the overlay is a build-time step.
- **`cudnn`/MIOpen stays on.** MIOpen is the accuracy-preserving path on ROCm; `torch.backends.cudnn.enabled = False` swaps in an `aten::lstm` fallback that's numerically different and produces worse-sounding audio on this stack.

## Out of scope (v1)

- Streaming TTS (speaking sentence-by-sentence as Claude writes). Claude Code's `--include-partial-messages` exposes text deltas over stream-json; wiring those into the TTS backend is a follow-up.
- ROCm flash attention that actually works on gfx1201.
- TTS barge-in — the wake listener stays muted during TTS via `tts_active.lock` but doesn't actively cut off playback.
- Multi-window/multi-session support — one `claude.exe` at a time.
- Languages other than English.

## Uninstall

```powershell
.\installers\uninstall_windows.ps1
```

Removes any Task Scheduler entries, `%USERPROFILE%\.claude\plugins\voice\`, and `%LOCALAPPDATA%\voice-plugin\` (including logs and any cached TTS artifacts). `~/.claude/settings.json` is left alone — edit it by hand if you want to drop the permission allowlist and Stop hook entries. The `.venv` and `vendor/` build outputs in the workspace are untouched.
