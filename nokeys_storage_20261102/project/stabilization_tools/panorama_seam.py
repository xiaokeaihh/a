"""Small seam plan; full panoramas are still projected in bounded strips."""
import math
import cv2
import numpy as np

def project_strip(image,orientation,k,d,width,height,y0,y1):
    f=width/(2*math.pi)
    yaw=(np.arange(width,dtype=np.float32)+.5-width/2)/f
    elevation=(np.arange(y0,y1,dtype=np.float32)+.5-height/2)/f
    x=np.broadcast_to(np.sin(yaw),(y1-y0,width));z=np.broadcast_to(np.cos(yaw),x.shape)
    world=np.stack([x,np.broadcast_to(elevation[:,None],x.shape),z],axis=-1)
    cam=world@np.asarray(orientation,np.float32)
    radius=np.hypot(cam[:,:,0],cam[:,:,1]);theta=np.arctan2(radius,cam[:,:,2]);t2=theta*theta
    td=theta*(1+d[0]*t2+d[1]*t2*t2+d[2]*t2**3+d[3]*t2**4)
    scale=td/np.maximum(radius,1e-7)
    mx=(k[0,0]*cam[:,:,0]*scale+k[0,2]).astype(np.float32)
    my=(k[1,1]*cam[:,:,1]*scale+k[1,2]).astype(np.float32)
    ih,iw=image.shape[:2]
    valid=(theta<1.42)&(mx>=2)&(mx<iw-3)&(my>=2)&(my<ih-3)
    valid&=~(((mx>=1085)|(mx<=194))&(my>=685))
    color=cv2.remap(image,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
    weight=valid.astype(np.float32)*np.maximum(np.cos(theta),0)**4
    weight*=np.clip(np.minimum.reduce([mx/32,(iw-1-mx)/32,my/32,(ih-1-my)/32]),0,1)
    return color,weight

def seam_plan(old,old_weight,image,orientation,k,d):
    # 512 x 128 bounds seam-finder work for preview AND full resolution.
    size=(512,128)
    previous=cv2.resize(old,size,interpolation=cv2.INTER_AREA)
    previous_weight=cv2.resize(old_weight,size,interpolation=cv2.INTER_NEAREST)
    incoming,weight=project_strip(image,orientation,k,d,*size,0,size[1])
    overlap=(previous_weight>.15)&(weight>.15)
    gain=1.
    if overlap.sum()>100:
        a=previous[overlap].mean(axis=1);b=incoming[overlap].mean(axis=1)
        good=(a>25)&(a<220)&(b>25)&(b<220)
        if good.sum()>60:gain=float(np.clip(np.median(a[good]/b[good]),.8,1.25))
    incoming=np.clip(incoming.astype(np.float32)*gain,0,255)
    # Keep the optical-axis preference: route the seam through the region
    # where both lenses have comparable quality, not a far-rim observation
    # that would overwrite a clear central sample merely by arriving later.
    old_mask=((previous_weight>0)&((weight==0)|(previous_weight>=weight*.55))).astype(np.uint8)*255
    new_mask=((weight>0)&((previous_weight==0)|(weight>=previous_weight*.55))).astype(np.uint8)*255
    if overlap.sum()<100 or np.count_nonzero((new_mask>0)&(old_mask==0))<8:return gain,None,False
    try:
        masks=cv2.detail_DpSeamFinder('COLOR_GRAD').find(
            [previous.astype(np.float32),incoming],[(0,0),(0,0)],[old_mask,new_mask])
        take=masks[1].get() if hasattr(masks[1],'get') else masks[1]
        return gain,take,True
    except cv2.error:
        # Keep valid optical-axis selection if disconnected masks have no DP
        # seam. Never blend displaced edges to conceal a fitting failure.
        return gain,None,False
