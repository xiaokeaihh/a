"""Bounded phone-style cylindrical panorama. No depth or unseen-scene synthesis.

Only JPEG keyframes and their own rotations survive a scan. The serial/fusion
lock is never held for feature fitting, projection, blending or file writing.
"""
from pathlib import Path
import base64, json, math, re, threading, time, uuid
import cv2
import numpy as np
from panorama_registration import robust_rotation, features, match_rotation, consensus_orientation
from panorama_seam import project_strip,seam_plan

MAX_KEYS=24
MAX_SECONDS=60
MAX_KEY_BYTES=1200000
PREVIEW_SIZE=(2048,512)
FINAL_SIZE=(4096,1024)

def rotation_angle(r):
    return float(np.degrees(np.arccos(np.clip((np.trace(r)-1)/2,-1,1))))

def center_covered_arc(image,mask):
    """Move the empty angular gap to the outer edges, retaining every pixel."""
    columns=np.flatnonzero(np.any(mask!=0,axis=0));width=image.shape[1]
    if len(columns)<2 or len(columns)==width:return image,mask,0
    gaps=np.diff(np.r_[columns,columns[0]+width]);gap=int(np.argmax(gaps))
    start=int(columns[(gap+1)%len(columns)]);end=int(columns[gap])
    middle=(start+((end-start)%width)/2)%width
    shift=int(round(width/2-middle))
    return np.roll(image,shift,axis=1),np.roll(mask,shift,axis=1),shift

def fit_rays(a,b):
    return robust_rotation(a,b)

def rays(points,k,d):
    xy=cv2.fisheye.undistortPoints(np.asarray(points,np.float64).reshape(-1,1,2),k,d).reshape(-1,2)
    a=np.c_[xy,np.ones(len(xy))];return a/np.linalg.norm(a,axis=1)[:,None]

class Mosaic:
    def __init__(self,size):
        self.width,self.height=size;self.f=self.width/(2*math.pi)
        # Retain the best optical-axis sample rather than averaging many
        # slightly displaced edges into a blurred panorama.
        self.color=np.zeros((self.height,self.width,3),np.uint8)
        self.weight=np.zeros((self.height,self.width),np.float32)
        self.seams_found=0;self.seam_fallbacks=0

    def add(self,image,orientation,k,d):
        gain,take,seam_found=seam_plan(self.color,self.weight,image,orientation,k,d)
        if seam_found:self.seams_found+=1
        elif np.any(self.weight):self.seam_fallbacks+=1
        # Only the 512x128 seam plan and a 64-row full-width strip are held.
        for y0 in range(0,self.height,64):
            y1=min(y0+64,self.height)
            color,w=project_strip(image,orientation,k,d,self.width,self.height,y0,y1)
            color=np.clip(color.astype(np.float32)*gain,0,255).astype(np.uint8)
            old_w=self.weight[y0:y1];old=self.color[y0:y1]
            if take is None:
                better=(w>0)&((old_w==0)|(w>old_w*1.02))
            else:
                yy=np.minimum((np.arange(y0,y1)*take.shape[0]//self.height),take.shape[0]-1)
                xx=np.minimum((np.arange(self.width)*take.shape[1]//self.width),take.shape[1]-1)
                winner=take[yy[:,None],xx[None,:]]>0
                better=(w>0)&((old_w==0)|winner)
            # Select one aligned observation at each seam. Averaging two
            # displaced beams/letters would create a second, ghosted edge.
            old[better]=color[better];old_w[better]=w[better]

    def image(self):
        return self.color.copy()

class Panorama:
    def __init__(self,folder,k,d):
        self.folder=Path(folder);self.k=np.asarray(k,float);self.d=np.asarray(d,float).ravel()
        self.lock=threading.RLock();self.token=0;self.state='idle';self.busy=False
        self.client='';self.keys=[];self.mosaic=None;self.preview=None;self.revision=0
        self.note='';self.error='';self.result=None;self.frames=0;self.rejected=0;self.work_ms=0.
        self.started=0.;self.last_request=0.;self.last_frame=None;self.previous=None
        self.origin_pose=None;self.last_pose=None;self.yaw=0.;self.coverage=0.
        self.detector=cv2.SIFT_create(nfeatures=1800,contrastThreshold=.015,edgeThreshold=12)
        self.matcher=cv2.BFMatcher(cv2.NORM_L2)
        self.references=[]

    def active(self):return self.state in ('collecting','solving')

    def start(self,client):
        with self.lock:
            if self.active() or self.busy:raise ValueError('全景正在处理，请等待或取消')
            if not isinstance(client,str) or not 8<=len(client)<=80:raise ValueError('页面标识无效')
            self.token+=1;self.client=client;self.state='collecting';self.keys=[];self.previous=None;self.references=[]
            self.origin_pose=None;self.last_pose=None;self.mosaic=Mosaic(PREVIEW_SIZE)
            self.preview=None;self.revision=0;self.error='';self.result=None;self.frames=self.rejected=0
            self.work_ms=0.;self.started=self.last_request=time.monotonic();self.last_frame=None
            self.note='缓慢左右扫动，尽量绕镜头转动，避免大幅平移';self.yaw=self.coverage=0.
            return self.token

    def authorize(self,data):
        if data.get('client_id')!=self.client or int(data.get('token',-1))!=self.token:
            raise ValueError('全景会话已变化，请在发起拍摄的页面操作')

    def frame(self,data,pose=None,horizontal_reversed=False):
        with self.lock:
            self.authorize(data)
            if self.state!='collecting':raise ValueError('全景采集已结束')
            if self.busy:return self.status()
            if time.monotonic()-self.started>MAX_SECONDS:
                self.note='已到60秒上限，请点击完成拼接';return self.status()
            frame=int(data['frame_id'])
            if self.last_frame is not None and frame<=self.last_frame:return self.status()
            if len(str(data.get('jpeg','')))>950000:raise ValueError('全景帧过大')
            token=self.token;self.busy=True;self.last_request=time.monotonic()
            previous=self.previous;references=tuple(self.references);mosaic=self.mosaic
        start=time.perf_counter()
        try:
            encoded=base64.b64decode(data['jpeg'],validate=True)
            if len(encoded)>MAX_KEY_BYTES:raise ValueError('全景帧过大')
            image=cv2.imdecode(np.frombuffer(encoded,np.uint8),cv2.IMREAD_COLOR)
            if image is None or image.shape!=(720,1280,3):raise ValueError('全景仅接受完整1280×720 RAW画面')
            # HDMI RAW scans canonical DDR rows bottom-to-top.
            image=cv2.flip(image,0)
            if horizontal_reversed:image=cv2.flip(image,1)
            current=features(image,self.k,self.detector)
            orientation=np.eye(3);matches_count=0;residual=0.;imu_used=False
            if previous is not None:
                relative,matches_count,residual=match_rotation(previous,current,self.k,self.d,self.matcher,pose)
                candidates=[(previous['orientation']@relative.T,matches_count,residual)]
                # Bounded multi-keyframe constraints reduce incremental drift;
                # keep the first reference as well for revisited directions.
                for reference in references:
                    if reference is previous:continue
                    if rotation_angle(reference['orientation'].T@previous['orientation'])>55:continue
                    try:
                        rel,count,error=match_rotation(reference,current,self.k,self.d,self.matcher,pose)
                    except (ValueError,cv2.error):continue
                    candidates.append((reference['orientation']@rel.T,count,error))
                orientation=consensus_orientation(candidates)
                relative=orientation.T@previous['orientation']
                angle=rotation_angle(relative)
                if angle<6:
                    self.note='重叠充足，继续绕镜头慢扫；尚未到下一关键帧方向';return self.status()
                if angle>28:raise ValueError('方向间隔过大，请回到刚才方向附近，保持重叠')
                if pose is not None and previous['pose'] is not None:
                    prior=previous['pose'].T@pose
                    if rotation_angle(prior@relative)<5:imu_used=True
            if len(self.keys)>=MAX_KEYS:
                self.note='已到24张关键帧上限，请点击完成拼接';return self.status()
            # Keep the received JPEG exactly. Re-encoding it after orientation
            # normalization used to compress every accepted frame a second time.
            entry=dict(jpeg=encoded,horizontal_reversed=bool(horizontal_reversed),orientation=orientation.copy(),frame_id=frame,
                capture_tick=int(data['capture_tick']),pose=None if pose is None else pose.copy(),
                imu_used=imu_used,matches=matches_count,residual_deg=residual)
            with self.lock:
                if token!=self.token or self.state!='collecting':return self.status()
            mosaic.add(image,orientation,self.k,self.d)
            # Projection/calibration use canonical DDR axes. Present the result
            # in the same upright, non-mirrored axes as the camera RAW display.
            preview_image=cv2.flip(mosaic.image(),-1)
            _,preview=cv2.imencode('.jpg',preview_image,[cv2.IMWRITE_JPEG_QUALITY,92])
            with self.lock:
                if token!=self.token or self.state!='collecting':return self.status()
                self.keys.append(entry);self.previous=dict(**current,orientation=orientation,pose=None if pose is None else pose.copy())
                self.references.append(self.previous)
                if len(self.references)>4:self.references=[self.references[0],*self.references[-3:]]
                self.preview=preview.tobytes();self.revision+=1;self.last_frame=frame
                self.yaw=float(np.degrees(np.arctan2(orientation[0,2],orientation[2,2])))
                self.coverage=float(np.mean(np.any(mosaic.weight>.05,axis=0))*360)
                self.note=f'已接入{len(self.keys)}张关键帧；'+('IMU＋视觉检查通过' if imu_used else '视觉配准')
                self.frames+=1
        except (ValueError,cv2.error) as e:
            with self.lock:
                if token==self.token:self.rejected+=1;self.note=str(e)
        finally:
            with self.lock:self.busy=False;self.work_ms=(time.perf_counter()-start)*1000
        return self.status()

    def finish(self,data):
        with self.lock:
            self.authorize(data)
            if self.state!='collecting' or self.busy:raise ValueError('等待当前图像处理完成后再拼接')
            if len(self.keys)<2:raise ValueError('至少需要两张不同方向的清晰关键帧，请继续慢扫')
            token=self.token;keys=list(self.keys);self.state='solving';self.busy=True
        def solve():
            try:
                mosaic=Mosaic(FINAL_SIZE)
                for key in keys:
                    if token!=self.token:return
                    image=cv2.imdecode(np.frombuffer(key['jpeg'],np.uint8),cv2.IMREAD_COLOR)
                    image=cv2.flip(image,0)
                    if key['horizontal_reversed']:image=cv2.flip(image,1)
                    mosaic.add(image,key['orientation'],self.k,self.d)
                image=cv2.flip(mosaic.image(),-1)
                mask=cv2.flip((mosaic.weight>.001).astype(np.uint8)*255,-1)
                image,mask,shift=center_covered_arc(image,mask)
                identity=uuid.uuid4().hex;self.folder.mkdir(parents=True,exist_ok=True)
                meta=dict(id=identity,created=time.time(),width=FINAL_SIZE[0],height=FINAL_SIZE[1],
                    projection='cylindrical',orientation_version=2,output_orientation='upright_camera_raw',
                    blending='bounded_low_resolution_dp_seam',registration_version=3,registration='mutual_SIFT_LK_multi_keyframe_rotation',imu_required=False,seams_found=mosaic.seams_found,seam_fallbacks=mosaic.seam_fallbacks,keyframe_encoding='original_received_jpeg',
                    focal_px=mosaic.f,origin_x=FINAL_SIZE[0]/2,origin_y=FINAL_SIZE[1]/2,
                    image_shift_px=shift,center_yaw_deg=-shift/FINAL_SIZE[0]*360,
                    source='camera',covered_degrees=self.coverage,source_K=self.k.tolist(),source_D=self.d.tolist(),
                    limits=dict(max_keyframes=MAX_KEYS,max_seconds=MAX_SECONDS),
                    frame_timestamp_definition='FPGA VSYNC tick; not calibrated exposure centre',
                    frames=[{k:(v.tolist() if isinstance(v,np.ndarray) else v) for k,v in key.items() if k!='jpeg'} for key in keys])
                pending=self.folder/('.pending-'+identity);pending.mkdir()
                try:
                    for suffix,img,params in [('jpg',image,[cv2.IMWRITE_JPEG_QUALITY,95]),('png',image,[]),('mask.png',mask,[])]:
                        ok,encoded=cv2.imencode('.png' if suffix.endswith('png') else '.jpg',img,params)
                        if not ok:raise ValueError('全景编码失败')
                        (pending/(identity+'.'+suffix)).write_bytes(encoded.tobytes())
                    (pending/(identity+'.json')).write_text(json.dumps(meta,ensure_ascii=False,indent=2),encoding='utf-8')
                    # Slow image encoding and disk I/O never hold the lock
                    # needed by status polling and the serial/fusion owner.
                    with self.lock:
                        if token!=self.token:return
                        for suffix in ('jpg','png','mask.png','json'):
                            (pending/(identity+'.'+suffix)).replace(self.folder/(identity+'.'+suffix))
                        self.result=meta;self.state='complete';self.note='全景已保存，可拖动或缩放查看已拍摄方向'
                finally:
                    for suffix in ('jpg','png','mask.png','json'):
                        f=pending/(identity+'.'+suffix)
                        if f.exists():f.unlink()
                    pending.rmdir()
            except Exception as e:
                with self.lock:
                    if token==self.token:self.state='failed';self.error=str(e)
            finally:
                with self.lock:
                    self.busy=False
                    if token==self.token:self.keys=[];self.previous=None;self.references=[];self.mosaic=None
        threading.Thread(target=solve,daemon=True,name='panorama-stitch').start()
        return self.status()

    def cancel(self,data=None,reason='已取消本次全景，原有照片保留'):
        with self.lock:
            if data is not None:self.authorize(data)
            self.token+=1;self.state='idle';self.note=reason;self.keys=[];self.previous=None;self.references=[];self.mosaic=None

    def status(self):
        with self.lock:
            return dict(state=self.state,token=self.token,client_id=self.client,busy=self.busy,revision=self.revision,
                keyframes=len(self.result['frames']) if self.state=='complete' and self.result else len(self.keys),rejected=self.rejected,note=self.note,error=self.error,result=self.result,
                yaw_deg=round(self.yaw,1),covered_degrees=round(self.coverage,1),
                processing_ms=round(self.work_ms,1),max_keyframes=MAX_KEYS,max_seconds=MAX_SECONDS,
                jpeg_bytes=sum(len(k['jpeg']) for k in self.keys),queue_depth=1,
                elapsed=round(time.monotonic()-self.started,1) if self.active() else 0)

    def file(self,identity,suffix):
        if not re.fullmatch('[0-9a-f]{32}',identity) or suffix not in ('jpg','png','json','mask.png'):
            raise ValueError('全景文件标识无效')
        source=self.folder/(identity+'.'+suffix)
        # Old panoramas were saved in inverted DDR axes. Serve a corrected
        # derivative for viewing/download, keeping every original untouched.
        if suffix in ('jpg','png','mask.png'):
            meta=self.folder/(identity+'.json')
            if meta.exists() and json.loads(meta.read_text(encoding='utf-8')).get('orientation_version',1)<2:
                cache=self.folder/'.upright-cache';target=cache/source.name
                if not target.exists() or target.stat().st_mtime<source.stat().st_mtime:
                    flag=cv2.IMREAD_GRAYSCALE if suffix=='mask.png' else cv2.IMREAD_COLOR
                    image=cv2.imdecode(np.frombuffer(source.read_bytes(),np.uint8),flag)
                    if image is None:raise ValueError('全景图像损坏')
                    ok,encoded=cv2.imencode('.jpg' if suffix=='jpg' else '.png',cv2.flip(image,-1),
                        [cv2.IMWRITE_JPEG_QUALITY,95] if suffix=='jpg' else [])
                    if not ok:raise ValueError('全景方向转换失败')
                    cache.mkdir(exist_ok=True)
                    temporary=cache/(source.name+'.'+uuid.uuid4().hex+'.tmp')
                    temporary.write_bytes(encoded.tobytes());temporary.replace(target)
                return target
        return source

    def list(self):
        if not self.folder.exists():return []
        rows=[]
        for p in sorted(self.folder.glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[:100]:
            try:
                m=json.loads(p.read_text(encoding='utf-8'));rows.append({k:m[k] for k in ('id','created','width','height','covered_degrees','projection')})
            except (ValueError,KeyError,OSError):pass
        return rows
