#!/usr/bin/env python3
"""Map any Mac-resolved glyph onto USB HID keycodes a US virtual keyboard can type.

UniversalHID only speaks the US QWERTY HID page. MirrorUE therefore:
1. Takes the *character* AppKit produced for the active Mac layout (AZERTY,
   QWERTZ, Dvorak, ABC Extended, …).
2. Folds / transliterates it to the closest ASCII HID chord.
3. Falls back to the physical key usage the Swift side sent when no glyph map
   exists (arrows, F-keys, CJK, etc.).
"""

from __future__ import annotations

import unicodedata
from typing import Optional, Tuple

# Extra glyphs → ASCII stand-ins before ASCII_TO_HID lookup.
# Covers leftovers NFKD does not strip (stroke letters, currency, quotes, …)
# plus compact phonetic maps for Cyrillic / Greek so those layouts still type.
_COMPAT: dict[str, str] = {
    # Latin leftovers
    "ß": "s",
    "ẞ": "S",
    "ø": "o",
    "Ø": "O",
    "đ": "d",
    "Đ": "D",
    "ł": "l",
    "Ł": "L",
    "ı": "i",
    "İ": "I",
    "œ": "o",
    "Œ": "O",
    "æ": "a",
    "Æ": "A",
    "þ": "t",
    "Þ": "T",
    "ð": "d",
    "Ð": "D",
    "ŋ": "n",
    "Ŋ": "N",
    # Currency / units
    "€": "e",
    "£": "l",
    "¥": "y",
    "¢": "c",
    "₽": "r",
    "₩": "w",
    "₹": "r",
    "°": "o",
    "§": "s",
    "©": "c",
    "®": "r",
    "™": "t",
    "µ": "u",
    "×": "x",
    "÷": "/",
    "±": "+",
    # Quotes / dashes / ellipsis
    "«": '"',
    "»": '"',
    "‹": "'",
    "›": "'",
    "“": '"',
    "”": '"',
    "„": '"',
    "‟": '"',
    "‘": "'",
    "’": "'",
    "‚": "'",
    "′": "'",
    "″": '"',
    "–": "-",
    "—": "-",
    "−": "-",
    "‑": "-",
    "…": ".",
    "·": ".",
    "•": "*",
    "¡": "!",
    "¿": "?",
    "‽": "?",
    "¸": ",",
    "¨": '"',
    "´": "'",
    "ˆ": "^",
    "˜": "~",
    "¯": "-",
    "№": "n",
    "†": "+",
    "‡": "+",
    "‰": "%",
    "∞": "8",
    "≈": "=",
    "≠": "=",
    "≤": "<",
    "≥": ">",
    "←": "<",
    "→": ">",
    "↑": "^",
    "↓": "v",
    "\u00a0": " ",  # nbsp
    "\u202f": " ",  # narrow nbsp
    "\u2009": " ",
    "\u2007": " ",
    # Greek (phonetic)
    "α": "a", "β": "b", "γ": "g", "δ": "d", "ε": "e", "ζ": "z",
    "η": "i", "θ": "t", "ι": "i", "κ": "k", "λ": "l", "μ": "m",
    "ν": "n", "ξ": "x", "ο": "o", "π": "p", "ρ": "r", "σ": "s",
    "ς": "s", "τ": "t", "υ": "y", "φ": "f", "χ": "h", "ψ": "p",
    "ω": "o",
    "Α": "A", "Β": "B", "Γ": "G", "Δ": "D", "Ε": "E", "Ζ": "Z",
    "Η": "I", "Θ": "T", "Ι": "I", "Κ": "K", "Λ": "L", "Μ": "M",
    "Ν": "N", "Ξ": "X", "Ο": "O", "Π": "P", "Ρ": "R", "Σ": "S",
    "Τ": "T", "Υ": "Y", "Φ": "F", "Χ": "H", "Ψ": "P", "Ω": "O",
    # Cyrillic (phonetic)
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e",
    "ё": "e", "ж": "z", "з": "z", "и": "i", "й": "i", "к": "k",
    "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
    "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "c",
    "ч": "c", "ш": "s", "щ": "s", "ъ": "", "ы": "y", "ь": "",
    "э": "e", "ю": "u", "я": "a",
    "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E",
    "Ё": "E", "Ж": "Z", "З": "Z", "И": "I", "Й": "I", "К": "K",
    "Л": "L", "М": "M", "Н": "N", "О": "O", "П": "P", "Р": "R",
    "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "H", "Ц": "C",
    "Ч": "C", "Ш": "S", "Щ": "S", "Ъ": "", "Ы": "Y", "Ь": "",
    "Э": "E", "Ю": "U", "Я": "A",
}


def fold_glyph(ch: str) -> str:
    """Reduce *ch* to an ASCII-ish string suitable for ASCII_TO_HID."""
    if not ch:
        return ""
    # Take the first extended grapheme as one unit (Swift sends one Character).
    unit = ch[0]
    if unit in _COMPAT:
        return _COMPAT[unit]
    decomposed = unicodedata.normalize("NFKD", unit)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    if not stripped:
        return ""
    if stripped in _COMPAT:
        return _COMPAT[stripped]
    out = []
    for c in stripped:
        if c in _COMPAT:
            out.append(_COMPAT[c])
        elif c.isascii():
            out.append(c)
        else:
            # Last resort: Latin letter name hint ("LATIN SMALL LETTER X …")
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


def glyph_to_hid(char: str, ascii_to_hid: dict) -> Optional[Tuple[int, bool]]:
    """Return ``(hid_usage, needs_shift)`` for *char*, or ``None``."""
    if not char:
        return None
    # Direct hit (ASCII punctuation, digits, letters).
    mapping = ascii_to_hid.get(char)
    if mapping is not None:
        return mapping
    folded = fold_glyph(char)
    if not folded:
        return None
    for candidate in (folded, folded.lower(), folded.upper()):
        mapping = ascii_to_hid.get(candidate)
        if mapping is not None:
            return mapping
    return None
