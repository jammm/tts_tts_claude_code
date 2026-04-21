# Local Voice I/O Plugin for Claude Code — Strix Halo + Navi 4, Linux + Windows

> **Status:** Plan only — no code written yet.
> **Targets:** Linux (Ubuntu 24.04+) and Windows 11 on AMD GPUs: Strix Halo (Ryzen AI Max+ 395, gfx1151) **and** Navi 4 (RX 9070 XT, gfx1201).
> **Today:** 2026-04-20.

## 1. Context

Claude Code is a terminal app. We want hands-free use:

- **TTS:** every Claude response is spoken aloud automatically. A `/speak` slash command additionally reads arbitrary text on demand.
- **STT:** push-to-talk hotkey. Hold a key, speak, release — the transcription is typed into the terminal at the cursor.
- **All inference is local** on the AMD GPU using open-source models. No cloud.

The plugin must work on two GPU families and two operating systems. The single design choice that makes this tractable: install everything via `pip` into a single Python virtualenv per machine.

- **`lemonade-sdk`** (pure-Python wheel on PyPI, with optional extras) drives inference. Its native bundled binaries — llama.cpp, whisper.cpp, koko — are gfx-targeted builds from [`lemonade-sdk/llamacpp-rocm` releases](https://github.com/lemonade-sdk/llamacpp-rocm) for gfx1151 and gfx120X.
- **TheRock PyTorch wheels** provide the ROCm runtime where Lemonade's bundled binaries don't cover (and as a fallback if we ever need to run something outside Lemonade). Strix Halo: `https://rocm.nightlies.amd.com/v2/gfx1151/`. Navi 4: `https://therock-nightly-python.s3.us-east-2.amazonaws.com/gfx120X-all/index.html`.
- If the `lemonade-sdk` pip install ever fails for a target, the build-from-source fallback (`git clone`, `pip install -e .`) is documented in §4.1.

One TTS model, one STT model, one inference server, one venv. No fallbacks at runtime.

## 2. Final stack

| Role | Component |
|---|---|
| Inference server (TTS + STT) | **AMD Lemonade Server** |
| TTS model | **Kokoro** (`kokoro-v1` via Lemonade) |
| STT model | **Whisper-Small** (`whisper-server` backend in Lemonade) |
| PTT daemon | Python: `pynput` + `sounddevice` + `pyautogui` + `requests` + `soundfile` |
| Process supervision | `systemd --user` (Linux) / Task Scheduler at logon (Windows) |
| Claude Code integration | Plugin: `Stop` hook (auto-TTS) + `/speak` slash command |

### Architecture

```
                ┌──────────────────────────────────────────────┐
                │         AMD GPU (gfx1151 or gfx1201)         │
                │                                              │
  hold F9 ──► PTT daemon ──► POST /api/v1/audio/transcriptions │
                │              (Lemonade :13305, Whisper)      │
                │                       │                      │
   pyautogui types text ◄──── transcription                    │
                │                                              │
   user submits prompt to Claude Code                          │
                │                                              │
   Claude responds → Stop hook fires                           │
                │                                              │
                └──► POST /api/v1/audio/speech (Kokoro) ──► sounddevice
```

## 3. Hardware / OS prerequisites

### 3.1 Linux (both GPUs)

- Ubuntu **24.04.4 HWE** or newer; kernel **≥ 6.18.4** for Strix Halo, **≥ 6.14** for Navi 4. Avoid `linux-firmware-20251125` on Strix Halo (breaks ROCm).
- GRUB on Strix Halo only: `amd_iommu=on iommu=pt amdgpu.gttsize=65536 ttm.pages_limit=16777216`
- `swapoff -a` on Strix Halo.
- Env vars (Strix Halo only): `HSA_ENABLE_SDMA=0`, `HSA_USE_SVM=0`, `ROCBLAS_USE_HIPBLASLT=1`, `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1`.
- **Python 3.12** (3.13 breaks TheRock wheel deps; 3.10/3.11 OK for `lemonade-sdk` but 3.12 is the common denominator).
- **No system ROCm install needed** — TheRock pip wheels ship the runtime.

### 3.2 Windows 11 (both GPUs)

- AMD Adrenalin driver **25.10+**.
- **Python 3.12** (matches scottt/rocm-TheRock Windows wheels).
- **No HIP SDK install needed** — TheRock wheels ship the runtime; Lemonade bundles its own llama.cpp/whisper.cpp/koko.
- Audio: WASAPI default device (handled automatically by `sounddevice`).

## 4. Component install

### 4.1 Single venv with Lemonade + TheRock PyTorch

One venv per machine holds Lemonade, TheRock PyTorch (for the GPU runtime), and the PTT daemon's pure-Python deps. This makes both Linux and Windows installs identical at the pip-command level.

**Linux + Strix Halo:**
```bash
sudo apt install python3.12 python3.12-venv
python3.12 -m venv ~/venvs/voice && source ~/venvs/voice/bin/activate
pip install --upgrade pip
pip install --pre torch torchvision torchaudio \
  --index-url https://rocm.nightlies.amd.com/v2/gfx1151/
pip install lemonade-sdk
pip install pynput sounddevice numpy requests pyautogui soundfile
```

**Linux + Navi 4 (gfx1201):** swap the torch index URL:
```bash
pip install --pre torch torchvision torchaudio \
  --find-links https://therock-nightly-python.s3.us-east-2.amazonaws.com/gfx120X-all/index.html
```

**Windows (both GPUs):**
```powershell
py -3.12 -m venv $env:USERPROFILE\venvs\voice
$env:USERPROFILE\venvs\voice\Scripts\Activate.ps1
pip install --upgrade pip
# scottt/rocm-TheRock ships Windows wheels for gfx1151 AND gfx1201
pip install <wheel-url-from-https://github.com/scottt/rocm-TheRock/releases/tag/v6.5.0rc-pytorch-gfx110x>
pip install lemonade-sdk
pip install pynput sounddevice numpy requests pyautogui soundfile
```

**Build-from-source fallback** (if `pip install lemonade-sdk` ever fails for a target — e.g., a Python-version mismatch with a future release):
```bash
git clone https://github.com/lemonade-sdk/lemonade.git ~/src/lemonade
cd ~/src/lemonade && pip install -e .
```
Lemonade's Python layer is pure Python; its native binaries (llama-server, whisper-server, koko) are downloaded at runtime from [`lemonade-sdk/llamacpp-rocm` releases](https://github.com/lemonade-sdk/llamacpp-rocm) for the detected gfx target. No CMake build is needed for the typical install path.

**Pull models and start the server (any OS):**
```bash
lemonade pull kokoro-v1
lemonade pull Whisper-Small
lemonade serve              # default port 13305
```

Smoke test:
```bash
curl http://localhost:13305/api/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"kokoro-v1\",\"input\":\"Hello\",\"voice\":\"af_heart\",\"response_format\":\"wav\"}" \
  --output hello.wav
curl http://localhost:13305/api/v1/audio/transcriptions \
  -F file=@hello.wav -F model=Whisper-Small
```

> Whisper backend is **WAV-only**. PTT daemon must encode WAV.

### 4.2 PTT daemon

Single Python file (~120 lines), pure-pip dependencies: `pynput`, `sounddevice`, `numpy`, `requests`, `pyautogui`, `soundfile`.

`~/.config/voice-plugin/ptt_daemon.py` (Linux) or `%LOCALAPPDATA%\voice-plugin\ptt_daemon.py` (Windows).

Behavior:

1. `pynput.keyboard.Listener` watches **F9 keydown/keyup** globally. Raw Listener (not `GlobalHotKeys`) for true press-and-hold.
2. On keydown: open default mic via `sounddevice.InputStream` at 16 kHz mono, append frames to a list. Soft start chime.
3. On keyup: stop stream, encode buffer to WAV in-memory (`soundfile.write` to a `BytesIO`), POST to `http://localhost:13305/api/v1/audio/transcriptions`. End chime.
4. On 200 OK: `pyautogui.typewrite(text, interval=0.005)` — types into the focused window.

**Linux requirement:** X11 session. Wayland blocks global hotkeys (`pynput` only sees Xwayland apps). Document this as a hard requirement; users on Wayland switch to an X11 session at login.

### 4.3 Service supervision

Both services run from the same venv created in §4.1.

**Linux** — two user systemd units in `~/.config/systemd/user/`:
- `lemonade.service`: `ExecStart=%h/venvs/voice/bin/lemonade serve`, includes Strix Halo env block where applicable.
- `ptt-daemon.service`: `ExecStart=%h/venvs/voice/bin/python %h/.config/voice-plugin/ptt_daemon.py`

`systemctl --user enable --now lemonade ptt-daemon`

**Windows** — two Task Scheduler entries created by `install.ps1`:
- Trigger: at user logon
- Action: `%USERPROFILE%\venvs\voice\Scripts\lemonade.exe serve` and `%USERPROFILE%\venvs\voice\Scripts\python.exe ptt_daemon.py`
- Run with normal user privileges, hidden window.

## 5. Claude Code plugin

### 5.1 Layout (identical on all platforms)

```
~/.claude/plugins/voice/                  (Linux/macOS)
%USERPROFILE%\.claude\plugins\voice\      (Windows)
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json
├── commands/
│   └── speak.md
└── scripts/
    ├── speak.py
    ├── run_python.sh        # Linux/macOS launcher
    └── run_python.cmd       # Windows launcher
```

### 5.2 `plugin.json`

```json
{
  "name": "voice",
  "version": "0.1.0",
  "description": "Local TTS for Claude responses + /speak slash command. Pairs with the host PTT daemon for STT.",
  "author": { "name": "you" },
  "hooks": "./hooks/hooks.json",
  "commands": "./commands"
}
```

### 5.3 `hooks/hooks.json`

```json
{
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        { "type": "command",
          "command": "${CLAUDE_PLUGIN_DIR}/scripts/run_python.sh ${CLAUDE_PLUGIN_DIR}/scripts/speak.py --from-hook" }
      ]
    }
  ]
}
```

The `.sh` launcher delegates to the `.cmd` launcher on Windows via the appropriate Claude Code path resolution. (Or ship two `hooks.json` variants and pick at install time — simpler but less elegant.)

### 5.4 `scripts/speak.py`

Same script handles both the Stop hook and the `/speak` slash command:

```python
#!/usr/bin/env python3
import json, sys, re, io, argparse, requests, sounddevice as sd, soundfile as sf

LEMONADE = "http://localhost:13305/api/v1/audio/speech"

def clean(text: str) -> str:
    text = re.sub(r"```.*?```", " (code block) ", text, flags=re.S)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"https?://\S+", "link", text)
    return text.strip()

def speak(msg: str):
    if len(msg) < 3:
        return
    r = requests.post(LEMONADE, json={
        "model": "kokoro-v1", "input": msg,
        "voice": "af_heart", "response_format": "wav",
    }, timeout=60)
    r.raise_for_status()
    data, sr = sf.read(io.BytesIO(r.content))
    sd.play(data, sr); sd.wait()

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--from-hook", action="store_true")
    p.add_argument("text", nargs="*")
    args = p.parse_args()
    if args.from_hook:
        payload = json.loads(sys.stdin.read())
        speak(clean(payload.get("last_assistant_message", "")))
    else:
        speak(clean(" ".join(args.text)))

if __name__ == "__main__":
    try: main()
    except Exception as e: sys.stderr.write(f"[voice] {e}\n")
    sys.exit(0)              # never block Claude
```

### 5.5 `commands/speak.md`

```markdown
---
description: Speak text aloud using Kokoro.
allowed-tools: Bash(python:*), Bash(python3:*)
---

Run: `python ${CLAUDE_PLUGIN_DIR}/scripts/speak.py "$ARGUMENTS"`
```

### 5.6 Permissions (`~/.claude/settings.json`)

```json
{
  "permissions": {
    "allow": [
      "Bash(python ${CLAUDE_PLUGIN_DIR}/scripts/*)",
      "Bash(python3 ${CLAUDE_PLUGIN_DIR}/scripts/*)"
    ]
  }
}
```

## 6. Critical files this plan will create

| Path (Linux / Windows) | Purpose |
|---|---|
| `~/.config/voice-plugin/ptt_daemon.py` / `%LOCALAPPDATA%\voice-plugin\ptt_daemon.py` | PTT capture + transcribe + type |
| `~/.config/systemd/user/{lemonade,ptt-daemon}.service` | Linux service wrappers |
| `installers/windows/*.xml` | Task Scheduler entries |
| `~/.claude/plugins/voice/.claude-plugin/plugin.json` | Plugin manifest |
| `~/.claude/plugins/voice/hooks/hooks.json` | Stop hook declaration |
| `~/.claude/plugins/voice/commands/speak.md` | `/speak` slash command |
| `~/.claude/plugins/voice/scripts/{speak.py,run_python.sh,run_python.cmd}` | Hook + slash command implementation |
| `~/.claude/settings.json` | Permission allowlist |
| `installers/{install_linux.sh, install_windows.ps1}` | One-shot bootstrap per OS |

Total new code: ~250 lines Python, ~50 lines JSON/markdown, ~120 lines installer shell/PowerShell.

## 7. Verification

Run on each target (Linux/Strix, Linux/Navi4, Win/Strix, Win/Navi4):

1. `lemonade backends` lists `koko` and `whisper-server` in "ready" status.
2. `rocminfo` (Linux) / `hipinfo` (Windows) reports the expected gfx target.
3. Kokoro round-trip: `curl … /audio/speech` returns playable WAV in <1s; GPU util visible (`rocm-smi`).
4. Whisper round-trip: feed Kokoro WAV back to `/audio/transcriptions`, recover original text within ~5% WER.
5. PTT daemon: hold F9, say "list files in current directory", release — text appears at the terminal cursor in <1.5s after release.
6. Stop hook: `claude -p "say hi in five words"` triggers Kokoro playback after the response completes.
7. `/voice:speak Hello world` plays back via Kokoro.
8. Killing `lemonade` mid-conversation logs an error to stderr but does not block Claude.

## 8. Hard requirements / known issues

These are not "risks with fallbacks" — they are conditions to meet before the plugin works:

- **Linux desktop must be X11**, not Wayland. `pynput` global hotkeys don't work under Wayland.
- **Strix Halo Linux:** kernel ≥ 6.18.4, swap off, env vars set per §3.1.
- **gfx1201 ROCm 7.1.1 HSA hang** ([ROCm issue #5812](https://github.com/ROCm/ROCm/issues/5812)) — Lemonade's bundled runtime sidesteps this. Don't run a system Ollama on the same box concurrently.
- **Windows Lemonade ≥ 9.4.1** for streaming Kokoro — verify after install.
- **Markdown→speech sounds bad without filtering** — `clean()` in `speak.py` is intentionally aggressive. Tune to taste.
- **PTT daemon types into the focused window** — alt-tabbing mid-recording sends transcription elsewhere. By design for v1.

## 9. Out of scope (deliberately, for v1)

- Wake-word activation.
- Multi-language (English only).
- Voice cloning / premium TTS tier.
- Streaming TTS sentence-by-sentence as Claude writes.
- TTS barge-in (interrupting playback when PTT starts).
- macOS support.
- Marketplace distribution.

## 10. Sources

- [AMD Lemonade Server spec](https://lemonade-server.ai/docs/server/server_spec/)
- [`lemonade-sdk/lemonade` source (build-from-source fallback)](https://github.com/lemonade-sdk/lemonade)
- [`lemonade-sdk` on PyPI (migration from `turnkeyml`)](https://pypi.org/project/turnkeyml/)
- [`lemonade-sdk/llamacpp-rocm` (gfx1151 + gfx120X bundled ROCm 7 binaries)](https://github.com/lemonade-sdk/llamacpp-rocm)
- [TheRock PyTorch nightlies — gfx1151 (Strix Halo, Linux)](https://rocm.nightlies.amd.com/v2/gfx1151/)
- [TheRock PyTorch nightlies — gfx120X (Navi 4, Linux)](https://therock-nightly-python.s3.us-east-2.amazonaws.com/gfx120X-all/index.html)
- [`scottt/rocm-TheRock` Windows wheels (gfx1151 + gfx1201)](https://github.com/scottt/rocm-TheRock/releases/tag/v6.5.0rc-pytorch-gfx110x)
- [Strix Halo + Lemonade install (netstatz)](https://netstatz.com/strix_halo_lemonade/)
- [pynput cross-platform docs](https://pynput.readthedocs.io/en/latest/keyboard.html)
- [ROCm gfx1201 HSA hang issue](https://github.com/ROCm/ROCm/issues/5812)
