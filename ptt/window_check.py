"""Foreground-window gate for the PTT daemon.

Both F9 and the wake-word listener consult ``focus_passes_gate()`` before
recording. Returns True only when the focused window is hosting one of the
allowed processes (default: ``claude.exe``) — that is, ``claude.exe`` is a
descendant of the foreground window's process.

Rationale: STT that types into random windows is a footgun. Gating on Claude
Code's presence ensures transcriptions land in the terminal where Claude is
running, not the browser or Slack that happens to be focused.

Override via env:
  ``PTT_REQUIRE_APPS="claude.exe,codex.exe"`` — comma-separated allow-list.
  ``PTT_REQUIRE_APPS="any"`` — disable the gate (back to "types anywhere").
"""

from __future__ import annotations

import ctypes
import logging
import os
from ctypes import wintypes
from typing import Iterable

import psutil

log = logging.getLogger(__name__)

_DEFAULT_REQUIRED_APPS = ("claude.exe",)

_user32 = ctypes.WinDLL("user32", use_last_error=True)
_user32.GetForegroundWindow.restype = wintypes.HWND
_user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
_user32.GetWindowThreadProcessId.restype = wintypes.DWORD


def _required_apps() -> tuple[str, ...]:
    raw = os.environ.get("PTT_REQUIRE_APPS")
    if not raw:
        return _DEFAULT_REQUIRED_APPS
    return tuple(name.strip().lower() for name in raw.split(",") if name.strip())


def _gate_disabled(apps: Iterable[str]) -> bool:
    return any(a in ("*", "any", "none", "off") for a in apps)


def _foreground_pid() -> int:
    hwnd = _user32.GetForegroundWindow()
    if not hwnd:
        return 0
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return int(pid.value)


def _is_descendant_of(pid: int, ancestor_pid: int) -> bool:
    try:
        p: psutil.Process | None = psutil.Process(pid)
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return False
    try:
        while p is not None:
            if p.pid == ancestor_pid:
                return True
            p = p.parent()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass
    return False


def focus_passes_gate() -> bool:
    """Is any required app a descendant of the foreground window's process?"""
    apps = _required_apps()
    if not apps or _gate_disabled(apps):
        return True
    fg_pid = _foreground_pid()
    if fg_pid == 0:
        log.debug("focus gate: no foreground window")
        return False
    apps_set = {a.lower() for a in apps}
    for proc in psutil.process_iter(["name", "pid"]):
        name = (proc.info.get("name") or "").lower()
        if name not in apps_set:
            continue
        if _is_descendant_of(proc.pid, fg_pid):
            return True
    return False


def describe_current_focus() -> str:
    """For logging: which process owns the current foreground window?"""
    pid = _foreground_pid()
    if pid == 0:
        return "<none>"
    try:
        p = psutil.Process(pid)
        return f"{p.name()} (pid={pid})"
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return f"<pid={pid}>"
