#!/usr/bin/env python3
"""Local Mac-glyph → US HID translator (source of truth for MirrorUE).

Usage:
  ./tools/kb_translate.py é à ç 'a' A '&' 1
  ./tools/kb_translate.py --json        # dump ascii table
  echo 'bonjour' | ./tools/kb_translate.py --stdin

MirrorUE's Swift ``KeyboardTranslator`` mirrors this logic so layout glyphs
(AZERTY, QWERTZ, …) become US virtual-HID chords *before* the phone sees them.
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from typing import Optional, Tuple

# usage → needs_shift (US QWERTY)
ASCII_TO_HID: dict[str, Tuple[int, bool]] = {}
for i, ch in enumerate("abcdefghijklmnopqrstuvwxyz"):
    ASCII_TO_HID[ch] = (0x04 + i, False)
    ASCII_TO_HID[ch.upper()] = (0x04 + i, True)
for i, ch in enumerate("1234567890"):
    ASCII_TO_HID[ch] = (0x1E + i, False)
for ch, usage, shift in [
    ("!", 0x1E, True), ("@", 0x1F, True), ("#", 0x20, True), ("$", 0x21, True),
    ("%", 0x22, True), ("^", 0x23, True), ("&", 0x24, True), ("*", 0x25, True),
    ("(", 0x26, True), (")", 0x27, True),
    (" ", 0x2C, False), ("\t", 0x2B, False), ("\n", 0x28, False), ("\r", 0x28, False),
    ("-", 0x2D, False), ("_", 0x2D, True), ("=", 0x2E, False), ("+", 0x2E, True),
    ("[", 0x2F, False), ("{", 0x2F, True), ("]", 0x30, False), ("}", 0x30, True),
    ("\\", 0x31, False), ("|", 0x31, True),
    (";", 0x33, False), (":", 0x33, True), ("'", 0x34, False), ('"', 0x34, True),
    ("`", 0x35, False), ("~", 0x35, True),
    (",", 0x36, False), ("<", 0x36, True), (".", 0x37, False), (">", 0x37, True),
    ("/", 0x38, False), ("?", 0x38, True),
]:
    ASCII_TO_HID[ch] = (usage, shift)

COMPAT: dict[str, str] = {
    # Latin leftovers that NFKD does not fully ASCII-fold.
    "ß": "s", "ẞ": "S", "ø": "o", "Ø": "O", "đ": "d", "Đ": "D",
    "ł": "l", "Ł": "L", "ı": "i", "İ": "I", "œ": "o", "Œ": "O",
    "æ": "a", "Æ": "A", "þ": "t", "Þ": "T", "ð": "d", "Ð": "D",
    # Quotes / dashes (safe ASCII stand-ins).
    "«": '"', "»": '"', "“": '"', "”": '"', "„": '"',
    "‘": "'", "’": "'", "‚": "'",
    "–": "-", "—": "-", "−": "-", "…": ".", "·": ".",
    "¡": "!", "¿": "?",
    "\u00a0": " ", "\u202f": " ",
    # Intentionally NOT mapped (paste instead): € £ ¥ ¢ ₽ ° § µ × ÷ ± ∞ •
}
# Cyrillic / Greek phonetic (compact)
_CYR = "абвгдеёжзийклмнопрстуфхцчшщыэюя"
_CYR_TO = "abvgdeezzijklmnoprstufhccssyeua"
_CYR_U = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЫЭЮЯ"
_CYR_UTO = "ABVGDEEZZIJKLMNOPRSTUFHCCSSYEUA"
for a, b in zip(_CYR, _CYR_TO):
    COMPAT[a] = b
for a, b in zip(_CYR_U, _CYR_UTO):
    COMPAT[a] = b
_GR = "αβγδεζηθικλμνξοπρσςτυφχψω"
_GR_TO = "abgdezhqiklmncoprsstyfhpo"
_GR_U = "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"
_GR_UTO = "ABGDEZHQIKLMNCOPRSTYFHPO"
for a, b in zip(_GR, _GR_TO):
    COMPAT[a] = b
for a, b in zip(_GR_U, _GR_UTO):
    COMPAT[a] = b


def fold(glyph: str) -> str:
    if not glyph:
        return ""
    unit = glyph[0]
    if unit in COMPAT:
        return COMPAT[unit]
    decomposed = unicodedata.normalize("NFKD", unit)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    if stripped in COMPAT:
        return COMPAT[stripped]
    out = []
    for c in stripped:
        if c in COMPAT:
            out.append(COMPAT[c])
        elif c.isascii():
            out.append(c)
        else:
            try:
                name = unicodedata.name(c)
            except ValueError:
                continue
            for marker in ("LETTER ", "DIGIT "):
                if marker in name:
                    tail = name.split(marker, 1)[1].split()[0]
                    if len(tail) == 1 and tail.isascii():
                        out.append(tail.lower() if "SMALL" in name else tail)
                        break
    joined = "".join(out)
    if len(joined) > 1:
        for c in joined:
            if c.isascii() and (c.isalnum() or c in " \t\n"):
                return c
        return joined[0]
    return joined


def resolve(glyph: str, host_mods: int = 0) -> Optional[dict]:
    """Return ``{usage, token, mods, shift}`` or None."""
    folded = fold(glyph)
    if not folded:
        return None
    ch = folded[0]
    if not ch.isascii():
        return None
    mapping = ASCII_TO_HID.get(ch) or ASCII_TO_HID.get(ch.lower()) or ASCII_TO_HID.get(ch.upper())
    if mapping is None:
        return None
    usage, needs_shift = mapping
    mods = host_mods & 0x0A
    want_shift = bool(needs_shift) or ch.isupper()
    if want_shift:
        mods |= 0x01
    return {
        "glyph": glyph[0],
        "folded": folded,
        "token": ch,
        "usage": usage,
        "usage_hex": f"0x{usage:02X}",
        "shift": want_shift,
        "mods": mods,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("glyphs", nargs="*", help="glyphs to translate")
    ap.add_argument("--stdin", action="store_true", help="read UTF-8 text from stdin")
    ap.add_argument("--json", action="store_true", help="dump ASCII_TO_HID as JSON")
    ap.add_argument("--test", action="store_true", help="run EN/FR/IT layout regression suite")
    args = ap.parse_args()

    if args.json:
        dump = {k: {"usage": u, "shift": s} for k, (u, s) in sorted(ASCII_TO_HID.items())}
        json.dump(dump, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    if args.test:
        return run_layout_tests()

    chars: list[str] = []
    if args.stdin:
        chars.extend(sys.stdin.read())
    chars.extend(args.glyphs)

    if not chars:
        ap.print_help()
        return 2

    for raw in chars:
        if raw == "":
            continue
        for ch in raw:
            if ch == "\n" and args.stdin:
                print()
                continue
            info = resolve(ch)
            if info is None:
                print(f"{ch!r:8} → PASTE (keep glyph)")
            else:
                print(
                    f"{info['glyph']!r:8} → {info['token']!r}  "
                    f"usage={info['usage_hex']}  shift={int(info['shift'])}  mods=0x{info['mods']:02x}"
                )
    return 0


def run_layout_tests() -> int:
    """Regression: EN / FR AZERTY / IT accent keys must resolve sensibly."""
    cases: list[tuple[str, str, Optional[str]]] = []
    # (label, glyph, expected_token or None for paste)

    # English
    for ch in "abcXYZ0123":
        cases.append(("EN", ch, ch))
    for ch, exp in [("!", "!"), ("@", "@"), ("#", "#"), ("$", "$")]:
        cases.append(("EN", ch, exp))

    # French AZERTY primary row (unshifted) + shifted digits
    for ch, exp in [
        ("&", "&"), ("é", "e"), ('"', '"'), ("'", "'"), ("(", "("),
        ("-", "-"), ("è", "e"), ("_", "_"), ("ç", "c"), ("à", "a"),
        (")", ")"), ("=", "="),
        ("1", "1"), ("2", "2"), ("5", "5"), ("°", None), ("+", "+"),
    ]:
        cases.append(("FR", ch, exp))
    for ch, exp in [
        ("â", "a"), ("ê", "e"), ("ù", "u"), ("ü", "u"), ("€", None),
        ("«", '"'), ("»", '"'), ("œ", "o"), ("æ", "a"), ("É", "E"),
    ]:
        cases.append(("FR", ch, exp))

    # Italian accents (Mac Italiano)
    for ch, exp in [
        ("à", "a"), ("è", "e"), ("é", "e"), ("ì", "i"), ("ò", "o"), ("ù", "u"),
        ("À", "A"), ("È", "E"), ("Ì", "I"), ("Ò", "O"), ("Ù", "U"),
        ("°", None), ("§", None), ("£", None), ("ç", "c"),
        ("!", "!"), ("?", "?"), ("/", "/"),
    ]:
        cases.append(("IT", ch, exp))

    # German / Spanish smoke
    for ch, exp in [("ä", "a"), ("ö", "o"), ("ü", "u"), ("ß", "s"), ("ñ", "n"), ("¿", "?"), ("¡", "!")]:
        cases.append(("DE/ES", ch, exp))

    failed = 0
    for label, glyph, expected in cases:
        info = resolve(glyph)
        got = None if info is None else info["token"]
        if got != expected:
            print(f"FAIL [{label}] {glyph!r}: got {got!r}, want {expected!r} (fold={fold(glyph)!r})")
            failed += 1
        else:
            mode = "paste" if expected is None else f"HID {info['usage_hex']}"
            print(f"OK   [{label}] {glyph!r} → {mode}")

    print(f"\n{len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
