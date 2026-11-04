from pathlib import Path
import json
r=Path(__file__).resolve().parents[1]/'verification_quality'
a=(r/'frame_6.txt').read_text(encoding='ascii').splitlines()
b=(r/'frame_gold_6.txt').read_text(encoding='ascii').splitlines()
assert len(a)==len(b)==57600
for n,(x,y) in enumerate(zip(a,b)):
    assert x.strip().lower()==y.strip().lower(),n
(r/'no65_frame_comparison.json').write_text(json.dumps(dict(view=6,pixels=921600,beats=57600,all_DDR_addresses_and_RGB565_match=True),indent=2),encoding='utf-8')
print('PASS no65 full-frame DDR and RGB565 match')
