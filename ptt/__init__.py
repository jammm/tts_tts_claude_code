"""Voice PTT + wake-word daemon for Claude Code on Windows.

Two activation paths, one pipeline:
  F9 (hold-to-talk, pynput)         -> Recorder.start/stop
  "hey jarvis" (openwakeword thread) -> Recorder.start/stop (silence endpoint)

Both routes POST the captured WAV to Lemonade's /api/v1/audio/transcriptions
endpoint (Whisper-Small) and pyautogui.typewrite the result into the focused
window.
"""
