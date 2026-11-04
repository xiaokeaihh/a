"""Reproduce the exact physical ROM initializers after calibration table updates."""
from pathlib import Path
import argparse,hashlib,json,re

def generate(check=False,write_report=True):
    P=Path(__file__).resolve().parent
    R=P/'source/design_fisheye_5frame_720p60_pipeline/rtl'
    D=R.parent/'data';f=R/'stabilized_projection.v';text=f.read_text()
    before=text;inputs={}
    for parity in ['even','odd']:
        source=D/f'stabilization_lossless_{parity}.mem'
        words=[int(v,16) for v in source.read_text().split()]
        assert len(words)==2048 and max(words)<1<<26
        inputs[source.name]=hashlib.sha256(source.read_bytes()).hexdigest()
        a=text.index(f'module projection_residual_{parity}(')
        b=text.index('endmodule',a)+len('endmodule')
        module=text[a:b]
        for bank in range(3):
            values=[(w>>(9*bank))&511 for w in words]
            marker=module.index(f') bank{bank}(')
            start=module.rfind(' GTP_DRM18K_E1 #(',0,marker)
            part=module[start:marker]
            for i in range(64):
                value=sum(values[32*i+k]<<(9*k) for k in range(32))
                pattern=rf"(\.INIT_{i:02X}\(288'h)[0-9a-fA-F]+(\))"
                part,count=re.subn(pattern,lambda m:m[1]+f'{value:072x}'+m[2],part)
                assert count==1,(parity,bank,i)
            module=module[:start]+part+module[marker:]
        text=text[:a]+module+text[b:]
    if check:assert text==before,'Calibration changed: regenerate physical ROMs before building'
    elif text!=before:f.write_text(text)
    report=dict(passed=True,words_checked=4096,word_width=26,latency_edges=1,inputs=inputs,projection_sha256=hashlib.sha256(f.read_bytes()).hexdigest())
    out=P/'verification/packing_generation.json'
    if write_report:
        out.parent.mkdir(parents=True,exist_ok=True)
        out.write_text(json.dumps(report,indent=2))
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true')
    parser.add_argument('--no-report',action='store_true')
    args=parser.parse_args()
    print(json.dumps(generate(args.check,write_report=not args.no_report),indent=2))
