"""Check visible color regions in the public two-color artwork fixture."""
import colorsys
import json
import sys
from pathlib import Path

from PIL import Image


def inspect(path):
    image = Image.open(path).convert("RGB")
    field = image.crop((round(image.width * .05), round(image.height * .2),
                        round(image.width * .95), round(image.height * .75)))
    blue = orange = vivid = 0
    count = field.width * field.height
    for rgb in field.getdata():
        hue, saturation, value = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
        if saturation < .55 or value < .2:
            continue
        vivid += 1
        blue += 195 <= hue * 360 <= 250
        orange += 10 <= hue * 360 <= 45
    return {"blueArea": blue / count, "orangeArea": orange / count,
            "vividArea": vivid / count}


rows = []
for surface in ("fullscreen", "card"):
    measurements = inspect(Path(sys.argv[1]) / f"{surface}-color-backdrop.png")
    rows.append({"name": f"{surface}: both cover hues occupy vivid, substantial regions",
                 **measurements,
                 "passed": measurements["blueArea"] >= .15 and
                 measurements["orangeArea"] >= .15 and measurements["vividArea"] >= .6})
print(json.dumps(rows, indent=2))
sys.exit(0 if all(row["passed"] for row in rows) else 1)
