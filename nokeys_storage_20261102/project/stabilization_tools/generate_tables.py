"""Generate fixed lens/reciprocal ROMs; no pose-specific image maps are sent."""
from pathlib import Path
import json, math

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'source/design_fisheye_5frame_720p60_pipeline/data'

def generate():
    cfg = json.loads((DATA / 'baseline_config.json').read_text())
    fx, fy = cfg['source_K'][0][0], cfg['source_K'][1][1]
    d = cfg['source_D']
    words = []
    for i in range(4097):
        r = math.sqrt(i / 64)
        t = math.atan(r)
        distorted = t * (1 + sum(k * t ** (2*j+2) for j, k in enumerate(d)))
        g = distorted / r if r else 1.0
        words.append((round(fy*g*4096) << 22) | round(fx*g*4096))
    for parity, name in [(0, 'even'), (1, 'odd')]:
        values = words[parity::2][:2048]
        (DATA / f'stabilization_gain_{name}.mem').write_text(''.join(f'{x:011x}\n' for x in values))
    far=[]
    for i in range(4096):
        r=math.sqrt(64+i);t=math.atan(r)
        distorted=t*(1+sum(k*t**(2*j+2) for j,k in enumerate(d)))
        far.append((round(fy*distorted/r*4096)<<22)|round(fx*distorted/r*4096))
    for parity,name in [(0,'even'),(1,'odd')]:
        (DATA/f'stabilization_far_{name}.mem').write_text(''.join(f'{x:011x}\n' for x in far[parity::2]))
    (DATA / 'stabilization_constants.vh').write_text(f"`define STAB_LAST_GAIN_WORD 44'h{words[-1]:011x}\n")
    (DATA / 'stabilization_gain_last.mem').write_text(f'{words[-1]:011x}\n')
    (DATA / 'stabilization_reciprocal.mem').write_text(''.join(
        f'{round((1 << 24)/(1+(i+0.5)/1024)):07x}\n' for i in range(1024)))
    (DATA / 'stabilization_config.json').write_text(json.dumps({
        'matrix_format': 'signed Q8.24, R_camera_from_virtual times inverse(output_K)',
        'gain_domain': 'normalized radius squared: 0..64 at 1/64 spacing; 64..4096 at 1 spacing',
        'minimum_positive_z': 1/64, 'output_size': [1280, 720],
        'source_K': cfg['source_K'], 'source_D': d,
        'default_output_K': cfg['output_K'], 'sample_rate_hz': 500,
        'stabilized_views':[1,2,3,4,5,6,7],'pose_bundle_bytes':230,
        'timestamp_tick_us': 10, 'binary_baud': 921600,
        'camera_imu_alignment_calibrated': False,
        'exposure_timestamp_offset_calibrated': False}, indent=2))

if __name__ == '__main__':
    generate()
