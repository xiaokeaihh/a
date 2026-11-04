from pathlib import Path
import subprocess,json,re
P=Path(__file__).resolve().parent;V=P/'verification';W=V/'fast_test_sources';R=P/'source/design_fisheye_5frame_720p60_pipeline/rtl'
S=Path(r'C:\intelFPGA\18.1\modelsim_ase\win32aloem');lib=W/'video_work'
def run(exe,args,name):
 with (V/name).open('wb') as out:r=subprocess.run([str(S/exe),*map(str,args)],cwd=P,stdout=out,stderr=subprocess.STDOUT)
 t=(V/name).read_text(errors='replace')
 assert r.returncode==0 and '** Error' not in t and '** Fatal' not in t,t[-5000:]
 return t
run('vlib.exe',[lib],'fast_video_vlib.log')
files=[f for f in R.glob('*.v') if f.name not in ['fisheye5_imu_top.v','rom_diagnostic.v']]+list((R/'fifo_vendor').glob('*.v'))
files += [P/'source/rtl'/n for n in ['i2c_com.v','wr_cmd_trans.v','wr_ctrl.v','rd_ctrl.v','wr_rd_ctrl_top.v']]
files += [P/'ipcore/wr_fram_buf/rtl/ipm2l_sdpram_v1_10_wr_fram_buf.v']
vendor=Path(r'D:\fpgapango\PDS_2022.2-SP6.4\arch\vendor\pango\verilog\simulation')
files += [vendor/(n+'.v') for n in ['GTP_DRM18K','GTP_DRM36K_E1','GTP_GRS','GTP_RAM32X2DP','GTP_CLKBUFG','GTP_CLKBUFGMUX']]
run('vlog.exe',['-sv','-work',lib,*files,W/'tb_real_scanout.sv'],'fast_video_vlog.log')
print('FAST_VIDEO_COMPILE_PASS',flush=True)
t=run('vsim.exe',['-c','-lib',lib,'tb_real_scanout','-do','run -all; quit -f'],'fast_video.log')
assert 'PASS REAL_SCANOUT' in t,t[-5000:]
m=re.search(r'first_output_ms=([\d.]+) first_content_ms=([\d.]+)',t);assert m
result=dict(passed=True,first_output_ms=float(m[1]),first_content_ms=float(m[2]),max_service_cycles=int(re.search(r'MAX_SERVICE cycles=(\d+)',t)[1]),pixels_checked=921600,hardware_measurement=False,phase='manual admission plus 14000 pixel clocks; continuous automatic controller separately tested')
(V/'fast_video_tests.json').write_text(json.dumps(result,indent=2))
print(t[-3200:],flush=True)
