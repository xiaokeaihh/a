"""Split the row-major 720p anchor LUT into four nonduplicated parity banks.

Bank names are row parity followed by column parity. Each bank has a 41-word
stride and 23 rows. Unused positions in the odd-column banks are zero-filled
so that all four FPGA memories have the same address calculation.
"""

from __future__ import annotations

import argparse
from pathlib import Path

ANCHOR_COLUMNS = 81
ANCHOR_ROWS = 46
BANK_COLUMNS = (ANCHOR_COLUMNS + 1) // 2
BANK_ROWS = (ANCHOR_ROWS + 1) // 2
BANK_DEPTH = BANK_COLUMNS * BANK_ROWS


def write_banked_anchors(anchor_file: Path) -> list[Path]:
    lines = [line.strip() for line in anchor_file.read_text(encoding="ascii").splitlines()]
    if len(lines) != ANCHOR_COLUMNS * ANCHOR_ROWS:
        raise ValueError(f"expected 3726 anchors in {anchor_file}, got {len(lines)}")
    if any(len(line) != 10 or int(line, 16) >= (1 << 40) for line in lines):
        raise ValueError("each anchor must be a 10-digit hexadecimal Q12.8 pair")

    banks = [["0000000000"] * BANK_DEPTH for _ in range(4)]
    for row in range(ANCHOR_ROWS):
        for column in range(ANCHOR_COLUMNS):
            bank = ((row & 1) << 1) | (column & 1)
            local_address = (row >> 1) * BANK_COLUMNS + (column >> 1)
            banks[bank][local_address] = lines[row * ANCHOR_COLUMNS + column]

    paths = []
    for bank, suffix in enumerate(("00", "01", "10", "11")):
        path = anchor_file.with_name(f"map_anchor_{suffix}.mem")
        path.write_text("\n".join(banks[bank]) + "\n", encoding="ascii")
        paths.append(path)
    return paths


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("anchor_file", type=Path)
    arguments = parser.parse_args()
    for bank_file in write_banked_anchors(arguments.anchor_file):
        print(bank_file)
