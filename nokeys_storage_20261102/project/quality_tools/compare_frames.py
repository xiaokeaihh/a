from pathlib import Path
import json
V=Path(__file__).resolve().parents[1]/'verification_quality';report={}
for v in range(8):
    actual=(V/f'frame_{v}.txt').read_text().splitlines();gold=(V/f'frame_gold_{v}.txt').read_text().splitlines()
    assert len(actual)==len(gold)==57600,(v,len(actual),len(gold))
    for n,(a,b) in enumerate(zip(actual,gold)):assert a.strip().lower()==b.strip().lower(),(v,n,a,b)
    report[v]=dict(pixels=921600,DDR_beats=57600,all_addresses_and_RGB565_match=True)
(V/'frame_comparison.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('PASS every DDR address and RGB565 pixel in all eight layouts')
