"""Generate parity-banked mesh, native-pane output maps and safe tile ROIs."""
import json,sys
from pathlib import Path
import numpy as np
import cv2
from balanced_geometry import ROOT,DATA,OUT,K,D,BT,DIST,project,matrix,valid_neighborhood,optimize

def mem(name,a,digits,folder=DATA):
    (folder/name).write_text(''.join(f'{int(v):0{digits}x}\n' for v in np.ravel(a)),encoding='ascii')

def grid(c):
    y,x=np.indices((46,81));sx,sy,b,_,_=project(c,x*16.,y*16.)
    sx=np.rint(sx*256).astype(np.int64);sy=np.rint(sy*256).astype(np.int64);b=np.rint(b).astype(np.int64)
    assert sx.min()>=0 and sy.min()>=0 and sx.max()<2**20 and sy.max()<2**20
    return sx,sy,b

def reconstruct(nodes):
    y,x=np.indices((720,1280));ax=x>>4;ay=y>>4;fx=x&15;fy=y&15;values=[]
    for table in nodes:
        top=(table[ay,ax]*(16-fx)+table[ay,ax+1]*fx+8)>>4
        bottom=(table[ay+1,ax]*(16-fx)+table[ay+1,ax+1]*fx+8)>>4
        values.append((top*(16-fy)+bottom*fy+8)>>4)
    return values

def spans(v):
    result=[]
    for y,row in enumerate(v):
        ix=np.flatnonzero(row)
        if not len(ix):result.append(0);continue
        assert np.all(np.diff(ix)==1),('noncontiguous valid row',y)
        result.append((1<<22)|(int(ix[-1])<<11)|int(ix[0]))
    return result

def display_spans(v):
    a=[];b=[]
    for row in v:
        padded=np.r_[False,row,False];starts=np.flatnonzero(np.diff(padded.astype(int))==1);ends=np.flatnonzero(np.diff(padded.astype(int))==-1)-1
        assert len(starts)<=2,'display row requires more than two intervals'
        entries=[(1<<22)|(int(e)<<11)|int(s) for s,e in zip(starts,ends)]
        a.append(entries[0] if entries else 0);b.append(entries[1] if len(entries)>1 else 0)
    return a,b

def frame_gold(vid,sx,sy,bl,valid):
    sys.path.insert(0,str(ROOT/'fusion_tools'))
    from fixed_model import adaptive_pixels,pattern_windows
    pixels,_=adaptive_pixels(pattern_windows(sx,sy),sx&255,sy&255,bl,valid)
    with (OUT/f'frame_gold_{vid}.txt').open('w',encoding='ascii') as f:
        for ty in range(90):
          for tx in range(10):
           for y in range(ty*8,(ty+1)*8):
            for beat in range(8):
                x=tx*128+beat*16;word=sum(int(pixels[y,x+j])<<(16*j) for j in range(16))
                f.write(f'{0x180000+y*640+x//2:07x} {word:064x}\n')

def full_radial(c):
    p=matrix(c);x=np.arange(1280);y=np.arange(720)
    qx=np.rint(((x-c['cx'])/p[0,0])**2*16384).astype(np.int64)
    qy=np.rint(((y-c['cy'])/p[1,1])**2*16384).astype(np.int64)
    q=qx[None,:]+qy[:,None];i=q>>8;phase=q&255;assert i.max()<1024
    qs=np.arange(1025)/64;r=np.sqrt(qs);t=np.arctan(r);t2=t*t
    rd=t*(1+t2*(D[0]+t2*(D[1]+t2*(D[2]+t2*D[3]))))
    gain=np.rint(np.divide(rd,r,out=np.ones_like(r),where=r>0)*K[0,0]/p[0,0]*65536).astype(np.int64)
    assert gain.max()<131072 and qx.max()<2**18 and qy.max()<2**18
    g=(gain[i]*256+(gain[i+1]-gain[i])*phase+128)>>8
    b=(BT[i]*256+(BT[i+1]-BT[i])*phase+128)>>8
    dx=x*4096-round(c['cx']*4096);dy=y*4096-round(c['cy']*4096)
    sx=(dx[None,:]*g+round(K[0,2]*2**28)+2**19)>>20;sy=(dy[:,None]*g+round(K[1,2]*2**28)+2**19)>>20
    v=valid_neighborhood(sx/256,sy/256,b)
    mem('radial_axis_x.mem',qx,5);mem('radial_axis_y.mem',qy,5)
    mem('radial_gain_even.mem',gain[::2],5);mem('radial_gain_odd.mem',np.r_[gain[1::2],gain[-1]],5)
    mem('full_source_spans.mem',spans(v),6)
    (DATA/'radial_constants.vh').write_text(f'''// Balanced central rectilinear view; K/D unchanged.
`define FISHEYE_OUTPUT_CX_Q12 24'sd{round(c['cx']*4096)}
`define FISHEYE_OUTPUT_CY_Q12 24'sd{round(c['cy']*4096)}
`define FISHEYE_RADIAL_CX_Q28 43'sd{round(K[0,2]*2**28)}
`define FISHEYE_RADIAL_CY_Q28 43'sd{round(K[1,2]*2**28)}
''',encoding='ascii')
    return [sx,sy,b,v]

def old_baseline():
    y,x=np.indices((720,1280));qx=np.array([int(v,16) for v in (DATA/'baseline_axis_x.mem').read_text(encoding='ascii').split()]);qy=np.array([int(v,16) for v in (DATA/'baseline_axis_y.mem').read_text(encoding='ascii').split()]);q=qx[None,:]+qy[:,None];i=q>>8;f=q&255
    gain=np.empty(1025,np.int64);gain[::2]=[int(v,16) for v in (DATA/'baseline_gain_even.mem').read_text(encoding='ascii').split()];gain[1::2]=[int(v,16) for v in (DATA/'baseline_gain_odd.mem').read_text(encoding='ascii').split()][:512]
    g=(gain[i]*256+(gain[i+1]-gain[i])*f+128)>>8;b=(BT[i]*256+(BT[i+1]-BT[i])*f+128)>>8
    sx=((x*4096-round(639.5*4096))*g+round(K[0,2]*2**28)+2**19)>>20;sy=((y*4096-round(359.5*4096))*g+round(K[1,2]*2**28)+2**19)>>20
    v=np.ones((720,1280),bool)
    return [sx,sy,b,v]

def native_capacity(values):
    padded=[np.full((720,1280),int(a[0,0]),dtype=a.dtype) for a in values[:3]]+[np.zeros((720,1280),bool)]
    for j in range(4):padded[j][180:540,320:960]=values[j][::2,::2]
    sx,sy,b,v=padded;ix,iy=sx>>8,sy>>8;ex=(b>0).astype(np.int64)
    xl,xh,yl,yh=ix-ex,ix+1+ex,iy-ex,iy+1+ex
    mw=mh=words=0
    for ty in range(90):
      for tx in range(10):
        sl=np.s_[ty*8:(ty+1)*8,tx*128:(tx+1)*128];sel=v[sl]
        if not sel.any():continue
        x0=int(xl[sl][sel].min())//16*16;y0=int(yl[sl][sel].min())//2*2
        x1=(int(xh[sl][sel].max())//16+1)*16;y1=(int(yh[sl][sel].max())//2+1)*2
        w,h=x1-x0,y1-y0;mw=max(mw,w);mh=max(mh,h);words=max(words,w*h//4)
    return dict(maximum_roi_width=mw,maximum_roi_height=mh,maximum_words_per_parity_bank=words)

def main():
    cfg=json.loads((DATA/'balanced_config.json').read_text(encoding='utf-8')) if (DATA/'balanced_config.json').exists() else optimize()
    configs=[cfg['fixed_view0']]+[c['config'] for c in cfg['quadrants']]
    canonical=[];node_list=[];report=[]
    yy,xx=np.indices((720,1280));span_rows=[]
    for vid,c in enumerate(configs):
        nodes=grid(c);sx,sy,b=reconstruct(nodes);rx,ry,_,slope,theta=project(c,xx.astype(float),yy.astype(float));v=valid_neighborhood(sx/256,sy/256,b)&(slope>0)
        e=np.hypot(sx/256-rx,sy/256-ry);assert e[v].max()<.125,(vid,float(e[v].max()))
        span_rows.extend(spans(v));canonical.append([sx,sy,b,v]);node_list.append(nodes)
        report.append(dict(id=vid,config=c,canonical_black_pixels=int((~v).sum()),maximum_mesh_coordinate_error_px=float(e[v].max()),rms_mesh_coordinate_error_px=float(np.sqrt(np.mean(e[v]**2))),maximum_source_angle_deg=float(np.rad2deg(theta[v]).max())))
    for rr,cc in [(0,0),(0,1),(1,0),(1,1)]:
        bank=np.zeros((5,23,41),dtype=np.int64)
        for vid,nodes in enumerate(node_list):
            a=(nodes[2]<<40)|(nodes[1]<<20)|nodes[0];part=a[rr::2,cc::2];bank[vid,:part.shape[0],:part.shape[1]]=part
        mem(f'mesh_anchor_{rr}{cc}.mem',bank,13)
        flat=bank.ravel()
        mem(f'mesh_anchor_{rr}{cc}_main.mem',flat[:4096],13)
        mem(f'mesh_anchor_{rr}{cc}_tail.mem',np.pad(flat[4096:],(0,1024-len(flat[4096:]))),13)
    mem('rect_spans.mem',span_rows,6)
    # Native 640x360 view is written in a centered DDR viewport. The reader
    # sends it directly to the comparison right half without a second resize.
    maps=[]
    for values in canonical:
        padded=[np.full((720,1280),int(a[0,0]),dtype=a.dtype) for a in values[:3]]+[np.zeros((720,1280),bool)]
        for j in range(4):padded[j][180:540,320:960]=values[j][::2,::2]
        maps.append(padded)
    quad=[np.zeros((720,1280),dtype=a.dtype) for a in canonical[0]]
    for vid,ys,xs in [(3,slice(0,360),slice(0,640)),(4,slice(0,360),slice(640,1280)),(1,slice(360,720),slice(0,640)),(2,slice(360,720),slice(640,1280))]:
        for j in range(4):quad[j][ys,xs]=canonical[vid][j][::2,::2]
    maps.append(quad)
    candidates=json.loads((OUT/'balanced_candidates.json').read_text(encoding='utf-8'))['central_candidates']
    rejected=[]
    for candidate in sorted(candidates,key=lambda a:a['score']):
        values=full_radial(candidate['config']);capacity=native_capacity(values)
        if capacity['maximum_roi_width']<=240 and capacity['maximum_roi_height']<=64 and capacity['maximum_words_per_parity_bank']<=2048:
            cfg['central_full']=candidate;cfg['central_cache_capacity']=capacity;break
        rejected.append(dict(config=candidate['config'],capacity=capacity))
    else:raise RuntimeError('No central candidate fits preserved 2048-word cache')
    cfg['rejected_central_cache_candidates']=rejected
    (DATA/'balanced_config.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
    print('Central view after cache gate',cfg['central_full'],capacity,flush=True)
    rx,ry,_,_,theta=project(cfg['central_full']['config'],xx.astype(float),yy.astype(float));e=np.hypot(values[0]/256-rx,values[1]/256-ry);assert e[values[3]].max()<.05
    report.append(dict(id=6,config=cfg['central_full']['config'],canonical_black_pixels=int((~values[3]).sum()),maximum_mesh_coordinate_error_px=float(e[values[3]].max()),maximum_source_angle_deg=float(np.rad2deg(theta[values[3]]).max()),mapping='one-dimensional radial table, no angular mask'))
    padded=[np.full((720,1280),int(a[0,0]),dtype=a.dtype) for a in values[:3]]+[np.zeros((720,1280),bool)]
    for j in range(4):padded[j][180:540,320:960]=values[j][::2,::2]
    maps.append(padded);mem('valid_spans.mem',spans(padded[3]),6)
    maps.append(old_baseline())
    rois=[];da=[];db=[]
    for vid,(sx,sy,b,v) in enumerate(maps):
        mem(f'mapping_{vid}.mem',(v.astype(np.int64)<<49)|(b<<40)|((sy&0xfffff)<<20)|(sx&0xfffff),13,OUT)
        cv2.imencode('.png',v.astype(np.uint8)*255)[1].tofile(OUT/f'mask_{vid}.png')
        a,bb=display_spans(v);da.extend(a);db.extend(bb)
        ix,iy=sx>>8,sy>>8;ex=(b>0).astype(np.int64);xl,xh,yl,yh=ix-ex,ix+1+ex,iy-ex,iy+1+ex
        maxw=maxh=maxwords=total=0
        for ty in range(90):
          for tx in range(10):
            sl=np.s_[ty*8:(ty+1)*8,tx*128:(tx+1)*128];sel=v[sl]
            if sel.any():
                x0=int(xl[sl][sel].min())//16*16;y0=int(yl[sl][sel].min())//2*2
                x1=(int(xh[sl][sel].max())//16+1)*16;y1=(int(yh[sl][sel].max())//2+1)*2
            else:x0,y0,x1,y1=672,372,688,376
            w,h=x1-x0,y1-y0;assert w<=240 and h<=64 and w*h//4<=2048 and x1<=1280 and y1<=720,(vid,tx,ty,w,h)
            maxw=max(maxw,w);maxh=max(maxh,h);maxwords=max(maxwords,w*h//4);total+=w*h
            rois.append((h<<40)|(w<<32)|(y0<<16)|x0)
        stats=dict(view=vid,valid_output_pixels=int(v.sum()),maximum_roi_width=maxw,maximum_roi_height=maxh,maximum_words_per_parity_bank=maxwords,prefetch_pixels=total)
        (OUT/f'balanced_layout_{vid}.json').write_text(json.dumps(stats,indent=2),encoding='utf-8')
        if '--frames' in sys.argv:frame_gold(vid,sx,sy,b,v)
        print('Generated layout',vid,stats,flush=True)
    mem('display_spans_a.mem',da,6);mem('display_spans_b.mem',db,6);mem('rect_quad_roi.mem',rois,12)
    (OUT/'balanced_mapping_report.json').write_text(json.dumps(dict(output_size=[1280,720],display_hz=60,single_native_pane=[640,360],quad_panel=[640,360],coordinate_latency_clocks=16,mesh_anchor_step=16,mesh_parity_bank_depth=943,mesh_views=5,angular_mask=False,no_q_or_z_domain_clipping=True,pixel_interpolation_changed=False,views=report,measured_MTF=False),indent=2),encoding='utf-8')

if __name__=='__main__':main()
