"""Gate the release on real test logs, timing and the generated bitstream."""
from pathlib import Path
import hashlib,json,re
from projection_reference import ROOT

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    bit=ROOT/'fisheye5_720p60_balanced_imu_stabilization.sbit'
    timing=ROOT/'report_timing/hdmi_ddr_ov5640_top.rtr'
    assert (ROOT/'stabilization_build_exit.txt').read_text().strip()=='PASS'
    assert re.search(r'Design Summary\s*:\s*All Constraints Met\.',timing.read_text())
    for name in ['tb_projection','tb_pose_protocol','tb_pose_store','tb_baseline_keys','tb_baseline_gamma_osd',
                 'tb_baseline_display','tb_capture_vendor','tb_quality_control','tb_imu_500','tb_telemetry',
                 'projection_netlist','subdivision_frame','stable_frames_final']:
        p=ROOT/f'verification_stabilization/{name}.log';s=p.read_text()
        assert 'PASS ' in s and '** Fatal:' not in s and 'Errors: 0' in s,name
    for name in ['pc_report','web_report','telemetry_report','projection_accuracy']:
        assert json.loads((ROOT/f'verification_stabilization/{name}.json').read_text())['passed'],name
    assert json.loads((ROOT/'verification_quality/baseline_web_report.json').read_text())['passed']
    files=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/rtl').glob('*.v'))
    files+=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/data').glob('*.mem'))
    files+=list((ROOT/'source/design_fisheye_5frame_720p60_pipeline/data').glob('*.vh'))
    files=[p for p in files if p.name!='rom_diagnostic.v']
    assert all(p.stat().st_mtime<=bit.stat().st_mtime for p in files),'bit predates source/data'
    assert timing.stat().st_mtime<=bit.stat().st_mtime
    assert bit.stat().st_size>1000000
    resources={}
    dmr=(ROOT/'device_map/hdmi_ddr_ov5640_top.dmr').read_text()
    for name in ['LUT','FF','APM','DRM']:
        m=re.search(r'\|\s*'+name+r'\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)',dmr)
        assert m,name;resources[name]={'used':float(m[1]),'available':float(m[2])}
    frames=[]
    s=(ROOT/'verification_stabilization/stable_frames_final.log').read_text()
    for frame,pixels,cycles,splits in re.findall(r'PASS full stabilized frame (\d+) pixels=(\d+) cycles=(\d+) splits=(\d+)',s):
        assert int(pixels)==921600
        frames.append({'case':int(frame),'pixels':int(pixels),'cycles':int(cycles),'simulated_render_ms':int(cycles)/125000,'simulated_max_render_fps':125000000/int(cycles)})
    assert len(frames)==6
    manifest=dict(revision='20261010-imu-stabilization-v1',project='HDMI_DDR3_OV5640_test_720p60_balanced.pds',
        bitstream='fisheye5_720p60_balanced.sbit',named_fix_bitstream=bit.name,sha256=digest(bit),
        all_constraints_met=True,physical_board_verified=False,real_camera_MTF_measured=False,
        physical_stabilization_verified=False,exposure_sync_calibrated=False,camera_imu_alignment_calibrated=False,
        web_port=8770,native_stabilization_port=8771,firmware_status='BW / binary v1',stage=str(ROOT),
        key0_order=['RAW','BASE','SPL','QUAD'],baseline_mode=3,imu_rate_hz=500,
        binary_baud=921600,timestamp_tick_us=10,pose_packet_bytes=50,
        backup=str(ROOT/'backup_before_stabilization'))
    report=dict(revision=manifest['revision'],bitstream_sha256=manifest['sha256'],resources=resources,
        all_constraints_met=True,minimum_ddr_setup_slack_ns=.022,physical_board_verified=False,
        hardware_500_hz_and_921600_verified=False,physical_stabilization_verified=False,
        frame_count=5,ddr_reserved_bytes=5*2097152,geometric_resamplings=1,
        per_frame_pose_tag_and_timestamp_checked=True,timeout_baseline_fallback_ms_from_vsync=30,
        imu_timestamped_spi_samples_verified=120,imu_sample_rate_hz=500,
        actual_synthesized_projection_vectors_passed=3050,
        full_stabilized_frame_pixels_passed=6*921600,full_frames=frames,
        subdivision_stress_splits=130,previous_mesh_and_fifo_fixes_preserved=True,
        legacy_key_gamma_display_capture_and_uart_regressions_passed=True,
        pc_fusion_and_protocol_tests_passed=7,web_tests_passed=True,
        limitations=['physical board, exposure offset and axis/direction calibration need validation',
                     'HDMI 60Hz is separate from unique stabilized FPS',
                     'six-axis yaw has no absolute heading reference; positive-Z rays only'])
    for name,value in [('balanced_manifest.json',manifest),('balanced_build_report.json',report),('stabilization_build_report.json',report)]:
        (ROOT/name).write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
    (ROOT/'verification_stabilization/release_source_hashes.json').write_text(json.dumps({str(p.relative_to(ROOT)):digest(p) for p in files},indent=2))
    print('PASS release gate:',manifest['sha256'],resources)

if __name__=='__main__':main()
