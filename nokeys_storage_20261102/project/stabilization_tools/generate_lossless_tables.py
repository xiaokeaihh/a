"""Encode all calibrated lens nodes in the existing exact 53/26-bit ROM layout."""
from pathlib import Path
import json

DATA = Path(__file__).resolve().parents[1]/'source/design_fisheye_5frame_720p60_pipeline/data'

def signed(value, bits):
    value &= (1 << bits)-1
    return value-(1 << bits) if value & (1 << (bits-1)) else value

def generate():
    def load(name):
        return [int(x, 16) for x in (DATA/name).read_text(encoding='ascii').split()]
    bases, packed_even, packed_odd = [], [], []
    checked = 0
    maximum_x_residue = maximum_difference_residue = 0
    for domain in ('gain', 'far'):
        even = load(f'stabilization_{domain}_even.mem')
        odd = load(f'stabilization_{domain}_odd.mem')
        assert len(even) == len(odd) == 2048
        words = [value for pair in zip(even, odd) for value in pair]
        residues = []
        for start in range(0, 4096, 8):
            group = words[start:start+8]
            xs = [w & ((1 << 22)-1) for w in group]
            differences = [(w >> 22)-x for w, x in zip(group, xs)]
            slope = round((xs[-1]-xs[0])/7)
            dslope = round((differences[-1]-differences[0])/7)
            x0 = round(sum(x-slope*i for i, x in enumerate(xs))/8)
            d0 = round(sum(d-dslope*i for i, d in enumerate(differences))/8)
            assert 0 <= x0 < (1 << 22)
            assert -(1 << 12) <= d0 < (1 << 12)
            assert -(1 << 12) <= slope < (1 << 12)
            assert -16 <= dslope < 16
            base = x0 | ((d0 & 8191) << 22) | ((slope & 8191) << 35) | ((dslope & 31) << 48)
            bases.append(base)
            for i, (x, difference) in enumerate(zip(xs, differences)):
                rx = x-x0-slope*i
                rd = difference-d0-dslope*i
                assert -256 <= rx <= 255, (domain, start, rx)
                assert -8 <= rd <= 7, (domain, start, rd)
                residue = (rx & 511) | ((rd & 15) << 9)
                residues.append(residue)
                # Decode the exact RTL fields, including signed offsets.
                dx = (base & ((1 << 22)-1)) + signed(base >> 35, 13)*i + signed(residue, 9)
                dd = signed(base >> 22, 13) + signed(base >> 48, 5)*i + signed(residue >> 9, 4)
                assert ((dx+dd) << 22) | dx == group[i]
                maximum_x_residue = max(maximum_x_residue, abs(rx))
                maximum_difference_residue = max(maximum_difference_residue, abs(rd))
                checked += 1
        for values,target in ((residues[::2], packed_even), (residues[1::2], packed_odd)):
            packed = [values[i] | (values[i+1] << 13) for i in range(0, 2048, 2)]
            target.extend(packed)
    assert len(bases) == 1024 and len(packed_even) == len(packed_odd) == 2048
    for name, values, digits in [('base', bases, 14), ('even', packed_even, 7), ('odd', packed_odd, 7)]:
        (DATA/f'stabilization_lossless_{name}.mem').write_text(''.join(f'{v:0{digits}x}\n' for v in values), encoding='ascii')
    report = dict(passed=True, decoded_nodes_checked=checked, maximum_abs_x_residue=maximum_x_residue,
                  maximum_abs_difference_residue=maximum_difference_residue, base_words=len(bases),
                  even_words=len(packed_even), odd_words=len(packed_odd), exact_integer_reconstruction=True)
    (DATA/'lossless_encoding_report.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(report))

if __name__ == '__main__':
    generate()
