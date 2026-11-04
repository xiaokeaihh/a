"""Convert a dense inverse map into the FPGA anchor and tile-ROI tables.

Input NPZ fields:
  map_x: float32/float64 array [720,1280], source X for every output pixel
  map_y: float32/float64 array [720,1280], source Y for every output pixel

Example:
  python export_calibration_tables.py calibrated_map.npz data
"""
from pathlib import Path

from bank_anchor_table import write_banked_anchors
import sys
import numpy as np

WIDTH, HEIGHT = 1280, 720
ANCHOR_COLS, ANCHOR_ROWS = WIDTH // 16 + 1, HEIGHT // 16 + 1
TILE_COLS, TILE_ROWS = WIDTH // 128, (HEIGHT + 31) // 32


def q8(value: float) -> int:
    """Convert one coordinate to unsigned Q12.8; invalid points become black."""
    if not np.isfinite(value):
        return 0
    return max(0, min((1 << 20) - 1, int(round(value * 256.0))))


def sample_edge_extended(array: np.ndarray, x: int, y: int) -> float:
    """Sample the anchor grid, linearly extending its right/bottom edges."""
    x0 = min(x, WIDTH - 1)
    y0 = min(y, HEIGHT - 1)
    value = float(array[y0, x0])
    if x >= WIDTH:
        value += (x - (WIDTH - 1)) * float(
            array[y0, WIDTH - 1] - array[y0, WIDTH - 2])
    if y >= HEIGHT:
        value += (y - (HEIGHT - 1)) * float(
            array[HEIGHT - 1, x0] - array[HEIGHT - 2, x0])
    return value


def export(npz_path: Path, output_dir: Path) -> None:
    source = np.load(npz_path)
    map_x = source["map_x"]
    map_y = source["map_y"]
    if map_x.shape != (HEIGHT, WIDTH) or map_y.shape != (HEIGHT, WIDTH):
        raise ValueError("map_x and map_y must both have shape (720, 1280)")
    output_dir.mkdir(parents=True, exist_ok=True)

    # Quantize exactly as the FPGA sees the anchor table.  The ROI table below
    # is derived from this quantized, bilinearly interpolated map so a source
    # neighborhood cannot fall outside its prefetched tile because of table
    # approximation or Q8 rounding.
    anchor_x_q8 = np.empty((ANCHOR_ROWS, ANCHOR_COLS), dtype=np.int64)
    anchor_y_q8 = np.empty((ANCHOR_ROWS, ANCHOR_COLS), dtype=np.int64)
    with (output_dir / "map_anchor.mem").open("w", encoding="ascii") as out:
        for ay in range(ANCHOR_ROWS):
            for ax in range(ANCHOR_COLS):
                x = q8(sample_edge_extended(map_x, ax * 16, ay * 16))
                y = q8(sample_edge_extended(map_y, ax * 16, ay * 16))
                anchor_x_q8[ay, ax] = x
                anchor_y_q8[ay, ax] = y
                out.write(f"{((y << 20) | x):010x}\n")

    yy, xx = np.indices((HEIGHT, WIDTH), dtype=np.int64)
    ax, ay = xx >> 4, yy >> 4
    fx, fy = xx & 15, yy & 15

    def interpolate_q8(anchors: np.ndarray) -> np.ndarray:
        top = ((anchors[ay, ax] * (16 - fx)
                + anchors[ay, ax + 1] * fx + 8) >> 4)
        bottom = ((anchors[ay + 1, ax] * (16 - fx)
                   + anchors[ay + 1, ax + 1] * fx + 8) >> 4)
        return ((top * (16 - fy) + bottom * fy + 8) >> 4)

    hardware_x_q8 = interpolate_q8(anchor_x_q8)
    hardware_y_q8 = interpolate_q8(anchor_y_q8)

    with (output_dir / "tile_roi.mem").open("w", encoding="ascii") as out:
        for ty in range(TILE_ROWS):
            y0, y1 = ty * 32, min(HEIGHT, ty * 32 + 32)
            for tx in range(TILE_COLS):
                x0, x1 = tx * 128, min(WIDTH, tx * 128 + 128)
                mx = hardware_x_q8[y0:y1, x0:x1] >> 8
                my = hardware_y_q8[y0:y1, x0:x1] >> 8
                valid = ((mx >= 0) & (mx <= WIDTH - 2)
                         & (my >= 0) & (my <= HEIGHT - 2))
                if np.any(valid):
                    sx0 = int(mx[valid].min())
                    sy0 = int(my[valid].min())
                    sx1 = int(mx[valid].max()) + 2
                    sy1 = int(my[valid].max()) + 2
                else:
                    # The complete output tile is black.  Keep a legal minimum
                    # prefetch rectangle; no pixel from it will be displayed.
                    sx0, sy0, sx1, sy1 = 0, 0, 16, 4
                sx0, sy0 = sx0 // 16 * 16, sy0 // 4 * 4
                sx1 = min(WIDTH, (sx1 + 15) // 16 * 16)
                sy1 = min(HEIGHT, (sy1 + 3) // 4 * 4)
                width, height = sx1 - sx0, sy1 - sy0
                if width > 160 or height > 56:
                    raise ValueError(
                        f"tile ({tx},{ty}) ROI {width}x{height} exceeds cache 160x56")
                word = (height << 40) | (width << 32)
                word |= (sy0 << 16) | sx0
                out.write(f"{word:012x}\n")

    write_banked_anchors(output_dir / "map_anchor.mem")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: export_calibration_tables.py MAP.npz OUTPUT_DIR")
    export(Path(sys.argv[1]), Path(sys.argv[2]))
