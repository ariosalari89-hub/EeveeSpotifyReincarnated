"""Compare actual backdrop captures and conservative text contrast, not CSS syntax."""
import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageStat


def luminance(rgb):
    values = [c / 255 for c in rgb]
    linear = [c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in values]
    return sum(c * w for c, w in zip(linear, (.2126, .7152, .0722)))


def contrast(background, color):
    alpha = color[3] if len(color) > 3 else 1
    foreground = [c * alpha + b * (1 - alpha) for c, b in zip(color, background)]
    return (luminance(foreground) + .05) / (luminance(background) + .05)


before, after = map(Path, sys.argv[1:3])
rows = []
for surface in ('fullscreen', 'card'):
    old = Image.open(before / f'{surface}-color-readability.png').convert('RGB')
    new = Image.open(after / f'{surface}-color-readability.png').convert('RGB')
    crop = (0, int(new.height * .4), new.width, int(new.height * .55))
    old_mean = sum(ImageStat.Stat(old.crop(crop)).mean) / 3
    new_mean = sum(ImageStat.Stat(new.crop(crop)).mean) / 3
    rows.append(dict(name=f'{surface}: central artwork pixels are materially brighter',
                     before=old_mean, after=new_mean, ratio=new_mean / old_mean,
                     passed=new_mean / old_mean >= 1.35))
    edge = Image.open(after / f'{surface}-color-backdrop.png').convert('RGB')
    y = edge.height // 2
    left, right = edge.getpixel((edge.width // 4, y))[0], edge.getpixel((edge.width * 3 // 4, y))[0]
    progress = [(edge.getpixel((x, y))[0] - left) / (right - left) for x in range(edge.width)]
    lo = next(x for x, value in enumerate(progress) if value >= .1)
    hi = next(x for x, value in enumerate(progress) if value >= .9)
    rows.append(dict(name=f'{surface}: cover edge keeps visible detail', edgeWidthPx=hi-lo, passed=hi-lo <= 9))
    bright = Image.open(after / f'{surface}-contrast-backdrop.png').convert('RGB')
    maximum = [pair[1] for pair in bright.getextrema()]
    ratio = contrast(maximum, [255, 255, 255, .85])
    rows.append(dict(name=f'{surface}: Increase Contrast retains small quiet-text contrast',
                     background=maximum, ratio=ratio, passed=ratio >= 5))

for sample in json.loads((after / 'paint.json').read_text(encoding='utf-8-sig')):
    if sample['surface'] != 'fullscreen' or sample['sample'] != 'white':
        continue
    picture = Image.open(after / 'fullscreen-white-readability.png').convert('RGB')
    for label in sample['labels']:
        r = label['rect']
        if not r['width'] or not r['height']:
            continue
        crop = (max(0, int(r['x'])), max(0, int(r['y'])),
                min(picture.width, int(r['x'] + r['width'] + 1)),
                min(picture.height, int(r['y'] + r['height'] + 1)))
        maximum = [pair[1] for pair in picture.crop(crop).getextrema()]
        color = list(map(float, re.findall(r'[\d.]+', label['color'])))
        ratio = contrast(maximum, color)
        rows.append(dict(name=f"Default white artwork: {label['selector']} contrast",
                         background=maximum, ratio=ratio, passed=ratio >= 4.5))
    r = sample['active']
    crop = (max(0, int(r['x'])), max(0, int(r['y'])),
            min(picture.width, int(r['x']+r['width'])), min(picture.height, int(r['y']+r['height'])))
    maximum = [pair[1] for pair in picture.crop(crop).getextrema()]
    ratio = contrast(maximum, [255, 255, 255, .85])
    rows.append(dict(name='Default white artwork: active large lyric contrast', background=maximum, ratio=ratio, passed=ratio >= 3))

print(json.dumps(rows, indent=2))
sys.exit(0 if all(row['passed'] for row in rows) else 1)
