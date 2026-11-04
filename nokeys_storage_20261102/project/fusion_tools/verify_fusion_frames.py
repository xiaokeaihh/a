"""Compare complete DDR write traces, including addresses, against frozen gold."""
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'verification'


def compare(actual_name, gold_name):
    count = 0
    with (OUT/actual_name).open() as actual, (OUT/gold_name).open() as gold:
        for count, (a, b) in enumerate(itertools.zip_longest(actual, gold), 1):
            if a is None or b is None or [int(v, 16) for v in a.split()] != [int(v, 16) for v in b.split()]:
                raise AssertionError(f'{actual_name}: DDR write mismatch at beat {count}: {a!r} != {b!r}')
    if count != 57600:
        raise AssertionError(f'{actual_name}: expected 57600 DDR write beats, got {count}')
    return {'beats': count, 'pixels': count*16, 'all_addresses_and_RGB565_match': True}


def main():
    cases = [('fusion_frame_actual.txt', 'adaptive_frame_gold.txt'),
             ('fusion_frame_stress.txt', 'adaptive_frame_gold.txt'),
             ('fusion_frame_epoch0.txt', 'adaptive_frame_gold.txt'),
             ('fusion_frame_epoch1.txt', 'adaptive_frame_epoch_gold.txt')]
    report = {name: compare(name, gold) for name, gold in cases}
    (OUT/'fusion_frame_comparison.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print('PASS 4 complete rendered frames: 3686400 RGB565 pixels and all 230400 DDR write addresses; stalled DDR and epoch changes included')


if __name__ == '__main__':
    main()
