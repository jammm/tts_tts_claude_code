"""Wrapper that registers TheRock's ROCm bin/ as a Python DLL search path
before delegating to koboldcpp.py. koboldcpp_hipblas.dll links against
amdhip64_7 / hipblas / rocblas, which live in the rocm-sdk-devel venv
site-packages tree but aren't on %PATH% or registered with
os.add_dll_directory by default. Without this shim ctypes.CDLL fails
with "Could not find module ... or one of its dependencies".

Usage:
    python launch_kobold_rocm.py --usecuda normal 0 nommq \
        --ttsmodel Kokoro_no_espeak_Q4.gguf --ttsgpu --port 13308

All CLI args pass through unchanged.
"""
from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path


def _discover_rocm_bin() -> Path | None:
    """Find rocm-sdk-devel/bin. Honor ROCM_SDK_BIN env var first, then
    walk upward looking for the usual TheRock venv layout."""
    env = os.environ.get("ROCM_SDK_BIN")
    if env and Path(env).is_dir():
        return Path(env)

    here = Path(__file__).resolve().parent
    for parent in [here, *here.parents]:
        candidate = parent / ".venv" / "Lib" / "site-packages" / "_rocm_sdk_devel" / "bin"
        if candidate.is_dir():
            return candidate
    return None


def main() -> int:
    rocm_bin = _discover_rocm_bin()
    if rocm_bin is None:
        print(
            "launch_kobold_rocm: couldn't find rocm-sdk-devel/bin; "
            "set ROCM_SDK_BIN or run from a venv with rocm-sdk-devel installed",
            file=sys.stderr,
        )
        return 2

    os.add_dll_directory(str(rocm_bin))
    os.environ["PATH"] = str(rocm_bin) + os.pathsep + os.environ.get("PATH", "")

    kobold_py = Path(__file__).resolve().parent / "koboldcpp.py"
    sys.argv = [str(kobold_py), *sys.argv[1:]]
    runpy.run_path(str(kobold_py), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
