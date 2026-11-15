#!/usr/bin/env python3
"""Write WebP and 800w/1600w variants of the website snapshots.

For each source PNG (not itself a width variant) this writes:

    name.webp
    name-800.png  name-1600.png
    name-800.webp name-1600.webp

which is the AtaSite `scripts/images.py` naming (`site-hero-light-800.png`).
WebP is skipped when `cwebp` is not on PATH. Quality is 82.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

WIDTHS = (800, 1600)
QUALITY = "82"


def is_source(path: Path) -> bool:
    if path.suffix.lower() != ".png":
        return False
    stem = path.stem
    return not stem.endswith("-800") and not stem.endswith("-1600")


def resize(im, width):
    height = round(im.height * width / im.width)
    return im.resize((width, height), Image.Resampling.LANCZOS)


def prepared(im):
    im.load()
    if im.mode == "RGBA":
        lo, hi = im.getchannel("A").getextrema()
        if lo == 255 and hi == 255:
            return im.convert("RGB")
        return im
    if im.mode != "RGB":
        return im.convert("RGBA")
    return im


def save_png(im, dest):
    im.save(dest, format="PNG", optimize=True, compress_level=9)


def save_webp(im, dest, cwebp):
    if cwebp is None:
        return False
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        im.save(tmp_path, format="PNG")
        subprocess.run(
            [cwebp, "-q", QUALITY, "-m", "6", "-metadata", "none", "-quiet",
             str(tmp_path), "-o", str(dest)],
            check=True,
        )
    finally:
        tmp_path.unlink(missing_ok=True)
    return True


def main():
    if len(sys.argv) != 2:
        print("usage: site_images.py <directory>", file=sys.stderr)
        return 2
    folder = Path(sys.argv[1])
    sources = sorted(p for p in folder.iterdir() if p.is_file() and is_source(p))
    if not sources:
        print(f"no source PNGs in {folder}", file=sys.stderr)
        return 1
    cwebp = shutil.which("cwebp")
    if cwebp is None:
        print("cwebp not installed; skipping WebP", file=sys.stderr)
    for src in sources:
        im = prepared(Image.open(src))
        stem = src.stem
        wrote = save_webp(im, folder / f"{stem}.webp", cwebp)
        webp_size = (folder / f"{stem}.webp").stat().st_size if wrote else 0
        print(f"{stem}.webp {im.width}x{im.height} {webp_size}")
        for width in WIDTHS:
            variant = resize(im, width)
            png = folder / f"{stem}-{width}.png"
            save_png(variant, png)
            webp = folder / f"{stem}-{width}.webp"
            wrote_variant = save_webp(variant, webp, cwebp)
            variant_webp = webp.stat().st_size if wrote_variant else 0
            print(f"{png.name} {variant.width}x{variant.height} {png.stat().st_size} webp {variant_webp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
