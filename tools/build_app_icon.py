#!/usr/bin/env python3
"""Regenerate the app icon from mobile/assets/app_icon.svg.

The SVG is the master; this only rasterises it into the sizes iOS and Android
insist on having as PNGs. Run it after editing the SVG:

    pip install svglib reportlab pillow
    python tools/build_app_icon.py

macOS only — it uses `sips` to rasterise. Any other SVG rasteriser
(rsvg-convert, Inkscape, a browser) renders app_icon.svg identically; this
script exists so the twenty output files stay in step, not because the icon
depends on it.

Why the mask detour: `sips` colour-manages, and rasterising the brand colours
through it shifted the deep green from #01821B to #38802D — desaturated enough
to read as a different green. So only a black-on-white silhouette goes through
sips, and the brand colours are composited afterwards in Pillow, where the
bytes are exactly what was asked for.
"""
import pathlib
import re
import subprocess
import tempfile

from PIL import Image
from reportlab.graphics import renderPDF
from svglib.svglib import svg2rlg

ROOT = pathlib.Path(__file__).resolve().parent.parent
MASTER = ROOT / 'mobile/assets/app_icon.svg'
IOS = ROOT / 'mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset'
ANDROID = ROOT / 'mobile/android/app/src/main/res'

# Sampled from mojoandco.uk — see the Brand section of CLAUDE.md.
GROUND = (0x01, 0x82, 0x1B)   # deep green
MARK = (0xD2, 0xFF, 0xD4)     # pale green

# Rasterise well above the largest output so every downscale is a reduction.
RENDER_AT = 2048

IOS_ICONS = {
    'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60, 'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120, 'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180, 'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152, 'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}

ANDROID_ICONS = {
    'mipmap-mdpi': 48, 'mipmap-hdpi': 72, 'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144, 'mipmap-xxxhdpi': 192,
}


def render_mask(size):
    """The silhouette as an alpha mask: 255 where the dog is."""
    markup = MASTER.read_text()
    # Strip the brand colours back out — only the shape matters here.
    mask_markup = re.sub(r'fill="#[0-9A-Fa-f]{6}"', 'fill="#000000"', markup)
    mask_markup = mask_markup.replace('<rect', '<rect data-ground="1" ', 1)
    mask_markup = re.sub(
        r'(<rect data-ground="1"[^>]*?)fill="#000000"', r'\1fill="#FFFFFF"', mask_markup,
    )

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        (tmp / 'mask.svg').write_text(mask_markup)
        drawing = svg2rlg(str(tmp / 'mask.svg'))
        scale = size / drawing.width
        drawing.scale(scale, scale)
        drawing.width = drawing.height = size
        renderPDF.drawToFile(drawing, str(tmp / 'mask.pdf'))
        subprocess.run(
            ['sips', '-s', 'format', 'png', str(tmp / 'mask.pdf'),
             '--out', str(tmp / 'mask.png')],
            check=True, capture_output=True,
        )
        grey = Image.open(tmp / 'mask.png').convert('L')

    # White ground, black dog -> invert so the dog is the opaque part.
    return Image.eval(grey, lambda v: 255 - v)


def compose(mask):
    """Exact brand colours, no colour management in the way."""
    icon = Image.new('RGB', mask.size, GROUND)
    icon.paste(Image.new('RGB', mask.size, MARK), (0, 0), mask)
    return icon


def main():
    master = compose(render_mask(RENDER_AT))

    for name, size in IOS_ICONS.items():
        # No alpha anywhere: the App Store rejects a 1024 icon that has one,
        # and the rest are opaque squares regardless.
        master.resize((size, size), Image.LANCZOS).save(IOS / name)
    print(f'{len(IOS_ICONS)} iOS icons -> {IOS.relative_to(ROOT)}')

    for folder, size in ANDROID_ICONS.items():
        out = ANDROID / folder / 'ic_launcher.png'
        master.resize((size, size), Image.LANCZOS).save(out)
    print(f'{len(ANDROID_ICONS)} Android icons -> {ANDROID.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
