"""Single selected person, sparse optical flow and bounded recovery."""
import math
import cv2
import numpy as np
from bbox_stabilizer import BoxStabilizer

def clip_box(box):
    x,y,w,h=map(float,box);x2=min(640,max(0,x+w));y2=min(360,max(0,y+h))
    x=min(639,max(0,x));y=min(359,max(0,y))
    return np.array([x,y,max(0,x2-x),max(0,y2-y)],float)

def iou(a,b):
    x=max(a[0],b[0]);y=max(a[1],b[1]);right=min(a[0]+a[2],b[0]+b[2]);bottom=min(a[1]+a[3],b[1]+b[3])
    area=max(0,right-x)*max(0,bottom-y)
    return area/max(1,a[2]*a[3]+b[2]*b[3]-area)

def signature(image,box):
    x,y,w,h=clip_box(box).astype(int)
    # Torso interior reduces hands, feet and background in the identity cue.
    patch=image[y+int(h*.18):y+max(int(h*.75),1),x+int(w*.15):x+max(int(w*.85),1)]
    if patch.size<30:return None
    hsv=cv2.cvtColor(patch,cv2.COLOR_BGR2HSV)
    hist=cv2.calcHist([hsv],[0,1],None,[16,8],[0,180,0,256]);cv2.normalize(hist,hist)
    return hist

def similarity(a,b):
    if a is None or b is None:return .5
    return max(0,1-float(cv2.compareHist(a,b,cv2.HISTCMP_BHATTACHARYYA)))

class PersonTracker:
    def __init__(self):
        self.candidates=[];self.next_id=1;self.selected=None;self.box=None;self.hist=None
        self.previous_gray=None;self.points=None;self.last_seen=0.;self.last_detected=0.;self.last_time=None
        self.score=0.;self.velocity=np.zeros(2);self.recovery_seconds=2.;self.requested=None
        self.reacquire_pending=None;self.reacquire_count=0;self.reacquire_reason='';self.just_reacquired=False
        self.output_box=BoxStabilizer()
        self.size_observed=False

    def select(self,identity):
        candidate=next((c for c in self.candidates if c['id']==identity),None)
        if candidate is None:raise ValueError('此人已不在当前候选中，请等待新画面再点选')
        self.selected=identity;self.box=np.array(candidate['bbox'],float);self.hist=candidate['hist'].copy() if candidate['hist'] is not None else None
        self.last_seen=self.last_detected=candidate['time'];self.score=candidate['score'];self.points=None;self.velocity=np.zeros(2)
        self.reacquire_pending=None
        self.output_box.reset(self.box,candidate['time'])

    def _accept(self,candidate,now,recovered=False,reason=''):
        self.size_observed=True
        appearance=similarity(self.hist,candidate['hist'])
        # A stable sole entrant can be a new person. Keep an old ID only when
        # its appearance supports that claim; following still resumes either way.
        if reason=='single_person' and appearance<.72:self.selected=candidate['id']
        self.box=np.array(candidate['bbox'],float);self.score=candidate['score']
        self.last_seen=self.last_detected=now;candidate['id']=self.selected
        self.candidates=[c for c in self.candidates if c is candidate or c['id']!=self.selected]
        if self.hist is None or (reason=='single_person' and appearance<.72):
            self.hist=candidate['hist'].copy() if candidate['hist'] is not None else None
        elif candidate['hist'] is not None and appearance>.65:self.hist=.97*self.hist+.03*candidate['hist']
        self.points=None;self.reacquire_pending=None
        if recovered:
            self.velocity=np.zeros(2);self.just_reacquired=True
            self.reacquire_count+=1;self.reacquire_reason=reason

    def _reacquire(self,fresh,now,age):
        ranked=sorted(((similarity(self.hist,c['hist']),c) for c in fresh),key=lambda x:x[0],reverse=True)
        candidate=None;reason='';hold=.20
        if ranked and self.hist is not None and ranked[0][0]>=.72 and (len(ranked)==1 or ranked[0][0]-ranked[1][0]>=.12):
            candidate=ranked[0][1];reason='appearance'
        elif len(fresh)==1 and age>self.recovery_seconds:
            candidate=fresh[0];reason='single_person';hold=.35
        if candidate is None:self.reacquire_pending=None;return
        identity=candidate['id'];pending=self.reacquire_pending
        if pending is None or pending['id']!=identity or pending['reason']!=reason or now-pending['last']>.3:
            pending=dict(id=identity,since=now,last=now,hits=1,reason=reason)
        else:pending.update(last=now,hits=pending['hits']+1)
        self.reacquire_pending=pending
        if pending['hits']>=3 and now-pending['since']>=hold:self._accept(candidate,now,True,reason)

    def _points(self,gray):
        if self.box is None:return None
        x,y,w,h=clip_box(self.box).astype(int);mask=np.zeros(gray.shape,np.uint8)
        mask[y+int(h*.1):y+int(h*.9),x+int(w*.1):x+int(w*.9)]=255
        return cv2.goodFeaturesToTrack(gray,maxCorners=60,qualityLevel=.015,minDistance=4,mask=mask,blockSize=5)

    def _flow(self,gray):
        if self.previous_gray is None or self.points is None or len(self.points)<6:return False
        p,ok,_=cv2.calcOpticalFlowPyrLK(self.previous_gray,gray,self.points,None,winSize=(15,15),maxLevel=2)
        if p is None:return False
        back,back_ok,_=cv2.calcOpticalFlowPyrLK(gray,self.previous_gray,p,None,winSize=(15,15),maxLevel=2)
        if back is None:return False
        valid=(ok.ravel()!=0)&(back_ok.ravel()!=0)&(np.linalg.norm((back-self.points).reshape(-1,2),axis=1)<1.5)
        movement=(p-self.points).reshape(-1,2);valid&=np.isfinite(movement).all(axis=1)
        if valid.sum()<6:return False
        delta=np.median(movement[valid],axis=0)
        if np.linalg.norm(delta)>45:return False
        residual=np.linalg.norm(movement[valid]-delta,axis=1)
        if np.median(residual)>5:return False
        self.box[:2]+=delta;self.box=clip_box(self.box);self.points=p[valid].reshape(-1,1,2)
        return self.box[2]>=12 and self.box[3]>=24

    def step(self,image,now,detections=None):
        self.just_reacquired=False
        self.size_observed=False
        gray=cv2.cvtColor(image,cv2.COLOR_BGR2GRAY)
        elapsed=0 if self.last_time is None else max(0,now-self.last_time)
        before=self.box.copy() if self.box is not None else None
        flow=False
        if self.selected is not None and elapsed<.25 and now-self.last_detected<.35:flow=self._flow(gray)
        if flow:self.last_seen=now
        if detections is not None:
            fresh=[];used=set()
            for det in detections:
                box=clip_box(det['bbox']);hist=signature(image,box)
                matches=[]
                for old in self.candidates:
                    if old['id'] in used or now-old['time']>self.recovery_seconds:continue
                    overlap=iou(box,old['bbox']);appearance=similarity(hist,old['hist'])
                    distance=np.linalg.norm((box[:2]+box[2:]/2)-(np.array(old['bbox'][:2])+np.array(old['bbox'][2:])/2))/max(40,np.linalg.norm(box[2:]))
                    if (overlap>.15 and appearance>.2) or (distance<.65 and appearance>.72):
                        matches.append((overlap+.35*appearance-.15*distance,old['id']))
                identity=max(matches)[1] if matches else self.next_id
                if not matches:self.next_id+=1
                used.add(identity);fresh.append(dict(id=identity,bbox=box.tolist(),hist=hist,time=now,score=det['score']))
            # Retain only compact descriptors during short occlusions.
            self.candidates=fresh+[c for c in self.candidates if c['id'] not in used and now-c['time']<self.recovery_seconds]
            self.candidates=self.candidates[:24]
            visible_ids={c['id'] for c in fresh}
            if self.selected is None and len(fresh)==1:self.select(fresh[0]['id'])
            if self.selected is not None and self.box is not None:
                proposals=[]
                age=now-self.last_detected
                predicted=self.box.copy();predicted[:2]+=self.velocity*min(age,.25)
                for candidate in fresh:
                    overlap=iou(predicted,candidate['bbox']);appearance=similarity(self.hist,candidate['hist'])
                    center=np.array(candidate['bbox'][:2])+np.array(candidate['bbox'][2:])/2
                    distance=np.linalg.norm(center-(predicted[:2]+predicted[2:]/2))/max(40,np.linalg.norm(predicted[2:]))
                    # Recovery needs appearance plus location; never switch merely
                    # because another person exists in the scene.
                    good=(overlap>.2 and appearance>.25) if age<.35 else (appearance>.72 and distance<.8)
                    if good and now-self.last_detected<=self.recovery_seconds:
                        proposals.append((.55*overlap+.4*appearance-.15*distance,candidate))
                proposals.sort(key=lambda v:v[0],reverse=True)
                if proposals and (len(proposals)==1 or proposals[0][0]-proposals[1][0]>.08):
                    self._accept(proposals[0][1],now,age>.35,'appearance_location' if age>.35 else '')
                elif age>.35:self._reacquire(fresh,now,age)
            self.visible=[dict(id=c['id'],bbox=c['bbox'],score=c['score']) for c in fresh]
        if self.box is not None and before is not None and elapsed>0 and now-self.last_seen<.01 and not self.just_reacquired:
            measured=(self.box[:2]-before[:2])/elapsed
            speed=np.linalg.norm(measured)
            if speed>400:measured*=400/speed
            self.velocity=.7*self.velocity+.3*measured
        if self.selected is not None and (self.points is None or len(self.points)<15) and now-self.last_seen<.01:self.points=self._points(gray)
        self.previous_gray=gray;self.last_time=now
        age=now-self.last_seen if self.selected is not None else 0
        state='waiting' if self.selected is None else 'following' if age<.18 and now-self.last_detected<.35 else 'recovering' if now-self.last_detected<=self.recovery_seconds else 'lost'
        raw_box=self.box.tolist() if self.box is not None else None
        if raw_box is None:stable_box=None
        elif self.just_reacquired:stable_box=self.output_box.reset(raw_box,now)
        elif state=='following':stable_box=self.output_box.update(raw_box,now,size_fresh=self.size_observed)
        else:stable_box=self.output_box.box() or raw_box
        # The selected person's visible rectangle and the control observation
        # must be identical. Candidate descriptors/association remain raw.
        people=[dict(c,bbox=stable_box) if c['id']==self.selected and stable_box is not None else dict(c)
                for c in getattr(self,'visible',[])]
        return dict(state=state,selected_id=self.selected,bbox=stable_box,raw_bbox=raw_box,score=self.score,
                    visible=state=='following',people=people,person_age_ms=round(age*1000,1),
                    auto_reacquire=True,reacquire_count=self.reacquire_count,reacquire_reason=self.reacquire_reason)
