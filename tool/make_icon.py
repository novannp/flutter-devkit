"""Generates the app icon (windows/runner/resources/app_icon.ico, assets/logo.png, docs/logo.png).

Run: python tool/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 1024  # draw large, downscale for crisp edges

TOP = (167, 139, 250)  # violet-400
BOTTOM = (59, 29, 143)  # deep violet

# A chamfered S, kept far from Flutter's blue facets on purpose.
LETTER = [
    (350, 200), (744, 200), (744, 330), (410, 330), (410, 447), (674, 447), (744, 517), (744, 754),
    (674, 824), (280, 824), (280, 694), (614, 694), (614, 577), (350, 577), (280, 507), (280, 270),
]
TIP = (280, 694, 392, 824)


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

    # The S, with its tail picked out.
    letter = Image.new('L', (S, S), 0)
    draw = ImageDraw.Draw(letter)
    draw.polygon(LETTER, fill=255)
    shadow = Image.new('RGBA', (S, S), (20, 8, 60, 0))
    shadow.putalpha(letter.point(lambda v: v * 110 // 255).transform((S, S), Image.AFFINE, (1, 0, -12, 0, 1, -20)))
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(16)))
    icon.paste((255, 255, 255, 255), (0, 0), letter)
    ImageDraw.Draw(icon).rectangle(TIP, fill=(110, 231, 183, 255))
    return icon


def main() -> None:
    icon = render()
    sizes = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]
    for out in [ROOT / 'windows/runner/resources/app_icon.ico']:
        icon.save(out, sizes=sizes)
    (ROOT / 'docs').mkdir(exist_ok=True)
    icon.resize((256, 256), Image.LANCZOS).save(ROOT / 'docs/logo.png')
    icon.resize((128, 128), Image.LANCZOS).save(ROOT / 'assets/logo.png')
    for size in [16, 32, 64, 128, 256, 512, 1024]:
        icon.resize((size, size), Image.LANCZOS).save(ROOT / f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png')
    print('icons written')


if __name__ == '__main__':
    main()
