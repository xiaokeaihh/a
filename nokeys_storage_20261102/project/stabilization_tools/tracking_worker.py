"""Private worker. Receives local JPEGs; never imports or opens serial."""
import base64,json,sys,time
import cv2
import numpy as np
from object_recovery import ObjectRecovery
from bbox_stabilizer import BoxStabilizer

cv2.setNumThreads(1)

class ObjectTracker:
    def __init__(self):
        self.tracker=None;self.template=None;self.hist=None;self.lost=True
        self.recovery=None;self.lost_at=None;self.last_search=-1e9;self.reacquire_count=0;self.reacquire_reason=''
        self.output_box=BoxStabilizer()

    def create_tracker(self,image,roi):
        params=cv2.TrackerCSRT_Params();params.use_segmentation=False
        self.tracker=cv2.TrackerCSRT_create(params);self.tracker.init(image,tuple(map(int,roi)))

    def recover(self,image,now):
        self.lost=True
        if self.lost_at is None:self.lost_at=now
        found=None
        if self.recovery and now-self.last_search>=.18:
            self.last_search=now;found=self.recovery.find(image);self.reacquire_reason=self.recovery.reason
        if found:
            box=found['bbox'];patch=self.patch(image,box);self.template,self.hist=self.appearance(patch)
            self.create_tracker(image,box);self.lost=False;self.lost_at=None;self.reacquire_count+=1
            return dict(bbox=self.output_box.reset(box,now),raw_bbox=list(box),score=found['score'],lost=False,state='following',reacquired=True,
                        reacquire_count=self.reacquire_count,reacquire_reason=self.reacquire_reason)
        return dict(lost=True,bbox=None,score=0.,state='recovering' if now-self.lost_at<=2 else 'lost',
                    reacquire_count=self.reacquire_count,reacquire_reason=self.reacquire_reason)

    @staticmethod
    def patch(image,box):
        x,y,w,h=map(int,box)
        if w<12 or h<12 or x<0 or y<0 or x+w>640 or y+h>360:
            raise ValueError('目标框须在总览内，且至少12×12像素')
        return image[y:y+h,x:x+w]

    @staticmethod
    def appearance(patch):
        gray=cv2.resize(cv2.GaussianBlur(cv2.cvtColor(patch,cv2.COLOR_BGR2GRAY),(5,5),1.),(48,48)).astype(np.float32)
        hsv=cv2.cvtColor(patch,cv2.COLOR_BGR2HSV)
        hist=cv2.calcHist([hsv],[0,1],None,[12,8],[0,180,0,256]);cv2.normalize(hist,hist)
        return gray,hist

    def process(self,image,roi=None,now=None):
        now=time.monotonic() if now is None else now
        if roi is not None:
            roi=tuple(map(int,roi));patch=self.patch(image,roi)
            self.template,self.hist=self.appearance(patch)
            if self.template.std()<7:raise ValueError('目标纹理不足，请选择有图案或明显边缘的物体')
            self.create_tracker(image,roi);self.recovery=ObjectRecovery(patch)
            self.lost=False;self.lost_at=None;self.last_search=-1e9;self.reacquire_count=0
            return dict(bbox=self.output_box.reset(roi,now),raw_bbox=list(roi),score=1.,lost=False,state='following',reacquire_count=0)
        if self.lost or self.tracker is None:return self.recover(image,now)
        ok,box=self.tracker.update(image)
        if not ok:return self.recover(image,now)
        try:
            patch=self.patch(image,box);gray,hist=self.appearance(patch)
            # Tolerate a few pixels of bounding-box jitter without accepting a
            # featureless patch or unrelated appearance.
            correlation=float(cv2.matchTemplate(gray,self.template[5:43,5:43],cv2.TM_CCOEFF_NORMED).max())
            color=1-float(cv2.compareHist(self.hist,hist,cv2.HISTCMP_BHATTACHARYYA))
            score=max(0,min(1,.7*max(0,correlation)+.3*color))
            if gray.std()<5 or correlation<.12 or color<.25:self.lost=True
        except ValueError:self.lost=True;score=0.
        if self.lost:return self.recover(image,now)
        raw_box=list(map(float,box))
        return dict(lost=False,bbox=self.output_box.update(raw_box,now),raw_bbox=raw_box,
                    score=score,state='following',reacquire_count=self.reacquire_count)

def main():
    tracker=ObjectTracker();generation=None;previous_tick=None;first_update=False
    print(json.dumps({'ready':hasattr(cv2,'TrackerCSRT_create'),'opencv':cv2.__version__}),flush=True)
    for line in sys.stdin:
        started=time.perf_counter()
        try:
            job=json.loads(line)
            if job['generation']!=generation:
                tracker=ObjectTracker();generation=job['generation'];previous_tick=None;first_update=False
            encoded=base64.b64decode(job['jpeg'],validate=True)
            image=cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_COLOR)
            if image is None or image.shape!=(360,640,3):raise ValueError('跟踪只接受640×360真实总览')
            # The first update follows a frozen selection frame. Permit up to
            # one second once, while still requiring CSRT/appearance to match.
            if previous_tick is not None and (job['tick']-previous_tick)*1e-5>(1. if first_update else .4):tracker.lost=True
            result=tracker.process(image,job.get('roi'));previous_tick=job['tick']
            first_update=job.get('roi') is not None
        except Exception as error:result={'error':str(error),'lost':True,'bbox':None,'score':0.}
        result['compute_ms']=(time.perf_counter()-started)*1000
        print(json.dumps(result,allow_nan=False),flush=True)

if __name__=='__main__':main()
