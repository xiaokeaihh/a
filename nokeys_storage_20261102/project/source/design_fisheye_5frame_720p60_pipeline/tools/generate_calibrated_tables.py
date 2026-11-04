"""Build 720p five-frame bilinear anchor/ROI tables from camera calibration.

The output scale is configurable below. Generated ROIs must fit the tile cache.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from bank_anchor_table import write_banked_anchors

import cv2 as cv
import numpy as np


WIDTH, HEIGHT = 1280, 720
ANCHOR_COLS, ANCHOR_ROWS = WIDTH // 16 + 1, HEIGHT // 16 + 1
TILE_COLS, TILE_ROWS = WIDTH // 128, (HEIGHT + 31) // 32
DATA_DIR = Path(__file__).resolve().parents[1] / "data"


def main() -> None:
    report = json.loads((DATA_DIR / "calibration_720p.json").read_text(encoding="utf-8"))
    crop = json.loads((DATA_DIR / "crop_config.json").read_text(encoding="utf-8"))
    scale = float(crop["output_scale"])
    if not np.isfinite(scale) or scale <= 0:
        raise ValueError("Output scale must be finite and positive")
    if report["image_size_width_height"] != [WIDTH, HEIGHT]:
        raise ValueError("Calibration resolution must be 1280x720")
    k = report["calibration"]["K"]
    d = report["calibration"]["D"]
    if d[3] != 0:
        raise ValueError("This camera calibration fixes k4=0")
    fx, fy, cx, cy = k[0][0], k[1][1], k[0][2], k[1][2]
    k1, k2, k3 = d[:3]
    output_k = [[fx * scale, 0, WIDTH / 2], [0, fy * scale, HEIGHT / 2], [0, 0, 1]]
    if not np.allclose(output_k, crop["output_K"], rtol=0, atol=1e-9):
        raise ValueError("Crop projection does not match this calibration and scale")
    content_mask = cv.imdecode(np.fromfile(str(DATA_DIR / crop["source_content_mask"]),
                                         dtype=np.uint8), cv.IMREAD_GRAYSCALE)
    if content_mask is None or content_mask.shape != (HEIGHT, WIDTH):
        raise ValueError("A matching 720p optical-content mask is required")
    padded = np.pad(content_mask, 1, constant_values=0)
    distance = cv.distanceTransform(padded, cv.DIST_L2, cv.DIST_MASK_PRECISE)[1:-1, 1:-1]
    border_margin = float(crop["border_margin_px"])

    anchors = np.empty((ANCHOR_ROWS, ANCHOR_COLS), dtype=np.int64)
    with (DATA_DIR / "map_anchor.mem").open("w", encoding="ascii", newline="\n") as out:
        for ay in range(ANCHOR_ROWS):
            for ax in range(ANCHOR_COLS):
                xn = (ax * 16 - WIDTH / 2) / (fx * scale)
                yn = (ay * 16 - HEIGHT / 2) / (fy * scale)
                r = math.hypot(xn, yn)
                theta = math.atan(r)
                theta2 = theta * theta
                theta_d = theta * (1 + k1 * theta2 + k2 * theta2**2 + k3 * theta2**3)
                radial = theta_d / r if r else 1.0
                sx = round((cx + fx * xn * radial) * 256)
                sy = round((cy + fy * yn * radial) * 256)
                if not (0 <= sx < 1 << 20 and 0 <= sy < 1 << 20):
                    raise ValueError(f"Anchor ({ax},{ay}) is outside Q12.8 range")
                anchors[ay, ax] = (sy << 20) | sx
                out.write(f"{int(anchors[ay, ax]):010x}\n")

    x = np.arange(WIDTH, dtype=np.int64)
    ax, frac_x = x >> 4, x & 15
    tile_bounds = np.empty((TILE_ROWS, TILE_COLS, 4), dtype=np.int64)
    tile_bounds[:, :, 0:2] = 1 << 30
    tile_bounds[:, :, 2:4] = -1
    valid_pixels = 0
    for y in range(HEIGHT):
        ay, frac_y, ty = y >> 4, y & 15, y >> 5
        coordinates = []
        for shift in (0, 20):
            values = (anchors >> shift) & 0xFFFFF
            upper = (values[ay, ax] * (16 - frac_x)
                     + values[ay, ax + 1] * frac_x + 8) >> 4
            lower = (values[ay + 1, ax] * (16 - frac_x)
                     + values[ay + 1, ax + 1] * frac_x + 8) >> 4
            coordinates.append(((upper * (16 - frac_y)
                                 + lower * frac_y + 8) >> 4) >> 8)
        sx, sy = coordinates
        valid = (sx >= 0) & (sx <= WIDTH - 2) & (sy >= 0) & (sy <= HEIGHT - 2)
        if not np.all(valid):
            raise ValueError(f"Output row {y} leaves the valid 2x2 source area")
        safety = np.minimum.reduce([distance[sy, sx], distance[sy, sx + 1],
                                    distance[sy + 1, sx], distance[sy + 1, sx + 1]])
        if safety.min() < border_margin:
            raise ValueError(f"Output row {y} samples the excluded fisheye/OSD border")
        valid_pixels += int(np.count_nonzero(valid))
        for tx in range(TILE_COLS):
            sl = slice(tx * 128, (tx + 1) * 128)
            good = valid[sl]
            if not np.any(good):
                continue
            bx, by = sx[sl][good], sy[sl][good]
            bounds = tile_bounds[ty, tx]
            bounds[0] = min(bounds[0], int(bx.min()))
            bounds[1] = min(bounds[1], int(by.min()))
            bounds[2] = max(bounds[2], int(bx.max()) + 1)
            bounds[3] = max(bounds[3], int(by.max()) + 1)

    widths, heights = [], []
    if valid_pixels != WIDTH * HEIGHT:
        raise ValueError(f"Only {valid_pixels} of {WIDTH * HEIGHT} output pixels have a 2x2 source")
    with (DATA_DIR / "tile_roi.mem").open("w", encoding="ascii", newline="\n") as out:
        for ty in range(TILE_ROWS):
            for tx in range(TILE_COLS):
                low_x, low_y, high_x, high_y = map(int, tile_bounds[ty, tx])
                if high_x < 0:
                    x0, y0, width, height = 0, 0, 16, 4
                else:
                    x0 = max(0, low_x // 16 * 16)
                    y0 = max(0, low_y // 4 * 4)
                    x1 = min(WIDTH, (high_x // 16 + 1) * 16)
                    y1 = min(HEIGHT, (high_y // 4 + 1) * 4)
                    width, height = x1 - x0, y1 - y0
                if x0 < 0 or y0 < 0 or x0 + width > WIDTH or y0 + height > HEIGHT:
                    raise ValueError(f"Tile ({tx},{ty}) leaves source frame")
                if not (0 < width <= 160 and 0 < height <= 56):
                    raise ValueError(f"Tile ({tx},{ty}) needs {width}x{height}; cache is 160x56")
                widths.append(width)
                heights.append(height)
                word = (height << 40) | (width << 32) | (y0 << 16) | x0
                out.write(f"{word:012x}\n")

    write_banked_anchors(DATA_DIR / "map_anchor.mem")

    summary = {
        "calibration": "calibration_720p.json",
        "model": "OpenCV fisheye k1,k2,k3; k4=0",
        "mode": "calibrated_fisheye_crop_fill",
        "resolution": [WIDTH, HEIGHT],
        "output_scale": scale,
        "output_K": output_k,
        "crop_config": "crop_config.json",
        "anchor_count": int(anchors.size),
        "tile_count": TILE_COLS * TILE_ROWS,
        "valid_output_pixels": valid_pixels,
        "max_roi_width": max(widths),
        "max_roi_height": max(heights),
        "max_roi_area": max(w * h for w, h in zip(widths, heights)),
        "interpolator": "bilinear_2x2",
    }
    (DATA_DIR / "table_report.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
