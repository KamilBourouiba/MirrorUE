#!/usr/bin/env python3
"""Regenerate favicons and reels watermark logo from docs/logo.png."""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
REELS = ROOT / "tools" / "reels" / "assets"


def deblack(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if r < 28 and g < 28 and b < 28:
                px[x, y] = (0, 0, 0, 0)
    return im


def fit_square(im: Image.Image, size: int) -> Image.Image:
    im = im.copy()
    im.thumbnail((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(im, ((size - im.width) // 2, (size - im.height) // 2), im)
    return out


def main() -> None:
    src = DOCS / "logo.png"
    if not src.exists():
        raise SystemExit(f"Missing {src}")

    logo = Image.open(src)
    icon = deblack(logo.crop((0, 0, 390, logo.height)))

    REELS.mkdir(parents=True, exist_ok=True)
    deblack(logo.copy()).save(REELS / "logo.png")

    for size, name in [(32, "favicon-32.png"), (180, "apple-touch-icon.png"), (192, "icon-192.png")]:
        fit_square(icon, size).save(DOCS / name)

    fit_square(icon, 32).save(DOCS / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32)])
    print(f"Updated favicons in {DOCS} and watermark logo in {REELS}")


if __name__ == "__main__":
    main()
