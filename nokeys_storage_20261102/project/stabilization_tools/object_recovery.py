"""Bounded appearance search for a selected object; no category or face model."""
import cv2
import numpy as np

def overlap(a,b):
    x=max(a[0],b[0]);y=max(a[1],b[1]);right=min(a[0]+a[2],b[0]+b[2]);bottom=min(a[1]+a[3],b[1]+b[3])
    area=max(0,right-x)*max(0,bottom-y)
    return area/max(1,a[2]*a[3]+b[2]*b[3]-area)

class ObjectRecovery:
    def __init__(self,patch):
        self.height,self.width=patch.shape[:2]
        self.gray=cv2.GaussianBlur(cv2.cvtColor(patch,cv2.COLOR_BGR2GRAY),(3,3),.7)
        self.hist=self.histogram(patch);self.pending=None;self.confirmed=0
        self.orb=cv2.ORB_create(nfeatures=500,edgeThreshold=7,patchSize=15,fastThreshold=12)
        self.points,self.descriptors=self.orb.detectAndCompute(self.gray,None)
        self.reason=''

    @staticmethod
    def histogram(patch):
        hsv=cv2.cvtColor(patch,cv2.COLOR_BGR2HSV)
        hist=cv2.calcHist([hsv],[0,1],None,[12,8],[0,180,0,256]);cv2.normalize(hist,hist)
        return hist

    def score(self,image,box,correlation):
        x,y,w,h=map(int,box)
        if w<12 or h<12 or x<0 or y<0 or x+w>image.shape[1] or y+h>image.shape[0]:return None
        patch=image[y:y+h,x:x+w]
        if patch.std()<5:return None
        color=1-float(cv2.compareHist(self.hist,self.histogram(patch),cv2.HISTCMP_BHATTACHARYYA))
        if color<.5 or correlation<.53:return None
        return dict(bbox=[x,y,w,h],score=.8*correlation+.2*color)

    def find(self,image):
        gray=cv2.GaussianBlur(cv2.cvtColor(image,cv2.COLOR_BGR2GRAY),(3,3),.7)
        candidates=[]
        # Search at half resolution. Exactly five scales, at most two peaks each.
        small=cv2.resize(gray,(320,180),interpolation=cv2.INTER_AREA)
        for scale in (.6,.8,1.,1.25,1.6):
            w=round(self.width*scale/2);h=round(self.height*scale/2)
            if w<6 or h<6 or w>315 or h>175:continue
            template=cv2.resize(self.gray,(w,h),interpolation=cv2.INTER_AREA)
            scores=cv2.matchTemplate(small,template,cv2.TM_CCOEFF_NORMED)
            for _ in range(2):
                _,peak,_,point=cv2.minMaxLoc(scores)
                if peak<.56:break
                x,y=point;box=[x*2,y*2,w*2,h*2]
                item=self.score(image,box,float(peak))
                if item:candidates.append(item)
                scores[max(0,y-h//2):min(scores.shape[0],y+h//2+1),max(0,x-w//2):min(scores.shape[1],x+w//2+1)]=-1
        # ORB handles moderate rotation/scale, checked again against appearance.
        if self.descriptors is not None and len(self.descriptors)>=8:
            kp,des=self.orb.detectAndCompute(gray,None)
            if des is not None and len(des)>=8:
                pairs=cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(self.descriptors,des,k=2)
                good=[a for pair in pairs if len(pair)==2 for a,b in [pair] if a.distance<.72*b.distance]
                if len(good)>=8:
                    src=np.float32([self.points[m.queryIdx].pt for m in good]);dst=np.float32([kp[m.trainIdx].pt for m in good])
                    transform,inliers=cv2.estimateAffinePartial2D(src,dst,method=cv2.RANSAC,ransacReprojThreshold=3,maxIters=300)
                    if transform is not None and int(inliers.sum())>=8 and float(inliers.mean())>=.6:
                        corners=np.float32([[0,0],[self.width,0],[0,self.height],[self.width,self.height]])
                        moved=cv2.transform(corners[None],transform)[0];low=np.floor(moved.min(axis=0)).astype(int);high=np.ceil(moved.max(axis=0)).astype(int)
                        box=[*low,*(high-low)]
                        if .35<=box[2]/self.width<=2.5 and .35<=box[3]/self.height<=2.5:
                            x,y,w,h=map(int,box)
                            if x>=0 and y>=0 and x+w<=640 and y+h<=360:
                                patch=cv2.resize(gray[y:y+h,x:x+w],(self.width,self.height))
                                correlation=float(cv2.matchTemplate(patch,self.gray,cv2.TM_CCOEFF_NORMED)[0,0])
                                item=self.score(image,box,correlation)
                                if item:candidates.append(item)
        candidates.sort(key=lambda a:a['score'],reverse=True)
        distinct=[]
        for item in candidates:
            if all(overlap(item['bbox'],old['bbox'])<.3 for old in distinct):distinct.append(item)
        if not distinct:self.pending=None;self.reason='等待原目标重新出现';return None
        best=distinct[0]
        if best['score']<.67 or (len(distinct)>1 and distinct[1]['score']>best['score']-.07):
            self.pending=None;self.reason='候选外观相近，等待更明确的原目标';return None
        previous=self.pending
        count=previous['count']+1 if previous and overlap(previous['bbox'],best['bbox'])>.35 else 1
        self.pending=dict(bbox=best['bbox'],count=count)
        self.reason=f'正在确认原目标 {count}/3'
        if count<3:return None
        self.confirmed+=1;self.pending=None;self.reason='原目标外观与位置连续确认，已自动接续'
        return best
