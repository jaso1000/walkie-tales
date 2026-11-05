"""Draw the WalkieTales app icons for the remote web app: python tools/make-web-icons.py companion/web"""
import os
import sys

from PIL import Image, ImageDraw

out = sys.argv[1]
SS = 4  # supersampling


def draw(size, scale_art=1.0, rounded=False):
    S = size * SS
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    # background: soft vertical purple gradient
    top, bot = (0x84, 0x66, 0xFF), (0x57, 0x37, 0xDE)
    grad = Image.new('RGBA', (1, S))
    for y in range(S):
        t = y / (S - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    grad = grad.resize((S, S))
    mask = Image.new('L', (S, S), 0)
    md = ImageDraw.Draw(mask)
    if rounded:
        md.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
    else:
        md.rectangle([0, 0, S, S], fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # artwork is laid out on the launcher's 108-unit grid, centred and scaled
    k = S / 108 * scale_art
    off = (S - 108 * k) / 2

    def P(x, y):
        return (off + x * k, off + y * k)

    # soft shadow under the card
    sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([*P(31, 28.5), *P(79, 84.5)], radius=6 * k, fill=(30, 10, 90, 90))
    from PIL import ImageFilter
    sh = sh.filter(ImageFilter.GaussianBlur(2.2 * k))
    img.alpha_composite(sh)
    d = ImageDraw.Draw(img)
    # the card
    d.rounded_rectangle([*P(30, 26), *P(78, 82)], radius=6 * k, fill=(255, 255, 255, 255))
    # the note (Material "music note", translated 36,35 and scaled 1.5 like the launcher)
    note = (0x6C, 0x4C, 0xF1, 255)

    def N(x, y):
        return P(36 + 1.5 * x, 35 + 1.5 * y)

    d.rectangle([*N(12, 3), *N(14, 17)], fill=note)      # stem
    d.rectangle([*N(12, 3), *N(18, 7)], fill=note)       # flag
    cx, cy = N(10, 17)
    r = 4 * 1.5 * k
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=note)  # head
    return img.resize((size, size), Image.LANCZOS)


os.makedirs(out, exist_ok=True)
draw(512, 1.3).save(os.path.join(out, 'icon-512.png'))
draw(192, 1.3).save(os.path.join(out, 'icon-192.png'))
draw(512, scale_art=1.12).save(os.path.join(out, 'icon-maskable-512.png'))  # Android crops these to circles/squircles
draw(180, 1.3).convert('RGB').save(os.path.join(out, 'apple-touch-icon.png'))   # iOS rounds the corners itself
draw(64, 1.35, rounded=True).save(os.path.join(out, 'favicon.png'))
print('icons written to', out)
