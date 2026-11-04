from pathlib import Path
import json,subprocess,sys
P=Path(__file__).resolve().parent;ok=True
for n in ['person_runtime.json','tracking_runtime.json']:
 d=json.loads((P/'stabilization_tools'/n).read_text(encoding='utf-8'));exe=Path(d['python']);print(n,'python',exe.is_file(),str(exe));ok=ok and exe.is_file()
 if exe.is_file():
  code="import cv2,importlib.util,json;print(json.dumps(dict(opencv=cv2.__version__,csrt=hasattr(cv2,'TrackerCSRT_create'),onnx=bool(importlib.util.find_spec('onnxruntime')),serial=bool(importlib.util.find_spec('serial')))))"
  r=subprocess.run([str(exe),'-c',code],capture_output=True,text=True);print(r.stdout.strip());ok=ok and r.returncode==0
 if 'model' in d:print('model',Path(d['model']).is_file());ok=ok and Path(d['model']).is_file()
print('ENVIRONMENT_PASS' if ok else 'ENVIRONMENT_INCOMPLETE');sys.exit(0 if ok else 1)
