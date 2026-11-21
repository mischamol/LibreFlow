"""Draws the LibreFlow app icon (1024x1024, opaque) into the asset catalog. Run: python3 tools/make_icon.py"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
K = 4                      # supersampling for smooth edges
W = S * K
OUT = Path(__file__).resolve().parents[1] / "LibreFlow/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    top, bottom = (255, 122, 92), (196, 52, 38)          # app accent colours (--accent dark/light)
    # diagonal gradient, row by row for speed
    grad = Image.new("RGB", (1, 256))
    for i in range(256):
        grad.putpixel((0, i), lerp(top, bottom, i / 255))
    grad = grad.resize((W * 2, W * 2), Image.BICUBIC).rotate(-30, resample=Image.BICUBIC)
    c = W // 2
    return grad.crop((c, c, c + W, c + W))


def flow_points(y0, amp, phase, spike):
    """A smooth running 'flow' line; with spike=True a heartbeat blip in the middle."""
    pts = []
    x0, x1 = 0.10 * W, 0.90 * W
    n = 1200
    for i in range(n + 1):
        t = i / n
        x = x0 + (x1 - x0) * t
        wave = amp * math.sin(2 * math.pi * (t * 1.15 + phase))
        if spike:
            d = t - 0.5
            wave *= 1 - math.exp(-(d / 0.12) ** 2)          # flat baseline around the beat
            wave += -0.22 * W * math.exp(-(d / 0.011) ** 2) + 0.10 * W * math.exp(-((d - 0.028) / 0.011) ** 2)
        y = y0 + wave
        pts.append((x, y))
    return pts


def stroke(draw, pts, width, fill):
    """Round-capped stroke made of densely stamped discs (PIL's wide lines show seams on curves)."""
    r = width / 2
    step = max(1.0, width / 10)
    for (xa, ya), (xb, yb) in zip(pts, pts[1:]):
        n = max(1, int(math.hypot(xb - xa, yb - ya) / step))
        for j in range(n + 1):
            x, y = xa + (xb - xa) * j / n, ya + (yb - ya) * j / n
            draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


img = background()

# soft shadow under the main line
shadow = Image.new("L", (W, W), 0)
stroke(ImageDraw.Draw(shadow), [(x, y + 0.012 * W) for x, y in flow_points(0.58 * W, 0.045 * W, 0.0, True)],
       int(0.055 * W), 90)
shadow = shadow.filter(ImageFilter.GaussianBlur(0.02 * W))
img.paste((120, 25, 15), mask=shadow)

layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
stroke(d, flow_points(0.22 * W, 0.035 * W, 0.15, False), int(0.035 * W), (255, 255, 255, 80))
stroke(d, flow_points(0.82 * W, 0.035 * W, 0.40, False), int(0.035 * W), (255, 255, 255, 80))
stroke(d, flow_points(0.58 * W, 0.045 * W, 0.0, True), int(0.055 * W), (255, 255, 255, 255))
img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")

OUT.parent.mkdir(parents=True, exist_ok=True)
img.resize((S, S), Image.LANCZOS).save(OUT)
print(OUT)
