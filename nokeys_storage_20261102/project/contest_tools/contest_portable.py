"""Packaging helpers; FPGA sources and the supplied bitstream are never edited."""
from pathlib import Path
import argparse,hashlib,json,os,re,runpy,shutil,subprocess,sys

ROOT=Path(__file__).resolve().parents[1]
BIT='fisheye5_calibrated_6mm_nokeys_storage_20261102.sbit'
EXPECTED_BIT_SHA256='788e841d71df6e9eb3a959c987d022fd7817b8095d4668b9d90ab3e0bb388229'
PDS='HDMI_DDR3_OV5640_test_720p60_pipeline.pds'

def load_config(name):
    return json.loads((ROOT/'stabilization_tools'/name).read_text(encoding='utf-8'))

def find_pds(explicit=None):
    candidates=[explicit,os.environ.get('FPGA_PDS_SHELL'),shutil.which('pds_shell'),
                r'D:\fpgapango\PDS_2022.2-SP6.4\bin\pds_shell.exe']
    return next((str(Path(x).resolve()) for x in candidates if x and Path(x).is_file()),None)

def runtime_candidates():
    values=[os.environ.get('FPGA_CONTROL_PYTHON'),os.environ.get('FPGA_TRACKING_PYTHON'),
            str(ROOT/'.venv/Scripts/python.exe'),str(ROOT/'.venv/bin/python'),
            load_config('person_runtime.json').get('python'),load_config('tracking_runtime.json').get('python'),
            sys.executable,shutil.which('python')]
    found=[]
    for value in values:
        if not value:continue
        p=Path(value)
        if not p.is_file() or 'windowsapps' in str(p).lower():continue
        resolved=str(p.resolve())
        if resolved.casefold() not in [x.casefold() for x in found]:found.append(resolved)
    return found

def probe(executable):
    code='''import importlib.util,json,sys
d={'python':sys.executable,'version':sys.version.split()[0]}
for name in ['numpy','serial','cv2','onnxruntime']:
 d[name]=importlib.util.find_spec(name) is not None
d['csrt']=False
if d['cv2']:
 import cv2
 d['opencv_version']=cv2.__version__
 d['csrt']=hasattr(cv2,'TrackerCSRT_create')
print(json.dumps(d))'''
    try:
        p=subprocess.run([executable,'-B','-c',code],capture_output=True,text=True,encoding='utf-8',timeout=12)
        if p.returncode:return dict(python=executable,error=p.stderr.strip().splitlines()[-1:] or ['runtime failed'])
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (OSError,ValueError,subprocess.TimeoutExpired) as error:return dict(python=executable,error=str(error))

def inspect_environment(explicit_pds=None):
    probes=[probe(exe) for exe in runtime_candidates()]
    person=next((p['python'] for p in probes if all(p.get(n) for n in ['numpy','serial','cv2','onnxruntime'])),None)
    tracking=next((p['python'] for p in probes if all(p.get(n) for n in ['numpy','cv2','csrt'])),None)
    bit=ROOT/BIT
    return dict(project=str(ROOT),pds_shell=find_pds(explicit_pds),
                main_project_exists=(ROOT/PDS).is_file(),model_exists=(ROOT/'models/yolo11n_person_640x384.onnx').is_file(),
                bit_sha256=hashlib.sha256(bit.read_bytes()).hexdigest() if bit.is_file() else None,
                expected_bit_sha256=EXPECTED_BIT_SHA256,person_python=person,tracking_python=tracking,
                control_environment_ready=bool(person and tracking),probes=probes)

def configure(report):
    if not report['control_environment_ready'] or not report['model_exists']:
        raise SystemExit('缺少完整运行环境。请按 requirements_windows.txt 安装依赖，再运行本工具；不会连接串口。')
    backup=ROOT/'submission_docs/original_runtime_configs';backup.mkdir(parents=True,exist_ok=True)
    for filename in ['person_runtime.json','tracking_runtime.json']:
        src=ROOT/'stabilization_tools'/filename
        if not (backup/filename).exists():shutil.copy2(src,backup/filename)
    person=load_config('person_runtime.json')
    person.update(python=report['person_python'],model=(ROOT/'models/yolo11n_person_640x384.onnx').as_posix(),
                  cache=(ROOT/'runtime_cache/person').as_posix())
    tracking=load_config('tracking_runtime.json');tracking['python']=report['tracking_python']
    for name,data in [('person_runtime.json',person),('tracking_runtime.json',tracking)]:
        path=ROOT/'stabilization_tools'/name
        path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('已定位本机解释器和包内模型；原始配置保存在 submission_docs/original_runtime_configs。',flush=True)

def main():
    parser=argparse.ArgumentParser(description='比赛源码包的运行环境和重建入口')
    parser.add_argument('action',choices=['check','configure','serve','build'])
    parser.add_argument('--pds-shell');parser.add_argument('--no-browser',action='store_true');parser.add_argument('--port',type=int)
    args,build_options=parser.parse_known_args()
    if build_options and args.action!='build':parser.error('未知参数：'+' '.join(build_options))
    if args.action=='build':
        exe=find_pds(args.pds_shell)
        if not exe:raise SystemExit('请安装 PDS 2022.2-SP6.4，并通过 --pds-shell 或 FPGA_PDS_SHELL 指定 pds_shell.exe。')
        file=ROOT/'build_nokeys_storage.py'
        if not file.is_file():raise SystemExit('缺少本版优化构建脚本。')
        os.chdir(ROOT)
        os.environ['PDS_SHELL']=exe
        sys.path.insert(0,str(ROOT))
        sys.argv=[str(file),*build_options]
        runpy.run_path(str(file),run_name='__main__')
        return
    report=inspect_environment(args.pds_shell)
    print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
    if args.action=='check':
        if report['bit_sha256']!=EXPECTED_BIT_SHA256:raise SystemExit('烧录文件校验未通过。')
        return
    configure(report)
    if args.action=='serve':
        options=[report['person_python'],'-B',str(ROOT/'web_control/start_web.py')]
        if args.no_browser:options.append('--no-browser')
        if args.port is not None:options+=['--port',str(args.port)]
        raise SystemExit(subprocess.call(options,cwd=ROOT))

if __name__=='__main__':main()
