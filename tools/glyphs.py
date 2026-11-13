"""Rasterise JetBrains Mono into the kernel's 8x16 console font: printable ASCII, 16 bytes per glyph, top row first.

Usage: py tools/glyphs.py (needs Pillow; writes src/debug/glyphs.bin)
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH = 8
HEIGHT = 16

project = Path(__file__).resolve().parent.parent
face = ImageFont.truetype(str(project / "src/gui/fonts/JetBrainsMono-Regular.ttf"), 13)
output = bytearray()

for code in range(32, 127):
    image = Image.new("L", (WIDTH, HEIGHT), 0)
    ImageDraw.Draw(image).text((0, 12), chr(code), font=face, fill=255, anchor="ls")
    for y in range(HEIGHT):
        row = 0
        for x in range(WIDTH):
            if image.getpixel((x, y)) >= 72:
                row |= 0x80 >> x
        output.append(row)

(project / "src/debug/glyphs.bin").write_bytes(output)
