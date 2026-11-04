from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,os,re,shutil,subprocess,sys,time
P=Path(__file__).resolve().parent
W=P/'release_support';V=P/'verification'
EXE=Path(os.environ.get('PDS_SHELL',r'D:\fpgapango\PDS_2022.2-SP6.4\bin\pds_shell.exe'))
ARCH='set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def state(stage,**more):
    report=dict(stage=stage,at=datetime.now(timezone.utc).isoformat(),**more)
    (V/'build_state.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
def run(args,stage):
    state(stage)
    with (V/(stage+'.log')).open('wb') as out:
        r=subprocess.run([str(EXE),'-work_dir',str(P),*map(str,args)],cwd=P,stdout=out,stderr=subprocess.STDOUT,creationflags=0x08000000)
    log=(V/(stage+'.log')).read_text(errors='replace')
    if r.returncode or re.search(r'^\s*E:',log,re.M):raise RuntimeError(stage+' failed: '+log[-5000:])
    state(stage+'_complete')
def resources(path):
    lines=path.read_text(errors='replace').splitlines()
    for line in lines:
        fields=[p.strip() for p in line.split('|')]
        if len(fields)>6 and fields[1]=='hdmi_ddr_ov5640_top':
            return dict(zip(['LUT','FF','Distributed_RAM','APM','DRM'],map(float,fields[2:7])))
    mapped={}
    names={'LUT':'LUT','FF':'FF','Distributed RAM':'Distributed_RAM','APM':'APM','DRM':'DRM'}
    for line in lines:
        fields=[p.strip() for p in line.split('|')]
        if len(fields)>3 and fields[1] in names:
            mapped[names[fields[1]]]=float(fields[2])
    if len(mapped)==5:return mapped
    raise RuntimeError('Missing resource summary')
def restore_physical_constraints(destination=None):
    snapshot=W/'calibration_board_verified.pcf'
    reference=json.loads((W/'physical_reference.json').read_text())
    assert sha(snapshot)==reference['sha256'],'Verified physical snapshot changed'
    assert sha(P/'calibration_route_priority.rcf')==reference['route_priority_sha256'],'Routing reference changed'
    assert len(re.findall(r'^def_inst_site ',snapshot.read_text(),re.M))==25
    target=Path(destination) if destination is not None else P/'calibration_board.pcf'
    target.write_bytes(snapshot.read_bytes())
    return sha(target)

def main():
    V.mkdir(parents=True,exist_ok=True)
    from regenerate_packed_projection import generate
    generate(check=True)
    def argument(name,default):
        return sys.argv[sys.argv.index(name)+1] if name in sys.argv else default
    place_seed=int(argument('--place-seed','5'))
    route_seed=int(argument('--route-seed','19'))
    fast_router='--slow-router' not in sys.argv
    placed_db=Path(argument('--placed-db','')) if '--placed-db' in sys.argv else None
    files=[f for name in ['source','ipcore'] for f in (P/name).rglob('*') if f.is_file()]
    frozen={str(f.relative_to(P)):sha(f) for f in files}
    constraints={f.name:sha(f) for f in P.glob('*.fdc')}
    if '--resume-map' in sys.argv:
        saved=json.loads((V/'build_inputs.json').read_text())
        assert saved['sources']==frozen and saved['timing_constraints']==constraints,'Cannot reuse mapping with changed inputs'
        assert (P/'device_map/hdmi_ddr_ov5640_top_map.adf').is_file()
    else:
        (V/'build_inputs.json').write_text(json.dumps(dict(sources=frozen,timing_constraints=constraints),indent=2))
        run(['-project','HDMI_DDR3_OV5640_test_720p60_pipeline.pds','-run','dev_map'],'compile_and_map')
    report=P/'device_map/hdmi_ddr_ov5640_top.dmr'
    if report.exists():
        shutil.copy2(report,V/'device_map.dmr')
        print(json.dumps(dict(mapped_resources=resources(report))),flush=True)
    if '--map-only' in sys.argv:return
    # Mapping rewrites the PDS GUI physical file and drops def_inst_site lines.
    # Restore the frozen original constraints after every map, before routing.
    physical_hash=restore_physical_constraints()
    (V/'physical_constraints_used.json').write_text(json.dumps(dict(restored_after_mapping=True,
        mandatory_restored_sites=22,total_fixed_sites=25,sha256=physical_hash,source='release_support/calibration_board_verified.pcf',
        route_priority_sha256=sha(P/'calibration_route_priority.rcf')),indent=2))
    tests=W/'rtl_tests_verified.json'
    while not tests.exists():
        state('waiting_for_rtl_tests');time.sleep(3)
    assert json.loads(tests.read_text())['passed'],'RTL tests failed'
    test_sources=json.loads(tests.read_text())['sources']
    rtl=P/'source/design_fisheye_5frame_720p60_pipeline/rtl'
    assert test_sources=={f.name:sha(f) for f in rtl.glob('*.v')},'Rerun RTL tests after changing sources'
    for f in files:assert sha(f)==frozen[str(f.relative_to(P))],str(f)
    baseline=json.loads((W/'reference_resources.json').read_text())
    if report.exists():assert resources(report)['DRM']<=baseline['DRM'],'Block RAM exceeds this release'
    route=ARCH+''.join(f'add_constraint {{{(P/n).as_posix()}}}\n' for n in ['HDMI_DDR3_OV5640_test_fullview_plus.fdc','hdmi_rx_recovery_cdc.fdc','calibration_board.pcf','calibration_route_priority.rcf'])
    route_input=placed_db or P/'device_map/hdmi_ddr_ov5640_top_map.adf'
    assert route_input.is_file(),str(route_input)
    refine=' -enable_route_constraint_iterate -route_constraint_iterate_times 3 -route_constraint_slack 0.15 -route_constraint_max_timing_path 30' if placed_db else ''
    route+=f'pnr -input_db_file {{{route_input.as_posix()}}} -gplace_seed {place_seed} -groute_seed {route_seed} -mode performance -fast_router {str(fast_router).lower()} -share_router_control_signal false -fix_hold_violation -fix_hold_violation_iterations 80 -fix_hold_violation_threshold 100 -fix_hold_violation_threshold_for_clock_path_cross_srb 100 -fix_hold_violation_threshold_for_clk_tree 0 -optimize_multi_corner_timing{refine} -force_to_run\n'
    (V/'route.tcl').write_text(route)
    run(['-file',V/'route.tcl'],'place_route')
    assert sha(P/'calibration_board.pcf')==physical_hash,'Physical constraint changed during route'
    timing=ARCH+''.join(f'add_constraint {{{(P/n).as_posix()}}}\n' for n in ['HDMI_DDR3_OV5640_test_fullview_plus.fdc','hdmi_rx_recovery_cdc.fdc'])
    timing+=f'report_timing -input_db_file {{{(P/"place_route/hdmi_ddr_ov5640_top_pnr.adf").as_posix()}}} -force_to_run\n'
    (V/'timing.tcl').write_text(timing);run(['-file',V/'timing.tcl'],'timing')
    report=P/'report_timing/hdmi_ddr_ov5640_top.rtr';text=report.read_text(errors='replace');shutil.copy2(report,V/'timing_final.rtr')
    passed='Design Summary : All Constraints Met.' in text and 'Slack (VIOLATED)' not in text
    refinement_used=bool(placed_db)
    if not passed and not placed_db:
        shutil.copy2(V/'timing_final.rtr',V/'timing_before_refine.rtr')
        plc=P/'place_route/hdmi_ddr_ov5640_top_plc.adf'
        assert plc.is_file()
        refined=route.replace(route_input.as_posix(),plc.as_posix()).replace(' -force_to_run',
            ' -enable_route_constraint_iterate -route_constraint_iterate_times 3 -route_constraint_slack 0.15 -route_constraint_max_timing_path 30 -force_to_run')
        (V/'route_refine.tcl').write_text(refined)
        run(['-file',V/'route_refine.tcl'],'place_route_refine')
        assert sha(P/'calibration_board.pcf')==physical_hash
        run(['-file',V/'timing.tcl'],'timing_refine')
        text=report.read_text(errors='replace');shutil.copy2(report,V/'timing_final.rtr')
        passed='Design Summary : All Constraints Met.' in text and 'Slack (VIOLATED)' not in text
        refinement_used=True
    assert passed,'Timing failed; no bit exported'
    for f in files:assert sha(f)==frozen[str(f.relative_to(P))]
    assert constraints=={f.name:sha(f) for f in P.glob('*.fdc')}
    generate=ARCH+f'gen_bit_stream -input_db_file {{{(P/"place_route/hdmi_ddr_ov5640_top_pnr.adf").as_posix()}}} -force_to_run\n'
    (V/'bit.tcl').write_text(generate);run(['-file',V/'bit.tcl'],'bitstream')
    bit=P/'fisheye5_calibrated_6mm_nokeys_storage_20261102.sbit'
    shutil.copy2(P/'generate_bitstream/hdmi_ddr_ov5640_top.sbit',bit)
    physical=P/'place_route/hdmi_ddr_ov5640_top.prr';shutil.copy2(physical,V/'place_route.prr')
    result=dict(passed=True,bitstream=str(bit),sha256=sha(bit),baseline=baseline,current=resources(physical),timing='All Constraints Met',
                placement_seed=place_seed,route_seed=route_seed,fast_router=fast_router,route_constraint_iterations=3 if refinement_used else 0,
                reused_placement_db=str(placed_db) if placed_db else None,
                hardware_programmed=False,hardware_measured=False)
    (V/'build_result.json').write_text(json.dumps(result,indent=2));state('PASS',**result)
if __name__=='__main__':
    try:main()
    except Exception as e:state('FAILED',error=str(e));raise
