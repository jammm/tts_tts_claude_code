"""Runtime configuration for the PTT daemon.

All paths and tunables live here so install_windows.ps1 can patch LEMONADE_URL
or TTS_LOCK_PATH without touching code.
"""

from __future__ import annotations

import os
from pathlib import Path

LEMONADE_URL = os.environ.get("LEMONADE_URL", "http://localhost:13305")
TRANSCRIBE_ENDPOINT = f"{LEMONADE_URL}/api/v1/audio/transcriptions"
WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "Whisper-Small")

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "int16"
CHUNK_SAMPLES = 1280  # 80 ms at 16 kHz — matches openwakeword's expected frame

PTT_HOTKEY = os.environ.get("PTT_HOTKEY", "f9")

WAKE_MODEL = os.environ.get("WAKE_MODEL", "hey_jarvis_v0.1")
WAKE_THRESHOLD = float(os.environ.get("WAKE_THRESHOLD", "0.5"))
WAKE_VAD_THRESHOLD = float(os.environ.get("WAKE_VAD_THRESHOLD", "0.5"))
WAKE_PREBUFFER_FRAMES = 7  # ~560 ms of audio prepended so first word isn't clipped
WAKE_COOLDOWN_SECONDS = 2.0

# End-of-utterance detection for wake-word recordings (energy-based, simple).
# The wake listener passes frames to the recorder; once EOU_SILENCE_MS of
# below-threshold audio has accrued, we stop and transcribe.
EOU_SILENCE_MS = 800
EOU_MAX_RECORDING_MS = 10_000
EOU_ENERGY_THRESHOLD = 450  # int16 RMS; tuned by ear — lower = more sensitive

# Cross-process signal: speak.py touches this file while Kokoro is playing so
# the wake listener stays quiet. Prevents Kokoro speaking "jarvis" from
# re-triggering itself.
def _default_lock_dir() -> Path:
    base = os.environ.get("LOCALAPPDATA")
    if base:
        return Path(base) / "voice-plugin"
    return Path.home() / ".voice-plugin"


TTS_LOCK_PATH = Path(os.environ.get("TTS_LOCK_PATH", str(_default_lock_dir() / "tts_active.lock")))


def tts_is_active() -> bool:
    return TTS_LOCK_PATH.exists()
