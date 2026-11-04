"""Publish the verified unified UI and exposure firmware, preserving installation data."""
from pathlib import Path
import argparse, datetime, hashlib, json, re, shutil

ROOT=Path(__file__).resolve().parents[1]
REVISION='20261011-unified-exposure'
BIT='fisheye5_720p60_balanced_unified_exposure.sbit'
RTL=Path('source/design_fisheye_5frame_720p60_pipeline/rtl')
CHANGED={str(RTL/'reg_config_720p.v')}

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read_json(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def write_json(path,value):path.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
def checked_log(name,pattern='PASS '):
    path=ROOT/'verification_stabilization'/f'{name}.log'
    text=path.read_text()
    if pattern not in text or 'Errors: 0' not in text or '** Fatal:' in text:raise RuntimeError(f'Incomplete verification: {name}')
    return path

def validate():
    if (ROOT/'unified_build_exit.txt').read_text().strip()!='PASS':raise RuntimeError('Exposure firmware build not complete')
    timing=ROOT/'report_timing/hdmi_ddr_ov5640_top.rtr'
    if not re.search(r'Design Summary\s*:\s*All Constraints Met\.',timing.read_text()):raise RuntimeError('Timing constraints not met')
    bit=ROOT/BIT
    old=read_json(ROOT/'verification_stabilization/allviews_source_hashes.json')
    source_paths=[ROOT/name for name in old if name.startswith('source')]
    unchanged=[];changed=[]
    for name,expected in old.items():
        if not name.startswith('source'):continue
        current=digest(ROOT/name)
        if current==expected:unchanged.append(name)
        elif name in CHANGED:changed.append(name)
        else:raise RuntimeError('Unexpected geometry/source change: '+name)
    if set(changed)!=CHANGED:raise RuntimeError('Expected exposure change missing')
    for path in source_paths:
        if path.stat().st_mtime>bit.stat().st_mtime:raise RuntimeError('Bitstream predates source: '+str(path))
    selected=read_json(ROOT/'verification_stabilization/unified_selected_route.json')
    if selected.get('uses_previous_design_database'):raise RuntimeError('Old-design routing is not a valid new firmware build')
    for relative,key in [('place_route/hdmi_ddr_ov5640_top_pnr.adf','sha256'),('device_map/hdmi_ddr_ov5640_top_map.adf','mapped_design_sha256'),('HDMI_DDR3_OV5640_test_fullview_plus.fdc','timing_constraints_sha256')]:
        if digest(ROOT/relative)!=selected[key]:raise RuntimeError('Selected build input changed: '+relative)
    if timing.stat().st_mtime>bit.stat().st_mtime:raise RuntimeError('Bitstream predates timing verification')
    for name,pattern in [('camera_exposure','PASS 500-line exposure'),('exposure_net','PASS actual synthesized sensor ROM'),('tb_telemetry','PASS '),('tb_allviews_routes','PASS '),('projection_netlist','PASS actual full-design synthesized projection/ROM, 150 vectors')]:checked_log(name,pattern)
    checked_log('allviews_frames','PASS all-view case')
    checked_log('tb_projection')
    tests={name:read_json(ROOT/'verification_stabilization'/f'{name}.json') for name in ['pc_report','web_report','telemetry_report','unified_launch_report','routed_exposure_report']}
    if not all(value['passed'] for value in tests.values()):raise RuntimeError('Software or protocol verification failed')
    if tests['routed_exposure_report']['routed_database_sha256']!=selected['sha256']:raise RuntimeError('Actual exposure check belongs to another routed design')
    original=read_json(ROOT/'allviews_release_report.json')
    if not original['all_constraints_met'] or original['full_frame_pixels_checked']!=12902400:raise RuntimeError('Original geometry evidence incomplete')
    mapped_resources={}
    dmr=(ROOT/'device_map/hdmi_ddr_ov5640_top.dmr').read_text()
    for name in ['LUT','FF','APM','DRM']:
        row=re.search(r'\|\s*'+name+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)',dmr)
        if not row:raise RuntimeError('Missing mapped resource report: '+name)
        mapped_resources[name]={'used':float(row[1]),'available':float(row[2])}
    report=dict(revision=REVISION,bitstream=BIT,sha256=digest(bit),all_constraints_met=True,
        exposure_lines=500,previous_exposure_lines=444,exposure_increase_percent=(500/444-1)*100,
        nominal_exposure_ms=500/740*1000/30,actual_exposure_time_measured=False,
        sensor_gain=2.0,white_balance_unchanged=True,frame_timing_unchanged=True,
        selected_route=selected,mapped_resources=mapped_resources,unified_web_port=8770,single_serial_owner=True,
        saved_installation_automatically_restored=True,calibration_file_preserved='stabilization_tools/camera_imu.json',
        pc_tests=tests['pc_report']['tests'],web_tests_passed=True,web_checks=tests['web_report']['checks'],
        actual_projection_net_sha256=digest(ROOT/'verification_stabilization/actual_projection_net.v'),
        synthesized_projection_boundary_vectors=150,
        geometry_evidence=dict(reused_from=original['revision'],unchanged_source_files=unchanged,
            changed_source_files=changed,full_frame_pixels_checked=original['full_frame_pixels_checked'],
            full_frame_cases=original['full_frame_cases'],RTL_projection_vectors=original['RTL_projection_vectors'],
            reason='Only exposure register constants changed; rendering, lens tables and FPGA serial protocol are unchanged.'),
        stabilized_views=original['stabilized_views'],frame_count=5,DDR_reserved_bytes=5*2097152,
        pose_bundle_bytes=230,one_sampling_per_pixel=True,RAW_unstabilized=True,compare_RAW_left_unstabilized=True,
        physical_board_verified=False,physical_stabilization_verified=False,
        limitations=['Actual exposure, FPS and LAT need board measurement','Longer exposure can increase motion blur'])
    write_json(ROOT/'unified_release_report.json',report)
    for name in ['balanced_build_report.json','stabilization_build_report.json']:write_json(ROOT/name,report)
    manifest=dict(revision=REVISION,project='HDMI_DDR3_OV5640_test_720p60_balanced.pds',bitstream='fisheye5_720p60_balanced.sbit',
        named_fix_bitstream=BIT,sha256=report['sha256'],all_constraints_met=True,physical_board_verified=False,
        physical_stabilization_verified=False,web_port=8770,native_stabilization_port=8770,
        key0_order=['RAW','BASE','SPL','QUAD'],stabilized_views=report['stabilized_views'],pose_bundle_bytes=230,
        saved_calibration_auto_restore=True,calibration_file_preserved=report['calibration_file_preserved'],frame_count=5,exposure_lines=500)
    write_json(ROOT/'balanced_manifest.json',manifest)
    shutil.copy2(bit,ROOT/'fisheye5_720p60_balanced.sbit')
    tools_files=['attitude.py','server.py','protocol.py','projection_reference.py','test_pc.py','check_telemetry.py',
        'extract_projection_netlist.py','run_net_allviews.ps1','run_regressions.ps1','run_allviews_frames.ps1','run_allviews_control.ps1',
        'extract_exposure_netlist.py','run_exposure_net.ps1','run_exposure_verification.ps1','check_routed_exposure.py','release_unified.py']
    runtime=[ROOT/'stabilization_tools'/name for name in tools_files]
    runtime+=[ROOT/'web_control'/name for name in ['start_web.py','启动网页.cmd','test_stabilization.cjs','test_launcher.py']]
    runtime+=list((ROOT/'web_control/dist').glob('*'))
    runtime+=[ROOT/name for name in ['HDMI_DDR3_OV5640_test_720p60_balanced.pds','HDMI_DDR3_OV5640_test_fullview_plus.fdc','build_unified_exposure.ps1','启动网页控制.cmd','启动稳像控制.cmd']]
    write_json(ROOT/'verification_stabilization/unified_source_hashes.json',{str(p.relative_to(ROOT)):digest(p) for p in source_paths+runtime})
    return report

def publish(destination):
    destination=destination.resolve()
    if destination==ROOT:raise RuntimeError('Publication target must differ from staging project')
    report=validate()
    profile=destination/'stabilization_tools/camera_imu.json'
    before=digest(profile) if profile.exists() else None
    if profile.exists() and not read_json(profile).get('alignment_calibrated'):raise RuntimeError('Existing saved installation is not complete')
    manifest=read_json(ROOT/'verification_stabilization/unified_source_hashes.json')
    old=read_json(ROOT/'verification_stabilization/allviews_source_hashes.json')
    # Source was already delivered by the previous all-view release. Refuse to
    # replace new independent hardware edits made during this long build.
    for name,expected in manifest.items():
        if not name.startswith('source'):continue
        target=destination/name
        if target.exists() and digest(target) not in {expected,old.get(name)}:raise RuntimeError('User source changed during build: '+name)
    stamp=datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    backup=ROOT/('backup_publish_unified_'+stamp)
    explicit=[BIT,'fisheye5_720p60_balanced.sbit','unified_release_report.json','balanced_build_report.json','stabilization_build_report.json','balanced_manifest.json',
        'README_统一网页与曝光.md','README_IMU稳像.md','build_unified_exposure.ps1','unified_compile.tcl',
        '启动网页控制.cmd','启动稳像控制.cmd','HDMI_DDR3_OV5640_test_720p60_balanced.pds',
        'device_map/hdmi_ddr_ov5640_top_map.adf','device_map/hdmi_ddr_ov5640_top.dmr','device_map/hdmi_ddr_ov5640_top.pcf',
        'synthesize/hdmi_ddr_ov5640_top_syn.vm','synthesize/hdmi_ddr_ov5640_top_syn.adf',
        'place_route/hdmi_ddr_ov5640_top_pnr.adf','place_route/hdmi_ddr_ov5640_top.prr',
        'report_timing/hdmi_ddr_ov5640_top.rtr','generate_bitstream/hdmi_ddr_ov5640_top.sbit',
        'verification_stabilization/unified_source_hashes.json','verification_stabilization/unified_selected_route.json',
        'verification_stabilization/actual_projection_net.v','verification_stabilization/netlist_cells.json',
        'verification_stabilization/tb_projection_netlist.sv','verification_stabilization/tb_camera_exposure.sv',
        'verification_stabilization/actual_exposure_rom.v','verification_stabilization/exposure_net_cells.json','verification_stabilization/tb_exposure_net.sv']
    explicit+=[str(checked_log(name).relative_to(ROOT)) for name in ['camera_exposure','exposure_net','tb_telemetry','tb_allviews_routes','projection_netlist']]
    explicit+=['verification_stabilization/'+name+'.json' for name in ['pc_report','web_report','telemetry_report','unified_launch_report','routed_exposure_report']]
    # Keep the existing, verified geometry files in place; only the
    # changed RTL module need publication in this revision.
    explicit+=[name for name in manifest if not name.startswith('source') or name in CHANGED]
    names=sorted(set(explicit))
    copied={}
    for name in names:
        if name=='stabilization_tools\\camera_imu.json' or name=='stabilization_tools/camera_imu.json':raise RuntimeError('Calibration must not be copied')
        source=ROOT/name
        if not source.is_file():raise RuntimeError('Missing release file: '+name)
        target=destination/name
        if target.exists():
            saved=backup/name;saved.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(target,saved)
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
        if digest(target)!=digest(source):raise RuntimeError('Publication checksum mismatch: '+name)
        copied[name]=digest(target)
    after=digest(profile) if profile.exists() else None
    if before!=after:raise RuntimeError('Calibration changed during publication; it was not written by this publisher')
    publication=dict(revision=REVISION,project=str(destination),backup=str(backup),files=len(copied),
        calibration_preserved=True,calibration_sha256=after,bitstream_sha256=report['sha256'],copied_sha256=copied)
    write_json(ROOT/'verification_stabilization/unified_publication.json',publication)
    shutil.copy2(ROOT/'verification_stabilization/unified_publication.json',destination/'verification_stabilization/unified_publication.json')
    print('PASS unified exposure release; calibration preserved;',len(copied),'files;',report['sha256'])

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--publish',type=Path)
    args=parser.parse_args()
    if args.publish:publish(args.publish)
    else:print('PASS verified unified release',validate()['sha256'])
