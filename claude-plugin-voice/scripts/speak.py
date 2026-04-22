#!/usr/bin/env python3
"""Speak text aloud via Kokoro on the local Lemonade server.

Two invocation modes:
  --from-hook : reads Stop hook payload from stdin (JSON) and speaks
                `last_assistant_message`. Honors `stop_hook_active` to avoid
                loops. Wired into hooks.json.
  positional  : speaks the concatenated args. Wired into /voice:speak.

While audio is playing we touch %LOCALAPPDATA%\\voice-plugin\\tts_active.lock
so the PTT daemon's wake-word listener can ignore activations (prevents Kokoro
speaking "jarvis" from re-triggering itself).
"""

from __future__ import annotations

import argparse
import io
import json
import logging
import os
import re
import sys
from contextlib import contextmanager
from pathlib import Path

import requests
import sounddevice as sd
import soundfile as sf

# TTS backend selection. Priority:
#   1. TTS_SPEECH_URL env (full URL override)
#   2. TTS_URL + TTS_SPEECH_PATH env overrides
#   3. VOICE_TTS env var
#   4. %LOCALAPPDATA%\voice-plugin\services.json's `tts_backend` field —
#      what start_services.ps1 actually launched. This matters for the
#      Stop hook in ~/.claude/settings.json: Claude Code runs speak.py
#      as a subprocess and doesn't inherit env vars from the shell that
#      ran start_services.ps1, so without this fallback speak.py always
#      thought the backend was "cpu" and hit lemond on :13305 even if
#      the user had VOICE_TTS=hip running HIP Kokoro internally.
#   5. "cpu" (lemond's built-in CPU Kokoro)
#
# Backend port mapping:
#   cpu     -> lemond built-in CPU Kokoro,        :13305/api/v1/audio/speech
#   hip     -> lemond -> kokoro-hip-server.exe,   :13305/api/v1/audio/speech
#   kokoro  -> our ROCm PyTorch Kokoro,           :13306/api/v1/audio/speech
#   f5      -> F5-TTS on GPU,                     :13307/api/v1/audio/speech
#   kobold  -> legacy alias for "hip" from pre-lemondate-split installs
#              where koboldcpp HIP Kokoro listened on :13308/v1/audio/
#              speech directly; those installs no longer exist but we
#              keep the entry in case an old services.json survived.
#
# 127.0.0.1 not localhost: Windows resolves ::1 first and the fallback
# adds ~2s per fresh connection (speak.py is a short-lived subprocess
# per Claude turn so never benefits from connection reuse).
_TTS_DEFAULTS = {
    "cpu":    ("http://127.0.0.1:13305", "/api/v1/audio/speech"),
    "hip":    ("http://127.0.0.1:13305", "/api/v1/audio/speech"),
    "kokoro": ("http://127.0.0.1:13306", "/api/v1/audio/speech"),
    "f5":     ("http://127.0.0.1:13307", "/api/v1/audio/speech"),
    "kobold": ("http://127.0.0.1:13305", "/api/v1/audio/speech"),
}


def _read_services_json_backend() -> str | None:
    """Return tts_backend from %LOCALAPPDATA%\\voice-plugin\\services.json,
    or None if the file is missing / unreadable / malformed."""
    base = os.environ.get("LOCALAPPDATA")
    if not base:
        return None
    path = Path(base) / "voice-plugin" / "services.json"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None
    backend = data.get("tts_backend")
    if isinstance(backend, str) and backend in _TTS_DEFAULTS:
        return backend
    return None


_VOICE_TTS = (
    os.environ.get("VOICE_TTS")
    or _read_services_json_backend()
    or "cpu"
).lower()
_default_url, _default_path = _TTS_DEFAULTS.get(_VOICE_TTS, _TTS_DEFAULTS["cpu"])
TTS_URL = os.environ.get("TTS_URL", _default_url)
TTS_SPEECH_PATH = os.environ.get("TTS_SPEECH_PATH", _default_path)
SPEECH_ENDPOINT = os.environ.get("TTS_SPEECH_URL", f"{TTS_URL}{TTS_SPEECH_PATH}")
KOKORO_MODEL = os.environ.get("KOKORO_MODEL", "kokoro-v1")
KOKORO_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
MAX_CHARS = int(os.environ.get("SPEAK_MAX_CHARS", "1500"))

_default_lock_base = Path(os.environ.get("LOCALAPPDATA") or Path.home())
TTS_LOCK_PATH = Path(os.environ.get("TTS_LOCK_PATH", str(_default_lock_base / "voice-plugin" / "tts_active.lock")))

log = logging.getLogger("speak")


def clean(text: str) -> str:
    """Make markdown palatable to a TTS engine."""
    if not text:
        return ""
    text = re.sub(r"```.*?```", " (code block) ", text, flags=re.S)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"!\[[^\]]*\]\([^)]+\)", " ", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "link", text)
    text = re.sub(r"^#{1,6}\s*", "", text, flags=re.M)
    text = re.sub(r"(\*\*|__)(.*?)\1", r"\2", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


@contextmanager
def tts_lock():
    """Create the lock file on enter, remove on exit. Best-effort — never
    raises if directory creation fails."""
    try:
        TTS_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
        TTS_LOCK_PATH.write_text(str(os.getpid()))
    except Exception:
        log.debug("couldn't create TTS lock at %s", TTS_LOCK_PATH, exc_info=True)
    try:
        yield
    finally:
        try:
            TTS_LOCK_PATH.unlink(missing_ok=True)
        except Exception:
            log.debug("couldn't remove TTS lock", exc_info=True)


def _read_last_assistant_from_transcript(path: str | None) -> str:
    """Parse the newline-delimited JSON transcript Claude Code writes and
    return the most recent assistant text. Best-effort — returns '' on any
    error."""
    if not path:
        return ""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except Exception:
        return ""
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "assistant":
            continue
        msg = rec.get("message") or {}
        for block in msg.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                return block.get("text") or ""
    return ""


def speak(msg: str) -> None:
    if not msg:
        return
    msg = msg[:MAX_CHARS]
    if len(msg) < 3:
        return
    r = requests.post(
        SPEECH_ENDPOINT,
        json={
            "model": KOKORO_MODEL,
            "input": msg,
            "voice": KOKORO_VOICE,
            "response_format": "wav",
        },
        timeout=120,
    )
    r.raise_for_status()
    data, sr = sf.read(io.BytesIO(r.content))
    with tts_lock():
        sd.play(data, sr)
        sd.wait()


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.WARNING)
    parser = argparse.ArgumentParser(description="Speak via Kokoro")
    parser.add_argument("--from-hook", action="store_true")
    parser.add_argument("text", nargs="*")
    args = parser.parse_args(argv)

    if args.from_hook:
        # Claude Code pipes the Stop hook payload as UTF-8 JSON on stdin.
        # On Windows, sys.stdin defaults to the console codepage (usually
        # cp1252), which mis-decodes em-dash bytes e2 80 94 into "â€" —
        # the middle byte e2 82 ac is the EURO SIGN, which Kokoro's
        # REPLACEABLE map pronounces "jˈʊɹɹoʊz" ("euros"). Read raw
        # bytes and decode as UTF-8 to preserve what Claude actually
        # sent.
        raw_bytes = sys.stdin.buffer.read()
        try:
            raw = raw_bytes.decode("utf-8")
        except UnicodeDecodeError:
            # Some non-UTF-8 hook payload got through. Fall back to the
            # default decoder but replace undecodable bytes rather than
            # crash.
            raw = raw_bytes.decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw or "{}")
        except Exception:
            log.exception("invalid hook payload")
            payload = {}
        # Audit trail for debugging. Grows forever if enabled; gate with env.
        audit = os.environ.get("SPEAK_AUDIT_LOG")
        if audit:
            try:
                with open(audit, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"payload_keys": list(payload.keys()), "raw_len": len(raw)}) + "\n")
            except Exception:
                pass
        if payload.get("stop_hook_active"):
            return 0
        text = payload.get("last_assistant_message") or ""
        if not text:
            # Fallback: tail the transcript at transcript_path for the last
            # assistant turn. Some Claude Code code paths omit
            # last_assistant_message from headless mode payloads.
            text = _read_last_assistant_from_transcript(payload.get("transcript_path"))
        speak(clean(text))
        return 0

    joined = " ".join(args.text).strip()
    if not joined:
        return 0
    speak(clean(joined))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        sys.stderr.write(f"[voice] {exc}\n")
        sys.exit(0)
