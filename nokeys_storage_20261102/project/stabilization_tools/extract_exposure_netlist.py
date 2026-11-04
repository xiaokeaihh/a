"""Extract the actual sensor configuration ROM from full-design synthesis."""
from pathlib import Path
import re,json
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'synthesize/hdmi_ddr_ov5640_top_syn.vm').read_text()
module=re.search(r'^module reg_config\b[\s\S]*?^endmodule\b',source,re.M)
if not module:raise RuntimeError('Synthesized camera configuration missing')
cell=re.search(r'GTP_DRM18K_E1 /\* reg_data \*/ #[\s\S]*?\n\s*reg_data \([\s\S]*?\);',module.group())
if not cell:raise RuntimeError('Synthesized camera configuration ROM missing')
text=cell.group().replace('(N1246)',"(1'b1)")
floating=sorted(set(re.findall(r'\\(reg_data_\S+)\s',text)))
wrapper='module camera_config_rom_net(input clock_20k,input [8:0] reg_index,output [31:0] i2c_data);\n'
wrapper+=''.join('wire \\'+name+' ;\n' for name in floating)+text+'\nendmodule\n'
out=ROOT/'verification_stabilization/actual_exposure_rom.v';out.write_text(wrapper)
folder=Path('D:/fpgapango/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation')
visited=set()
def dependencies(path):
    if path in visited:return
    visited.add(path)
    for name in set(re.findall(r'\b((?:GTP|INT)_\w+)\b',path.read_text(errors='replace'))):
        candidate=folder/(name+'.v')
        if candidate.exists():dependencies(candidate)
for name in ['GTP_DRM18K_E1','GTP_GRS']:dependencies(folder/(name+'.v'))
(ROOT/'verification_stabilization/exposure_net_cells.json').write_text(json.dumps([str(p) for p in sorted(visited)]))
print('Extracted actual synthesized sensor ROM with unchanged initialization parameters')
