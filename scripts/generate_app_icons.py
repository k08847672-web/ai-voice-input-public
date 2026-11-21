#!/usr/bin/env python3
"""Generate the original VoiceInput macOS icon using only the Python standard library."""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
CANVAS = 1024

SLOTS = {
    "icon-16.png": 16,
    "icon-16@2x.png": 32,
    "icon-32.png": 32,
    "icon-32@2x.png": 64,
    "icon-128.png": 128,
    "icon-128@2x.png": 256,
    "icon-256.png": 256,
    "icon-256@2x.png": 512,
    "icon-512.png": 512,
    "icon-512@2x.png": 1024,
    "icon-ios-1024.png": 1024,
}


def clamp(value: float, low: float = 0, high: float = 1) -> float:
    return max(low, min(high, value))


def smooth_alpha(distance: float, feather: float = 1.25) -> float:
    return clamp(0.5 - distance / feather)


def rounded_box_distance(x: float, y: float, center: tuple[float, float], size: tuple[float, float], radius: float) -> float:
    dx = abs(x - center[0]) - size[0] / 2 + radius
    dy = abs(y - center[1]) - size[1] / 2 + radius
    outside = math.hypot(max(dx, 0), max(dy, 0))
    inside = min(max(dx, dy), 0)
    return outside + inside - radius


def blend(pixel: tuple[int, int, int, int], color: tuple[int, int, int], alpha: float) -> tuple[int, int, int, int]:
    source_alpha = clamp(alpha)
    destination_alpha = pixel[3] / 255
    output_alpha = source_alpha + destination_alpha * (1 - source_alpha)
    if output_alpha <= 0:
        return (0, 0, 0, 0)
    channels = []
    for index in range(3):
        value = (color[index] * source_alpha + pixel[index] * destination_alpha * (1 - source_alpha)) / output_alpha
        channels.append(round(value))
    return (*channels, round(output_alpha * 255))


def render() -> bytearray:
    pixels = bytearray(CANVAS * CANVAS * 4)
    for y in range(CANVAS):
        vertical = y / (CANVAS - 1)
        for x in range(CANVAS):
            horizontal = x / (CANVAS - 1)
            offset = (y * CANVAS + x) * 4
            distance = rounded_box_distance(x + 0.5, y + 0.5, (512, 512), (928, 928), 218)
            shape_alpha = smooth_alpha(distance)
            if shape_alpha <= 0:
                continue

            glow = clamp(1 - math.hypot(x - 720, y - 260) / 760)
            red = round(41 + 8 * horizontal + 5 * glow)
            green = round(50 + 78 * horizontal + 16 * glow)
            blue = round(124 + 86 * (1 - vertical) + 24 * glow)
            pixels[offset : offset + 4] = bytes((red, green, blue, round(255 * shape_alpha)))

    bars = [172, 294, 404, 520, 404, 294, 172]
    centers = [270, 350, 430, 510, 590, 670, 750]
    for center_x, height in zip(centers, bars):
        width = 48
        radius = width / 2
        for y in range(max(0, round(512 - height / 2 - 2)), min(CANVAS, round(512 + height / 2 + 2))):
            for x in range(round(center_x - width / 2 - 2), round(center_x + width / 2 + 2)):
                distance = rounded_box_distance(x + 0.5, y + 0.5, (center_x, 512), (width, height), radius)
                alpha = smooth_alpha(distance)
                if alpha <= 0:
                    continue
                offset = (y * CANVAS + x) * 4
                current = tuple(pixels[offset : offset + 4])
                pixels[offset : offset + 4] = bytes(blend(current, (250, 252, 255), alpha * 0.96))

    # A warm text cursor distinguishes voice-to-text from a generic audio recorder.
    cursor_center = (820, 512)
    for y in range(322, 702):
        for x in range(795, 845):
            distance = rounded_box_distance(x + 0.5, y + 0.5, cursor_center, (34, 356), 17)
            alpha = smooth_alpha(distance)
            if alpha <= 0:
                continue
            offset = (y * CANVAS + x) * 4
            current = tuple(pixels[offset : offset + 4])
            pixels[offset : offset + 4] = bytes(blend(current, (255, 190, 68), alpha))
    return pixels


def resize_box(source: bytearray, target_size: int) -> bytearray:
    if target_size == CANVAS:
        return source
    scale = CANVAS / target_size
    target = bytearray(target_size * target_size * 4)
    for target_y in range(target_size):
        y0 = round(target_y * scale)
        y1 = round((target_y + 1) * scale)
        for target_x in range(target_size):
            x0 = round(target_x * scale)
            x1 = round((target_x + 1) * scale)
            count = max(1, (x1 - x0) * (y1 - y0))
            channels = [0, 0, 0, 0]
            for source_y in range(y0, y1):
                for source_x in range(x0, x1):
                    offset = (source_y * CANVAS + source_x) * 4
                    for channel in range(4):
                        channels[channel] += source[offset + channel]
            output = (target_y * target_size + target_x) * 4
            target[output : output + 4] = bytes(round(value / count) for value in channels)
    return target


def png_chunk(name: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))


def flatten_rgb(source: bytearray, background: tuple[int, int, int]) -> bytearray:
    result = bytearray(CANVAS * CANVAS * 3)
    for index in range(CANVAS * CANVAS):
        source_offset = index * 4
        target_offset = index * 3
        alpha = source[source_offset + 3] / 255
        for channel in range(3):
            result[target_offset + channel] = round(
                source[source_offset + channel] * alpha + background[channel] * (1 - alpha)
            )
    return result


def write_png(path: Path, width: int, height: int, pixels: bytearray, channels: int = 4) -> None:
    rows = bytearray()
    row_bytes = width * channels
    for y in range(height):
        rows.append(0)
        start = y * row_bytes
        rows.extend(pixels[start : start + row_bytes])
    color_type = 6 if channels == 4 else 2
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    payload = b"\x89PNG\r\n\x1a\n"
    payload += png_chunk(b"IHDR", header)
    payload += png_chunk(b"IDAT", zlib.compress(bytes(rows), level=9))
    payload += png_chunk(b"IEND", b"")
    path.write_bytes(payload)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = render()
    ios_source = flatten_rgb(source, background=(41, 50, 124))
    cache: dict[int, bytearray] = {CANVAS: source}
    for name, size in SLOTS.items():
        if name == "icon-ios-1024.png":
            write_png(OUTPUT / name, CANVAS, CANVAS, ios_source, channels=3)
            print(f"generated {name} ({CANVAS}x{CANVAS})")
            continue
        pixels = cache.setdefault(size, resize_box(source, size))
        write_png(OUTPUT / name, size, size, pixels)
        print(f"generated {name} ({size}x{size})")


if __name__ == "__main__":
    main()
