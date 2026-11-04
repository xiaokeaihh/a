"""Native WYC geometry -> radial fixed-point LUT, expanded ROI and independent gold.

Reads existing calibration/footprint unchanged. Only generated numerical tables
and verification references are written; no recalibration or source-image edits.
"""
import hashlib
import json
import sys
from pathlib import Path

import cv2 as cv
import numpy as np

from fixed_model import adaptive_pixels, pattern_windows, smooth

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / 'source/design_fisheye_5frame_720p60_native130_wyc_fused'
DATA, OUT = DESIGN / 'data', ROOT / 'verification'
W, H, DX_BITS = 1280, 720, 12
CHECK_ONLY = '--check' in sys.argv


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mem(path, values, digits):
    contents = ''.join(f'{int(v):0{digits}x}\n' for v in np.ravel(values))
    if CHECK_ONLY and path.parent == DATA:
        assert path.read_text(encoding='ascii') == contents, f'Generated table differs: {path.name}'
    else:
        path.write_text(contents, encoding='ascii')


def json_file(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n', encoding='utf-8')


def gain(q, d):
    radius = np.sqrt(q)
    theta = np.arctan(radius)
    t2 = theta*theta
    poly = 1+t2*(d[0]+t2*(d[1]+t2*(d[2]+t2*d[3])))
    return np.divide(theta*poly, radius, out=np.ones_like(radius), where=radius != 0)


def frame_gold(path, pixels):
    with path.open('w', encoding='ascii') as out:
        for ty in range(23):
            for tx in range(10):
                for y in range(ty*32, min((ty+1)*32, H)):
                    for beat in range(8):
                        x = tx*128+beat*16
                        word = sum(int(pixels[y, x+j]) << (16*j) for j in range(16))
                        out.write(f'{0x180000+y*640+x//2:07x} {word:064x}\n')


def main():
    protected = ['calibration_720p.json', 'crop_config.json', 'valid_spans.mem', 'source_content_mask.png',
                 'cubic_phase_compact.mem', 'cubic_phase_q12.mem', 'detail_gate_q8.mem']
    before = {name: sha(DATA/name) for name in protected}
    cal = json.loads((DATA/'calibration_720p.json').read_text(encoding='utf-8'))
    crop = json.loads((DATA/'crop_config.json').read_text(encoding='utf-8'))
    k, d, p = np.array(cal['calibration']['K']), np.array(cal['calibration']['D']), np.array(crop['output_K'])
    if not np.allclose(k, p, rtol=0, atol=1e-9) or k[0, 1] != 0 or crop['optical_axis_rotation_deg'] != [0, 0, 0]:
        raise ValueError('This fusion requires unchanged native K, zero skew and identity rotation')
    if cal['image_size_width_height'] != [W, H]:
        raise ValueError('Wrong camera image size')
    xx, yy = np.meshgrid(np.arange(W), np.arange(H))
    spans = np.array([int(v, 16) for v in (DATA/'valid_spans.mem').read_text().split()], dtype=np.int64)
    inside = ((spans[:, None] >> 22) != 0) & (xx >= (spans[:, None] & 2047)) & (xx <= ((spans[:, None] >> 11) & 2047))
    assert np.count_nonzero(inside) == 779336
    axis_x = np.rint(((np.arange(W)-p[0, 2])/p[0, 0])**2 * 16384).astype(np.int64)
    axis_y = np.rint(((np.arange(H)-p[1, 2])/p[1, 1])**2 * 16384).astype(np.int64)
    q_table = np.arange(1025)/64
    gains = np.rint(gain(q_table, d)*65536).astype(np.int64)
    q_fixed = axis_y[:, None]+axis_x[None, :]
    index, phase = q_fixed >> 8, q_fixed & 255
    assert index.max()+1 < len(gains) and max(axis_x.max(), axis_y.max()) < (1 << 18)
    assert 0 < gains.min() and gains.max() < (1 << 17)
    g = (gains[index]*256+(gains[index+1]-gains[index])*phase+128) >> 8
    dx = np.arange(W, dtype=np.int64)*4096-round(p[0, 2]*4096)
    dy = np.arange(H, dtype=np.int64)*4096-round(p[1, 2]*4096)
    sx = (dx[None, :]*g+round(k[0, 2]*(1 << 28))+(1 << 19)) >> 20
    sy = (dy[:, None]*g+round(k[1, 2]*(1 << 28))+(1 << 19)) >> 20
    cvx, cvy = cv.fisheye.initUndistortRectifyMap(k, d, np.eye(3), p, (W, H), cv.CV_32FC1)
    error = np.hypot(sx/256-cvx, sy/256-cvy)[inside]
    if error.max() > 0.05:
        raise ValueError(f'Native mapping accuracy gate failed: {error.max()}')
    q = (xx-p[0, 2])**2/p[0, 0]**2+(yy-p[1, 2])**2/p[1, 1]**2
    analytic_inside = q <= np.tan(np.deg2rad(65))**2
    assert np.array_equal(analytic_inside, inside), 'Existing natural footprint differs from retained native cone'
    t2 = np.arctan(np.sqrt(q_table))**2
    slope = (1+t2*(3*d[0]+t2*(5*d[1]+t2*(7*d[2]+t2*9*d[3]))))/(1+q_table)
    if np.any(slope <= 0):
        raise ValueError('Nonpositive radial magnification slope')
    blend_table = np.floor(smooth(1/slope, 2.4, 4.0)*256+0.5).astype(np.int64)
    blend = (blend_table[index]*256+(blend_table[index+1]-blend_table[index])*phase+128) >> 8
    ix, iy, expand = sx >> 8, sy >> 8, (blend > 0).astype(np.int64)
    xlo, ylo, xhi, yhi = ix-expand, iy-expand, ix+1+expand, iy+1+expand
    if not np.all((xlo[inside] >= 0) & (ylo[inside] >= 0) & (xhi[inside] < W) & (yhi[inside] < H)):
        raise ValueError('Valid adaptive 4x4 neighborhood extends outside camera frame')
    source_mask = cv.imdecode(np.fromfile(str(DATA/'source_content_mask.png'), dtype=np.uint8), cv.IMREAD_GRAYSCALE)
    distance = cv.distanceTransform(np.pad(source_mask, 1), cv.DIST_L2, cv.DIST_MASK_PRECISE)[1:-1, 1:-1]
    margin = min(float(distance[cy[inside], cx[inside]].min()) for cy in (ylo, yhi) for cx in (xlo, xhi))
    if margin < crop['border_margin_px']:
        raise ValueError(f'Optical-content margin failed: {margin}')
    rois, sizes, empty, prefetched = [], [], 0, 0
    for ty in range(23):
        for tx in range(10):
            sl = np.s_[ty*32:min((ty+1)*32, H), tx*128:(tx+1)*128]
            selected = inside[sl]
            if np.any(selected):
                x0 = int(xlo[sl][selected].min())//16*16
                y0 = int(ylo[sl][selected].min())//4*4
                x1 = (int(xhi[sl][selected].max())//16+1)*16
                y1 = (int(yhi[sl][selected].max())//4+1)*4
            else:
                # Existing renderer expects a nonzero ROI; harmless minimum fetch.
                x0, y0, x1, y1 = 672, 372, 688, 376
                empty += 1
            width, height = x1-x0, y1-y0
            if width > 160 or height > 56 or ((width+1)//2)*((height+1)//2) > 2240 or x1 > W or y1 > H:
                raise ValueError(f'Fusion ROI exceeds preserved cache at {tx},{ty}: {width}x{height}')
            sizes.append((width, height));prefetched += width*height
            rois.append((height << 40)|(width << 32)|(y0 << 16)|x0)
    for name, values, digits in [('radial_axis_x.mem', axis_x, 5), ('radial_axis_y.mem', axis_y, 5),
            ('radial_gain_even.mem', gains[::2], 5), ('radial_gain_odd.mem', np.r_[gains[1::2], gains[-1]], 5),
            ('blend_even.mem', blend_table[::2], 3), ('blend_odd.mem', np.r_[blend_table[1::2], blend_table[-1]], 3),
            ('tile_roi.mem', rois, 12)]:
        mem(DATA/name, values, digits)
    header = f'''// Generated for unchanged WYC native K and fractional output principal point.
`define FISHEYE_OUTPUT_CX_Q12 24'sd{round(p[0, 2]*4096)}
`define FISHEYE_OUTPUT_CY_Q12 24'sd{round(p[1, 2]*4096)}
`define FISHEYE_RADIAL_CX_Q28 43'sd{round(k[0, 2]*(1 << 28))}
`define FISHEYE_RADIAL_CY_Q28 43'sd{round(k[1, 2]*(1 << 28))}
'''
    if CHECK_ONLY:
        assert (DATA/'radial_constants.vh').read_text(encoding='ascii') == header
    else:
        (DATA/'radial_constants.vh').write_text(header, encoding='ascii')
    mem(OUT/'adaptive_mapping_gold.mem', (inside.astype(np.int64) << 49)|(blend << 40)|(sy << 20)|sx, 13)
    windows = pattern_windows(sx, sy)
    pixels, alpha = adaptive_pixels(windows, sx & 255, sy & 255, blend, inside)
    epoch_pixels, _ = adaptive_pixels(windows ^ 0x379b, sx & 255, sy & 255, blend, inside)
    frame_gold(OUT/'adaptive_frame_gold.txt', pixels)
    frame_gold(OUT/'adaptive_frame_epoch_gold.txt', epoch_pixels)
    mem(OUT/'rendered_rgb565.mem', pixels, 4)
    metrics = {'maximum_source_error_px': float(error.max()), 'rms_source_error_px': float(np.sqrt(np.mean(error**2))),
        'valid_pixels': int(inside.sum()), 'original_footprint_bit_exact': True, 'output_scale': 1.0,
        'output_K': p.tolist(), 'minimum_optical_margin_px': margin, 'max_roi_width': max(w for w,h in sizes),
        'max_roi_height': max(h for w,h in sizes), 'cache_capacity_per_bank': 2240,
        'empty_tiles_with_minimum_safe_ROI': empty, 'source_prefetch_pixels': prefetched,
        'radial_nonzero_pixels': int(np.count_nonzero(inside & (blend != 0))),
        'texture_active_synthetic_pixels': int(np.count_nonzero((alpha != 0) & inside)),
        'protected_sha256': before, 'mapping_coordinate_format': 'axis Q4.14, gain Q1.16, offset Q12, source Q8'}
    if before != {name: sha(DATA/name) for name in protected}:
        raise AssertionError('Protected camera, footprint or interpolation curves changed')
    json_file(OUT/'fusion_reference_report.json', metrics)
    if not CHECK_ONLY:
        json_file(DATA/'fusion_table_report.json', metrics)
    print(json.dumps(metrics, indent=2))


if __name__ == '__main__':
    main()
