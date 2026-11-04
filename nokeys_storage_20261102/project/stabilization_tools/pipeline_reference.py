"""Shared preset geometry and exact Q8 bilinear reference for the pipeline RTL."""
import math
import numpy as np
from projection_reference import ROOT,DATA,CFG,VIEWS,view_matrices
from generate_frame_gold import fixed_map

def local0():
    c=VIEWS['fixed_view0'];f=1280/(2*math.tan(math.radians(c['hfov']/2)))
    k=np.array([[f,0,c['cx']],[0,f*CFG['source_K'][1][1]/CFG['source_K'][0][0],c['cy']],[0,0,1.]])
    return np.rint(np.linalg.inv(k)@np.diag([2,2,1])*(1<<24)).astype(np.int64)

def bundle_for(view):
    h=view_matrices()
    if view==0:h[0]=local0()
    return h

def pack_bundle(h):
    return sum((int(a)&0xffffffff)<<(32*j) for j,a in enumerate(np.asarray(h).ravel()))

def map_pane(h,width,height,fixed):
    v,u=np.indices((height,width),dtype=np.int64)
    if fixed:return fixed_map(h,u,v)
    ray=(h.astype(float)/(1<<24))@np.stack([u,v,np.ones_like(u)]).reshape(3,-1)
    ray=ray.reshape(3,height,width);x,y,z=ray
    nx=np.divide(x,z,out=np.zeros_like(x),where=z!=0);ny=np.divide(y,z,out=np.zeros_like(y),where=z!=0)
    r=np.hypot(nx,ny);t=np.arctan(r);d=CFG['source_D'];t2=t*t
    td=t*(1+t2*(d[0]+t2*(d[1]+t2*(d[2]+t2*d[3]))))
    g=np.divide(td,r,out=np.ones_like(t),where=r!=0)
    sx=CFG['source_K'][0][0]*nx*g+CFG['source_K'][0][2]
    sy=CFG['source_K'][1][1]*ny*g+CFG['source_K'][1][2]
    valid=(z>=1/64)&(z<4)&(r<64)&(sx>=0)&(sx<1279)&(sy>=0)&(sy<719)
    return sx,sy,valid

def maps(view,fixed=True):
    h=bundle_for(view);out=[np.zeros((720,1280),np.int64 if fixed else float),np.zeros((720,1280),np.int64 if fixed else float),np.zeros((720,1280),bool)]
    if view==7:parts=[(0,slice(None),slice(None),1280,720)]
    elif view==5:parts=[(3,slice(0,360),slice(0,640),640,360),(4,slice(0,360),slice(640,1280),640,360),(1,slice(360,720),slice(0,640),640,360),(2,slice(360,720),slice(640,1280),640,360)]
    else:parts=[(0 if view==0 else 5 if view==6 else view,slice(180,540),slice(320,960),640,360)]
    for slot,ys,xs,w,hh in parts:
        result=map_pane(h[slot],w,hh,fixed)
        for j in range(3):out[j][ys,xs]=result[j]
    return out[0],out[1],np.zeros((720,1280)),out[2]

def bilinear(source,sx,sy,valid,fixed=True):
    x=sx if fixed else sx*256;y=sy if fixed else sy*256
    ix=np.floor(x/256).astype(np.int64);iy=np.floor(y/256).astype(np.int64)
    fx=(x.astype(np.int64)&255) if fixed else x-ix*256
    fy=(y.astype(np.int64)&255) if fixed else y-iy*256
    ps=[source[np.clip(iy+dy,0,719),np.clip(ix+dx,0,1279)].astype(np.int64) for dy,dx in [(0,0),(0,1),(1,0),(1,1)]]
    result=np.zeros_like(ix)
    for shift,mask in [(11,31),(5,63),(0,31)]:
        a,b,c,d=[(p>>shift)&mask for p in ps]
        q=((a*(256-fx)+b*fx)*(256-fy)+(c*(256-fx)+d*fx)*fy+32768)
        q=(q>>16) if fixed else np.floor(q/65536).astype(np.int64)
        result|=q<<shift
    return np.where(valid,result,0).astype(np.uint16)

def generate_constants():
    (DATA/'pipeline_view_constants.vh').write_text(f"`define PIPELINE_STATIC_BUNDLE 1728'h{pack_bundle(view_matrices()):0432x}\n`define PIPELINE_STATIC_LOCAL0 288'h{pack_bundle([local0()]):072x}\n",encoding='ascii')

if __name__=='__main__':generate_constants();print('Generated fixed preset matrices from current calibrated K/D and balanced geometry')
