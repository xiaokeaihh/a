"""Release only verified all-view firmware and host code; never touch calibration."""
from pathlib import Path
import hashlib,json,re,shutil
from projection_reference import ROOT

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def log_pass(name,pattern='PASS '):
    s=(ROOT/'verification_stabilization'/f'{name}.log').read_text()
    if pattern not in s or '** Fatal:' in s or 'Errors: 0' not in s:raise RuntimeError(f'Incomplete verification: {name}')
    return s

def main():
    if (ROOT/'stabilization_build_exit.txt').read_text().strip()!='PASS':raise RuntimeError('Build not complete')
    timing=ROOT/'report_timing/hdmi_ddr_ov5640_top.rtr'
    if not re.search(r'Design Summary\s*:\s*All Constraints Met\.',timing.read_text()):raise RuntimeError('Timing failed')
    bit=ROOT/'generate_bitstream/hdmi_ddr_ov5640_top.sbit'
    files=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/rtl').glob('*.v'))
    files+=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/data').glob('*.mem'))
    files+=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/data').glob('*.vh'))
    files=[p for p in files if p.name!='rom_diagnostic.v']
    if not all(p.stat().st_mtime<=bit.stat().st_mtime for p in files):raise RuntimeError('Firmware predates source')
    if timing.stat().st_mtime>bit.stat().st_mtime:raise RuntimeError('Firmware predates timing')
    selected_route=json.loads((ROOT/'verification_stabilization/selected_route.json').read_text())
    if digest(ROOT/'place_route/hdmi_ddr_ov5640_top_pnr.adf')!=selected_route['sha256']:raise RuntimeError('Selected routing database changed')
    if digest(ROOT/'HDMI_DDR3_OV5640_test_fullview_plus.fdc')!=selected_route['timing_constraints_sha256']:raise RuntimeError('Timing constraints changed')
    for name in ['tb_projection','tb_pose_protocol','tb_pose_store','tb_allviews_routes','tb_telemetry','tb_baseline_keys','tb_baseline_gamma_osd','tb_baseline_display','tb_capture_vendor','tb_quality_control']:
        log_pass(name)
    log_pass('projection_netlist','PASS actual full-design synthesized projection/ROM, 150 vectors')
    s=log_pass('allviews_frames');frames=[]
    for case,view,roll,pixels,cycles,splits in re.findall(r'PASS all-view case (\d+) view=(\d+) roll=(\d+) pixels=(\d+) cycles=(\d+) splits=(\d+)',s):
        if int(pixels)!=921600:raise RuntimeError('Incomplete pixel coverage')
        frames.append(dict(case=int(case),view=int(view),roll_deg=int(roll),pixels=int(pixels),cycles=int(cycles),splits=int(splits),simulated_render_ms=int(cycles)/125000,simulated_max_render_fps=125000000/int(cycles)))
    if len(frames)!=14 or {(f['view'],f['roll_deg']) for f in frames}!={(v,a) for v in range(1,8) for a in [0,90]}:raise RuntimeError('Missing view/rotation cases')
    tests={}
    for name in ['pc_report','web_report','telemetry_report','projection_accuracy']:
        tests[name]=json.loads((ROOT/f'verification_stabilization/{name}.json').read_text())
        if not tests[name]['passed']:raise RuntimeError(f'{name} failed')
    mapped_resources={};dmr=(ROOT/'device_map/hdmi_ddr_ov5640_top.dmr').read_text()
    for name in ['LUT','FF','APM','DRM']:
        m=re.search(r'\|\s*'+name+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)',dmr)
        if not m:raise RuntimeError('Missing resource report')
        mapped_resources[name]={'used':float(m[1]),'available':float(m[2])}
    resources={};prr=(ROOT/'place_route/hdmi_ddr_ov5640_top.prr').read_text()
    for name in ['LUT','FF']:
        rows=re.findall(r'^\|\s*'+name+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)',prr,re.M)
        if len(rows)!=2:raise RuntimeError('Missing final placement resource report')
        resources[name]={'used':sum(float(row[0]) for row in rows),'available':sum(float(row[1]) for row in rows)}
    for name in ['APM','DRM']:
        m=re.search(r'\|\s*Use of '+name+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)',prr)
        if not m:raise RuntimeError('Missing final placement resource report')
        resources[name]={'used':float(m[1]),'available':float(m[2])}
    named='fisheye5_720p60_balanced_allviews_stabilization.sbit'
    for name in [named,'fisheye5_720p60_balanced_imu_stabilization.sbit','fisheye5_720p60_balanced.sbit']:shutil.copy2(bit,ROOT/name)
    report=dict(revision='20261010-allviews-autorestore-v2',bitstream=named,sha256=digest(bit),all_constraints_met=True,resources=resources,mapped_resources=mapped_resources,resource_report='place_route/hdmi_ddr_ov5640_top.prr',
        stabilized_views=[1,2,3,4,5,6,7],RAW_unstabilized=True,compare_RAW_left_unstabilized=True,
        pose_bundle_bytes=230,one_sampling_per_pixel=True,frame_count=5,DDR_reserved_bytes=5*2097152,selected_route=selected_route,
        full_frame_cases=frames,full_frame_pixels_checked=14*921600,RTL_projection_vectors=5150,synthesized_projection_boundary_vectors=150,
        pc_tests=tests['pc_report']['tests'],web_tests_passed=True,saved_installation_automatically_restored=True,actual_projection_net_sha256=digest(ROOT/'verification_stabilization/actual_projection_net.v'),
        stationary_bias_initialization_seconds=2,reference_3d='current connection initial pose',
        physical_board_verified=False,physical_stabilization_verified=False,exposure_offset_calibrated=False,
        limitations=['Actual FPS and LAT need board measurement','Six-axis IMU has no persistent absolute heading','Out-of-view and rear-facing rays are black'])
    for name in ['allviews_release_report.json','stabilization_build_report.json','balanced_build_report.json']:
        (ROOT/name).write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    manifest=dict(revision=report['revision'],project='HDMI_DDR3_OV5640_test_720p60_balanced.pds',bitstream='fisheye5_720p60_balanced.sbit',named_fix_bitstream=named,
        sha256=report['sha256'],all_constraints_met=True,physical_board_verified=False,physical_stabilization_verified=False,
        web_port=8770,native_stabilization_port=8771,key0_order=['RAW','BASE','SPL','QUAD'],
        stabilized_views=report['stabilized_views'],pose_bundle_bytes=230,saved_calibration_auto_restore=True,
        calibration_file_preserved='stabilization_tools/camera_imu.json',frame_count=5)
    (ROOT/'balanced_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    runtime_files=['attitude.py','server.py','protocol.py','projection_reference.py','generate_tables.py','generate_frame_gold.py','test_pc.py','check_telemetry.py','extract_projection_netlist.py','release_allviews.py','run_regressions.ps1','run_allviews_frames.ps1','run_allviews_control.ps1','run_net_allviews.ps1']
    files+=[ROOT/'stabilization_tools'/name for name in runtime_files]
    files+=list((ROOT/'web_control/dist').glob('*'))
    files+=[ROOT/name for name in ['HDMI_DDR3_OV5640_test_720p60_balanced.pds','HDMI_DDR3_OV5640_test_fullview_plus.fdc','build_stabilization.ps1','route_iterate_fix.tcl']]
    files+=[ROOT/'source/design_fisheye_5frame_720p60_pipeline/data'/name for name in ['baseline_config.json','balanced_config.json','stabilization_config.json']]
    (ROOT/'verification_stabilization/allviews_source_hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)):digest(p) for p in files if p.is_file()},indent=2))
    print('PASS all-view release',report['sha256'],resources)

if __name__=='__main__':main()
