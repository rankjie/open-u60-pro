#!/usr/bin/env python3
"""Build a local gallery from the pinned firmware's real LVGL pixel output."""
import argparse
from pathlib import Path
import struct
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 320, 480


def png(path, rgb):
    def chunk(kind, value):
        body = kind + value
        return struct.pack(">I", len(value)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    rows = b"".join(b"\0" + rgb[y * WIDTH * 3:(y + 1) * WIDTH * 3] for y in range(HEIGHT))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" +
                     chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)) +
                     chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--factory-home", type=Path,
                        help="An explicitly inspected, credential-free 320x480 P6 Home capture")
    args = parser.parse_args()
    subprocess.run(["sh", "native/wifi-ui/test-native-panel.sh"], cwd=ROOT, check=True)
    subprocess.run(["sh", "native/wifi-ui/test-native-calls.sh"], cwd=ROOT, check=True)
    output = ROOT / "target/wifi-ui/preview"
    output.mkdir(parents=True, exist_ok=True)
    factory = None
    if args.factory_home:
        header, factory = args.factory_home.read_bytes().split(b"\n255\n", 1)
        if header != b"P6\n320 480" or len(factory) != WIDTH * HEIGHT * 3:
            raise ValueError("The factory reference must be a complete 320x480 P6 frame")
        png(output / "factory.png", factory)
    for name in ("home", "lock", "menu", "panel", "confirmation", "keyboard", "connection", "calls", "help", "call-home"):
        probe = "native-calls-probe" if name in ("calls", "help", "call-home") else "native-panel-probe"
        raw = (ROOT / f"target/wifi-ui/{probe}/{name}.rgb565").read_bytes()
        pixels = struct.unpack("<153600H", raw)
        rgb = bytearray()
        for pixel in pixels:
            rgb.extend(((pixel >> 11) * 255 // 31, ((pixel >> 5) & 63) * 255 // 63, (pixel & 31) * 255 // 31))
        if factory:
            # The extension deliberately leaves these factory-owned areas in
            # place. Use only the previously inspected public Home reference.
            rgb[:WIDTH * 24 * 3] = factory[:WIDTH * 24 * 3]
            if name == "home":
                for y in range(459, 475):
                    start, end = (y * WIDTH + 144) * 3, (y * WIDTH + 176) * 3
                    rgb[start:end] = factory[start:end]
        else:
            rgb[:WIDTH * 24 * 3] = bytes(WIDTH * 24 * 3)
        png(output / f"{name}.png", rgb)
    template = (ROOT / "native/wifi-ui/preview.html").read_text()
    (output / "index.html").write_text(template.replace("__HAS_FACTORY__", "true" if factory else "false"))
    print(output / "index.html")


if __name__ == "__main__":
    main()
