# This file is part of Kumo.
# Copyright (C) 2026 Nam <namicedtea@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file at the app root for the full notice.
"""Draws every Kumo icon from one definition of the mark.

The mark is a cloud (kumo, 雲) with a play triangle cut out of it, so the
ground shows through where the triangle is. Everything below derives from the
shapes in CLOUD and PLAY, laid out on a 512 grid.

    python tool/make_icons.py

Needs Pillow and resvg-py (`pip install pillow resvg-py`). Writes:

- icon.svg and the Linux scalable icon — the editable vector source
- assets/icon/*.png — the inputs to flutter_launcher_icons and
  flutter_native_splash, which then regenerate the platform folders:

      dart run flutter_launcher_icons
      dart run flutter_native_splash:create

- linux/packaging/icons/hicolor/<n>x<n>/apps/dev.icedtea.kumo.png
- android/app/src/main/res/drawable-{xhdpi,xxhdpi}/tv_banner.png
"""

import io
import sys
from pathlib import Path

import resvg_py
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "assets/icon"
FONT = ROOT / "assets/fonts/Roboto-Variable.ttf"

# Sky: one flat colour, no gradient, no shading.
SKY = "#4A8CF7"
CLOUD_FILL = "#FFFFFF"

# The cloud: a pill for its flat base and three bumps on top. Their union is
# centred on (256, 258) and spans x 96..416, y 128..388.
CLOUD = [
    '<rect x="96" y="262" width="320" height="126" rx="63"/>',
    '<circle cx="184" cy="268" r="76"/>',
    '<circle cx="276" cy="226" r="98"/>',
    '<circle cx="352" cy="282" r="64"/>',
]

# The play triangle, cut out of the cloud. Its corners are rounded by stroking
# it in the mask, which grows it by half the stroke.
PLAY = "M234 248 L234 340 L312 294 Z"
PLAY_ROUND = 22


def glyph(scale=1.0, fill=CLOUD_FILL, uid="k"):
    """The mark alone, on a transparent ground, scaled about the centre."""
    shapes = "".join(CLOUD)
    t = f"translate(256 256) scale({scale}) translate(-256 -256)"
    return (
        f'<defs><mask id="{uid}m" maskUnits="userSpaceOnUse" '
        f'x="0" y="0" width="512" height="512">'
        f'<rect width="512" height="512" fill="#fff"/>'
        f'<path d="{PLAY}" fill="#000" stroke="#000" '
        f'stroke-width="{PLAY_ROUND}" stroke-linejoin="round"/>'
        f"</mask></defs>"
        f'<g transform="{t}"><g mask="url(#{uid}m)" fill="{fill}">'
        f"{shapes}</g></g>"
    )


def svg(body, title=None):
    head = f"<title>{title}</title>" if title else ""
    return (
        '<svg width="512" height="512" viewBox="0 0 512 512" '
        'xmlns="http://www.w3.org/2000/svg" role="img">'
        f"{head}{body}</svg>\n"
    )


def rounded_icon():
    """The everyday icon: the mark on the sky, in a rounded square."""
    return svg(
        f'<rect width="512" height="512" rx="118" fill="{SKY}"/>'
        + glyph(),
        "Kumo app icon",
    )


def square_icon():
    """Full bleed and opaque, for iOS, which applies its own mask."""
    return svg(f'<rect width="512" height="512" fill="{SKY}"/>' + glyph())


def background():
    """The adaptive icon's back layer: the sky alone."""
    return svg(f'<rect width="512" height="512" fill="{SKY}"/>')


def foreground():
    """The adaptive icon's front layer. A launcher shows only the middle
    72/108 of it and may crop to a circle of 66/108, so the mark is drawn
    smaller than on the rounded icon."""
    return svg(glyph(scale=0.66))


def splash():
    """The mark on nothing, for the navy splash; Android 12 masks it to a
    circle covering the middle two thirds, so it sits well inside that."""
    return svg(glyph(scale=0.62))


def render(markup, size):
    png = resvg_py.svg_to_bytes(svg_string=markup, width=size, height=size)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def save(img, path, opaque=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        img = img.convert("RGB")
    img.save(path, optimize=True)
    print("wrote", path.relative_to(ROOT))


def tv_banner(width, height):
    """Android TV's launcher banner: the sky full-bleed, the mark on the left
    and the name beside it. The launcher rounds the corners itself."""
    unit = width / 320
    ground = render(background(), max(width, height)).resize((width, height))
    mark = render(svg(glyph()), round(150 * unit))
    # The cloud spans 304/512 of the rendered square; trim to it.
    bbox = mark.getbbox()
    mark = mark.crop(bbox)

    font = ImageFont.truetype(str(FONT), round(50 * unit))
    font.set_variation_by_axes([700])
    text = "Kumo"
    l, t, r, b = font.getbbox(text)
    gap = round(16 * unit)
    group = mark.width + gap + (r - l)
    x = (width - group) // 2
    ground.alpha_composite(mark, (x, (height - mark.height) // 2))
    d = ImageDraw.Draw(ground)
    tx = x + mark.width + gap - l
    ty = (height - (b - t)) // 2 - t
    d.text((tx, ty), text, font=font, fill=CLOUD_FILL)
    return ground


def preview(path):
    """One sheet with every variant, for looking at the design."""
    tiles = [
        render(rounded_icon(), 256),
        render(square_icon(), 256),
        Image.alpha_composite(render(background(), 256), render(foreground(), 256)),
        Image.alpha_composite(
            Image.new("RGBA", (256, 256), "#0C2A4A"), render(splash(), 256)
        ),
    ]
    small = [render(rounded_icon(), n) for n in (16, 24, 32, 48, 64, 128)]
    sheet = Image.new("RGBA", (4 * 276 + 20, 276 + 160 + 360), "#ECEFF4")
    for i, tile in enumerate(tiles):
        sheet.alpha_composite(tile, (20 + i * 276, 20))
    x = 20
    for s in small:
        sheet.alpha_composite(s, (x, 296 + (128 - s.height)))
        x += s.width + 24
    dark = Image.new("RGBA", (sheet.width - x - 20, 128), "#1E1F22")
    sheet.alpha_composite(dark, (x, 296))
    dx = x + 20
    for n in (24, 48, 96):
        s = render(rounded_icon(), n)
        sheet.alpha_composite(s, (dx, 296 + (128 - n) // 2))
        dx += n + 24
    sheet.alpha_composite(tv_banner(480, 270), (20, 460))
    sheet.save(path)
    print("wrote", path)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--preview":
        preview(Path(sys.argv[2]))
        return

    (ROOT / "icon.svg").write_text(rounded_icon(), encoding="utf-8")
    scalable = ROOT / "linux/packaging/icons/hicolor/scalable/apps/dev.icedtea.kumo.svg"
    scalable.write_text(rounded_icon(), encoding="utf-8")

    save(render(rounded_icon(), 1024), ICON / "icon.png")
    save(render(rounded_icon(), 256), ICON / "icon_256.png")
    save(render(square_icon(), 1024), ICON / "icon_ios.png", opaque=True)
    save(render(background(), 1024), ICON / "icon_background.png")
    save(render(foreground(), 1024), ICON / "icon_foreground.png")
    save(render(splash(), 1024), ICON / "splash.png")

    for n in (16, 24, 32, 48, 64, 128, 256, 512):
        save(
            render(rounded_icon(), n),
            ROOT / f"linux/packaging/icons/hicolor/{n}x{n}/apps/dev.icedtea.kumo.png",
        )

    res = ROOT / "android/app/src/main/res"
    save(tv_banner(320, 180), res / "drawable-xhdpi/tv_banner.png", opaque=True)
    save(tv_banner(480, 270), res / "drawable-xxhdpi/tv_banner.png", opaque=True)


if __name__ == "__main__":
    main()
