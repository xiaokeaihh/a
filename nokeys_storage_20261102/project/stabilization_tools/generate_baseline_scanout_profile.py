"""Reproduce/check the fixed BASE7 scanout envelope without changing geometry."""
import argparse, hashlib, json, re
import numpy as np
from pipeline_reference import ROOT, DATA, maps, bundle_for, pack_bundle

def generate():
    text=(DATA/'pipeline_view_constants.vh').read_text()
    packed=int(re.search(r"PIPELINE_STATIC_BUNDLE 1728'h([0-9a-fA-F]+)",text)[1],16)
    assert pack_bundle(bundle_for(7))==packed, 'Actual compiled preset matrices differ from the calibration/config reference'
    _,y,_,inside=maps(7,True)
    sy=y>>8
    req=[int(np.where(inside[720-8*(i+1):720-8*i],720-sy[720-8*(i+1):720-8*i],0).max()) for i in range(90)]
    # A proved upper envelope needs only shifts/adds, not a new DRM ROM.
    intercept=max(0,max(value-15*i//4 for i,value in enumerate(req)))
    bound=[intercept+15*i//4 for i in range(90)]
    assert all(a<=b for a,b in zip(req,bound)), 'Affine source envelope no longer covers this calibration'
    line,band,scan,margin=6656,24576,2777,12288
    limits=[]
    for p in range(90):
        need=0;possible=True
        for k in range(p,90):
            deadline=8*k*scan-margin
            if (k-p+1)*band>deadline:possible=False
            for j in range(p,k+1):need=max(need,bound[j]-(deadline-(k-j+1)*band)//line)
        limits.append(max(0,need) if possible else 1023)
    valid=[(i,n) for i,n in enumerate(limits) if n<=720]
    first=min(i for i,n in valid);lead=max(n for i,n in valid)
    header=['// Generated from the existing exact Q8 BASE7 mapping; no pixel LUT changes.',
        f"`define BASE_LEAD_ROWS 11'd{lead}",f"`define BASE_PREFIX_ROWS 11'd{first*8}",
        f'`define BASE_LINE_CYCLES {line}',f'`define BASE_BAND_CYCLES {band}',
        'function [10:0] baseline_band_source_rows;',' input [6:0] band;',' begin case(band)']
    header=header[:-1] # Replace the case declaration with arithmetic.
    header+=[' reg [10:0] band_times_15;',
        ' begin', " band_times_15={band,4'b0}-{4'b0,band};",
        f" baseline_band_source_rows=band<90 ? 11'd{intercept}+(band_times_15>>2) : 11'd720;",
        ' end','endfunction','']
    result='\n'.join(header)
    # Explicit exhaustive schedule proof for every eligible output prefix,
    # including each possible source-release point in the max-plus recurrence.
    worst_slack=1<<60
    for p in range(first,90):
        t=0
        for k in range(p,90):
            t=max(t,max(0,bound[k]-lead)*line)+band
            slack=8*k*scan-margin-t
            assert slack>=0,(p,k,slack)
            worst_slack=min(worst_slack,slack)
    inputs=['pipeline_view_constants.vh','baseline_constants.vh','stabilization_constants.vh',
        'stabilization_reciprocal.mem','stabilization_lossless_base.mem','stabilization_lossless_even.mem','stabilization_lossless_odd.mem',
        'baseline_config.json','balanced_config.json']
    report={'view':7,'reverse_capture':True,'dynamic_pose_allowed':False,'output':'1280x720',
        'all_pixels_checked':1280*720,'output_band_rows':8,'required_source_rows_per_8_output_rows':req,
        'conservative_source_bound_per_band':bound,'minimum_source_rows_by_committed_band':limits,'minimum_committed_source_rows':lead,'minimum_committed_output_rows':first*8,
        'source_line_budget_cycles':line,'band_service_budget_cycles':band,'scan_line_cycles':scan,
        'fetch_margin_cycles':margin,'minimum_deadline_slack_cycles':worst_slack,
        'input_sha256':{n:hashlib.sha256((DATA/n).read_bytes()).hexdigest() for n in inputs}}
    return result,report

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    text,report=generate();path=DATA/'baseline_scanout_profile.vh'
    if args.check:assert path.read_text()==text,'Stale BASE scanout profile; regenerate before building'
    else:path.write_text(text,encoding='ascii')
    out=ROOT/'verification_baseline_latency';out.mkdir(exist_ok=True)
    (out/'envelope_proof.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('PASS exact BASE profile, 921600 Q8 pixels, every future-band deadline; source lead',report['minimum_committed_source_rows'],'output prefix',report['minimum_committed_output_rows'])
