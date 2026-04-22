#!/usr/bin/env python3
"""Scan Kokoro_no_espeak_Q4.gguf for phonemizer dictionary entries whose
keys match an argv word and dump the corresponding value strings.

Why: the phonemizer dict is embedded as two parallel string arrays in
the gguf metadata (phonemizer.dictionary.{keys,values}). The file
format uses LEN-prefixed UTF-8 strings, so any entry containing an
ASCII word can be fished out with a byte scan. Not a full gguf parser,
but good enough to answer "what's in the dict for 'responses'?".
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def scan(path: Path, needles: list[str]) -> None:
    data = path.read_bytes()
    for needle in needles:
        nbytes = needle.encode("utf-8")
        i = 0
        print(f"\n=== {needle!r} (len={len(nbytes)}) ===")
        hits = 0
        while True:
            i = data.find(nbytes, i)
            if i < 0:
                break
            # Guess we're inside a LEN-prefixed string: a u64 LE length
            # followed by the bytes. Check 8 bytes before for a plausible
            # length that matches what we found.
            guess_as_key = False
            if i >= 8:
                (prelen,) = struct.unpack_from("<Q", data, i - 8)
                if prelen == len(nbytes):
                    guess_as_key = True
            # Tail: try to find the matching values entry nearby. gguf
            # layouts keep keys[] and values[] as two arrays, but
            # entries are interleaved by parallel index, so the value
            # string is not adjacent. We print context around the hit
            # instead — the reader can eyeball.
            start = max(0, i - 40)
            end = min(len(data), i + len(nbytes) + 60)
            ctx = data[start:end]
            printable = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in ctx)
            key_marker = " KEY?" if guess_as_key else ""
            print(f"  offset={i:#x}{key_marker}: {printable!r}")
            hits += 1
            i += 1
        if hits == 0:
            print("  no hits")


if __name__ == "__main__":
    args = sys.argv[1:] or ["response", "responses", "responds", "bosses", "pauses"]
    model = Path(r"d:\jam\lemondate\models\Kokoro_no_espeak_Q4.gguf")
    if not model.exists():
        print(f"model not at {model}", file=sys.stderr)
        sys.exit(1)
    scan(model, args)
