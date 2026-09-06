"""Rendered pixels, independent of animation API or background implementation."""
import colorsys
import json
import sys
from pathlib import Path

from PIL import Image


root = Path(sys.argv[1])
flow_names = sorted((path.stem for path in root.glob("flow-*.png")), key=lambda name: int(name.split("-")[1]))
assert all(name in flow_names for name in ("flow-0", "flow-4", "flow-8")), "Missing required motion captures"
images = {name: Image.open(root / f"{name}.png").convert("RGB")
          for name in flow_names + ["paused-0", "paused-1"]}


def pixels(image):
    return image.get_flattened_data()


def changed(first, second):
    count = sum(max(abs(a - b) for a, b in zip(left, right)) > 8
                for left, right in zip(pixels(first), pixels(second)))
    return count / (first.width * first.height)


rows = []
for name in flow_names[1:]:
    fraction = changed(images["flow-0"], images[name])
    rows.append({"name": f"{name}: internal color flow while outer surface is fixed",
                 "changedFraction": fraction, "passed": fraction >= .10})
    areas = dict(red=0, blue=0, gold=0, green=0)
    for rgb in pixels(images[name]):
        hue, saturation, value = colorsys.rgb_to_hsv(*(c / 255 for c in rgb))
        hue *= 360
        if saturation < .55 or value < .15:
            continue
        areas["red"] += hue < 15 or hue > 345
        areas["blue"] += 200 <= hue <= 255
        areas["gold"] += 30 <= hue <= 65
        areas["green"] += 115 <= hue <= 180
    areas = {key: count / (images[name].width * images[name].height) for key, count in areas.items()}
    rows.append({"name": f"{name}: all source hues survive the flow",
                 "areas": areas, "passed": min(areas.values()) >= .08})
fraction = changed(images["paused-0"], images["paused-1"])
rows.append({"name": "pausing playback freezes the rendered gradient",
             "changedFraction": fraction, "passed": fraction == 0})
print(json.dumps(rows, indent=2))
sys.exit(0 if all(row["passed"] for row in rows) else 1)
