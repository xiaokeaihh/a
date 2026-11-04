"""Bounded visual registration for the calibrated camera RAW axes."""
import math
import cv2
import numpy as np
from auto_alignment import fit_rotation

def ray_points(points,k,d):
    xy=cv2.fisheye.undistortPoints(np.asarray(points,np.float64).reshape(-1,1,2),k,d).reshape(-1,2)
    a=np.c_[xy,np.ones(len(xy))]
    return a/np.linalg.norm(a,axis=1)[:,None]

def angular_errors(a,b,r):
    # atan2 is accurate for sub-pixel angles, including near zero.
    p=a@r.T
    return np.degrees(np.arctan2(np.linalg.norm(np.cross(p,b),axis=1),np.sum(p*b,axis=1)))

def robust_rotation(a,b):
    a=np.asarray(a,float);b=np.asarray(b,float)
    if len(a)<25:raise ValueError('有效匹配不足，请慢扫并保持与上一方向重叠')
    rng=np.random.default_rng(23);best=np.zeros(len(a),bool);best_score=float('inf')
    for _ in range(180):
        pick=rng.choice(len(a),3,replace=False)
        if np.linalg.norm(np.cross(a[pick[1]]-a[pick[0]],a[pick[2]]-a[pick[0]]))<.001:continue
        r=fit_rotation(a[pick],b[pick]);res=angular_errors(a,b,r);good=res<.40
        score=float(np.median(res[good])) if good.any() else float('inf')
        if good.sum()>best.sum() or (good.sum()==best.sum() and score<best_score):best,best_score=good,score
    if best.sum()<25 or best.mean()<.40:
        raise ValueError('重叠不足、重复纹理或明显平移，请回到上一方向并绕镜头转动')
    for _ in range(3):
        r=fit_rotation(a[best],b[best]);res=angular_errors(a,b,r)
        threshold=min(.35,max(.12,float(np.median(res[best]))*2.5+.04))
        trimmed=res<threshold
        if trimmed.sum()<25:break
        best=trimmed
    r=fit_rotation(a[best],b[best]);res=angular_errors(a,b,r)
    median=float(np.median(res[best]));tail=float(np.percentile(res[best],90))
    if median>.12 or tail>.30 or best.mean()<.40:
        raise ValueError('配准误差偏大，本帧未拼入；请减少平移、放慢转动并避开近处物体')
    # A small, self-consistent foreground patch must not steer the whole room.
    spread=np.ptp(a[best],axis=0)
    if spread[0]<.16 or spread[1]<.12:
        raise ValueError('匹配集中在小区域，请让更多远处固定纹理进入画面')
    if best.mean()<.60 and np.percentile(res,80)>1.25:
        raise ValueError('近物与背景存在明显视差，本帧未拼入；请绕镜头转动并远离近物')
    return r,int(best.sum()),median

def features(image,k,detector):
    scale=.75
    small=cv2.resize(image,None,fx=scale,fy=scale,interpolation=cv2.INTER_AREA)
    gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
    sg=cv2.cvtColor(small,cv2.COLOR_BGR2GRAY)
    if cv2.Laplacian(cv2.resize(sg,(640,360)),cv2.CV_64F).var()<18:
        raise ValueError('画面模糊，请放慢转动或改善照明')
    yy,xx=np.indices(sg.shape);ks=np.asarray(k)*scale
    radius=((xx-ks[0,2])/ks[0,0])**2+((yy-ks[1,2])/ks[1,1])**2
    mask=(radius<1.30**2).astype(np.uint8)*255
    mask[:12]=mask[-12:]=0;mask[:,:12]=mask[:,-12:]=0
    points,desc=detector.detectAndCompute(sg,mask)
    if desc is None or len(points)<40:
        raise ValueError('固定纹理不足，请对准书架、海报等，避开纯色墙和大面积近物')
    return dict(points=np.asarray([p.pt for p in points],np.float32)/scale,desc=desc,gray=gray)

def match_rotation(previous,current,k,d,matcher,pose=None):
    forward=matcher.knnMatch(previous['desc'],current['desc'],k=2)
    reverse=matcher.knnMatch(current['desc'],previous['desc'],k=2)
    reverse_good={a.queryIdx:a.trainIdx for pair in reverse if len(pair)==2 for a,b in [pair] if a.distance<.75*b.distance}
    matches=[a for pair in forward if len(pair)==2 for a,b in [pair]
             if a.distance<.72*b.distance and reverse_good.get(a.trainIdx)==a.queryIdx]
    # Bound work and prevent a repetitive tile or foreground object from
    # dominating merely because it contains many descriptors.
    selected=[];cells={}
    for m in sorted(matches,key=lambda m:m.distance):
        x,y=previous['points'][m.queryIdx];cell=(int(x//160),int(y//120))
        if cells.get(cell,0)>=10:continue
        cells[cell]=cells.get(cell,0)+1;selected.append(m)
    if len(selected)<25:raise ValueError('重叠纹理不足，请慢扫并回到刚才方向附近')
    pa=np.asarray([previous['points'][m.queryIdx] for m in selected],np.float32)
    pb=np.asarray([current['points'][m.trainIdx] for m in selected],np.float32)
    p0=pa.reshape(-1,1,2);p1=pb.reshape(-1,1,2)
    args=dict(winSize=(21,21),maxLevel=3,criteria=(cv2.TERM_CRITERIA_EPS|cv2.TERM_CRITERIA_COUNT,30,.01),flags=cv2.OPTFLOW_USE_INITIAL_FLOW)
    refined,ok,_=cv2.calcOpticalFlowPyrLK(previous['gray'],current['gray'],p0,p1.copy(),**args)
    if refined is None:raise ValueError('图像跟踪失败，请放慢转动')
    back,bok,_=cv2.calcOpticalFlowPyrLK(current['gray'],previous['gray'],refined,p0.copy(),**args)
    if back is None:raise ValueError('图像跟踪失败，请放慢转动')
    good=(ok.ravel()!=0)&(bok.ravel()!=0)
    good&=np.linalg.norm(back[:,0]-pa,axis=1)<.65
    good&=np.linalg.norm(refined[:,0]-pb,axis=1)<5
    a=ray_points(pa[good],k,d);b=ray_points(refined[:,0][good],k,d)
    visual=robust_rotation(a,b)
    # Validate imagery before applying an optional IMU gate. A stale or
    # uncalibrated pose must not select a self-consistent foreground patch
    # and silently prevent a real camera sweep from advancing.
    if pose is not None and previous.get('pose') is not None:
        predicted=pose.T@previous['pose']
        mismatch=np.degrees(np.arccos(np.clip((np.trace(predicted.T@visual[0])-1)/2,-1,1)))
        if mismatch<=5:
            near=np.sum((a@predicted.T)*b,axis=1)>math.cos(math.radians(8))
            if near.sum()>=25 and not near.all():
                try:return robust_rotation(a[near],b[near])
                except ValueError:pass
    return visual

def consensus_orientation(candidates):
    reference=candidates[0][0]
    for orientation,_,_ in candidates[1:]:
        angle=np.degrees(np.arccos(np.clip((np.trace(reference.T@orientation)-1)/2,-1,1)))
        if angle>.45:raise ValueError('相邻关键帧方向不一致，本帧未拼入；请减少平移并回到上一方向')
    total=np.zeros((3,3))
    for orientation,count,residual in candidates:
        total+=orientation*min(count,120)/max(residual,.04)
    u,_,vt=np.linalg.svd(total)
    return u@np.diag([1.,1.,np.linalg.det(u@vt)])@vt
