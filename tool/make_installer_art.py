"""Generates the installer wizard images (windows/installer/*.bmp) from docs/logo.png.

Run: python tool/make_installer_art.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'windows' / 'installer'
TOP = (7, 62, 122)  # deep blue
BOTTOM = (3, 32, 74)  # darker blue

logo = Image.open(ROOT / 'docs' / 'logo.png').convert('RGBA')


def gradient(w: int, h: int) -> Image.Image:
    im = Image.new('RGB', (w, h))
    px = im.load()
    for y in range(h):
        c = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * y / h) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return im


def with_logo(bg: Image.Image, size: int, y: int) -> Image.Image:
    mark = logo.resize((size, size), Image.LANCZOS)
    bg.paste(mark, ((bg.width - size) // 2, y), mark)
    return bg


OUT.mkdir(parents=True, exist_ok=True)
# Inno picks the closest file for the current DPI scaling: 100% and 200%.
for scale in (1, 2):
    w, h = 164 * scale, 314 * scale
    with_logo(gradient(w, h), 96 * scale, int(h * 0.3)).save(OUT / f'wizard-{scale}x.bmp')
    s = 55 * scale
    with_logo(Image.new('RGB', (s, s), (255, 255, 255)), s, 0).save(OUT / f'wizard-small-{scale}x.bmp')
