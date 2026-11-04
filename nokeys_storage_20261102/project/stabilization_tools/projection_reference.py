from pathlib import Path
import json, math
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'source/design_fisheye_5frame_720p60_pipeline/data'
CFG=json.loads((DATA/'baseline_config.json').read_text())
VIEWS=json.loads((DATA/'balanced_config.json').read_text())

def matrix(rotation=np.eye(3), zoom=1.0):
    k=np.array(CFG['output_K'],float); k[0,0]*=zoom;k[1,1]*=zoom
    return np.rint(rotation@np.linalg.inv(k)*(1<<24)).astype(np.int64)

def view_matrices(compensation=np.eye(3),zoom=1.0,image_y_sign=1):
    """Baseline, four native 640x360 panes, then the 134-degree center pane."""
    sign=np.diag([1,image_y_sign,1]);result=[matrix(sign@compensation@sign,zoom)]
    for c in [v['config'] for v in VIEWS['quadrants']]+[VIEWS['central_full']['config']]:
        f=1280/(2*math.tan(math.radians(c['hfov']/2)))
        k=np.array([[f*zoom,0,c['cx']],[0,f*zoom*CFG['source_K'][1][1]/CFG['source_K'][0][0],c['cy']],[0,0,1.]])
        yaw,pitch=np.radians([c['yaw'],c['pitch']]);cy,sy,cp,sp=math.cos(yaw),math.sin(yaw),math.cos(pitch),math.sin(pitch)
        view=np.array([[cy,0,sy],[0,1,0],[-sy,0,cy]])@np.array([[1,0,0],[0,cp,sp],[0,-sp,cp]])
        # Sensor/image convention applies to both sides of compensation; the
        # established view rotations and DDR coordinate conventions stay fixed.
        h=sign@compensation@sign@view@np.linalg.inv(k)@np.diag([2,2,1])
        result.append(np.rint(h*(1<<24)).astype(np.int64))
    return result

def active_view_matrix(view,compensation=np.eye(3),zoom=1.0,image_y_sign=1):
    """Exactly the former BASE or CENTER matrix, without forming four corners."""
    sign=np.diag([1,image_y_sign,1])
    if view==7:return matrix(sign@compensation@sign,zoom)
    if view!=6:raise ValueError('Static corner views do not accept dynamic poses')
    c=VIEWS['central_full']['config']
    f=1280/(2*math.tan(math.radians(c['hfov']/2)))
    k=np.array([[f*zoom,0,c['cx']],[0,f*zoom*CFG['source_K'][1][1]/CFG['source_K'][0][0],c['cy']],[0,0,1.]])
    yaw,pitch=np.radians([c['yaw'],c['pitch']]);cy,sy,cp,sp=math.cos(yaw),math.sin(yaw),math.cos(pitch),math.sin(pitch)
    view_rotation=np.array([[cy,0,sy],[0,1,0],[-sy,0,cy]])@np.array([[1,0,0],[0,cp,sp],[0,-sp,cp]])
    h=sign@compensation@sign@view_rotation@np.linalg.inv(k)@np.diag([2,2,1])
    return np.rint(h*(1<<24)).astype(np.int64)

def rotation(roll=0,pitch=0,yaw=0):
    a,b,c=np.radians([roll,pitch,yaw]);ca,sa,cb,sb,cc,sc=math.cos(a),math.sin(a),math.cos(b),math.sin(b),math.cos(c),math.sin(c)
    rz=np.array([[ca,-sa,0],[sa,ca,0],[0,0,1]])
    rx=np.array([[1,0,0],[0,cb,-sb],[0,sb,cb]])
    ry=np.array([[cc,0,sc],[0,1,0],[-sc,0,cc]])
    return rz@rx@ry

def fixed_project(u,v,h):
    x,y,z=h@np.array([u,v,1],dtype=np.int64)
    good=z>=262144 and z<67108864
    e=max(int(z).bit_length()-1-24,-6) if z>0 else -6
    norm=int(z)>>e if e>=0 else int(z)<<-e
    idx=(norm>>14)&1023
    seed=round((1<<24)/(1+(idx+.5)/1024))
    inv=(seed*((1<<25)-((norm*seed)>>24)))>>24
    inv=inv>>e if e>=0 else inv<<-e
    nx=(int(x)*inv+(1<<31))>>32;ny=(int(y)*inv+(1<<31))>>32
    good=good and abs(nx)<=4194304 and abs(ny)<=4194304
    r2=nx*nx+ny*ny
    radius_ok=r2<4096*(1<<32);good=good and radius_ok
    far=radius_ok and r2>=64*(1<<32)
    i=(r2>>32)-64 if far else r2>>26 if radius_ok else 0;frac=(r2>>(24 if far else 18))&255
    def gain(j,axis):
        r=math.sqrt(64+j if far else j/64);t=math.atan(r)
        td=t*(1+sum(k*t**(2*n+2) for n,k in enumerate(CFG['source_D'])))
        return round(CFG['source_K'][axis][axis]*(td/r if r else 1)*4096)
    out=[]
    for n,q in enumerate([nx,ny]):
        a,b=gain(i,n),gain(i+1,n)
        g=a+((b-a)*frac+128>>8)
        center=round(CFG['source_K'][n][2]*(1<<28))
        value=q*g+center+(1<<19)
        good=good and value>=0 and value<([1279,719][n]<<28)
        out.append((value>>20)&((1<<20)-1))
    return *out,bool(good)

def float_project(u,v,h):
    x,y,z=(h/(1<<24))@np.array([u,v,1])
    if z<=0:return float('nan'),float('nan')
    nx,ny=x/z,y/z;r=math.hypot(nx,ny);t=math.atan(r)
    td=t*(1+sum(k*t**(2*n+2) for n,k in enumerate(CFG['source_D'])))
    g=td/r if r else 1
    return CFG['source_K'][0][2]+CFG['source_K'][0][0]*nx*g,CFG['source_K'][1][2]+CFG['source_K'][1][1]*ny*g

if __name__=='__main__':
    out=ROOT/'verification_stabilization';out.mkdir(exist_ok=True)
    rng=np.random.default_rng(72); cases=[]
    angles=[(0,0,0),(45,0,0),(90,0,0),(180,0,0),(-90,0,0),(359,0,0),(35,20,-25),(120,-30,35),(0,85,0),(0,180,0)]
    worst=0.0
    for case,(r,p,y) in enumerate(angles):
        h=matrix(rotation(r,p,y))
        for u,v in [(0,0),(1279,0),(0,719),(1279,719),(639,359)]+[tuple(a) for a in rng.integers([0,0],[1280,720],size=(300,2))]:
            sx,sy,valid=fixed_project(int(u),int(v),h)
            fx,fy=float_project(u,v,h)
            if valid: worst=max(worst,abs(sx/256-fx),abs(sy/256-fy))
            packed=sum((int(a)&0xffffffff)<<(32*i) for i,a in enumerate(h.flat))
            cases.append(f'{u:03x} {v:03x} {packed:072x} {sx:05x} {sy:05x} {int(valid)}')
    for r,p,y in [(0,0,0),(90,0,0),(180,0,0),(25,20,-15)]:
        for h in view_matrices(rotation(r,p,y))[1:]:
            for u,v in [(0,0),(639,0),(0,359),(639,359),(319,179)]+[tuple(a) for a in rng.integers([0,0],[640,360],size=(100,2))]:
                sx,sy,valid=fixed_project(int(u),int(v),h);fx,fy=float_project(u,v,h)
                if valid:worst=max(worst,abs(sx/256-fx),abs(sy/256-fy))
                packed=sum((int(a)&0xffffffff)<<(32*i) for i,a in enumerate(h.flat))
                cases.append(f'{u:03x} {v:03x} {packed:072x} {sx:05x} {sy:05x} {int(valid)}')
    (out/'projection_vectors.txt').write_text('\n'.join(cases)+'\n')
    assert worst<0.03,worst
    (out/'projection_accuracy.json').write_text(json.dumps({'vectors':len(cases),'max_fixed_vs_float_coordinate_error_px':worst,'passed':True},indent=2))
    print('PASS floating reference',len(cases),'vectors, worst pixel error',worst)
