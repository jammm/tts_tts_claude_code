"""Persistent Kokoro TTS service running on the AMD GPU (ROCm/HIP).

Loads ``hexgrad/Kokoro-82M`` onto the first ``torch.cuda`` device at startup
(first call JIT-compiles ~15 s of MIOpen kernels; we pre-warm to amortize).
Exposes an OpenAI-compatible ``POST /api/v1/audio/speech`` endpoint, plus a
``GET /api/v1/health`` probe.

Drop-in for the Lemonade CPU Kokoro backend — ``speak.py`` just points at
``http://localhost:13306`` instead of Lemonade's ``13305``.

Env overrides:
    KOKORO_PORT   default 13306
    KOKORO_LANG   default "a" (American English)
    KOKORO_VOICE  default "af_heart"
    KOKORO_DEVICE default "cuda" (set "cpu" to bypass the GPU)
"""

from __future__ import annotations

import contextlib
import io
import logging
import os
import queue
import threading
import time
from concurrent.futures import Future

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

# Silence MIOpen's "workspace=0" warnings during JIT; they're informational.
os.environ.setdefault("MIOPEN_LOG_LEVEL", "0")

from kokoro import KPipeline  # noqa: E402 (after env var)

# Keep cuDNN/MIOpen enabled — the aten LSTM fallback produces numerically
# degraded audio on ROCm 7.2 (tinnitus-like high-frequency artifacts at
# utterance starts, raspy timbre on voiced sustain). MIOpen's LSTM path is
# slightly slower but preserves the model's original precision.
# Set KOKORO_DISABLE_CUDNN=1 if you want to experiment.
if os.environ.get("KOKORO_DISABLE_CUDNN", "0") == "1":
    torch.backends.cudnn.enabled = False

# Use full float32 for matmul (default is "highest"; confirm explicitly to
# defeat any global config that would downgrade precision for RNN-adjacent
# operations).
torch.set_float32_matmul_precision("highest")

log = logging.getLogger("kokoro_server")

PORT = int(os.environ.get("KOKORO_PORT", "13306"))
LANG_CODE = os.environ.get("KOKORO_LANG", "a")
DEFAULT_VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
DEVICE = os.environ.get("KOKORO_DEVICE", "cuda")
SAMPLE_RATE = 24_000
# hexgrad/Kokoro-82M peaks at ~0.19 for normal speech; Lemonade's Kokoros
# ONNX export peaks at ~0.48 for the same text. Match that with a peak
# normalize so the user doesn't need to crank the volume to compare.
TARGET_PEAK = float(os.environ.get("KOKORO_TARGET_PEAK", "0.5"))


class SpeechRequest(BaseModel):
    """Mirrors OpenAI's /audio/speech body so existing clients (Lemonade's
    callers, our speak.py) work unchanged."""

    model: str | None = None
    input: str
    voice: str = DEFAULT_VOICE
    response_format: str = "wav"
    speed: float = 1.0


_COMPILE_WARMUP_TEXTS = (
    # Short / medium / long representative shapes. Triton compiles a kernel
    # per distinct seq length on first call; running each here pre-caches the
    # kernels so real user requests find warm compiled code.
    "Hello.",
    "The quick brown fox jumps over the lazy dog.",
    "Ask not what your country can do for you; ask what you can do for your country.",
    "On the forty-third attempt, something shifted: it stopped measuring and started watching, "
    "letting the color and smell guide its servos rather than its algorithms.",
)


class KokoroService:
    def __init__(self) -> None:
        device = DEVICE
        if device == "cuda" and not torch.cuda.is_available():
            log.warning("CUDA/HIP not available; falling back to CPU")
            device = "cpu"
        self._device = device
        device_name = (
            torch.cuda.get_device_name(0) if device == "cuda" else "CPU"
        )
        log.info("Loading Kokoro on %s (lang=%s)", device_name, LANG_CODE)
        t0 = time.monotonic()
        self._pipeline = KPipeline(lang_code=LANG_CODE, device=device)
        log.info("Kokoro load: %.1f s", time.monotonic() - t0)
        self._lock = threading.Lock()

        # torch.compile is off by default. On ROCm 7.2 with gfx1201, the
        # reduce-overhead CUDA-graph path produces audibly broken output:
        # tinnitus-like high-frequency hiss at utterance starts and a
        # hoarse/raspy timbre on sustained voiced content. Eager mode
        # preserves the model's native precision. Opt into compile via
        # KOKORO_COMPILE=1 if you want to experiment (quality will suffer).
        if device == "cuda" and os.environ.get("KOKORO_COMPILE", "0") == "1":
            log.info("torch.compile(dynamic=True, mode=reduce-overhead) on KModel.forward...")
            try:
                self._pipeline.model.forward = torch.compile(
                    self._pipeline.model.forward,
                    dynamic=True,
                    mode="reduce-overhead",
                    fullgraph=False,
                )
            except Exception:
                log.exception("torch.compile failed; falling back to eager")

        # Single-threaded inference worker so torch.compile's CUDA graphs
        # stay valid. FastAPI's threadpool would otherwise invalidate them
        # on every thread hop.
        self._job_queue: queue.Queue[tuple[str, str, Future]] = queue.Queue()
        self._worker = threading.Thread(
            target=self._worker_loop, name="kokoro-worker", daemon=True
        )
        self._worker.start()
        self._warm()

    @property
    def device(self) -> str:
        return self._device

    def _warm(self) -> None:
        """On GPU, Triton compiles kernels per sequence-length shape on first
        call. Run a range of lengths at startup so client requests see warm
        compiled code rather than the multi-second compile path."""
        for text in _COMPILE_WARMUP_TEXTS:
            t0 = time.monotonic()
            try:
                self.synthesize(text, voice=DEFAULT_VOICE)
                log.info("warmup %.0f ms : %s", (time.monotonic() - t0) * 1000, text[:40])
            except Exception:
                log.exception("warmup failed (server will still start)")
                break

    def _worker_loop(self) -> None:
        """Consume (text, voice, future) jobs from the queue, run the
        Kokoro pipeline on this thread, set the future's result.

        Pinning inference to this thread keeps torch.compile's cached
        CUDA graphs valid across requests.
        """
        while True:
            text, voice, fut = self._job_queue.get()
            try:
                t0 = time.monotonic()
                wav = self._synthesize_on_worker(text, voice)
                dt = (time.monotonic() - t0) * 1000
                log.info("synth %.0f ms (%d chars -> %d wav bytes)",
                         dt, len(text), len(wav))
                fut.set_result(wav)
            except BaseException as exc:  # propagate to the caller
                fut.set_exception(exc)

    def _synthesize_on_worker(self, text: str, voice: str) -> bytes:
        if not text.strip():
            return b""
        gen = self._pipeline(text, voice=voice)
        chunks: list[np.ndarray] = []
        for _gs, _ps, audio in gen:
            if audio is None:
                continue
            if isinstance(audio, torch.Tensor):
                audio = audio.detach().cpu().numpy()
            chunks.append(np.asarray(audio, dtype=np.float32))
        if not chunks:
            return b""
        joined = np.concatenate(chunks)
        # Peak-normalize so clients don't have to crank the volume. The
        # raw PyTorch checkpoint outputs ~2.5x quieter than Lemonade's
        # Kokoros ONNX export for the same text.
        peak = float(np.max(np.abs(joined)))
        if TARGET_PEAK > 0 and peak > 0:
            joined = joined * (TARGET_PEAK / peak)
        buf = io.BytesIO()
        sf.write(buf, joined, SAMPLE_RATE, subtype="PCM_16", format="WAV")
        return buf.getvalue()

    def synthesize(self, text: str, *, voice: str) -> bytes:
        fut: Future[bytes] = Future()
        self._job_queue.put((text, voice, fut))
        return fut.result()


@contextlib.asynccontextmanager
async def _lifespan(_app: FastAPI):
    global service
    service = KokoroService()
    yield
    # No teardown — process exit reclaims VRAM


app = FastAPI(title="Voice Plugin Kokoro Server (ROCm)", lifespan=_lifespan)
service: KokoroService | None = None


@app.get("/api/v1/health")
def health():
    if service is None:
        return {"status": "loading"}
    return {
        "status": "ok",
        "model": "kokoro-v1",
        "device": service.device,
        "port": PORT,
    }


@app.post("/api/v1/audio/speech")
def audio_speech(req: SpeechRequest):
    if service is None:
        raise HTTPException(status_code=503, detail="Model still loading")
    wav = service.synthesize(req.input, voice=req.voice)
    if not wav:
        raise HTTPException(status_code=400, detail="Empty input")
    return Response(content=wav, media_type="audio/wav")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")


if __name__ == "__main__":
    main()
