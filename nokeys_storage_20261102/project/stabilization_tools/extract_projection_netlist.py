from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
import re,json
source=(ROOT/'synthesize/hdmi_ddr_ov5640_top_syn.vm').read_text()
chunks=[]
for name in ['stabilized_projection','stabilization_projection_rom']:
    m=re.search(r'^module '+name+r'\b[\s\S]*?^endmodule\b',source,re.M)
    if not m:raise RuntimeError(name+' missing in actual full-design synthesis')
    chunks.append(m.group())
s='\n\n'.join(chunks)
# Full-design synthesis renumbers this promoted parent enable when unrelated
# camera configuration constants change. Give the test a stable port name.
enable_ports=re.findall(r'^\s*input (_N131\d+)\s*,',chunks[0],re.M)
if len(enable_ports)!=1:raise RuntimeError('Unexpected promoted projection enable ports: '+repr(enable_ports))
s=re.sub(r'\b'+enable_ports[0]+r'\b','projection_enable',s)
for a,b in [('stabilization_projection_rom','stabilization_projection_rom_net'),('stabilized_projection','stabilized_projection_net')]:
    s=re.sub(r'\b'+a+r'\b',b,s)
for name,new in [('u_fisheye_video_path/u_renderer/dynamic_renderer/N378','frame_pose_unregistered'),
                 ('u_fisheye_video_path/u_renderer/dynamic_renderer/N268_1','pipeline_reset'),
                 ('u_fisheye_video_path/u_renderer/dynamic_renderer/N1754','frame_latch'),
                 ('u_fisheye_video_path/u_renderer/dynamic_renderer/single_view_inv','single_view_inv')]:
    s=s.replace('\\'+name+' ',new+' ')
(ROOT/'verification_stabilization/actual_projection_net.v').write_text(s)
cells=sorted(set(re.findall(r'^\s*(GTP_\w+)\b',s,re.M)))
folder=Path('D:/fpgapango/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation')
files=[folder/(c+'.v') for c in cells]+[folder/'GTP_GRS.v',folder/'INT_LUTMUX2_UDP.v',folder/'INT_LUTMUX4_UDP.v']
assert all(p.exists() for p in files)
visited=set()
def add_dependencies(p):
    if p in visited:return
    visited.add(p)
    for name in set(re.findall(r'\b((?:GTP|INT)_\w+)\b',p.read_text(errors='replace'))):
        dependency=folder/(name+'.v')
        if dependency.exists():add_dependencies(dependency)
for p in files:add_dependencies(p)
files=sorted(visited)
(ROOT/'verification_stabilization/netlist_cells.json').write_text(json.dumps([str(p) for p in files]))
for key in ['pipeline_reset','frame_latch']:
    matches=[line.strip() for line in s.splitlines() if key in line]
    print(key,matches[:12])
print('Extracted actual full-design projection and ROM,',len(cells),'vendor cell kinds')
vectors=(ROOT/'verification_stabilization/projection_vectors.txt').read_text().splitlines()
assert len(vectors)==5150
selected=[]
for base in [i*305 for i in range(10)]+[3050+i*105 for i in range(20)]:selected.extend(vectors[base:base+5])
(ROOT/'verification_stabilization/projection_net_vectors.txt').write_text('\n'.join(selected)+'\n')
