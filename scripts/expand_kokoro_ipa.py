#!/usr/bin/env python3
"""Append hand-curated English word -> IPA entries to the kokoro_ipa.embd
override dictionary consumed by ttscpp's populate_kokoro_ipa_map().

The koboldcpp-shipped 65k-entry dict leaves out a bunch of common words
that tokenise to the buggy rule cascade: the -ize verb family, some
close-family words, and a handful of miscellaneous items Claude Code
tends to produce. Rather than letting the rule engine mangle them,
this script appends correct IPA for each base + -s/-es/-ed/-ing form.

The underlying dict format is one `word,IPA` per line, UTF-8. This
script only appends; existing entries win on the first match (the
ttscpp map uses the last entry but since we dedupe against the map
on load, duplicates are harmless and the ones we ship are correct).
"""
from __future__ import annotations

import pathlib
import sys

EMBD_IN  = pathlib.Path(r"d:\jam\lemondate\assets\embd_res\kokoro_ipa.embd")
EMBD_OUT = EMBD_IN  # append in place

# --- IPA morphology helpers, modelled on misaki/en.py:_s / _ed / _ing ---

UNVOICED = set("ptkfθ")             # stem-final -> +s
SIBILANTS = {"s", "z", "ʃ", "ʒ", "ʧ", "ʤ"}  # stem-final -> +ᵻz
VOWELS_FOR_D = set("aeiouəɛɪɑɔʊʌæɜɝœɘɚɤɛ̃ɔ̃iː uː ɑː ɔː ɜː".replace(" ", ""))  # stem-final vowel -> +d (no schwa)

# Stress marker(s) we use: ˈ (primary) and ˌ (secondary). Keep them as-is.
# Terminal phone for inflection purposes is whatever the last phone
# character is; we ignore length markers (ː, ʲ, etc.) when classifying.

def _last_phone_class(stem_ipa: str) -> str:
    """Return 'unvoiced'|'sibilant'|'voiced' based on the stem's final phoneme.
    Ignores stress markers and length marks when picking the terminal."""
    # Strip trailing length / secondary-stress markers.
    tail = stem_ipa.rstrip("ːˈˌ")
    if not tail:
        return "voiced"
    # Multi-char phonemes like ʃ/ʒ/ʧ/ʤ are single codepoints.
    c = tail[-1]
    if c in UNVOICED:
        return "unvoiced"
    if c in SIBILANTS:
        return "sibilant"
    return "voiced"


def _plural(stem_ipa: str) -> str:
    cls = _last_phone_class(stem_ipa)
    if cls == "unvoiced":  return stem_ipa + "s"
    if cls == "sibilant":  return stem_ipa + "ᵻz"
    return stem_ipa + "z"


def _past(stem_ipa: str) -> str:
    # t-ending consonants -> +ᵻd, voiced/vowel -> +d, unvoiced -> +t
    tail = stem_ipa.rstrip("ːˈˌ")
    if not tail:
        return stem_ipa + "d"
    c = tail[-1]
    if c in ("t", "d"): return stem_ipa + "ᵻd"
    if c in UNVOICED:   return stem_ipa + "t"
    return stem_ipa + "d"


def _gerund(stem_ipa: str) -> str:
    # -ing is always +ɪŋ
    return stem_ipa + "ɪŋ"


# --- manual entries. Prefer `stem` + let the helpers produce forms.  Where
#     a verb has an irregular stem-final sound (e.g. "use" ends in /z/ but
#     spells with a silent 'e'), put a note and override.
HAND_ENTRIES: dict[str, str] = {}

def add(base: str, ipa: str, *, only_base: bool = False, verb: bool = True) -> None:
    """Add `base -> ipa` plus inflected forms unless only_base."""
    HAND_ENTRIES[base] = ipa
    if only_base:
        return
    if verb:
        # 3sg / plural
        HAND_ENTRIES[base + "s"]  = _plural(ipa)
        # past / -ed
        past_form = base + "ed" if not base.endswith("e") else base + "d"
        HAND_ENTRIES[past_form]   = _past(ipa)
        # gerund
        ing_form = (base[:-1] + "ing") if base.endswith("e") else (base + "ing")
        HAND_ENTRIES[ing_form]    = _gerund(ipa.rstrip("ː") if ipa.endswith("eɪ") else ipa)

# --- -ize family verbs (stem ends in /aɪz/ -> sibilant -> plural +ᵻz) ---
IZE_STEMS = {
    "recognize":    "ˈɹɛkəɡnˌaɪz",
    "organize":     "ˈɔːɹɡənˌaɪz",
    "summarize":    "ˈsʌməɹˌaɪz",
    "emphasize":    "ˈɛmfəsˌaɪz",
    "categorize":   "ˈkætəɡəɹˌaɪz",
    "analyze":      "ˈænəlˌaɪz",
    "optimize":     "ˈɑːptəmˌaɪz",
    "normalize":    "ˈnɔːɹməlˌaɪz",
    "visualize":    "ˈvɪʒuəlˌaɪz",
    "customize":    "ˈkʌstəmˌaɪz",
    "synchronize":  "ˈsɪŋkɹənˌaɪz",
    "parameterize": "pəˈɹæmɪtəɹˌaɪz",
    "serialize":    "ˈsɪɹiəlˌaɪz",
    "deserialize":  "diˈsɪɹiəlˌaɪz",
    "initialize":   "ɪˈnɪʃəlˌaɪz",
    "finalize":     "ˈfaɪnəlˌaɪz",
    "minimize":     "ˈmɪnəmˌaɪz",
    "maximize":     "ˈmæksəmˌaɪz",
    "modernize":    "ˈmɑːdəɹnˌaɪz",
    "prioritize":   "pɹaɪˈɔːɹəᵻˌaɪz",
    "tokenize":     "ˈtoʊkənˌaɪz",
    "memorize":     "ˈmɛməɹˌaɪz",
    "authorize":    "ˈɔːθəɹˌaɪz",
    "realize":      "ˈɹiːəlˌaɪz",
    "apologize":    "əˈpɑːləʤˌaɪz",
    "sanitize":     "ˈsænəᵻˌaɪz",
    "standardize":  "ˈstændəɹdˌaɪz",
    "centralize":   "ˈsɛntɹəlˌaɪz",
    "monetize":     "ˈmɑːnəᵻˌaɪz",
    "generalize":   "ˈʤɛnəɹəlˌaɪz",
    "specialize":   "ˈspɛʃəlˌaɪz",
    "finalize":     "ˈfaɪnəlˌaɪz",
    "utilize":      "ˈjuːtəlˌaɪz",
    "realize":      "ˈɹiːəlˌaɪz",
    "stabilize":    "ˈsteɪbəlˌaɪz",
    "localize":     "ˈloʊkəlˌaɪz",
    "sterilize":    "ˈstɛɹəlˌaɪz",
    "criticize":    "ˈkɹɪᵻsˌaɪz",
    "materialize":  "məˈtɪɹiəlˌaɪz",
}
for b, ipa in IZE_STEMS.items():
    add(b, ipa, verb=True)

# --- close family (homograph: verb /kloʊz/, adj /kloʊs/). Pin them all
#     to the verb form since Kokoro has no POS info; we're optimising
#     for "the user dictated something about a file, function, request,
#     etc." which overwhelmingly uses the verb or the -es/-ed/-ing
#     inflections of it.
add("close",  "klˈoʊz",  verb=True)
add("disclose", "dɪsˈkloʊz", verb=True)
add("enclose",  "ɪnˈkloʊz", verb=True)
add("foreclose","fɔɹˈkloʊz", verb=True)

# --- a few other common verbs not in the koboldcpp dict ---
add("deprecate", "ˈdɛpɹəkˌeɪt", verb=True)
add("refactor",  "ˌɹiˈfæktəɹ",  verb=True)
add("rebase",    "ˌɹiˈbeɪs",    verb=True)
add("invalidate","ɪnˈvælɪdeɪt", verb=True)
add("commit",    "kəˈmɪt",      verb=True)
add("revert",    "ɹɪˈvɝt",      verb=True)
add("implement", "ˈɪmpləmɛnt",  verb=True)
add("deploy",    "dɪˈplɔɪ",     verb=True)

# --- nouns / plurals the rule engine mangles and that aren't in the
#     koboldcpp dict. "asses" / "intenses" / "suspenses" fall through
#     to the -es suffix rule which eats the stem vowel.
HAND_ENTRIES["asses"]     = "ˈæsᵻz"
HAND_ENTRIES["suspenses"] = "səspˈɛnsᵻz"
HAND_ENTRIES["intenses"]  = "ɪntˈɛnsᵻz"


def main() -> int:
    existing = set()
    if EMBD_IN.exists():
        with EMBD_IN.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\r\n")
                if not line or "," not in line:
                    continue
                existing.add(line.split(",", 1)[0])
    new_entries = [(w, p) for w, p in sorted(HAND_ENTRIES.items()) if w not in existing]
    if not new_entries:
        print(f"[expand] no new entries to append (all {len(HAND_ENTRIES)} already present)")
        return 0
    with EMBD_OUT.open("a", encoding="utf-8", newline="\n") as f:
        f.write("\n# --- hand-curated additions (expand_kokoro_ipa.py) ---\n")
        for w, p in new_entries:
            f.write(f"{w},{p}\n")
    print(f"[expand] appended {len(new_entries)} new entries to {EMBD_OUT}")
    print(f"[expand]   ({len(HAND_ENTRIES) - len(new_entries)} were already in the dict)")
    # A few spot-check prints so it's obvious what got added.
    sample = [(w, p) for w, p in new_entries[:6]]
    for w, p in sample:
        print(f"           {w:<18} -> {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
