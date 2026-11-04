"""DirectShow owns the card once. One replaceable latest frame, no FIFO."""
import threading,time
import cv2
import numpy as np

def devices():
    from pygrabber.dshow_graph import FilterGraph
    return [dict(index=i,name=name) for i,name in enumerate(FilterGraph().get_input_devices())]

def marker(frame):
    if frame.shape!=(720,1280,3):return None
    samples=[]
    for bit in range(96):
        x=1088+(bit%24)*8+4;y=(bit//24)*8+4
        samples.append(float(frame[y-1:y+2,x-1:x+2].mean())>128)
    data=bytes(sum(int(samples[i*8+j])<<j for j in range(8)) for i in range(12))
    crc=0
    for value in data[:10]:
        crc^=value
        for _ in range(8):crc=((crc<<1)^7)&255 if crc&128 else (crc<<1)&255
    if data[:2]!=b'\xa5\x01' or data[10]!=crc or data[11]!=(~crc&255):return None
    return dict(frame_id=int.from_bytes(data[2:6],'little'),capture_tick=int.from_bytes(data[6:10],'little'))

class LatestCapture:
    def __init__(self,index):
        self.index=index;self.condition=threading.Condition();self.latest=None;self.counter=0;self.closed=False;self.error='';self.opened=False
        self.thread=threading.Thread(target=self._run,daemon=True);self.thread.start()

    def _run(self):
        cap=None
        try:
            cap=cv2.VideoCapture(self.index,cv2.CAP_DSHOW)
            if not cap.isOpened():raise ValueError('采集卡无法打开，请关闭占用它的其它网页或软件')
            cap.set(cv2.CAP_PROP_FOURCC,cv2.VideoWriter_fourcc(*'MJPG'))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH,1280);cap.set(cv2.CAP_PROP_FRAME_HEIGHT,720);cap.set(cv2.CAP_PROP_FPS,60)
            cap.set(cv2.CAP_PROP_BUFFERSIZE,1)
            self.opened=True;failures=0
            while not self.closed:
                ok,image=cap.read()
                if not ok:
                    failures+=1
                    if failures>30:raise ValueError('采集卡图像中断')
                    time.sleep(.01);continue
                failures=0
                if image.shape!=(720,1280,3):raise ValueError('采集卡实际尺寸不是1280×720，请检查设置')
                with self.condition:
                    self.counter+=1;self.latest=(self.counter,time.monotonic(),image);self.condition.notify_all()
        except Exception as e:
            self.error=str(e)
            with self.condition:self.condition.notify_all()
        finally:
            if cap:cap.release()

    def next(self,previous,timeout=.1):
        with self.condition:
            self.condition.wait_for(lambda:self.counter!=previous or self.error or self.closed,timeout)
            return self.latest if self.latest and self.counter!=previous else None

    def close(self):
        self.closed=True
        with self.condition:self.condition.notify_all()
        self.thread.join(timeout=.5)
