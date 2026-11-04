"""Wide-angle ray mapping and native-pixel view selection; no camera refit."""
from pathlib import Path
import json
import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'source/design_fisheye_5frame_720p60_pipeline/data'
OUT=ROOT/'verification_quality'
W,H=1280,720
CAL=json.loads((DATA/'calibration_720p.json').read_text(encoding='utf-8'))
K=np.array(CAL['calibration']['K']); D=np.array(CAL['calibration']['D']).ravel()
mask=cv2.imdecode(np.fromfile(DATA/'source_content_mask.png',np.uint8),0)
contours,_=cv2.findContours(mask,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
# Historical OSD holes are not lens boundaries. Retain the outer component.
OPTICAL=np.zeros_like(mask)
cv2.drawContours(OPTICAL,[max(contours,key=cv2.contourArea)],-1,255,cv2.FILLED)
DIST=cv2.distanceTransform(np.pad(OPTICAL,1),cv2.DIST_L2,cv2.DIST_MASK_PRECISE)[1:-1,1:-1]
BT=np.full(2049,256,dtype=np.int64)
BT[:1025:2]=[int(x,16) for x in (DATA/'blend_even.mem').read_text(encoding='ascii').split()]
BT[1:1025:2]=[int(x,16) for x in (DATA/'blend_odd.mem').read_text(encoding='ascii').split()][:512]

def matrix(c):
    f=W/(2*np.tan(np.deg2rad(c['hfov']/2)))
    return np.array([[f,0,c['cx']],[0,f*K[1,1]/K[0,0],c['cy']],[0,0,1.]])

def project(c,x,y):
    p=matrix(c); t,a=np.deg2rad([c['yaw'],c['pitch']])
    R=np.array([[np.cos(t),0,np.sin(t)],[0,1,0],[-np.sin(t),0,np.cos(t)]]) @ np.array([[1,0,0],[0,np.cos(a),np.sin(a)],[0,-np.sin(a),np.cos(a)]])
    X,Y,Z=(R@np.stack([(x-c['cx'])/p[0,0],(y-c['cy'])/p[1,1],np.ones_like(x)]).reshape(3,-1)).reshape((3,)+x.shape)
    rho=np.hypot(X,Y); theta=np.arctan2(rho,Z); t2=theta*theta
    rd=theta*(1+t2*(D[0]+t2*(D[1]+t2*(D[2]+t2*D[3]))))
    gain=np.divide(rd,rho,out=np.zeros_like(rd),where=rho>1e-12)
    sx=K[0,2]+K[0,0]*X*gain; sy=K[1,2]+K[1,1]*Y*gain
    q=np.minimum(np.tan(theta)**2,32)
    blend=np.interp(q*64,np.arange(2049),BT)
    slope=1+t2*(3*D[0]+t2*(5*D[1]+t2*(7*D[2]+t2*9*D[3])))
    return sx,sy,blend,slope,theta

def valid_neighborhood(sx,sy,blend,margin=2.):
    ix=np.floor(sx).astype(np.int64);iy=np.floor(sy).astype(np.int64)
    ex=(blend>0).astype(np.int64);xl=ix-ex;xh=ix+1+ex;yl=iy-ex;yh=iy+1+ex
    # The historical mask includes capture OSD notches. It cannot be used as
    # a reliable lens boundary. Keep actual source-frame neighborhoods safe;
    # preserve the mask only as diagnostic data, without cropping by it.
    m=int(np.ceil(margin))
    v=(xl>=m)&(xh<W-m)&(yl>=m)&(yh<H-m)
    return v

def metrics(c):
    y,x=np.meshgrid(np.linspace(0,H-1,37),np.linspace(0,W-1,65),indexing='ij')
    sx,sy,b,slope,theta=project(c,x,y);valid=valid_neighborhood(sx,sy,b)&(slope>0)
    x_y,x_x=np.gradient(sx,(H-1)/36,(W-1)/64)
    y_y,y_x=np.gradient(sy,(H-1)/36,(W-1)/64)
    a=x_x*x_x+y_x*y_x;bb=x_x*x_y+y_x*y_y;d=x_y*x_y+y_y*y_y
    low=np.sqrt(np.maximum((a+d-np.sqrt((a-d)**2+4*bb*bb))/2,1e-15))
    # Each final pane is 640x360: sampling is directly at every second
    # canonical coordinate, not a second image resize.
    mag=1/(2*low)
    return dict(black_fraction=float(1-valid.mean()),maximum_pane_magnification=float(mag[valid].max()),
                center_pane_magnification=float(mag[18,32]),maximum_source_angle_deg=float(np.rad2deg(theta[valid]).max()))

def footprint(c):
    y,x=np.indices((360,640));sx,sy,b,slope,_=project(c,x*2.,y*2.)
    v=valid_neighborhood(sx,sy,b)&(slope>0)
    fp=np.zeros((H,W),np.uint8);fp[np.clip(np.rint(sy[v]).astype(int),0,H-1),np.clip(np.rint(sx[v]).astype(int),0,W-1)]=1
    return cv2.dilate(fp,np.ones((3,3),np.uint8))

def optimize():
    candidates=[];chosen=[]
    for vid,sxsign,sysign in [(1,-1,1),(2,1,1),(3,-1,-1),(4,1,-1)]:
        old=dict(yaw=35*sxsign,pitch=15*sysign,hfov=100,cx=639.5,cy=359.5)
        basefp=footprint(old); denom=int(basefp.sum())
        options=[]
        for yaw in [31,33,35,37,39]:
          for pitch in [11,13,15,17,19]:
           for hfov in [92,94,96,98,100]:
            for dx in [-32,0,32]:
             for dy in [-24,0,24]:
              c=dict(yaw=yaw*sxsign,pitch=pitch*sysign,hfov=hfov,cx=639.5+dx,cy=359.5+dy)
              m=metrics(c)
              # Initial engineering bounds, not optical MTF claims.
              if m['black_fraction']>.02 or m['center_pane_magnification']>1.10 or m['maximum_pane_magnification']>4.0:continue
              score=m['black_fraction']*120+max(m['maximum_pane_magnification']-2,0)*.15
              score+=(100-hfov)*.012+(abs(yaw-35)+abs(pitch-15))*.003+(abs(dx)/32+abs(dy)/24)*.001
              options.append(dict(id=vid,config=c,metrics=m,score=score))
        options.sort(key=lambda a:a['score'])
        accepted=[]
        for candidate in options:
            fp=footprint(candidate['config']); retained=float((fp&basefp).sum()/max(denom,1))
            candidate['retained_previous_unlimited_source_footprint']=retained
            if retained>=.93:accepted.append(candidate)
            if len(accepted)>=12:break
        baseline_metrics=metrics(old)
        accepted.append(dict(id=vid,config=old,metrics=baseline_metrics,
          score=baseline_metrics['black_fraction']*120+max(baseline_metrics['maximum_pane_magnification']-2,0)*.15,
          retained_previous_unlimited_source_footprint=1.0))
        if not accepted:raise RuntimeError(f'No acceptable candidate for quadrant {vid}')
        best=min(accepted,key=lambda a:a['score']);chosen.append(best);candidates.extend(accepted)
        print('Selected quadrant',vid,best,flush=True)
    oldunion=np.maximum.reduce([footprint(dict(yaw=sx*35,pitch=sy*15,hfov=100,cx=639.5,cy=359.5)) for sx,sy in [(-1,1),(1,1),(-1,-1),(1,-1)]])
    fp_cache={json.dumps(c['config'],sort_keys=True):footprint(c['config']) for c in candidates}
    def union_retained(selected):
        union=np.maximum.reduce([fp_cache[json.dumps(c['config'],sort_keys=True)] for c in selected])
        return float((oldunion&union).sum()/max(oldunion.sum(),1))
    retained=union_retained(chosen)
    for iteration in range(16):
        if retained>=.95:break
        alternatives=[]
        for index,current in enumerate(chosen):
            for c in candidates:
                if c['id']!=current['id']:continue
                test=chosen.copy();test[index]=c;newret=union_retained(test)
                if newret>retained+1e-5:
                    alternatives.append(((newret-retained)/(max(c['score']-current['score'],0)+.01),index,c,newret))
        if not alternatives:raise RuntimeError('Joint view coverage cannot satisfy retention bound')
        _,index,c,retained=max(alternatives,key=lambda a:a[0]);chosen[index]=c
    if retained<.95:raise RuntimeError(f'Overall source footprint retention too low: {retained}')
    mids=[]
    for hfov in range(112,145,2):
      for dx in [-32,-16,0,16,32]:
       for dy in [-24,-12,0,12,24]:
        c=dict(yaw=0,pitch=0,hfov=hfov,cx=639.5+dx,cy=359.5+dy);m=metrics(c)
        if m['black_fraction']<=.01 and m['maximum_pane_magnification']<=4.0:
            mids.append(dict(id=6,config=c,metrics=m,score=-hfov+m['black_fraction']*100+(abs(dx)/32+abs(dy)/24)*.01))
    if not mids:raise RuntimeError('No acceptable central full-view candidate')
    mid=min(mids,key=lambda a:a['score']);print('Selected central full view',mid,flush=True)
    cfg=dict(output_size=[W,H],single_final_pane=[640,360],single_DDR_viewport=[320,180,640,360],
      fixed_view0=dict(yaw=0,pitch=0,hfov=100,cx=639.5,cy=359.5),quadrants=chosen,central_full=mid,
      retained_previous_unlimited_four_view_source_footprint=retained,
      geometric_bounds=dict(max_black_fraction_local=.02,max_black_fraction_center=.01,
      max_local_center_pane_magnification=1.1,max_pane_magnification=4.0,min_union_coverage_retention=.95),
      measured_MTF=False,measured_straightness=False,camera_K_D_changed=False,
      math='atan2(hypot(X,Y),Z) ray-to-source KB polynomial; no q<32 or z>=0.25 clipping',
      source_mask='historical mask retained only for diagnostics; actual frame bounds and 2px interpolation margin')
    (DATA/'balanced_config.json').write_text(json.dumps(cfg,indent=2),encoding='utf-8')
    (OUT/'balanced_candidates.json').write_text(json.dumps(dict(selected=cfg,local_candidates=candidates,central_candidates=mids),indent=2),encoding='utf-8')
    cv2.imencode('.png',OPTICAL)[1].tofile(DATA/'source_outer_valid_mask.png')
    return cfg

if __name__=='__main__':optimize()
