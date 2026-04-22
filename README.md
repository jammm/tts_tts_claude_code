# Local Voice I/O for Claude Code — Windows + AMD ROCm

Local STT, wake word, and TTS for [Claude Code](https://docs.claude.com/en/docs/claude-code) on Windows 11. Everything runs on your own machine — no cloud.

- **STT (hold-F9 or wake-word) on the GPU** via our ROCm build of whisper.cpp. On a 9070 XT (gfx1201) with Whisper-Large-v3-Turbo, transcribes 37.8 s of speech in ~460 ms steady-state — 80× realtime. Requires a patched Lemonade (our `jam/windows-rocm-whisper` submodule branch) because upstream Lemonade only wires CPU / NPU / Vulkan for whispercpp.
- **Wake word ("hey halo" by default)** — no custom keyword-spotter. Every energy-gated speech burst gets transcribed by Whisper; the transcript is typed only if it starts with the configured wake phrase. Changing the wake phrase is a single env var.
- **TTS on the GPU** via our patched koboldcpp HIP build running Kokoro through ttscpp. Pinned to `jammm/koboldcpp jam/gfx1201-hip` with four upstream bug-fixes (128-byte tensor alignment, `reciprocal()` host-pointer hack, direct-`->data` writes in `set_inputs`, shared HIP stream) plus a fused `snake_1d` megakernel and CUDA implementations for the kcpp ttscpp dirtypatch ops. On a 9070 XT: **0.10 s short prompt, 1.30 s for a 402-char paragraph, median 0.37 s warm** once `ROCBLAS_USE_HIPBLASLT=1` is set (gives ~7× speedup by routing F32 matmul through hipBLASLt's complete gfx1201 kernel set instead of rocBLAS's incomplete one). Opt-out to CPU via `VOICE_TTS=cpu` or to F5-TTS via `VOICE_TTS=f5` — see [Switching TTS backends](#switching-tts-backends).
- **F9 push-to-talk** via [pynput](https://pynput.readthedocs.io/).
- **Focus gated to Claude Code** — F9 and wake only fire when the foreground window hosts a `claude.exe` process (or a terminal that has `claude` running alongside). Transcriptions never accidentally land in the wrong app.
- **Auto-submit** — the daemon presses Enter after typing the transcription so Claude starts processing the moment you stop talking. Set `PTT_AUTO_SUBMIT=0` to review before sending.

Based on [`PLAN.md`](PLAN.md), with Windows/ROCm-specific adjustments documented at the bottom.

## For AI agents working in this repo

If you're another Claude agent picking up this codebase, read this whole section before touching anything — the short version of how the pieces fit together:

- **Three things run on localhost**: `lemond.exe` (port 13305, STT + built-in CPU Kokoro fallback), `koboldcpp_hipblas.dll`-backed python process (port 13308, default GPU TTS) and the `ptt_daemon` Python process (no port; F9 + wake word + typing). Lemonade is always required. The kobold TTS service is default; F5 / kokoro / cpu-only are opt-in via `VOICE_TTS`. The PTT daemon is always required.
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
    ├── lemonade/                 lemonade-sdk/lemonade on our
    │                             jam/windows-rocm-whisper branch —
    │                             adds a ROCm backend for whispercpp
    │                             that upstream doesn't have. See
    │                             "Build / runtime notes" below.
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

Default runtime is `lemond` (STT on ROCm GPU + fallback CPU Kokoro) + `koboldcpp_hipblas` (GPU Kokoro) + `ptt_daemon`. F5 and the experimental PyTorch Kokoro GPU service are opt-in via `VOICE_TTS=f5` or `VOICE_TTS=kokoro`.

## Prerequisites

- Windows 11, AMD Radeon RX 9000-series or Ryzen AI Max+ / Strix Halo (gfx120X / gfx1151)
- Python 3.12 on `PATH` as `py -3.12`
- Visual Studio 2022 Community (Desktop C++ workload) — needed to build `lemond.exe`, `whisper-server.exe`, and `koboldcpp_hipblas.dll`
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

# 4. Build the three C++ binaries (~15-20 min total on a warm box).
# The default TTS backend is GPU Kokoro via koboldcpp, so all three
# are required for a first-time install.
.\tools\build_lemonade_cpp.cmd        # ~3 min    -> vendor\lemonade-cpp\lemond.exe
.\tools\build_whisper_hip.cmd         # ~2 min    -> vendor\whisper-cpp-rocm\whisper-server.exe (ROCm GPU STT)
.\tools\build_koboldcpp_hip.cmd       # ~10-15 min -> vendor\koboldcpp-rocm\koboldcpp_hipblas.dll (HIP GPU TTS)
# (Override gfx target with $env:GFX_TARGET="gfx1151" for Strix Halo
# before running the HIP builds — see Deploying on Strix Halo below.)

# 5. Download the Kokoro GGUF weights koboldcpp will serve
New-Item -ItemType Directory -Force models | Out-Null
curl.exe -L -o models\Kokoro_no_espeak_Q4.gguf `
  https://huggingface.co/koboldcpp/tts/resolve/main/Kokoro_no_espeak_Q4.gguf

# 6. Pull the Whisper STT model into Lemonade's cache
.\vendor\lemonade-cpp\lemond.exe          # leave running in this shell
.\vendor\lemonade-cpp\lemonade.exe pull Whisper-Large-v3-Turbo
# (Whisper-Small works too if you want ~3x faster but noticeably less
# accurate STT. Override with WHISPER_MODEL env var.)
# Ctrl-C the lemond above — start_services.ps1 launches it properly later.

# 7. Deploy plugin + daemon + settings.json hook
.\installers\install_windows.ps1

# 8. Launch services
.\installers\start_services.ps1
```

After step 8 you have `lemond` (STT on ROCm GPU) + `koboldcpp_hipblas` (TTS on HIP GPU) + `ptt_daemon` running. F9 push-to-talk and "hey halo" wake-word are both armed.

If you're resurrecting an existing install and just want to move from the old CPU-TTS default to the new GPU-TTS default: run steps 4b (`build_koboldcpp_hip.cmd`), 5 (download GGUF), 7 (`install_windows.ps1` to re-render the shim), then `.\installers\stop_services.ps1; .\installers\start_services.ps1`.

```powershell
claude --plugin-dir "$env:USERPROFILE\.claude\plugins\voice"
```

The Stop hook is also merged into `~/.claude/settings.json` by the installer, so it fires without `--plugin-dir` too.

## Deploying on Strix Halo (gfx1151 iGPU + XDNA2 NPU)

The dev machine is a Threadripper PRO 9995WX + RX 9070 XT (gfx1201, no NPU). The actual target is Strix Halo — Ryzen AI Max+ 395 / Radeon 8060S (gfx1151 iGPU) + 50-TOPS XDNA2 NPU. Three differences matter for deployment:

1. **PyTorch / ROCm SDK index URL** — TheRock publishes per-arch nightly wheel indices. Swap `gfx120X-all` for `gfx1151` in step 3:
   ```powershell
   pip install --index-url https://rocm.nightlies.amd.com/v2/gfx1151/ torch "rocm[libraries,devel]"
   rocm-sdk init
   ```
   (`gfx1151` is Strix Halo's Radeon 8060S iGPU — not to be confused with `gfx1150`, which is Strix Point's Radeon 880M/890M.)

2. **whisper.cpp + koboldcpp HIP builds** — both build scripts now honor `GFX_TARGET`. Set it once and rebuild:
   ```powershell
   $env:GFX_TARGET = "gfx1151"          # or "gfx1151;gfx1201" for fat binary
   .\tools\build_whisper_hip.cmd clean
   .\tools\build_koboldcpp_hip.cmd clean
   ```

3. **Whisper on the NPU instead of the iGPU** — Lemonade has a first-class `npu` whispercpp backend (`deps/lemonade/src/cpp/server/backends/whisper_server.cpp`) that auto-downloads its own NPU-compiled `whisper-server.exe` from `lemonade-sdk/whisper.cpp-builds` plus the model's vitisai-compiled `.rai` cache from `amd/whisper-large-v3-onnx-npu` (or `-large-turbo-`, `-medium-`, etc.). All you have to do is set the backend env var before launching services:
   ```powershell
   # Prereq: AMD Ryzen AI driver installed (NPU/XDNA driver — get the
   # latest "AMD Ryzen AI Software" installer; check Device Manager
   # afterwards for "AMD IPU Device" or "Neural Processors").
   $env:LEMONADE_WHISPER_BACKEND = "npu"
   .\installers\stop_services.ps1; .\installers\start_services.ps1
   ```
   `installers\run_lemonade.ps1.tmpl` reads `LEMONADE_WHISPER_BACKEND` and translates to Lemonade's internal `LEMONADE_WHISPERCPP=npu`. The NPU encoder is plenty fast for both `Whisper-Large-v3` and `Whisper-Large-v3-Turbo` (Lemonade's `server_models.json` includes a precompiled `.rai` for either). The decode side stays on CPU — that's how upstream's NPU whisper works.

Other defaults stay the same:

- **Kokoro TTS**: same CPU-via-Lemonade path on Strix Halo, just runs on Zen 5 cores instead of Zen 5 Threadripper cores. Median latency stays in the same ballpark (~1 s).
- **F5-TTS** (`VOICE_TTS=f5`): runs on the iGPU through the gfx1151 PyTorch wheels. Should work the same; haven't actually benchmarked on Strix Halo silicon.
- **PTT daemon, hooks, plugin**: pure Python, no platform-specific bits.

If Strix Halo doesn't even need ROCm whisper (the NPU is fast enough), you can skip building `vendor\whisper-cpp-rocm\whisper-server.exe` entirely — `run_lemonade.ps1` falls through to the CPU backend if no ROCm whisper binary is present and `LEMONADE_WHISPER_BACKEND` isn't set, and to NPU when it is.

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
# Default when vendor\koboldcpp-rocm\koboldcpp_hipblas.dll is built:
# koboldcpp HIP Kokoro on :13308 (runs Kokoro on the GPU — see
# "Kokoro on the GPU (HIP)" below for what that entails).
.\installers\stop_services.ps1; .\installers\start_services.ps1

# CPU opt-out (useful when the GPU is busy training or you want to
# A/B latency on the same DLL):
$env:VOICE_TTS = "cpu"      # Lemonade's built-in Kokoro on :13305
.\installers\stop_services.ps1; .\installers\start_services.ps1

# F5-TTS on GPU (pure-eager DiT, 300-900 ms/sentence, needs
# tools\build_koboldcpp_hip.cmd to have been run since F5 uses the
# same TheRock ROCm wheels):
$env:VOICE_TTS = "f5"
.\installers\stop_services.ps1; .\installers\start_services.ps1

# Experimental: our torch.compile-based Kokoro on GPU (has
# recompile cliffs; mostly kept for reference):
$env:VOICE_TTS = "kokoro"
.\installers\stop_services.ps1; .\installers\start_services.ps1

# Inside the "kobold" backend you can force ttscpp to CPU (A/B
# without rebuilding the DLL — useful because the services.json
# still records tts_backend=kobold so speak.py keeps routing to
# :13308 regardless):
$env:VOICE_TTS_KOBOLD_CPU = "1"
.\installers\stop_services.ps1; .\installers\start_services.ps1
```

`speak.py` auto-picks the right `TTS_URL` / `TTS_SPEECH_PATH` in this order:

1. `TTS_SPEECH_URL` env (full URL override)
2. `TTS_URL` + `TTS_SPEECH_PATH` env
3. `VOICE_TTS` env
4. `%LOCALAPPDATA%\voice-plugin\services.json` `tts_backend` — what `start_services.ps1` actually launched (this matters because Claude Code's Stop hook runs as a subprocess of `claude`, NOT of the shell that started services, so env vars from that shell don't propagate — the services.json hop is how the hook learns the current backend)
5. `cpu` fallback

Backend → port mapping used internally:

| VOICE_TTS | Server                  | URL                                            |
|-----------|-------------------------|------------------------------------------------|
| `kobold`  | koboldcpp HIP Kokoro    | `http://127.0.0.1:13308/v1/audio/speech`       |
| `cpu`     | Lemonade CPU Kokoro     | `http://127.0.0.1:13305/api/v1/audio/speech`   |
| `f5`      | F5-TTS on GPU           | `http://127.0.0.1:13307/api/v1/audio/speech`   |
| `kokoro`  | ROCm PyTorch Kokoro     | `http://127.0.0.1:13306/api/v1/audio/speech`   |

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

**Whispercpp backend** (used by `lemond.exe` internally — set in `installers/run_lemonade.ps1.tmpl`):

```powershell
# defaults baked into the shim:
$env:LEMONADE_WHISPERCPP          = "rocm"
$env:LEMONADE_WHISPERCPP_ROCM_BIN = "D:\jam\demos\vendor\whisper-cpp-rocm\whisper-server.exe"
$env:LEMONADE_WHISPERCPP_ARGS     = "-nfa"   # disables flash-attention (rocWMMA FA is wrong on gfx1201)

# override to switch back to CPU-only STT:
$env:LEMONADE_WHISPERCPP = "cpu"
```

Heads-up: Lemonade caches its resolved config at `%USERPROFILE%\.cache\lemonade\config.json` on first boot and only re-reads env vars if that file doesn't exist. If you change `LEMONADE_WHISPERCPP*` and don't see the change take effect, delete the cached `config.json` and restart.

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
- **koboldcpp HIP Kokoro as default TTS.** Runs Kokoro on the GPU through the ttscpp backend in our `jammm/koboldcpp jam/gfx1201-hip` fork (four upstream bugs patched so Kokoro even starts a kernel without crashing, plus a fused `snake_1d` megakernel and CUDA kernels for the kcpp ttscpp dirtypatch ops — see [Kokoro on the GPU (HIP)](#kokoro-on-the-gpu-hip)). No python in the hot loop, no `torch.compile` recompile cliffs. Latency varies with GPU — on gfx1201 / RX 9070 XT it's ~0.4 s for short prompts and ~8 s for a 400-char paragraph; on Strix Halo (gfx1151) once the NPU path matures it'll be the same or faster. Fallbacks: `VOICE_TTS=cpu` for Lemonade's built-in Kokoro (always available, lemond ships it), `VOICE_TTS=f5` for F5-TTS's flow-matching DiT on GPU.
- **F5-TTS over our custom `kokoro_server` as the PyTorch GPU TTS.** F5 is pure eager PyTorch — no `torch.compile`, no Dynamo shape guards, so no per-sentence-shape recompile cliffs. Our Kokoro service still exists (`ptt/kokoro_server.py`) for experimentation but isn't default and has torch-compile issues.
- **Focus gate.** F9 and wake only fire when a `claude.exe` process lives under the foreground window (or when a known terminal-hosting process like Windows Terminal is focused and `claude` is running anywhere on the system). The recorder re-checks just before typing to handle focus drift during Whisper's round-trip.
- **Stop hook lives in `~/.claude/settings.json`, not just `hooks/hooks.json`.** Claude Code's `--plugin-dir` loads plugin commands but not plugin hooks. The installer merges the Stop hook inline so it fires in both `--plugin-dir` and `/plugin install` modes.
- **Venv at workspace root (`.\.venv`).** The installer bakes the venv Python path into the shims, so the daemon always uses the right interpreter.
- **Flash attention disabled at runtime.** `whispercpp.args=-nfa` in Lemonade's config — the rocWMMA FA path produces garbled output on gfx1201 today. Non-FA ROCm is still 24× faster than CPU so we live with it.

## Build / runtime notes

- **Patched Lemonade fork for ROCm whisper.** The `deps/lemonade` submodule is pinned to our branch (`jam/windows-rocm-whisper`) which adds a `rocm` option to the `whispercpp` backend dispatch. Four surgical edits over upstream: registering the backend in `system_info.cpp`'s recipe table, an accept-`rocm` branch in `whisper_server.cpp` (plus a no-op `get_install_params` case so external binaries short-circuit the github download), two new env-var mappings in `config_file.cpp` (`LEMONADE_WHISPERCPP_ROCM_BIN` + `LEMONADE_WHISPERCPP_VULKAN_BIN`), and `rocm_bin`/`vulkan_bin` defaults in `resources/defaults.json`. If you re-init submodules you'll lose this — keep the branch.
- **Lemonade config.json is cached on first boot.** Env vars like `LEMONADE_WHISPERCPP_*` are only read into `%USERPROFILE%\.cache\lemonade\config.json` the first time lemond runs. If you later change a shim env var and it doesn't take effect, delete that file and restart.
- **CMake on Windows 11 misreads `CMAKE_SYSTEM_VERSION` as 6.2** with recent Windows SDKs via `cpp-httplib`. Both our build scripts pass `-DCMAKE_SYSTEM_VERSION="10.0.26100.0"` explicitly.
- **whisper.cpp + amdclang-cl.** Must use amdclang-cl from TheRock (`%VENV%\Lib\site-packages\_rocm_sdk_devel\lib\llvm\bin\amdclang-cl.exe`) for both C and CXX to match compiler families. Mixing with hipcc (GNU-driver) trips CMake's same-family check.
- **ggml overlay** happens automatically on each `build_whisper_hip.cmd` run: it `xcopy`s `deps/llama.cpp/ggml/` onto `deps/whisper.cpp/ggml/`. No submodule files get committed; the overlay is a build-time step.
- **`cudnn`/MIOpen stays on.** MIOpen is the accuracy-preserving path on ROCm; `torch.backends.cudnn.enabled = False` swaps in an `aten::lstm` fallback that's numerically different and produces worse-sounding audio on this stack.

### Building koboldcpp with HIPBLAS (required — default TTS backend)

`deps/koboldcpp` is pinned to `jammm/koboldcpp jam/gfx1201-hip`. This is our fork of `LostRuins/koboldcpp` with the HIPBLAS build working on Windows + the Kokoro-on-GPU patches (see [Kokoro on the GPU (HIP)](#kokoro-on-the-gpu-hip) below for the bug-fix rundown and the fused-op work). We build `koboldcpp_hipblas.dll` for `gfx1201` by default (override with `$env:GFX_TARGET` for other AMD GPUs — `gfx1151` for Strix Halo, `gfx1151;gfx1201` for a fat binary) and stage it at `vendor/koboldcpp-rocm/` alongside `launch_kobold_rocm.py` and koboldcpp's python launcher.

```powershell
.\tools\build_koboldcpp_hip.cmd          # full build (10-15 minutes)
.\tools\build_koboldcpp_hip.cmd clean    # force reconfigure + rebuild

# Download the Kokoro GGUF weights (188 MB, Q4-quantised; Q5 / Q8 / F16
# variants at https://huggingface.co/mmwillet2/Kokoro_GGUF/tree/main)
New-Item -ItemType Directory -Force models | Out-Null
curl.exe -L -o models\Kokoro_no_espeak_Q4.gguf `
    https://huggingface.co/koboldcpp/tts/resolve/main/Kokoro_no_espeak_Q4.gguf

# Re-run the installer so it renders run_kobold.ps1:
.\installers\install_windows.ps1

# Restart services — kobold is the default now, no VOICE_TTS needed:
.\installers\stop_services.ps1; .\installers\start_services.ps1
```

What's patched in `CMakeLists.txt` (in our fork):

- Added `target_include_directories` to the four `ggml-*rocm` HIP targets — upstream only set them on the main `ggml` target, which broke `amdclang-cl` with "ggml.h: file not found" on Windows.
- Switched the rocm targets from `SHARED` to `OBJECT` libraries absorbed into the parent `ggml`/`ggml_v2`/`ggml_v3` targets. Upstream's SHARED layout creates circular symbol refs (`ggml_v2.c` calls `ggml_v2_cuda_mul_mat` in the .cu sibling and vice versa) that only resolve on Linux static linking. Merging them drops the separate `ggml-v2-legacy-rocm` target (v2 and v2-legacy .cu files coexist in `ggml-v2-rocm` now).
- Dropped `BUILD_SHARED_LIBS=ON` in the build script. With shared libs every intermediate `common2.dll`, `gpttype_adapter.dll` etc. has to resolve all its symbols at link time, but upstream relies on `gpttype_adapter.cpp` doing `#include "src/llama.cpp"` so `llama_*` symbols live only there. Static intermediates defer resolution until the final `koboldcpp_hipblas.dll` link — which works.
- `clang++.exe` (GNU driver) instead of `amdclang-cl.exe` (MSVC driver) as the CXX compiler. The clang-cl driver names HIP offload-bundler intermediates `*.exe` (MSVC conventions) and then the bundler can't find them; the GNU driver produces `*.o` like the HIP toolchain expects.
- Added every `ggml/src/ggml-cuda/template-instances/fattn-vec-instance-*.cu` to `GGML_SOURCES_CUDA`. Upstream only listed a subset explicitly, which worked because their CUDA CMake glob caught the rest; on our HIP-only path the linker failed with "undefined symbol: `ggml_cuda_flash_attn_ext_vec_case<64,1,1>`" etc.

### Kokoro on the GPU (HIP)

`VOICE_TTS=kobold` is the default. Kokoro runs on the GPU through ttscpp in our submodule (not upstream — ttscpp in `LostRuins/koboldcpp` is hardcoded `cpu_only=true` for all its TTS architectures, and `koboldcpp.py`'s `--ttsgpu` flag's tooltip even calls out "OuteTTS / Q3TTS only"). Getting Kokoro itself onto HIP took four upstream bugs and two optimisations:

**Bugs that had to be fixed before a single kernel would launch:**

1. **Tensor alignment** in `tts_model::set_tensor` / `kokoro_model::post_load_assign`. Kokoro's loader places weights with manual offset arithmetic (`tensor->data = base + offset; offset += ggml_nbytes(tensor)`) — no padding. The CUDA/HIP buffer requires 128-byte alignment per tensor, so e.g. `noise_blocks.0.resblock.0.alpha1` ended up at a device pointer ending in `0x1E` and HIP rejected the very first kernel that touched it (`MUL failed`, `ROCm error: unspecified launch failure`). Fix: round `offset` up to `ggml_backend_buft_get_alignment(buffer)` before each placement, over-allocate the buffer by `n_tensors * (alignment - 1)` so the rounding can never overflow.
2. **`reciprocal()` host-pointer trick** in `ttsutil.cpp`. Upstream set `tensor->data = &one` (a host-side `static constexpr float`) with stride 0 as a clever "ones" broadcast. Works on CPU; crashes immediately when a GPU kernel dereferences the host pointer. Rewrote as `ggml_div(x, ggml_mul(x, x))` — mathematically `1/x` for non-zero x, uses only standard ops the scheduler can place on either backend.
3. **Direct `((T*)tensor->data)[i] = …` writes** in `set_inputs()` for both `kokoro_runner` and `kokoro_duration_runner` (positions, attn_mask, uv_noise_data, duration_mask). On GPU those are device pointers. Rewrote to build CPU staging vectors + upload via `ggml_backend_tensor_set`. Same dance for `compute_window_squared_sum`, which dereferenced `model->decoder->generator->window->data` as CPU memory — window is now cached on CPU in `model->window_cpu_cache` during `post_load_assign`.
4. **Three independent HIP streams** because `kokoro_model`, `kokoro_duration_context`, and `kokoro_context` each called `ggml_backend_cuda_init(0)` separately. Their interleaving made the first `MUL` kernel error out on gfx1201. The fork keeps one shared backend instance owned by `kokoro_model` and borrows it (with `owned_backend = false`) for both kctxes so the destructor doesn't double-free.

**Optimisations on top of that:**

1. **Fused `snake_1d` megakernel** as a new `GGML_OP_SNAKE_1D` op (`ggml_snake_1d(a, alpha)`). Snake activation is `a + sin²(a*α) / α`, which `ttsutil.cpp::snake_1d` previously expanded to a 7-op subgraph (mul, sin, sqr, mul, div, mul, add). Kokoro calls snake_1d 50+ times per inference (every AdaIN res block + noise res block), so that was 350 hipLaunchKernel + 300 intermediate allocs + 300 sync points. Now one fused kernel in `ggml-cuda/snake.cu` with a matching CPU impl in `ggml-cpu.c`.
2. **CUDA kernels for the kcpp ttscpp dirtypatch ops** in `ggml-cuda/ttscpp_ops.cu`: `GGML_OP_RECIPROCAL`, `GGML_OP_TTSROUND`, `GGML_OP_MOD`, `GGML_OP_CUMSUM_TTS`. Upstream had CPU-only impls, so each call to one of these inside an otherwise-GPU graph triggered a GPU→host→GPU bounce. Kokoro fires `ggml_mod` + `ggml_cumsum_tts` on every generator block.

**Runtime knobs the shim sets:**

- `GGML_CUDA_FORCE_MMQ=1` + `--usecuda normal 0 mmq`. TheRock's rocBLAS for gfx1201 ships with an incomplete Tensile kernel set — without MMQ you get a flood of `Cannot find the function: Cijk_Alik_Bljk_HSS_BH_Bias_HA_S_SAV_UserArgs_…` on every Q4 matmul and the slow rocBLAS fallback path runs instead of MMQ's quantised kernels.
- `ROCBLAS_USE_HIPBLASLT=1`. Reroutes rocBLAS's F32 matmul path through **hipBLASLt**, which in TheRock 7.x has a *complete* `gfx1201` / `gfx1200` Tensile kernel set in `<rocm>/bin/hipblaslt/library/TensileLibrary_*_gfx1201.co`. rocBLAS on its own is missing those same variants for RDNA 4, so without this env var every F32 `mul_mat` (duration predictor, AdaIN γ/β projections, conv-via-`mul_mat`) paid the lookup-failure-then-generic-fallback cost. Turning it on gave a **~7× speedup end-to-end** on the Kokoro benchmark set (median 2.33 s → 0.35 s, poem 8.18 s → 1.19 s) and flipped HIP from ~2.5× slower than CPU to ~2.5× faster. Same env var is set in `run_lemonade.ps1.tmpl` so whisper's matmul-heavy encoder benefits too.
- `--ttsgpu`. `koboldcpp.py` maps that to `inputs.gpulayers=999`, which our patched `kokoro_from_file` reads to decide between the HIP path and the (still-functional) CPU path. Set `$env:VOICE_TTS_KOBOLD_CPU=1` before `start_services.ps1` to force the CPU path back on (A/B debugging; `speak.py` still routes to `:13308` via services.json so `stop_services` + `start_services` is sufficient).

**What's still on CPU** (minor, hence the poem still takes ~1.3 s rather than ~0.8 s):

- ggml STFT / iSTFT (`GGML_OP_STFT`, `GGML_OP_ISTFT`, `GGML_OP_AA_*`) — kcpp dirtypatch ops with no CUDA impl. Every call in the decoder moves `O(audio-length)` samples host↔device. Implementable on top of hipFFT / rocFFT (which TheRock ships); not done yet.
- `ggml_upscale_linear` and `ggml_conv_transpose_1d_tts` — two more kcpp dirtypatch ops used by the sin generator / residual blocks. Simple enough to port as CUDA kernels (the latter can probably reuse ggml's stock `GGML_OP_CONV_TRANSPOSE_1D` which already has CUDA).
- `ggml_map_custom3(uv_noise_compute)` — a CPU-only custom callback inside `build_sin_gen`. Small data, called once per generator block.

### Benchmarks (gfx1201 / RX 9070 XT)

Current default (`VOICE_TTS=kobold`, with `ROCBLAS_USE_HIPBLASLT=1`) on the same 6-prompt set (warm):

| Prompt (chars)            | Kobold HIP (default) | F5-TTS (GPU, opt-in) | Kokoro-PyTorch (exp.)     | Kobold CPU (`VOICE_TTS=cpu`) |
|---------------------------|---------------------:|---------------------:|--------------------------:|-----------------------------:|
| short (12)                | **0.10 s**           | ~0.4 s               | ~1.5 s warm / ~15 s cold  | 0.22 s                       |
| medium (52)               | **0.22 s**           | ~0.6 s               | ~0.8 s warm               | 0.49 s                       |
| long (127)                | **0.35 s**           | ~1.3 s               | ~1.5 s warm               | 0.94 s                       |
| poem (402)                | **1.30 s**           | ~2.5 s               | 14.6 s cold / ~3.2 s warm | 3.37 s                       |
| code (128)                | **0.37 s**           | ~1.2 s               | ~1.5 s warm               | 0.98 s                       |
| explain (163)             | **0.47 s**           | ~1.5 s               | ~1.7 s warm               | 1.26 s                       |
| total 6 prompts (warm)    | **2.80 s**           | ~8 s                 | ~62 s (includes warmup)   | 7.33 s                       |
| median                    | **0.37 s**           | ~0.9 s               | ~1.5 s                    | 0.98 s                       |

HIP is now the fastest backend across the board. For context, before we discovered `ROCBLAS_USE_HIPBLASLT` (which is effectively a one-env-var change to route F32 matmul through hipBLASLt's complete kernel set instead of rocBLAS's incomplete one), the same bench run was:

| Prompt | Kobold HIP (without hipBLASLt) |
|---|---:|
| short (12)  | 0.45 s |
| medium (52) | 1.15 s |
| long (127)  | 2.28 s |
| poem (402)  | 8.18 s |
| median      | 2.33 s |

i.e. **~7× slower** across the board and ~2.5× slower than CPU.

On Strix Halo (gfx1151) the same hipBLASLt switch should do the same thing — TheRock ships gfx1151 Tensile libraries too — and there the NPU will also be on the STT side (see [Deploying on Strix Halo](#deploying-on-strix-halo-gfx1151-igpu--xdna2-npu)).

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
