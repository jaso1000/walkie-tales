"""Draw every WalkieTales icon from one design: the little player character with happy eyes, standing on headphone-cup
feet (cable legs), on the app's purple.

    python tools/make-icons.py

Writes docs/icon/walkietales-icon.svg (the master), the logo (docs/icon/walkietales-logo-*.svg and
docs/images/logo-light.png / logo-dark.png), the iPhone app icon, the remote's web/home-screen icons and
docs/images/icon.png. The Android launcher icon is a vector drawing of the same shapes in res/drawable/ic_launcher_fg.xml
(edit both together). PNGs are rendered with Playwright + Microsoft Edge (pip install playwright).
After changing the icon, bump the "?v=" on the icon links in companion/web/index.html and manifest.json, so phones
fetch the new picture instead of one they kept (Safari keeps a home-screen icon for a long time).
"""
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PURPLE, NAVY, YELLOW, PINK, CHEEK = "#6C4CF1", "#2B2250", "#FFD166", "#FF6B8A", "#FF8FA3"

# The character on a 120 x 120 grid. Its outline spans x 33-87, y 11-109; its centre is (60, 60).
FACE = f"""<g transform="translate(40 17) scale({40 / 52:.5f})">
    <rect width="52" height="52" rx="12" fill="{YELLOW}"/>
    <path d="M13 24 Q18 17 23 24" stroke="{NAVY}" stroke-width="3.5" fill="none" stroke-linecap="round"/>
    <path d="M29 24 Q34 17 39 24" stroke="{NAVY}" stroke-width="3.5" fill="none" stroke-linecap="round"/>
    <path d="M15 32 Q26 43 37 32" stroke="{NAVY}" stroke-width="4" fill="none" stroke-linecap="round"/>
    <circle cx="11" cy="31" r="3.5" fill="{CHEEK}"/>
    <circle cx="41" cy="31" r="3.5" fill="{CHEEK}"/>
  </g>"""
ART = f"""<path d="M50 86 L46 100" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round"/>
  <path d="M70 86 L74 100" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round"/>
  <rect x="33" y="98" width="20" height="11" rx="5.5" fill="{PINK}"/>
  <rect x="67" y="98" width="20" height="11" rx="5.5" fill="{PINK}"/>
  <rect x="34" y="11" width="52" height="77" rx="12" fill="{NAVY}"/>
  {FACE}
  <rect x="41" y="63" width="38" height="4" rx="2" fill="#FFFFFF" fill-opacity="0.35"/>
  <rect x="41" y="63" width="22" height="4" rx="2" fill="#FFFFFF"/>
  <circle cx="60" cy="77" r="6.5" fill="#FFFFFF"/>
  <path d="M58 73.5 L64 77 L58 80.5 Z" fill="{NAVY}"/>"""


def svg(rounded=True, scale=1.0, background=True):
    """The icon as SVG. scale shrinks the character about the centre (for icons that get cropped)."""
    bg = f'<rect width="120" height="120" rx="{28 if rounded else 0}" fill="{PURPLE}"/>' if background else ""
    t = f"translate({60 - 60 * scale:.3f} {60 - 60 * scale:.3f}) scale({scale})"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="120" height="120">'
            f'{bg}<g transform="{t}">{ART}</g></svg>')


def logo(dark):
    """Logo: the character standing on the name, lettered like the WalkerLab lockup (Segoe UI Bold, two-tone name, spaced
    grey tagline). Transparent background; dark=True for dark pages (white name and legs)."""
    art = ART if dark else ART.replace('stroke="#FFFFFF" stroke-width="3.5"', f'stroke="{NAVY}" stroke-width="3.5"')
    name, accent, tag = ("#FFFFFF", "#B9A6FF", "#9A96AE") if dark else (NAVY, PURPLE, "#8A879A")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 300" width="520" height="300">'
            f'<g transform="translate(165 -12) scale({190 / 120:.4f})">{art}</g>'
            f'<text x="260" y="236" text-anchor="middle" font-family="Segoe UI, system-ui, sans-serif" font-weight="700" '
            f'font-size="64" letter-spacing="-1" fill="{name}">Walkie<tspan fill="{accent}">Tales</tspan></text>'
            f'<text x="260" y="276" text-anchor="middle" font-family="Segoe UI, system-ui, sans-serif" font-weight="600" '
            f'font-size="15" letter-spacing="3" fill="{tag}">MUSIC AND STORIES FOR LITTLE HANDS</text></svg>')


def main():
    from playwright.sync_api import sync_playwright
    os.makedirs(os.path.join(ROOT, "docs", "icon"), exist_ok=True)
    with open(os.path.join(ROOT, "docs", "icon", "walkietales-icon.svg"), "w", encoding="utf-8") as f:
        f.write(svg())
    web = os.path.join(ROOT, "companion", "web")
    jobs = [  # (file, size, svg, transparent corners)
        (os.path.join(ROOT, "ios", "WalkieTales", "Resources", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
         1024, svg(rounded=False, scale=0.92), False),          # iOS rounds the corners itself; no transparency allowed
        (os.path.join(web, "icon-512.png"), 512, svg(rounded=False, scale=0.92), False),
        (os.path.join(web, "icon-192.png"), 192, svg(rounded=False, scale=0.92), False),
        (os.path.join(web, "icon-maskable-512.png"), 512, svg(rounded=False, scale=0.72), False),  # Android crops to a circle
        (os.path.join(web, "apple-touch-icon.png"), 180, svg(rounded=False, scale=0.92), False),
        (os.path.join(web, "favicon.png"), 64, svg(rounded=True, scale=1.0), True),
        (os.path.join(ROOT, "docs", "images", "icon.png"), 512, svg(rounded=True, scale=1.0), True),
    ]
    for dark in (False, True):
        with open(os.path.join(ROOT, "docs", "icon", f"walkietales-logo-{'dark' if dark else 'light'}.svg"), "w", encoding="utf-8") as f:
            f.write(logo(dark))
    with sync_playwright() as p:
        b = p.chromium.launch(channel="msedge")
        for dark in (False, True):  # the logo, at twice size, on a transparent background
            page = b.new_page(viewport={"width": 1040, "height": 600})
            page.set_content(f'<html><body style="margin:0;background:transparent">'
                             f'{logo(dark).replace("width=\"520\" height=\"300\"", "width=\"1040\" height=\"600\"", 1)}</body></html>')
            out = os.path.join(ROOT, "docs", "images", f"logo-{'dark' if dark else 'light'}.png")
            page.screenshot(path=out, omit_background=True, clip={"x": 0, "y": 0, "width": 1040, "height": 600})
            page.close()
            print("wrote", os.path.relpath(out, ROOT))
        for path, size, code, clear in jobs:
            page = b.new_page(viewport={"width": size, "height": size})
            page.set_content(f'<html><body style="margin:0;background:transparent">'
                             f'{code.replace("width=\"120\" height=\"120\"", f"width=\"{size}\" height=\"{size}\"", 1)}</body></html>')  # the outer size only
            page.screenshot(path=path, omit_background=clear, clip={"x": 0, "y": 0, "width": size, "height": size})
            page.close()
            print("wrote", os.path.relpath(path, ROOT))
        b.close()


if __name__ == "__main__":
    main()
