"""Measure conservative text contrast against an actual browser background PNG."""
import json
import sys

from PIL import Image


def luminance(rgb):
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
              for v in (c / 255 for c in rgb)]
    return sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))


styles = json.loads(sys.argv[2])
with Image.open(sys.argv[1]) as image:
    # Independent of the CSS gradient syntax/stop count. Per-channel maxima
    # conservatively bound every painted pixel, even if they occur apart.
    background = [extreme[1] for extreme in image.convert("RGB").getextrema()]
ratios = {}
for name, color in styles["colors"].items():
    opacity = color[3] if len(color) > 3 else 1
    foreground = [c * opacity + b * (1 - opacity) for c, b in zip(color, background)]
    ratios[name] = (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
print(json.dumps({"maximumBackground": background, "ratios": ratios,
    "opaqueLines": styles["opaqueLines"],
    "pass": styles["opaqueLines"] and ratios["inactive"] >= 3.5
            and ratios["artist"] >= 5 and ratios["timeline"] >= 5}))
