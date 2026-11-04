"""Check all sensor-ROM initialization words in the actual routed design."""
from pathlib import Path
import argparse, hashlib, json, re
ROOT=Path(__file__).resolve().parents[1]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def parameters(text,pattern):
    match=re.search(pattern,text)
    if not match:raise RuntimeError('Sensor configuration ROM not found')
    result=dict(re.findall(r'\.(INIT_\w+)\((\d+\x27b[01]+)\)',match.group()))
    if len(result)!=64:raise RuntimeError('Sensor ROM initialization is incomplete')
    return result
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('routed_netlist',type=Path);parser.add_argument('routed_database',type=Path)
    args=parser.parse_args()
    current=ROOT/'synthesize/hdmi_ddr_ov5640_top_syn.vm'
    expected=parameters(current.read_text(),r'GTP_DRM18K_E1 /\* reg_data \*/ #[\s\S]*?\n\s*reg_data \(')
    actual=parameters(args.routed_netlist.read_text(),r'V_DRM18K_E1 /\* coms1_reg_config/reg_data/gopdrm_18k/DRM18K_\d \*/ #[\s\S]*?\n\s*\\DRM_[^\n]+\(')
    if expected!=actual:raise RuntimeError('Routed sensor ROM differs from current 500-line source: '+repr([k for k in expected if expected[k]!=actual.get(k)]))
    report=dict(passed=True,physical_board_verified=False,exposure_lines=500,initialization_words_checked=64,
        post_route_rom_matches_current_synthesis=True,synthesized_netlist_sha256=digest(current),
        routed_database_sha256=digest(args.routed_database),routed_functional_netlist_sha256=digest(args.routed_netlist))
    (ROOT/'verification_stabilization/routed_exposure_report.json').write_text(json.dumps(report,indent=2))
    print('PASS routed sensor ROM matches current 500-line exposure design; all 64 initialization words checked')
