"""Wake-word listener thread.

Runs openwakeword ("hey jarvis") over a dedicated 16 kHz mono sounddevice
stream. On detection, invokes a callback with ~560 ms of pre-roll audio so the
first word of the utterance isn't clipped.

Also owns end-of-utterance detection for the wake path: while a recording is
active, frames are pushed into the Recorder and energy-based silence detection
determines when to stop.
"""

from __future__ import annotations

import collections
import logging
import threading
import time

import numpy as np
import sounddevice as sd
from openwakeword.model import Model

from . import config
from .window_check import describe_current_focus, focus_passes_gate

log = logging.getLogger(__name__)


class WakeListener:
    def __init__(self, recorder, stop_event: threading.Event):
        self.recorder = recorder
        self.stop_event = stop_event
        self._thread: threading.Thread | None = None
        self._last_fire = 0.0

    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, name="wake-listener", daemon=True)
        self._thread.start()

    def join(self, timeout: float | None = None) -> None:
        if self._thread is not None:
            self._thread.join(timeout)

    def _run(self) -> None:
        try:
            model = Model(
                wakeword_models=[config.WAKE_MODEL],
                vad_threshold=config.WAKE_VAD_THRESHOLD,
            )
        except Exception:
            log.exception("Failed to load wake-word model %r", config.WAKE_MODEL)
            return

        prebuffer: collections.deque[np.ndarray] = collections.deque(maxlen=config.WAKE_PREBUFFER_FRAMES)
        log.info("Wake listener ready (model=%s, threshold=%.2f)", config.WAKE_MODEL, config.WAKE_THRESHOLD)

        try:
            with sd.InputStream(
                samplerate=config.SAMPLE_RATE,
                channels=config.CHANNELS,
                dtype=config.DTYPE,
                blocksize=config.CHUNK_SAMPLES,
            ) as stream:
                while not self.stop_event.is_set():
                    frame, overflowed = stream.read(config.CHUNK_SAMPLES)
                    if overflowed:
                        log.debug("wake stream overflow")
                    frame = frame.flatten()

                    if self.recorder.is_recording():
                        self.recorder.feed(frame)
                        continue

                    prebuffer.append(frame)

                    if config.tts_is_active():
                        continue

                    if (time.monotonic() - self._last_fire) < config.WAKE_COOLDOWN_SECONDS:
                        continue

                    try:
                        scores = model.predict(frame)
                    except Exception:
                        log.exception("wake predict failed")
                        continue

                    score = scores.get(config.WAKE_MODEL, 0.0)
                    if score >= 0.1 and score < config.WAKE_THRESHOLD:
                        log.info("wake candidate (score=%.3f, below %.2f threshold)",
                                 score, config.WAKE_THRESHOLD)
                    if score >= config.WAKE_THRESHOLD:
                        # Only pay the process-iteration cost when we're
                        # actually about to fire.
                        if not focus_passes_gate():
                            log.info("wake suppressed: focus is %s (score=%.3f)",
                                     describe_current_focus(), score)
                            model.reset()
                            continue
                        self._last_fire = time.monotonic()
                        log.info("wake fired (score=%.3f)", score)
                        pre_audio = np.concatenate(list(prebuffer)) if prebuffer else None
                        self.recorder.start(source="wake", prebuffer=pre_audio, vad_endpoint=True)
                        model.reset()
                        prebuffer.clear()
        except Exception:
            log.exception("Wake listener crashed")
