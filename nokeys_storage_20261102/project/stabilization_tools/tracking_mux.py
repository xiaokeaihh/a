from pathlib import Path
import json,subprocess
from target_tracking import TargetTracking
from person_follow import PersonFollow

class TrackingMux:
    def __init__(self,k,d,context):
        self.object=TargetTracking(k,d);self.person=PersonFollow(k,d,context);self.current=self.object;self.camera_indices=set();self.composition_enabled=True

    def active(self):return self.current.active()
    def arm(self,reference,sign=1,client_id='',backend='object',camera=0,horizontal_reversed=False):
        self.stop()
        self.current=self.person if backend=='person' else self.object
        token=self.person.arm(reference,sign,client_id,camera,horizontal_reversed) if backend=='person' else self.object.arm(reference,sign,client_id,horizontal_reversed)
        self.configure_composition(self.composition_enabled)
        return token
    def reset_pose(self,reference,sign=1):
        if self.current is self.person:self.person.reset_pose(reference,sign)
        else:self.object.reset_pose(reference,sign)
        self.configure_composition(self.composition_enabled)

    def configure_composition(self,enabled):
        if not isinstance(enabled,bool):raise ValueError('智能构图开关无效')
        self.composition_enabled=enabled
        for target in (self.object,self.person):
            with target.lock:
                if target.aim:target.aim.framing_enabled=enabled

    def stop(self,note='跟随已停止。'):
        self.object.stop(note);self.person.stop(note)
    def request_stop(self,data):return self.current.request_stop(data)
    def matrix(self,*args):return self.current.matrix(*args)
    def submit(self,*args):
        if self.current is self.person:raise ValueError('人的跟随由PC直采，网页不上传图像')
        return self.object.submit(*args)
    def status(self):
        result=self.current.status()
        aim=self.current.aim
        result['composition']=aim.framing_status() if aim and hasattr(aim,'framing_status') else dict(enabled=self.composition_enabled)
        if self.current is self.object:result['kind']='object'
        return result
    def shutdown(self):self.object.shutdown();self.person.shutdown()
    def devices(self):
        config=json.loads(self.person.runtime.read_text(encoding='utf-8'))
        code='import json; from person_capture import devices; print(json.dumps(devices(),ensure_ascii=False))'
        result=subprocess.run([config['python'],'-X','utf8','-B','-c',code],cwd=str(Path(__file__).parent),capture_output=True,text=True,encoding='utf-8',timeout=8,
                              creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        if result.returncode:raise ValueError('无法读取PC采集设备：'+result.stderr[-200:])
        devices=json.loads(result.stdout);self.camera_indices={d['index'] for d in devices}
        return devices
