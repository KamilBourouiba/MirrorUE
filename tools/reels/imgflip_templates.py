"""Map memegen-style template slugs to Imgflip template IDs."""

from __future__ import annotations

import json
import urllib.request

IMGFLIP_GET_MEMES = "https://api.imgflip.com/get_memes"

# Slug → Imgflip template_id (verified via caption_image invalid-auth probe).
TEMPLATE_IDS: dict[str, int] = {
    "drake": 181913649,
    "mordor": 61579,
    "morpheus": 100947,
    "success": 61544,
    "wonka": 61522,
    "fine": 55311130,
    "both": 87845541,
    "interesting": 61532,
    "buzz": 91538330,
    "pigeon": 100777631,
    "rollsafe": 89370399,
    "woman-cat": 188390779,
    "officespace": 563423,
    "patrick": 417458453,
    "spongebob": 102156234,
    "leo": 5496396,
    "fry": 61520,
    "doge": 8072285,
    "bihw": 122242200,
    "db": 112126428,
    "handshake": 135256802,
    "gb": 93895088,
    "panik-kalm-panik": 226297822,
    "spiderman": 110133729,
    "same": 180190441,
    "astronaut": 252600902,
}

# Fallback when slug is missing from /get_memes (top-100 only).
BOX_COUNTS: dict[str, int] = {
    "morpheus": 2,
    "success": 2,
    "wonka": 2,
    "both": 2,
    "interesting": 2,
    "officespace": 2,
    "patrick": 2,
    "bihw": 2,
    "doge": 2,
    "gb": 4,
    "panik-kalm-panik": 3,
    "handshake": 3,
    "pigeon": 3,
    "astronaut": 2,
}

_box_cache: dict[str, int] | None = None


def fetch_box_counts() -> dict[str, int]:
    global _box_cache
    if _box_cache is not None:
        return _box_cache

    counts = dict(BOX_COUNTS)
    req = urllib.request.Request(IMGFLIP_GET_MEMES, headers={"User-Agent": "MirrorUE-Reels/2.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    by_id = {int(m["id"]): int(m.get("box_count") or 2) for m in data["data"]["memes"]}
    for slug, tid in TEMPLATE_IDS.items():
        if slug not in counts and tid in by_id:
            counts[slug] = by_id[tid]
    for slug, tid in TEMPLATE_IDS.items():
        counts.setdefault(slug, 2)
    _box_cache = counts
    return counts


def template_id(slug: str) -> int:
    if slug not in TEMPLATE_IDS:
        raise KeyError(f"No Imgflip mapping for template {slug!r}")
    return TEMPLATE_IDS[slug]


def fit_text(text: list[str], box_count: int) -> list[str]:
    """Merge or split caption lines to match Imgflip text box count."""
    if not text:
        return [""] * box_count
    if len(text) == box_count:
        return list(text)
    if len(text) < box_count:
        return text + [""] * (box_count - len(text))
    # More lines than boxes: pack evenly into boxes.
    out: list[str] = []
    n = len(text)
    for i in range(box_count):
        start = (i * n) // box_count
        end = ((i + 1) * n) // box_count
        chunk = text[start:end]
        out.append("\n".join(chunk))
    return out


def caption_fields(text: list[str], slug: str) -> dict[str, str]:
    boxes = fit_text(text, fetch_box_counts()[slug])
    return {f"text{i}": boxes[i] for i in range(len(boxes))}
