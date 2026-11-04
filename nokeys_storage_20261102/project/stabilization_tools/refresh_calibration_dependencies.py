"""Refresh source-row dependencies and measurement coordinates for new lens data."""
from pathlib import Path
import json
import subprocess
import sys
import numpy as np
from pipeline_reference import maps, ROOT, DATA

def main():
    normal, reverse, rows = [], [], []
    for view in range(8):
        _, y, _, valid = maps(view, True)
        sy = y >> 8
        highest = int(np.where(valid, sy+2, 0).max())
        suffix = int(np.where(valid, 720-sy, 0).max())
        normal.append(min(720, (highest+7)//8*8))
        reverse.append(min(720, (suffix+7)//8*8))
        rows.append(dict(view=view, normal_source_rows=normal[-1], reverse_source_rows=reverse[-1]))
    for filename, prefix, values in [('cutthrough_limits.vh','CUTTHROUGH',normal),
                                      ('reverse_capture_limits.vh','REVERSE',reverse)]:
        text = '// Generated from current calibrated exact-Q8 presets.\n'
        text += ''.join(f"`define {prefix}_LIMIT_VIEW{view} 11'd{value}\n" for view,value in enumerate(values))
        (DATA/filename).write_text(text, encoding='ascii')
    report = ROOT/'verification/calibration_20261028'
    report.mkdir(parents=True, exist_ok=True)
    (report/'source_row_dependencies.json').write_text(json.dumps(rows,indent=2)+'\n', encoding='utf-8')
    for script in ['stabilization_tools/generate_baseline_scanout_profile.py',
                   'stabilization_tools/generate_hdmi_scanout_profile.py',
                   'workflow/generate_minimum_profile.py']:
        logfile = report/(Path(script).stem+'.log')
        with logfile.open('wb') as out:
            subprocess.run([sys.executable, '-B', script], cwd=ROOT, stdout=out,
                           stderr=subprocess.STDOUT, check=True)
        print('UPDATED', script, flush=True)
    print('Updated camera/HDMI dependencies and static minimum-pixel measurement profiles', flush=True)

if __name__ == '__main__':
    main()
