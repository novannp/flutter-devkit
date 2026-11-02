"""Builds assets/fonts/devkit_icons.ttf, for file icons Material doesn't have. Needs fontTools and Pillow."""
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

ROOT = Path(__file__).resolve().parent.parent
GRID = 24
EM = 1200

# The Dart mark on a 24 grid, y down: its two-tone facets, told apart here by thin gaps.
DART = [
    [(4, 4), (12.2, 1.6), (14, 2.3), (19.6, 7.9), (7.9, 7.9)],
    [(4, 4), (7.9, 8.3), (7.9, 19.6), (2.3, 14), (1.6, 12.2)],
    [(8.7, 8.7), (22.4, 8.7), (22.4, 15.9), (15.9, 15.9)],
    [(8.7, 9.4), (15.9, 16.6), (15.9, 22.4), (8.7, 22.4)],
    [(16.7, 16.7), (22.4, 16.7), (16.7, 22.4)],
]


def glyph(shapes):
    pen = TTGlyphPen(None)
    for shape in shapes:
        # TrueType fills clockwise in its y-up space, which a y-down outline already reads as reversed.
        points = [(round(x / GRID * EM), round((GRID - y) / GRID * EM)) for x, y in shape]
        pen.moveTo(points[0])
        for point in points[1:]:
            pen.lineTo(point)
        pen.closePath()
    return pen.glyph()


def main():
    empty = TTGlyphPen(None).glyph()
    fb = FontBuilder(EM, isTTF=True)
    fb.setupGlyphOrder(['.notdef', 'dart'])
    fb.setupCharacterMap({0xE000: 'dart'})
    fb.setupGlyf({'.notdef': empty, 'dart': glyph(DART)})
    fb.setupHorizontalMetrics({'.notdef': (EM, 0), 'dart': (EM, 0)})
    fb.setupHorizontalHeader(ascent=EM, descent=0)
    fb.setupNameTable({'familyName': 'DevKitIcons', 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=EM, sTypoDescender=0, usWinAscent=EM, usWinDescent=0)
    fb.setupPost()
    out = ROOT / 'assets/fonts/devkit_icons.ttf'
    out.parent.mkdir(parents=True, exist_ok=True)
    fb.save(str(out))


if __name__ == '__main__':
    main()
