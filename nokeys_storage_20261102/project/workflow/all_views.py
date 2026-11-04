from pathlib import Path
import subprocess,json,hashlib,re,concurrent.futures,sys,numpy as np
W=Path(__file__).resolve().parent;P=W.parent;V=P/'verification';R=P/'source/design_fisheye_5frame_720p60_pipeline/rtl'
S=Path(r'C:\intelFPGA\18.1\modelsim_ase\win32aloem');lib=W/'all_views_work'
sys.path.insert(0,str(P/'stabilization_tools'))
from pipeline_reference import maps,bilinear,bundle_for,pack_bundle,map_pane
from projection_reference import view_matrices,rotation
src=np.arange(921600,dtype=np.int64).reshape(720,1280)
source=((src*251)^(src>>3)^0x5a96).astype(np.uint16)
for view in range(8):
    x,y,_,inside=maps(view,True);gold=bilinear(source,x,y,inside)
    np.savetxt(V/f'producer_gold_{view}_pose0.mem',gold.ravel(),fmt='%04x')
    (V/f'producer_bundle_{view}_pose0.mem').write_text(f'{pack_bundle(bundle_for(view)):0432x}\n')
for view in [6,7]:
    bundle=view_matrices(rotation(90))
    x,y,inside=map_pane(bundle[5 if view==6 else 0],640 if view==6 else 1280,360 if view==6 else 720,True)
    gold=bilinear(source,x,y,inside)
    if view==6:
        canvas=np.zeros((720,1280),np.uint16);canvas[180:540,320:960]=gold;gold=canvas
    np.savetxt(V/f'producer_gold_{view}_pose90.mem',gold.ravel(),fmt='%04x')
    (V/f'producer_bundle_{view}_pose90.mem').write_text(f'{pack_bundle(bundle):0432x}\n')
s=(W/'tests/tb_memory_producer.sv').read_text()
assert 'read_delay<=24' in s
(W/'tests/tb_all_views.sv').write_text(s.replace('module tb_memory_producer;','module tb_all_views;'))
def run(exe,args,name):
    with (V/name).open('wb') as out:r=subprocess.run([str(S/exe),*map(str,args)],cwd=P,stdout=out,stderr=subprocess.STDOUT)
    t=(V/name).read_text(errors='replace');assert r.returncode==0 and '** Error' not in t and '** Fatal' not in t,t[-6000:]
    assert 'Failed to open readmem' not in t,t[-3000:]
    return t
run('vlib.exe',[lib],'memory_views_vlib.log')
files=[f for f in R.glob('*.v') if f.name not in ['fisheye5_imu_top.v','rom_diagnostic.v']]+list((R/'fifo_vendor').glob('*.v'))
files += [P/'source/rtl'/n for n in ['i2c_com.v','wr_cmd_trans.v','wr_ctrl.v','rd_ctrl.v','wr_rd_ctrl_top.v']]
files += [P/'ipcore/wr_fram_buf/rtl/ipm2l_sdpram_v1_10_wr_fram_buf.v']
vendor=Path(r'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation')
files += [vendor/(n+'.v') for n in ['GTP_DRM18K','GTP_DRM36K_E1','GTP_GRS','GTP_RAM32X2DP','GTP_CLKBUFG','GTP_CLKBUFGMUX']]
run('vlog.exe',['-sv','-work',lib,*files,W/'tests/tb_all_views.sv'],'memory_views_compile.log')
def check(case):
    view,reverse,pose=case;name=f'memory_view{view}_reverse{reverse}_pose{pose}.log'
    print('START '+name,flush=True)
    t=run('vsim.exe',['-c','-lib',lib,'tb_all_views','-gCACHE_BITS=5','-gREQUEST_BITS=3',f'-gVIEW={view}',f'-gREVERSE={reverse}',f'-gPOSE={pose}','-do','run -all;quit -f'],name)
    assert 'PASS REAL_PRODUCER' in t
    result=re.search(r'PASS REAL_PRODUCER .*',t)[0];print(result,flush=True)
    return dict(view=view,reverse=reverse,pose=pose,result=result)
cases=[(v,r,0) for v in range(8) for r in (0,1)]+[(v,r,90) for v in [6,7] for r in (0,1)]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(check,cases))
sources={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in R.glob('*.v')}
(V/'memory_all_views.json').write_text(json.dumps(dict(passed=True,cases=results,cache_kib=8,source_requests=8,read_initial_delay_cycles=24,read_response_beats_per4cycles=2,all_pixels_match_reference=True,source_sha256=sources),indent=2))
print('PASS MEMORY_ALL_VIEWS twenty complete pixel frames, HDMI/camera/static and dynamic poses',flush=True)
