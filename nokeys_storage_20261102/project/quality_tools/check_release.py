from pathlib import Path
import hashlib,json,re,shutil
R=Path(__file__).resolve().parents[1]
V=R/'verification_quality';S=R/'source/design_fisheye_5frame_720p60_pipeline'
for name in ['source','control','mapping','frames','display']:
    log=(V/(name+'.log')).read_text(encoding='utf-8',errors='replace')
    assert '# PASS ' in log and '** Fatal:' not in log and '# Errors: 0, Warnings: 0' in log,name
mapping=(V/'mapping.log').read_text();assert len(re.findall('PASS mapping view=',mapping))==8
fr=(V/'frames.log').read_text();models=[float(x) for x in re.findall(r'frame_ms=([\d.]+)',fr)];assert len(models)==8
cmp=json.loads((V/'frame_comparison.json').read_text());assert len(cmp)==8
arbitrary=json.loads((V/'arbitrary_image_check/RTL_comparison/comparison.json').read_text());assert arbitrary['mismatched_pixels']==0
numeric=json.loads((V/'measurement_numeric_test.json').read_text());assert numeric['wrong_size_rejected']
web=json.loads((V/'web_report.json').read_text());assert web['passed']
timing=(R/'report_timing/hdmi_ddr_ov5640_top.rtr').read_text();assert 'Design Summary : All Constraints Met.' in timing
bit=R/'generate_bitstream/hdmi_ddr_ov5640_top.sbit';assert bit.exists()
assert bit.stat().st_mtime>max(p.stat().st_mtime for p in (S/'rtl').glob('*.v')),'Bitstream predates an RTL change'
console=(R/'quality_build_console_final.log').read_text(errors='replace');assert 'Process "Generate Bitstream" done.' in console
prr=(R/'place_route/hdmi_ddr_ov5640_top.prr').read_text();row=next(s for s in prr.splitlines() if re.match(r'\| hdmi_ddr_ov5640_top\s+\|',s));fields=[s.strip() for s in row.split('|')];resources=dict(LUT=int(fields[2]),FF=int(fields[3]),APM=int(fields[5]),DRM=float(fields[6]))
outbit=R/'fisheye5_720p60_quality_baseline.sbit';shutil.copy2(bit,outbit)
sourcehash={str(f.relative_to(R)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest() for f in S.rglob('*') if f.is_file() and f.suffix in ['.v','.vh','.mem','.json']}
report=dict(project='HDMI_DDR3_OV5640_test_720p60_quality_baseline.pds',bitstream=outbit.name,bitstream_sha256=hashlib.sha256(outbit.read_bytes()).hexdigest(),
    all_constraints_met=True,resources=resources,DDR_slots=5,output_size=[1280,720],HDMI_refresh_hz=60,hardware_verified=False,real_camera_MTF_measured=False,
    geometry=json.loads((V/'geometry_report.json').read_text()),source_overlap=json.loads((V/'source_overlap.json').read_text()),old_left_right_overlap=.5138440239963082,
    frames=cmp,frame_models_ms=models,arbitrary_image_simulation=arbitrary,numerical_measurement_checks=numeric,web=web,web_port=8767,source_sha256=sourcehash,
    limitations=['No real-camera MTF or line-error measurement yet','Arbitrary image input is RTL simulation; physical board uses deterministic test source','Existing mapping does not yet cover the lens nominal full 200 degrees'])
(R/'quality_build_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({k:report[k] for k in ['project','bitstream','all_constraints_met','resources','frame_models_ms','hardware_verified']},indent=2))
