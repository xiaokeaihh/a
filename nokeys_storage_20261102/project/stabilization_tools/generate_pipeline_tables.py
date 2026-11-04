"""Regenerate the new shared projection from current real K/D and view configs."""
from pathlib import Path
import json
from generate_tables import generate,DATA
from pipeline_reference import generate_constants
from generate_lossless_tables import generate as generate_lossless

def main():
    cfg=json.loads((DATA/'baseline_config.json').read_text(encoding='utf-8'))
    k=cfg['source_K'];p=cfg['output_K']
    if len(cfg['source_D'])!=4:raise ValueError('This pipeline uses the existing four-coefficient fisheye model')
    generate()
    generate_lossless()
    (DATA/'baseline_constants.vh').write_text(
        '// Generated from current real calibration.\n'
        f"`define FISHEYE_OUTPUT_CX_Q12 24'sd{round(p[0][2]*4096)}\n"
        f"`define FISHEYE_OUTPUT_CY_Q12 24'sd{round(p[1][2]*4096)}\n"
        f"`define FISHEYE_RADIAL_CX_Q28 43'sd{round(k[0][2]*(1<<28))}\n"
        f"`define FISHEYE_RADIAL_CY_Q28 43'sd{round(k[1][2]*(1<<28))}\n",encoding='ascii')
    generate_constants()
    print('Regenerated shared lens ROMs, principal-point constants and all fixed matrices; rebuild firmware before use')
if __name__=='__main__':main()
