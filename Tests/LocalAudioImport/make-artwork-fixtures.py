"""Rebuild tiny, synthetic embedded-art audio fixtures; no downloaded music/art."""
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib

fixtures = pathlib.Path(__file__).resolve().parent / "Fixtures"


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


pixels = b"".join(b"\0" + bytes([224, 40, 48]) * 16 + bytes([40, 80, 224]) * 16 for _ in range(32))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
with tempfile.TemporaryDirectory(prefix="local-art-fixtures-") as work:
    cover = pathlib.Path(work) / "cover.png"
    cover.write_bytes(png)
    for extension, codec in [("mp3", "copy"), ("m4a", "aac")]:
        subprocess.run([
            sys.argv[1], "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(fixtures / "synthetic-tone.mp3"), "-i", str(cover),
            "-map", "0:a", "-map", "1:v", "-c:a", codec, "-c:v", "copy",
            "-disposition:v", "attached_pic", "-metadata", "title=Midnight Library",
            "-metadata", "artist=A/B + 音", "-metadata", "album=Windows: Summer",
            "-metadata:s:v", "title=Cover", "-metadata:s:v", "comment=Cover (front)",
            str(fixtures / ("embedded-art." + extension)),
        ], check=True)
        print("Created", "embedded-art." + extension)

# Actual ID3 APIC containers with unusable artwork exercise metadata decoding,
# rather than passing raw image bytes straight into an internal image helper.
audio = (fixtures / "synthetic-tone.mp3").read_bytes()
if audio[:3] == b"ID3":
    tag_size = sum(value << (7 * (3 - index)) for index, value in enumerate(audio[6:10]))
    audio = audio[10 + tag_size:]
wide_png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 20_000, 1, 8, 2, 0, 0, 0))
wide_png += chunk(b"IDAT", zlib.compress(b"\0" + bytes([224, 40, 48]) * 20_000)) + chunk(b"IEND", b"")
for name, picture in [("embedded-corrupt.mp3", b"not an image"), ("embedded-oversize.mp3", wide_png)]:
    payload = b"\0image/png\0\x03\0" + picture
    frame = b"APIC" + struct.pack(">I", len(payload)) + b"\0\0" + payload
    size = bytes((len(frame) >> shift) & 127 for shift in (21, 14, 7, 0))
    (fixtures / name).write_bytes(b"ID3\x03\0\0" + size + frame + audio)
    print("Created", name)
