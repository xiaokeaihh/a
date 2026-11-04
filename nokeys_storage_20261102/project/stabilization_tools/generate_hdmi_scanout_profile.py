from pathlib import Path
import sys,json,re,hashlib
import numpy as np
W=Path(__file__).resolve().parent;P=W.parent if W.name=='stabilization_tools' else W/'project';V=P/'verification';V.mkdir(exist_ok=True)
sys.path.insert(0,str(P/'stabilization_tools'))
from pipeline_reference import maps,pack_bundle,bundle_for,view_matrices,DATA
LINE=3200;SCAN=2750;MARGIN=12288;BASE_BAND=22000;BASE_JITTER=768
constants=(DATA/'pipeline_view_constants.vh').read_text()
assert pack_bundle(view_matrices())==int(re.search(r"PIPELINE_STATIC_BUNDLE 1728'h([0-9a-fA-F]+)",constants)[1],16),'Compiled view presets differ from the profile reference'
assert pack_bundle([bundle_for(0)[0]])==int(re.search(r"PIPELINE_STATIC_LOCAL0 288'h([0-9a-fA-F]+)",constants)[1],16),'Compiled fixed view zero differs from reference'
admission=(DATA.parent/'rtl/hdmi_scanout_admission.v').read_text()
assert int(re.search(r'SOURCE_LINE_CYCLES\s*=\s*(\d+)',admission)[1])==LINE,'Source service budget differs from proof'

def prove(req,band_cycles,scan_rows,offset):
 n=len(req);j,b=np.indices((n,n));span=(b-j+1)*band_cycles
 deadline=offset*SCAN+b*scan_rows*SCAN-MARGIN
 threshold=req[:,None]-np.floor_divide(deadline-span,LINE)
 threshold=np.where(b>=j,threshold,-9999)
 limits=[]
 for p in range(n):
  if np.any((np.arange(p,n)-p+1)*band_cycles>offset*SCAN+np.arange(p,n)*scan_rows*SCAN-MARGIN):limits.append(1023)
  else:limits.append(max(0,int(threshold[p:,:].max())))
 valid=[i for i,l in enumerate(limits) if l<=720]
 if not valid:return None
 first=min(valid);lead=max(limits[first:])
 # Check every future band for every admitted prefix with a max-plus recurrence.
 worst=10**15
 for p in range(first,n):
  t=0
  for k in range(p,n):
   t=max(t,max(0,int(req[k])-lead)*LINE)+band_cycles
   slack=offset*SCAN+k*scan_rows*SCAN-MARGIN-t
   assert slack>=0,(p,k,slack)
   worst=min(worst,slack)
 return dict(lead=lead,prefix=first*8,minimum_slack_cycles=worst,source_budget=LINE,band_budget=band_cycles,limits=limits)

raw_lead=(720*LINE-719*SCAN+MARGIN+LINE-1)//LINE
split_lead=(720*LINE-539*SCAN+MARGIN+LINE-1)//LINE
profiles=[];header=['// Exact Q8 dependency upper envelopes and exhaustive future-scan proof.',f'`define HDMI_SOURCE_LINE_CYCLES {LINE}',f'`define HDMI_BASE_BAND_CYCLES {BASE_BAND}',f"`define HDMI_RAW_LEAD 11'd{raw_lead}",f"`define HDMI_SPLIT_RAW_LEAD 11'd{split_lead}"]
for view in range(8):
 x,y,_,inside=maps(view,True);native=view<5 or view==6
 sy=y[180:540,320:960] if native else y;valid=inside[180:540,320:960] if native else inside
 req=np.array([int(np.where(valid[i:i+8],(sy[i:i+8]>>8)+2,0).max()) for i in range(0,len(sy),8)])
 choices=[]
 for slope in range(129):
  intercept=max(0,int(np.max(req-(slope*np.arange(len(req))//8))))
  bound=np.minimum(720,intercept+slope*np.arange(len(req))//8)
  assert np.all(bound>=req)
  # BASE starts at VS; its first active pixel is 25 raster lines later.
  # Spend only 20 of those lines, keeping five blank lines plus MARGIN for
  # read setup and CDC. All future band deadlines remain exhaustively checked.
  normal=prove(bound,BASE_BAND if view==7 else (12288 if native else 24576),8,20 if view==7 else 0) if not native else None
  compare=prove(bound,12288 if native else 24576,8 if native else 4,180)
  results=[r for r in [normal,compare] if r]
  if results:choices.append((sum(r['lead'] for r in results)+intercept/1000,slope,intercept,bound,normal,compare))
 _,slope,intercept,bound,normal,compare=min(choices,key=lambda c:c[0])
 profiles.append(dict(view=view,native=native,intercept=intercept,slope_eighths=slope,
  exact_required=req.tolist(),bound=bound.tolist(),normal=normal,compare=compare))
 print(json.dumps({k:v for k,v in profiles[-1].items() if k not in ['exact_required','bound'] and k not in ['normal','compare'] } | {k:({kk:vv for kk,vv in v.items() if kk!='limits'} if v else None) for k,v in [('normal',normal),('compare',compare)]}),flush=True)

fallback=prove(np.array(profiles[7]['bound']),24576,8,0)
assert fallback is not None
assert fallback['minimum_slack_cycles']>=BASE_JITTER
# A shared, nonrenewable allowance adds at most BASE_JITTER to every path in
# the max-plus recurrence. Keep all original source/service/fetch bounds.
elastic_proof=dict(scope='All admitted BASE7 conservative prefixes and future bands; total source plus service excess over the whole frame',
    allowance_cycles=BASE_JITTER,original_residual_slack_cycles=fallback['minimum_slack_cycles'],
    residual_slack_cycles=fallback['minimum_slack_cycles']-BASE_JITTER,
    fetch_margin_cycles=MARGIN,source_line_cycles=LINE,band_cycles=24576,
    lead_rows=fallback['lead'],prefix_rows=fallback['prefix'])
(V/'hdmi_jitter_proof.json').write_text(json.dumps(elastic_proof,indent=2))
# Use the proven conservative envelope to select an output epoch independently
# of bank-retirement waits. Read admission remains guarded by the real producer.
prefix_cycles=0
for required in profiles[7]['bound'][:fallback['prefix']//8]:
 prefix_cycles=max(prefix_cycles,int(required)*LINE)+24576
prefix_cycles=max(prefix_cycles,fallback['lead']*LINE)
source_blank_pixels=25*1650+260
phase_pixels=(prefix_cycles*3+4)//5+source_blank_pixels+13200
# FAST runs only with output following the recovered HDMI pixel clock.
# Epoch placement uses the actual 1650 pixel clocks/line. SOURCE_LINE_CYCLES
# remains 3200 in the admission/deadline proof: it is a worst-case service
# bound, not the duration of a physical HDMI raster line. Applying it here
# accumulated an unnecessary per-row delay. The fallback retains 8 guard lines.
# FAST admission checks the real committed prefix on every frame boundary.
# Its unchanged max-plus proof spends only 20 of the 25 output blank lines,
# and separately retains the 12288-cycle fetch margin and shared768 jitter.
# Additional epoch padding covers that entire jitter plus 256 core cycles
# for the bounded metadata/CDC publication path, rounded up to 64 pixels.
# This epoch is a target only: late/failed sources cannot bypass admission.
metadata_guard_cycles=256
fast_guard_pixels=((((BASE_JITTER+metadata_guard_cycles)*3+4)//5+63)//64)*64
assert fast_guard_pixels==640
fast_phase_pixels=profiles[7]['normal']['lead']*1650+source_blank_pixels+fast_guard_pixels
assert profiles[7]['normal']['minimum_slack_cycles']>=BASE_JITTER
phase_header=('// Generated from the BASE7 conservative dependency/service envelope.\n'
 f'`define HDMI_BASE_CERTIFIED_PHASE_PIXELS {phase_pixels}\n'
 f'`define HDMI_BASE_FAST_PHASE_PIXELS {fast_phase_pixels}\n')
if '--check' in sys.argv:assert (DATA/'hdmi_scanout_phase.vh').read_text()==phase_header,'Stale HDMI phase profile'
else:(DATA/'hdmi_scanout_phase.vh').write_text(phase_header,encoding='ascii')
(V/'hdmi_phase_budget.json').write_text(json.dumps(dict(scope='Scheduling target only; actual guarded admission is still required',prefix_cycles=prefix_cycles,source_blank_pixels=source_blank_pixels,guard_pixels=13200,fast_guard_pixels=fast_guard_pixels,metadata_guard_cycles=metadata_guard_cycles,phase_pixels=phase_pixels,nominal_phase_ms=phase_pixels/74250,fast_phase_pixels=fast_phase_pixels,fast_epoch_line_pixels=1650,fast_epoch_uses_recovered_pixel_clock=True,admission_source_budget_unchanged=True,fast_nominal_phase_ms=fast_phase_pixels/74250,fast=profiles[7]['normal'],conservative=fallback),indent=2))
header += [f"`define HDMI_BASE_FALLBACK_LEAD 11'd{fallback['lead']}",f"`define HDMI_BASE_FALLBACK_PREFIX 11'd{fallback['prefix']}",f"`define HDMI_BASE_JITTER_CYCLES 10'd{BASE_JITTER}"]
header+=['function [10:0] hdmi_band_source_rows;',' input [2:0] view;input [6:0] band;',' reg [17:0] amount;',' begin case(view)']
for p in profiles:
 header.append(f" 3'd{p['view']}:amount=18'd{p['intercept']}+(({{11'd0,band}}*18'd{p['slope_eighths']})>>3);")
header+=[' default:amount=720;',' endcase',' hdmi_band_source_rows=amount>720?720:amount[10:0];',' end','endfunction']
for field in ['lead','prefix']:
 header += [f'function [10:0] hdmi_minimum_{field};',' input [2:0] view;input compare_mode;',' begin case({compare_mode,view})']
 for p in profiles:
  for c,name in [(0,'normal'),(1,'compare')]:
   value=p[name][field] if p[name] else 1023
   header.append(f" 4'd{c*8+p['view']}:hdmi_minimum_{field}=11'd{value};")
 header += [f" default:hdmi_minimum_{field}=11'd1023;",' endcase end','endfunction']
generated='\n'.join(header)+'\n'
if '--check' in sys.argv:assert (DATA/'hdmi_scanout_profile.vh').read_text()==generated,'Stale HDMI dependency profile; regenerate before compilation'
else:(DATA/'hdmi_scanout_profile.vh').write_text(generated,encoding='ascii')
inputs=['pipeline_view_constants.vh','baseline_config.json','balanced_config.json','stabilization_gain_even.mem','stabilization_gain_odd.mem','stabilization_gain_last.mem','stabilization_far_even.mem','stabilization_far_odd.mem','stabilization_reciprocal.mem']
(V/'hdmi_envelope_proof.json').write_text(json.dumps(dict(scope='all exact static Q8 pixels; per-band source/producer budgets and all future scan deadlines',source_line_budget=LINE,scan_line_budget=SCAN,fetch_margin=MARGIN,profile_sha256=hashlib.sha256((DATA/'hdmi_scanout_profile.vh').read_bytes()).hexdigest(),input_sha256={name:hashlib.sha256((DATA/name).read_bytes()).hexdigest() for name in inputs},profiles=profiles),indent=2),encoding='utf-8')
