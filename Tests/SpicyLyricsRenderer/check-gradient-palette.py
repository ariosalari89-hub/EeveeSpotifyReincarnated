"""Independent rendered-area oracle for four source-artwork hue families."""
import colorsys
import json
import sys
from pathlib import Path

from PIL import Image


rows = []
for surface in ("fullscreen", "card"):
    image = Image.open(Path(sys.argv[1]) / f"{surface}-multicolor-backdrop.png").convert("RGB")
    areas = dict(red=0, blue=0, gold=0, green=0)
    for rgb in image.getdata():
        hue, saturation, value = colorsys.rgb_to_hsv(*(channel / 255 for channel in rgb))
        hue *= 360
        if saturation < .55 or value < .15:
            continue
        areas["red"] += hue < 15 or hue > 345
        areas["blue"] += 200 <= hue <= 255
        areas["gold"] += 30 <= hue <= 65
        areas["green"] += 115 <= hue <= 180
    areas = {key: count / (image.width * image.height) for key, count in areas.items()}
    rows.append({"name": f"{surface}: all four source hues remain visible as broad regions",
                 "areas": areas, "passed": min(areas.values()) >= .08})
print(json.dumps(rows, indent=2))
sys.exit(0 if all(row["passed"] for row in rows) else 1)
