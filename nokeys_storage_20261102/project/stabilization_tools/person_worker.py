"""Native capture and person inference in a private PC process; no serial."""
from collections import deque
from pathlib import Path
import argparse,json,sys,threading,time
import cv2
import numpy as np
from person_capture import LatestCapture,marker
from person_inference import PersonDetector
from person_tracker import PersonTracker
from person_preview import PreviewPublisher

def send(value):print(json.dumps(value,ensure_ascii=False,allow_nan=False),flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--config',required=True);parser.add_argument('--camera',type=int,required=True);parser.add_argument('--preview',required=True)
    parser.add_argument('--preview-map',default=None)
    args=parser.parse_args();config=json.loads(Path(args.config).read_text(encoding='utf-8'))
    cv2.setNumThreads(2)
    detector=PersonDetector(config['model'],config.get('provider','auto'));tracker=PersonTracker()
    send(dict(kind='ready',**detector.info()))
    commands=deque(maxlen=8);closing=threading.Event()
    def read_commands():
        for line in sys.stdin:
            try:commands.append(json.loads(line))
            except ValueError:pass
        closing.set()
    threading.Thread(target=read_commands,daemon=True).start()
    capture=LatestCapture(args.camera);preview=Path(args.preview);preview.parent.mkdir(parents=True,exist_ok=True)
    publisher=PreviewPublisher(capture,preview,30,82,args.preview_map)
    previous_counter=0;previous_frame=None;last_detection=-10.;last_status=-10.;last_memory=-10.
    received=deque(maxlen=60);inference=deque(maxlen=180);rss_peak=0.;rss=0.;duplicates=0;processed=0
    try:
        import psutil
        process=psutil.Process()
        while not closing.is_set():
            while commands:
                command=commands.popleft()
                if command.get('action')=='select':
                    try:tracker.select(int(command['id']))
                    except ValueError as e:send(dict(kind='selection_error',note=str(e)))
                elif command.get('action')=='reselect':tracker=PersonTracker()
            item=capture.next(previous_counter)
            now=time.monotonic()
            if capture.error:raise ValueError(capture.error)
            if item is None:
                if now-last_status>1:send(dict(kind='waiting',note='正在打开PC直采画面。' if not capture.opened else '等待采集卡新画面。'));last_status=now
                continue
            previous_counter,captured,image=item
            begin=time.perf_counter();tag=marker(image)
            if tag is None:
                if now-last_status>1:send(dict(kind='waiting',note='已直采，等待对比画面的有效帧标记。'));last_status=now
                continue
            if tag['frame_id']==previous_frame:duplicates+=1;continue
            previous_frame=tag['frame_id'];received.append(captured);raw=image[180:540,:640]
            detections=None
            if captured-last_detection>=config.get('detection_interval_seconds',1/15):
                detections=detector.detect(raw);last_detection=captured;inference.append(detector.last_ms)
            tracking_begin=time.perf_counter();result=tracker.step(raw,captured,detections)
            tracking_ms=(time.perf_counter()-tracking_begin)*1000
            if now-last_memory>1:
                rss=process.memory_info().rss/1048576;rss_peak=max(rss_peak,rss);last_memory=now
            processed+=1
            fps=(len(received)-1)/(received[-1]-received[0]) if len(received)>1 and received[-1]>received[0] else 0
            result.update(kind='frame',**tag,captured_local=captured,compute_ms=(time.perf_counter()-begin)*1000,
                          inference_ms=detector.last_ms,tracking_ms=tracking_ms,inference_ran=detections is not None,
                          inference_mean_ms=float(np.mean(inference)) if inference else 0,tracking_fps=round(fps,1),
                          process_rss_mib=round(rss,1),process_peak_rss_mib=round(rss_peak,1),gpu_memory_mib=None,
                          frame_queue_capacity=1,duplicates=duplicates,processed=processed)
            result.update(publisher.status())
            send(result)
    except Exception as error:send(dict(kind='error',note=str(error)))
    finally:publisher.close();capture.close()

if __name__=='__main__':
    try:main()
    except Exception as error:send(dict(kind='error',note='人的推理启动失败：'+str(error)))
