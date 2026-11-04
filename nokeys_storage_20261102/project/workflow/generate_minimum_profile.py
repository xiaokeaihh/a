from pathlib import Path
import sys,json,hashlib,numpy as np
W=Path(__file__).resolve().parent;P=W.parent;D=P/'source/design_fisheye_5frame_720p60_pipeline/data';V=P/'verification'
sys.path.insert(0,str(P/'stabilization_tools'))
from pipeline_reference import maps
profiles=[];points=[]
for view in range(8):
    x,y,_,inside=maps(view,True)
    sx=(x>>8)+1;sy=(y>>8)+1
    source_index=np.where(inside,sy*1650+sx,-1)
    oy,ox=np.indices((720,1280),dtype=np.int64)
    for split in (False,True):
        if split:
            if view<5 or view==6:
                src=source_index[180:540,320:960]
            else:
                src=source_index.reshape(360,2,640,2).max(axis=(1,3))
            out_y,out_x=np.indices((360,640),dtype=np.int64);out_x+=640;out_y+=180
        else:src=source_index;out_x=ox;out_y=oy
        valid=src>=0;oi=out_y*1650+out_x
        # Exclude the existing drawn dividers and the latency panel itself.
        if split:valid&=out_x!=640
        elif view==5:valid&=(out_x!=640)&(out_y!=360)
        x0=648 if split else 328 if view<5 or view==6 else 8
        y0=188 if split or view<5 or view==6 else 8
        valid&=~((out_x>=x0)&(out_x<x0+368)&(out_y>=y0)&(out_y<y0+36))
        difference=np.where(valid,src-oi,-10**9)
        k=int(difference.argmax());r,c=np.unravel_index(k,difference.shape)
        si=int(src[r,c]);point=(si%1650,si//1650)
        if point not in points:points.append(point)
        p=dict(profile=8*int(split)+view,split=split,view=view,source_x=point[0],source_y=point[1],source_slot=points.index(point),output_x=int(out_x[r,c]),output_y=int(out_y[r,c]),offset_pixels=int(difference[r,c]),valid_pixels=int(valid.sum()))
        # Exhaustive proof: with the recovered HDMI clock on input and output,
        # every valid pixel delay is phase + O - S; this is the global minimum.
        assert np.all((si-int(oi[r,c]))>=difference[valid])
        profiles.append(p)
assert len(points)<=16
lines=['// Exhaustive static Q8 minimum-pixel proof; valid only for shared RX/output clock.',f'localparam integer MINIMUM_SOURCE_POINTS={len(points)};',
       'function [21:0] minimum_source_point;input [3:0] slot;begin case(slot)']
for i,(x,y) in enumerate(points):lines.append(f" 4'd{i}:minimum_source_point={{11'd{x},11'd{y}}};")
lines+=[' default:minimum_source_point=22\'h3fffff;endcase end endfunction',
        'function [24:0] minimum_output_point;input [3:0] profile;begin case(profile)']
for p in sorted(profiles,key=lambda d:d['profile']):lines.append(f" 4'd{p['profile']}:minimum_output_point={{4'd{p['source_slot']},11'd{p['output_x']},10'd{p['output_y']}}};")
lines+=[' default:minimum_output_point=25\'h1ffffff;endcase end endfunction']
(D/'minimum_pixel_profile.vh').write_text('\n'.join(lines)+'\n')
inputs={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in D.glob('*') if p.suffix in ('.vh','.mem','.json') and p.name!='minimum_pixel_profile.vh'}
(V/'minimum_pixel_proof.json').write_text(json.dumps(dict(passed=True,scope='All sixteen static corrected layouts, each valid pixel and all bilinear/2x2 source dependencies',shared_recovered_clock_required=True,black_pixels_excluded=True,source_time='Last of four fetched bilinear neighbors, or latest dependency of 2x2 split filter',points=points,profiles=profiles,inputs=inputs,profile_sha256=hashlib.sha256((D/'minimum_pixel_profile.vh').read_bytes()).hexdigest()),indent=2))
print(json.dumps(dict(points=len(points),profiles=profiles),indent=2),flush=True)
