"""Shared Recorder: accepts frames from either F9 PTT or wake-word path,
encodes to WAV, POSTs to Lemonade /audio/transcriptions, types the result.

One mutex guards state so the two activation paths can't collide.
"""

from __future__ import annotations

import io
import logging
import threading
import time

import numpy as np
import pyautogui
import requests
import soundfile as sf

from . import config
from .window_check import describe_current_focus, focus_passes_gate

log = logging.getLogger(__name__)


class Recorder:
    """Thread-safe recorder driven by external frame sources.

    F9 path:   start(source="ptt"), feed(frame)*, stop()
    Wake path: start(source="wake", prebuffer=..., vad_endpoint=True), feed(frame)*
               -> auto-stops on silence (energy VAD) or EOU_MAX_RECORDING_MS
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._recording = False
        self._source: str | None = None
        self._buffer: list[np.ndarray] = []
        self._started_at = 0.0
        self._last_voice_at = 0.0
        self._vad_endpoint = False

    def is_recording(self) -> bool:
        return self._recording

    def start(
        self,
        *,
        source: str,
        prebuffer: np.ndarray | None = None,
        vad_endpoint: bool = False,
    ) -> bool:
        with self._lock:
            if self._recording:
                log.debug("start ignored, already recording from %s", self._source)
                return False
            self._recording = True
            self._source = source
            self._buffer = []
            if prebuffer is not None and prebuffer.size > 0:
                self._buffer.append(prebuffer.astype(np.int16, copy=False))
            self._started_at = time.monotonic()
            self._last_voice_at = self._started_at
            self._vad_endpoint = vad_endpoint
            log.info("recording started (source=%s, vad=%s)", source, vad_endpoint)
            return True

    def feed(self, frame: np.ndarray) -> None:
        """Append a frame. Triggers auto-stop for wake-word path when silence
        has persisted past EOU_SILENCE_MS or the total duration exceeds
        EOU_MAX_RECORDING_MS."""
        with self._lock:
            if not self._recording:
                return
            self._buffer.append(frame.astype(np.int16, copy=False))

            if self._vad_endpoint:
                rms = _rms_int16(frame)
                now = time.monotonic()
                if rms >= config.EOU_ENERGY_THRESHOLD:
                    self._last_voice_at = now
                silence_ms = (now - self._last_voice_at) * 1000
                total_ms = (now - self._started_at) * 1000
                if silence_ms >= config.EOU_SILENCE_MS or total_ms >= config.EOU_MAX_RECORDING_MS:
                    log.info(
                        "VAD endpoint (silence=%.0fms, total=%.0fms)",
                        silence_ms,
                        total_ms,
                    )
                    threading.Thread(
                        target=self._finish_locked_release,
                        name="recorder-finish",
                        daemon=True,
                    ).start()

    def _finish_locked_release(self) -> None:
        # Drop the lock before calling stop() to avoid nested-acquire.
        self.stop()

    def stop(self) -> None:
        with self._lock:
            if not self._recording:
                return
            buf = self._buffer
            self._buffer = []
            self._recording = False
            source = self._source
            self._source = None
            self._vad_endpoint = False
        if not buf:
            log.info("recording stopped (source=%s, empty buffer)", source)
            return
        audio = np.concatenate(buf).astype(np.int16, copy=False)
        duration_ms = (audio.size / config.SAMPLE_RATE) * 1000
        log.info(
            "recording stopped (source=%s, samples=%d, %.0f ms)",
            source,
            audio.size,
            duration_ms,
        )
        if duration_ms < 300:
            log.info("skipping transcribe, clip too short")
            return
        try:
            text = _transcribe(audio)
        except Exception:
            log.exception("transcribe failed")
            return
        text = (text or "").strip()
        if not text:
            log.info("empty transcription, nothing to type")
            return
        if not focus_passes_gate():
            # Guard against focus drifting during Whisper's RTT (~100-300 ms).
            # Better to drop the transcript than type it into a random app.
            log.info("dropping transcript, focus shifted to %s: %r",
                     describe_current_focus(), text)
            return
        log.info("typing: %r", text)
        try:
            pyautogui.typewrite(text + " ", interval=0.005)
        except Exception:
            log.exception("typewrite failed")


def _rms_int16(frame: np.ndarray) -> float:
    if frame.size == 0:
        return 0.0
    x = frame.astype(np.float32)
    return float(np.sqrt(np.mean(x * x)))


def _transcribe(audio: np.ndarray) -> str:
    buf = io.BytesIO()
    sf.write(buf, audio, config.SAMPLE_RATE, subtype="PCM_16", format="WAV")
    buf.seek(0)
    t0 = time.monotonic()
    r = requests.post(
        config.TRANSCRIBE_ENDPOINT,
        files={"file": ("clip.wav", buf, "audio/wav")},
        data={"model": config.WHISPER_MODEL},
        timeout=60,
    )
    r.raise_for_status()
    latency_ms = (time.monotonic() - t0) * 1000
    payload = r.json()
    text = payload.get("text", "")
    log.info("whisper: %.0f ms -> %r", latency_ms, text)
    return text
