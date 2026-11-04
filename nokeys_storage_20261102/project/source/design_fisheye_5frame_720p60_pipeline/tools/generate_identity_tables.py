"""Generate 720p passthrough tables until camera calibration is available.

The final source row/column is clamped by two pixels so every output pixel
has a legal 2x2 RGB565 bilinear neighborhood. This only affects the border.
"""

from __future__ import annotations

import json
from pathlib import Path

from bank_anchor_table import write_banked_anchors


WIDTH, HEIGHT = 1280, 720
ANCHOR_COLS, ANCHOR_ROWS = WIDTH // 16 + 1, HEIGHT // 16 + 1
TILE_COLS, TILE_ROWS = WIDTH // 128, (HEIGHT + 31) // 32
DATA_DIR = Path(__file__).resolve().parents[1] / "data"


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with (DATA_DIR / "map_anchor.mem").open("w", encoding="ascii", newline="\n") as out:
        for ay in range(ANCHOR_ROWS):
            for ax in range(ANCHOR_COLS):
                sx = min(ax * 16, WIDTH - 2) * 256
                sy = min(ay * 16, HEIGHT - 2) * 256
                out.write(f"{((sy << 20) | sx):010x}\n")

    with (DATA_DIR / "tile_roi.mem").open("w", encoding="ascii", newline="\n") as out:
        for ty in range(TILE_ROWS):
            for tx in range(TILE_COLS):
                x0, y0 = tx * 128, ty * 32
                x1 = min(WIDTH, x0 + 144)
                y1 = min(HEIGHT, y0 + 36)
                width, height = x1 - x0, y1 - y0
                assert width <= 160 and height <= 56
                word = (height << 40) | (width << 32) | (y0 << 16) | x0
                out.write(f"{word:012x}\n")

    write_banked_anchors(DATA_DIR / "map_anchor.mem")

    report = {
        "mode": "identity_passthrough_until_720p_calibration",
        "resolution": [WIDTH, HEIGHT],
        "anchor_count": ANCHOR_COLS * ANCHOR_ROWS,
        "tile_count": TILE_COLS * TILE_ROWS,
        "interpolator": "bilinear_2x2",
        "max_roi_width": 144,
        "max_roi_height": 36,
    }
    (DATA_DIR / "table_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
