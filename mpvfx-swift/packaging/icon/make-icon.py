#!/usr/bin/env python3
#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
"""Draw the MpVFX app icon with the standard library only and write the files the installers use.

Run from mpvfx-swift/:  python3 packaging/icon/make-icon.py
Writes packaging/icon/mpvfx-<size>.png (16 to 1024) and packaging/icon/mpvfx.ico (PNG-compressed entries).
The shape: the studio-accent blue rounded square (macOS icon grid: 824 of 1024, radius 185) with a white
play triangle and a mint keyframe diamond (ThemeTokens.studioAccent and ThemeTokens.mint).
"""
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
N = 1024
TOP, BOTTOM = (0x3A, 0x8B, 0xFF), (0x16, 0x46, 0xB8)
MINT = (0x3C, 0xE6, 0xAC)
SIZES = [16, 24, 32, 48, 64, 128, 256, 512, 1024]


def rounded_box(px, py, cx, cy, half, radius):
    qx, qy = abs(px - cx) - (half - radius), abs(py - cy) - (half - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def triangle(px, py, a, b, c):
    """Signed distance to triangle abc (negative inside)."""
    d = float("inf")
    sign = 1.0
    for (x0, y0), (x1, y1) in ((a, b), (b, c), (c, a)):
        ex, ey = x1 - x0, y1 - y0
        wx, wy = px - x0, py - y0
        t = max(0.0, min(1.0, (wx * ex + wy * ey) / (ex * ex + ey * ey)))
        d = min(d, math.hypot(wx - ex * t, wy - ey * t))
    cross = [(b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0]),
             (c[0] - b[0]) * (py - b[1]) - (c[1] - b[1]) * (px - b[0]),
             (a[0] - c[0]) * (py - c[1]) - (a[1] - c[1]) * (px - c[0])]
    if all(v >= 0 for v in cross) or all(v <= 0 for v in cross):
        sign = -1.0
    return sign * d


def coverage(dist):
    return max(0.0, min(1.0, 0.5 - dist))


def over(dst, rgb, alpha):
    r, g, b, a = dst
    out_a = alpha + a * (1 - alpha)
    if out_a == 0:
        return (0.0, 0.0, 0.0, 0.0)
    mix = lambda s, d: (s * alpha + d * a * (1 - alpha)) / out_a
    return (mix(rgb[0], r), mix(rgb[1], g), mix(rgb[2], b), out_a)


def render(size):
    """Draw at `size` pixels; shapes are laid out on the 1024 grid and distances scaled to pixels."""
    k = size / N
    tri_r = 40.0   # corner rounding of the play triangle
    a, b, c = (392 + tri_r, 300 + tri_r * 0.8), (392 + tri_r, 724 - tri_r * 0.8), (740 - tri_r, 512)
    pixels = []
    for y in range(size):
        gy = (y + 0.5) / k
        t = max(0.0, min(1.0, (gy - 100) / 824))
        fill = tuple(TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3))
        row = []
        for x in range(size):
            gx = (x + 0.5) / k
            cov = lambda d: coverage(d * k)
            p = (0.0, 0.0, 0.0, 0.0)
            p = over(p, fill, cov(rounded_box(gx, gy, 512, 512, 412, 185)))
            p = over(p, (255, 255, 255), cov(triangle(gx, gy, a, b, c) - tri_r))
            manhattan = (abs(gx - 724) + abs(gy - 724)) / math.sqrt(2)
            p = over(p, fill, cov(manhattan - 84))
            p = over(p, MINT, cov(manhattan - 62))
            row.append(p)
        pixels.append(row)
    return pixels


def png_bytes(pixels):
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b, a in row:
            raw += bytes((round(r), round(g), round(b), round(a * 255)))
    h, w = len(pixels), len(pixels[0])
    chunk = lambda tag, data: struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def ico_bytes(pngs):
    """ICO with PNG entries (Windows Vista and later read these)."""
    head = struct.pack("<HHH", 0, 1, len(pngs))
    offset = 6 + 16 * len(pngs)
    entries, blobs = b"", b""
    for size, data in pngs:
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    return head + entries + blobs


def main():
    pngs = {}
    for size in SIZES:
        pngs[size] = png_bytes(render(size))
        with open(os.path.join(HERE, f"mpvfx-{size}.png"), "wb") as f:
            f.write(pngs[size])
    with open(os.path.join(HERE, "mpvfx.ico"), "wb") as f:
        f.write(ico_bytes([(s, pngs[s]) for s in (16, 24, 32, 48, 64, 128, 256)]))


if __name__ == "__main__":
    main()
