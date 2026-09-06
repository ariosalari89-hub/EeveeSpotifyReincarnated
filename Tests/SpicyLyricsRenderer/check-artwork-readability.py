"""Compare computed ink with independently captured composited background pixels.

The PC-style inactive fade is reported, not represented as WCAG conformance.
Increase Contrast's quiet text and ordinary metadata retain explicit gates.
"""
import json
import math
import re
import sys
from pathlib import Path

from PIL import Image


def luminance(rgb):
    values = [value / 255 for value in rgb]
    linear = [value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4 for value in values]
    return sum(value * weight for value, weight in zip(linear, (.2126, .7152, .0722)))


def contrast(image, viewport, rect, rgb, alpha):
    sx, sy = image.width / viewport['width'], image.height / viewport['height']
    left, top = max(0, math.floor(rect['x'] * sx)), max(0, math.floor(rect['y'] * sy))
    right = min(image.width, math.ceil((rect['x'] + rect['width']) * sx))
    bottom = min(image.height, math.ceil((rect['y'] + rect['height']) * sy))
    if right <= left or bottom <= top:
        return None
    pixels = image.load()
    smallest = float('inf')
    for y in range(top, bottom):
        for x in range(left, right):
            background = pixels[x, y]
            foreground = [value * alpha + behind * (1 - alpha) for value, behind in zip(rgb, background)]
            first, second = luminance(foreground), luminance(background)
            smallest = min(smallest, (max(first, second) + .05) / (min(first, second) + .05))
    return smallest


root = Path(sys.argv[1])
results = []
for sample in json.loads((root / 'paint.json').read_text(encoding='utf-8-sig')):
    with Image.open(root / f"{sample['surface']}-{sample['sample']}-readability.png") as source:
        image = source.convert('RGB')
        values = {}
        for label in sample['labels']:
            color = [float(value) for value in re.findall(r'[\d.]+', label['color'])]
            ratio = contrast(image, sample['viewport'], label['rect'], color[:3], color[3] if len(color) == 4 else 1)
            if ratio is not None:
                values[label['selector']] = ratio
        active = sample['activeInk']
        active_ratio = contrast(image, sample['viewport'], active['rect'], [255] * 3, active['brightAlpha'])
        quiet = sample['quietInk']
        quiet_ratio = contrast(image, sample['viewport'], quiet['rect'], [255] * 3, quiet['quietAlpha']) if quiet else None
        active_target = 3.5 if active['fontSize'] >= 24 else 5
        quiet_target = 3.5 if quiet and quiet['fontSize'] >= 24 else 5
        passed = all(value >= 5 for value in values.values()) and active_ratio >= active_target
        if sample['sample'] == 'contrast':
            passed = passed and quiet_ratio is not None and quiet_ratio >= quiet_target
        results.append({'surface': sample['surface'], 'sample': sample['sample'], 'metadata': values,
                        'brightTimedText': active_ratio, 'quietText': quiet_ratio, 'pass': passed})
print(json.dumps({'result': 'PASS' if all(row['pass'] for row in results) else 'FAIL', 'samples': results,
                  'scope': 'Metadata and bright timed text; quiet text gated with Increase Contrast. Default PC quiet fade is not an AA claim.'}, indent=2))
sys.exit(0 if all(row['pass'] for row in results) else 1)
