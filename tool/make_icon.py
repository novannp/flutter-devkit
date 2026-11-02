"""Generates the app icon (windows/runner/resources/app_icon.ico, assets/tray.ico, assets/logo.png, docs/logo.png).

Run: python tool/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # draw large, downscale for crisp edges

TOP = (56, 189, 248)  # sky-400
BOTTOM = (3, 74, 150)  # deep blue


LETTER = [
    [(300, 200), (800, 200), (652, 348), (300, 348)],
    [(300, 200), (448, 200), (448, 824), (300, 824)],
    [(300, 432), (652, 432), (504, 580), (300, 580)],
]


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
    ImageDraw.Draw(shine).ellipse((-200, -620, S + 200, 430), fill=20)
    shine = Image.composite(shine, Image.new('L', (S, S), 0), mask)
    icon = Image.alpha_composite(icon, Image.merge('RGBA', [Image.new('L', (S, S), 255)] * 3 + [shine]))

    # An F with chamfered arms, and a small diamond where its lower right would be.
    diamond = [(640, 590), (760, 710), (640, 830), (520, 710)]
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    for shape in [*LETTER, diamond]:
        draw.polygon([(x + 12, y + 20) for x, y in shape], fill=(1, 40, 90, 110))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(16)))
    draw = ImageDraw.Draw(icon)
    for shape in LETTER:
        draw.polygon(shape, fill=(255, 255, 255, 255))
    draw.polygon(diamond, fill=(125, 232, 255, 255))
    return icon


def main() -> None:
    icon = render()
    sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    for out in [ROOT / 'windows/runner/resources/app_icon.ico', ROOT / 'assets/tray.ico']:
        icon.save(out, sizes=sizes)
    (ROOT / 'docs').mkdir(exist_ok=True)
    icon.resize((256, 256), Image.LANCZOS).save(ROOT / 'docs/logo.png')
    icon.resize((128, 128), Image.LANCZOS).save(ROOT / 'assets/logo.png')
    for size in [16, 32, 64, 128, 256, 512, 1024]:
        icon.resize((size, size), Image.LANCZOS).save(ROOT / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')
    # The menu bar tints a template by its alpha, so only the letter is drawn.
    tray = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tray)
    for shape in LETTER:
        draw.polygon(shape, fill=(0, 0, 0, 255))
    tray.resize((44, 44), Image.LANCZOS).save(ROOT / 'assets/tray_mac.png')
    print('icons written')


if __name__ == '__main__':
    main()
