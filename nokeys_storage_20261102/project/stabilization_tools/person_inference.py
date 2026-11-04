"""Small fixed-shape person detector. No torch, serial, or frame queue."""
from pathlib import Path
import ctypes,json,time,uuid
import cv2
import numpy as np

def gpu_adapters():
    if not hasattr(ctypes,'WinDLL'):return []
    class Luid(ctypes.Structure):
        _fields_=[('low',ctypes.c_uint32),('high',ctypes.c_int32)]
    class Desc(ctypes.Structure):
        _fields_=[('name',ctypes.c_wchar*128),('vendor',ctypes.c_uint),('device',ctypes.c_uint),
                  ('subsys',ctypes.c_uint),('revision',ctypes.c_uint),('vram',ctypes.c_size_t),
                  ('system',ctypes.c_size_t),('shared',ctypes.c_size_t),('luid',Luid),('flags',ctypes.c_uint)]
    def method(p,index,restype,*args):
        address=ctypes.cast(p,ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents[index]
        return ctypes.WINFUNCTYPE(restype,ctypes.c_void_p,*args)(address)
    factory=ctypes.c_void_p();iid=(ctypes.c_ubyte*16).from_buffer_copy(uuid.UUID('770aae78-f26f-4dba-a829-253c83d1b387').bytes_le)
    create=ctypes.WinDLL('dxgi').CreateDXGIFactory1
    create.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)];create.restype=ctypes.c_long
    if create(ctypes.byref(iid),ctypes.byref(factory))<0:return []
    result=[]
    try:
        for index in range(16):
            adapter=ctypes.c_void_p()
            if method(factory,12,ctypes.c_long,ctypes.c_uint,ctypes.POINTER(ctypes.c_void_p))(factory,index,ctypes.byref(adapter))<0:break
            try:
                desc=Desc()
                if method(adapter,10,ctypes.c_long,ctypes.POINTER(Desc))(adapter,ctypes.byref(desc))>=0:
                    result.append(dict(index=index,name=desc.name,vendor=desc.vendor,vram_mib=round(desc.vram/1048576),software=bool(desc.flags&2)))
            finally:method(adapter,2,ctypes.c_ulong)(adapter)
    finally:method(factory,2,ctypes.c_ulong)(factory)
    return result

class PersonDetector:
    def __init__(self,model,provider='auto'):
        import onnxruntime as ort
        options=ort.SessionOptions();options.intra_op_num_threads=2;options.inter_op_num_threads=1
        options.enable_mem_pattern=False;options.execution_mode=ort.ExecutionMode.ORT_SEQUENTIAL
        options.log_severity_level=3
        adapters=gpu_adapters();gpu=next((a for a in adapters if a['vendor']==0x10de and not a['software']),None)
        available=ort.get_available_providers();self.warning=''
        preferred=[('DmlExecutionProvider',{'device_id':gpu['index'] if gpu else 0}),'CPUExecutionProvider'] if provider!='cpu' and 'DmlExecutionProvider' in available else ['CPUExecutionProvider']
        try:self.session=ort.InferenceSession(str(model),sess_options=options,providers=preferred)
        except Exception as error:
            self.warning='显卡初始化失败，已使用CPU：'+str(error)[:180]
            self.session=ort.InferenceSession(str(model),sess_options=options,providers=['CPUExecutionProvider'])
        self.provider=self.session.get_providers()[0];self.gpu_name=gpu['name'] if gpu and self.provider=='DmlExecutionProvider' else ''
        self.input_name=self.session.get_inputs()[0].name;self.model=Path(model)
        self.last_ms=0.
        self.detect(np.zeros((360,640,3),np.uint8))

    def detect(self,image,threshold=.28):
        start=time.perf_counter()
        if image.shape!=(360,640,3):raise ValueError('人的检测输入须为640×360总览')
        # The native raw image is not resized: 12 pixels of padding above/below.
        padded=cv2.copyMakeBorder(image,12,12,0,0,cv2.BORDER_CONSTANT,value=(114,114,114))
        tensor=np.ascontiguousarray(padded[:,:,::-1].transpose(2,0,1)[None],dtype=np.float32)/255
        output=self.session.run(None,{self.input_name:tensor})[0][0].T
        output=output[np.isfinite(output).all(axis=1)&(output[:,4]>=threshold)]
        if len(output):
            boxes=output[:,:4].copy();boxes[:,:2]-=boxes[:,2:]/2;boxes[:,1]-=12
            x1=np.clip(boxes[:,0],0,639);y1=np.clip(boxes[:,1],0,359)
            x2=np.clip(boxes[:,0]+boxes[:,2],0,640);y2=np.clip(boxes[:,1]+boxes[:,3],0,360)
            boxes=np.stack([x1,y1,x2-x1,y2-y1],axis=1)
            valid=(boxes[:,2]>=12)&(boxes[:,3]>=24)
            boxes,scores=boxes[valid],output[valid,4]
            indices=np.asarray(cv2.dnn.NMSBoxes(boxes.tolist(),scores.tolist(),threshold,.45)).ravel()
            result=[dict(bbox=boxes[i].round(2).tolist(),score=float(scores[i])) for i in indices[:12]]
        else:result=[]
        self.last_ms=(time.perf_counter()-start)*1000
        return result

    def info(self):
        return dict(model='YOLO11n · 人',model_bytes=self.model.stat().st_size,provider=self.provider,gpu=self.gpu_name,
                    input=[640,384],warning=self.warning,weights_sha256=__import__('hashlib').sha256(self.model.read_bytes()).hexdigest())

if __name__=='__main__':
    import sys
    print(json.dumps(gpu_adapters(),ensure_ascii=False))
    detector=PersonDetector(sys.argv[1])
    image=cv2.imread(sys.argv[2]) if len(sys.argv)>2 else np.zeros((360,640,3),np.uint8)
    image=cv2.resize(image,(640,360))
    measurements=[]
    for _ in range(25):
        people=detector.detect(image);measurements.append(detector.last_ms)
    print(json.dumps(dict(info=detector.info(),people=people,mean_ms=float(np.mean(measurements[5:])),p95_ms=float(np.percentile(measurements[5:],95))),ensure_ascii=False))
