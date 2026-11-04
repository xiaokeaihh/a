"""Encode the newest capture independently of AI; one JPEG replaces the last."""
from collections import deque
from pathlib import Path
import os, threading, time
import cv2
from person_capture import marker
from preview_buffer import PreviewBuffer


class PreviewPublisher:
    def __init__(self, capture, path, fps=30, quality=82, shared_name=None):
        self.capture=capture;self.path=Path(path);self.period=1/max(1,min(30,float(fps)))
        self.quality=int(quality);self.closed=threading.Event();self.lock=threading.Lock()
        self.frames=0;self.times=deque(maxlen=90);self.encode_times=deque(maxlen=90)
        self.error='';self.last_source=None;self.shared=PreviewBuffer(shared_name) if shared_name else None
        self.thread=threading.Thread(target=self._run,name='latest-preview',daemon=True)
        self.thread.start()

    def _run(self):
        previous=0;due=time.monotonic();temporary=self.path.with_suffix('.tmp')
        while not self.closed.is_set():
            if self.closed.wait(max(0,due-time.monotonic())):break
            item=self.capture.next(previous,timeout=.05)
            if item is None:
                if self.capture.error:break
                continue
            previous,captured,image=item
            # The marker is untouched in the JPEG. Suppress repeated HDMI frames
            # when a valid source ID is available, rather than reporting them as
            # new camera frames.
            tag=marker(image);identity=tag['frame_id'] if tag else None
            if identity is not None and identity==self.last_source:continue
            begin=time.perf_counter()
            ok,jpeg=cv2.imencode('.jpg',image,[cv2.IMWRITE_JPEG_QUALITY,self.quality])
            if not ok:continue
            try:
                if self.shared:self.shared.write(jpeg.tobytes())
                else:temporary.write_bytes(jpeg.tobytes());os.replace(temporary,self.path)
            except OSError as error:
                with self.lock:self.error=str(error)
                # No waiting FIFO or accumulation when a Windows reader briefly
                # holds the old file; the next attempt takes the newest capture.
                continue
            now=time.monotonic()
            with self.lock:
                self.last_source=identity;self.frames+=1;self.times.append(now)
                self.encode_times.append((time.perf_counter()-begin)*1000);self.error=''
            due+=self.period
            if due<now-self.period:due=now

    def status(self):
        with self.lock:
            fps=(len(self.times)-1)/(self.times[-1]-self.times[0]) if len(self.times)>1 and self.times[-1]>self.times[0] else 0
            return dict(preview_fps=round(fps,1),preview_frames=self.frames,
                        preview_encode_ms=round(sum(self.encode_times)/len(self.encode_times),2) if self.encode_times else 0,
                        preview_queue_capacity=1,preview_target_fps=30,preview_error=self.error)

    def close(self):
        self.closed.set();self.thread.join(timeout=1)
        if self.shared:self.shared.close()
