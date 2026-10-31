"""Generates the app icon (windows/runner/resources/app_icon.ico, assets/tray.ico, docs/logo.png).

Run: python tool/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # draw large, downscale for crisp edges

TOP = (52, 211, 153)  # emerald-400
BOTTOM = (4, 120, 87)  # emerald-700


def render() -> Image.Image:
    grad = Image.new('RGBA', (S, S))
    px = grad.load()
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S)
            px[x, y] = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)

    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((40, 40, S - 40, S - 40), radius=230, fill=255)
    icon = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), mask)

    # Soft top highlight.
    shine = Image.new('L', (S, S), 0)
    ImageDraw.Draw(shine).ellipse((-200, -620, S + 200, 430), fill=46)
    shine = Image.composite(shine, Image.new('L', (S, S), 0), mask)
    icon = Image.alpha_composite(icon, Image.merge('RGBA', [Image.new('L', (S, S), 255)] * 3 + [shine]))

    bolt = [(585, 150), (285, 575), (480, 575), (420, 875), (740, 425), (540, 425), (620, 150)]
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(x + 14, y + 22) for x, y in bolt], fill=(2, 60, 44, 120))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(18)))
    ImageDraw.Draw(icon).polygon(bolt, fill=(255, 255, 255, 255))
    return icon


def main() -> None:
    icon = render()
    sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    for out in [ROOT / 'windows/runner/resources/app_icon.ico', ROOT / 'assets/tray.ico']:
        icon.save(out, sizes=sizes)
    (ROOT / 'docs').mkdir(exist_ok=True)
    icon.resize((256, 256), Image.LANCZOS).save(ROOT / 'docs/logo.png')
    print('icons written')


if __name__ == '__main__':
    main()
