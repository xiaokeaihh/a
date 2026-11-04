"""Reproducible native-720p references and engineering image measurements.

Measurements are not a certified ISO 12233 implementation. Capture and gamma
assumptions are recorded. No input image is resized silently.
"""
from pathlib import Path
import argparse, csv, hashlib, json, math, sys, time, subprocess
import cv2
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'source/design_fisheye_5frame_720p60_pipeline/data'
sys.path.insert(0,str(ROOT/'fusion_tools'))
from fixed_model import pattern_pixels, pack_rgb, unpack_rgb
sys.path.insert(0,str(ROOT/'stabilization_tools'))
from pipeline_reference import maps as pipeline_maps, bilinear, bundle_for, pack_bundle

def save_json(path,value):
    Path(path).write_text(json.dumps(value,indent=2,ensure_ascii=False,allow_nan=False),encoding='utf-8')

def load_image(path):
    a=cv2.imdecode(np.fromfile(path,np.uint8),cv2.IMREAD_COLOR)
    if a is None:raise ValueError(f'Cannot decode {path}')
    if a.shape[:2]!=(720,1280):raise ValueError(f'Expected native 1280x720; got {a.shape[1]}x{a.shape[0]}. No automatic resize is permitted.')
    return a

def write_image(path,a):
    ext=Path(path).suffix or '.png';ok,b=cv2.imencode(ext,a)
    if not ok:raise ValueError('Image encoding failed')
    b.tofile(path)

def to565(bgr):
    c=bgr.astype(np.uint16)
    return ((c[...,2]>>3)<<11)|((c[...,1]>>2)<<5)|(c[...,0]>>3)

def from565(p):
    return np.stack([(p&31)<<3,((p>>5)&63)<<2,(p>>11)<<3],axis=-1).astype(np.uint8)

def input_pattern():
    y,x=np.indices((720,1280));return pattern_pixels(x,y).astype(np.uint16)

def read_maps(view):
    return pipeline_maps(view,True)

def analytic_maps(view):
    return pipeline_maps(view,False)[:3]

def sample_image(source,sx,sy,blend,valid,fixed):
    return bilinear(source,sx,sy,valid,fixed)

def references(args):
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    if args.pattern:source=input_pattern();source_hash=hashlib.sha256(source.astype('<u2').tobytes()).hexdigest()
    else:
        image=load_image(args.input);source=to565(image);source=source[::-1].copy() if args.input_orientation=='hdmi' else source;source_hash=hashlib.sha256(Path(args.input).read_bytes()).hexdigest()
    sx,sy,bl,valid=read_maps(args.view)
    ax,ay,ab=analytic_maps(args.view)
    fixed=sample_image(source,sx,sy,bl,valid,True);floating=sample_image(source,ax,ay,ab,valid,False)
    write_image(out/'raw_camera_rows.png',from565(source));write_image(out/'raw_hdmi.png',from565(source[::-1]))
    write_image(out/'fixed_expected_hdmi.png',from565(fixed[::-1]));write_image(out/'float_reference_hdmi.png',from565(floating[::-1]))
    np.save(out/'fixed_expected_camera_rows.npy',fixed)
    coordinate_error=np.hypot(sx/256-ax,sy/256-ay);error=np.abs(from565(fixed).astype(float)-from565(floating).astype(float))
    heat=np.clip(coordinate_error/.05*255,0,255).astype(np.uint8);write_image(out/'coordinate_error_heatmap.png',cv2.applyColorMap(heat[::-1],cv2.COLORMAP_TURBO))
    result=dict(view=args.view,input_pattern=args.pattern,input_sha256=source_hash,output_size=[1280,720],source_quantization='RGB565 before both reference paths',
      coordinate_max_px=float(coordinate_error[valid].max()),coordinate_rms_px=float(np.sqrt(np.mean(coordinate_error[valid]**2))),
      float_vs_fixed_RGB888_MAE=float(error[valid].mean()),interpolation='unified bilinear, double-precision weights versus Q8 integer hardware weights',
      HDMI_vertical_flip=True,real_camera_MTF_measured=False)
    save_json(out/'reference_report.json',result);print(json.dumps(result,ensure_ascii=False))

def decode_dump(path):
    lines=Path(path).read_text(encoding='ascii').splitlines()
    native=len(lines)==14400
    width,height=(640,360) if native else (1280,720)
    out=np.zeros((height,width),np.uint16);written=np.zeros((height,width),bool)
    for line in lines:
        address,data=line.split();start=(int(address,16)-0x180000)*2;y,x=divmod(start,width)
        if not (0<=y<height and x%16==0 and x+16<=width) or written[y,x:x+16].any():raise ValueError('Invalid or repeated DDR output address')
        value=int(data,16);out[y,x:x+16]=[(value>>(16*j))&65535 for j in range(16)];written[y,x:x+16]=True
    if not written.all():raise ValueError('Incomplete frame dump')
    if native:
        padded=np.zeros((720,1280),np.uint16);padded[180:540,320:960]=out;return padded
    return out


def compare(args):
    expected=load_image(args.expected);out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    if args.dump:actual=from565(decode_dump(args.dump)[::-1]);chain='DDR RGB565 dump, bit-exact comparison available'
    else:actual=load_image(args.actual);chain='HDMI capture; capture-card colorspace/conversion also contributes to error'
    delta=actual.astype(float)-expected.astype(float);per=np.mean(np.abs(delta),axis=-1);mse=float(np.mean(delta*delta));psnr=None if mse==0 else float(10*np.log10(255**2/mse))
    result=dict(size=[1280,720],mismatched_pixels=int(np.any(actual!=expected,axis=-1).sum()),MAE_RGB=float(per.mean()),max_channel_error=float(np.abs(delta).max()),PSNR_dB=psnr,comparison_chain=chain,
      warning='PNG from an HDMI capture card is not a raw DDR dump; a difference alone cannot locate an RTL error.')
    write_image(out/'actual.png',actual);write_image(out/'pixel_error_heatmap.png',cv2.applyColorMap(np.clip(per*8,0,255).astype(np.uint8),cv2.COLORMAP_TURBO));save_json(out/'comparison.json',result);print(json.dumps(result,ensure_ascii=False))

def gray_image(bgr,linearize):
    a=bgr.astype(float)/255
    if linearize=='srgb':a=np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)
    return a[...,2]*.2126+a[...,1]*.7152+a[...,0]*.0722

def crossing(f,v,target):
    ids=np.where((v[:-1]>=target)&(v[1:]<target))[0]
    if len(ids)==0:return None
    i=ids[0];return float(f[i]+(f[i+1]-f[i])*(v[i]-target)/(v[i]-v[i+1]))

def slanted_edge(roi):
    if min(roi.shape)<40:raise ValueError('SFR ROI should be at least 40x40, preferably 100x100 or larger')
    gx=np.gradient(roi,axis=1);gy=np.gradient(roi,axis=0);transposed=np.mean(np.abs(gy))>np.mean(np.abs(gx))
    a=roi.T if transposed else roi;h,w=a.shape
    blur=cv2.GaussianBlur(a,(0,0),.6);grad=np.gradient(blur,axis=1);centers=[];rows=[]
    for y in range(4,h-4):
        weights=np.abs(grad[y]);peak=int(weights.argmax())
        if peak<8 or peak>=w-8:continue
        lo,hi=peak-6,peak+7;ww=weights[lo:hi]
        if ww.sum()<.01:continue
        centers.append(float(np.dot(np.arange(lo,hi),ww)/ww.sum()));rows.append(y)
    if len(rows)<h*.6:raise ValueError('Cannot trace a single complete slanted edge; choose an ROI containing exactly one edge')
    rows=np.array(rows);centers=np.array(centers);coef=np.polyfit(rows,centers,1);res=centers-np.polyval(coef,rows)
    keep=np.abs(res)<=max(.25,3*np.median(np.abs(res-np.median(res))))
    coef=np.polyfit(rows[keep],centers[keep],1);slope,offset=coef;angle=abs(np.rad2deg(np.arctan(slope)))
    if angle<1 or angle>12:raise ValueError(f'Edge angle {angle:.2f} degrees is unsuitable. Use approximately 2..7 degrees from horizontal/vertical.')
    yy,xx=np.indices(a.shape);distance=(xx-slope*yy-offset)/np.sqrt(1+slope*slope)
    step=.25;radius=min(24,(w-12)/2);bins=np.floor((distance+radius)/step).astype(int);n=int(2*radius/step)
    sel=(bins>=0)&(bins<n)&(yy>=4)&(yy<h-4)
    count=np.bincount(bins[sel],minlength=n);total=np.bincount(bins[sel],weights=a[sel],minlength=n)
    if np.count_nonzero(count)<n*.9:raise ValueError('Insufficient slanted-edge phase coverage')
    esf=np.divide(total,count,out=np.zeros(n),where=count!=0);good=np.flatnonzero(count);esf=np.interp(np.arange(n),good,esf[good])
    lo,hi=float(esf[:12].mean()),float(esf[-12:].mean())
    if abs(hi-lo)<.05:raise ValueError('Edge contrast is too low')
    esf=(esf-lo)/(hi-lo);lsf=np.gradient(esf,step);lsf*=np.hamming(n)
    size=2048;f=np.fft.rfftfreq(size,step);mtf=np.abs(np.fft.rfft(lsf,size));mtf/=mtf[0]
    # Compensate the known central-difference frequency response.
    z=2*np.pi*step*f;corr=np.divide(z,np.sin(z),out=np.ones_like(z),where=np.abs(np.sin(z))>1e-12);mtf*=np.clip(corr,1,10)
    select=f<=.5;f=f[select];mtf=mtf[select];peak=float(mtf.max())
    result=dict(MTF50_cycles_per_pixel=crossing(f,mtf,.5),MTF50P_cycles_per_pixel=crossing(f,mtf,peak/2),
      MTF_at_Nyquist=float(mtf[-1]),MTF_peak=peak,edge_angle_deg=float(angle),
      edge_fit_RMS_px=float(np.sqrt(np.mean((centers[keep]-np.polyval(coef,rows[keep]))**2))),
      overshoot_percent=float(max(0,esf.max()-1)*100),undershoot_percent=float(max(0,-esf.min())*100),orientation='horizontal edge' if transposed else 'vertical edge',
      edge_normal_image=([-slope,1.] if transposed else [1.,-slope]))
    return result,f,mtf,esf

def straight_line(roi,orientation='vertical'):
    a=roi.T if orientation=='horizontal' else roi;h,w=a.shape;points=[]
    for y in range(3,h-3):
        profile=a[y];base=float(np.percentile(profile,85));dark=np.maximum(0,base-profile)
        peak=int(dark.argmax());lo=max(0,peak-6);hi=min(w,peak+7);weights=dark[lo:hi]
        if weights.max()<.04 or base-float(profile.min())<.02:continue
        weights=np.maximum(0,weights-.15*weights.max())
        if weights.sum()>.01:points.append([np.dot(np.arange(lo,hi),weights)/weights.sum(),y])
    if len(points)<h*.5:raise ValueError('Insufficient line points; select a narrow ROI containing one line and avoid intersections')
    points=np.array(points);center=points.mean(axis=0);_,_,vh=np.linalg.svd(points-center,full_matrices=False);normal=vh[-1];res=(points-center)@normal
    along=(points-center)@vh[0];length=float(along.max()-along.min());rms=float(np.sqrt(np.mean(res**2)));maximum=float(np.abs(res).max())
    return dict(RMS_px=rms,max_deviation_px=maximum,line_length_px=length,RMS_per_1000_line_length=rms/length*1000,max_per_1000_line_length=maximum/length*1000,points=len(points)),points,res

def select_rois(args):
    image=load_image(args.input);records=[]
    for i in range(args.count):
        rect=cv2.selectROI(f'{args.kind}: ROI {i+1}; ENTER accept, ESC finish',image,False,False);cv2.destroyAllWindows()
        if rect[2]==0 or rect[3]==0:break
        records.append(dict(name=f'{args.kind}_{i+1}',rect=list(map(int,rect)),kind=args.kind,orientation=args.orientation))
    save_json(args.out,dict(image_size=[1280,720],regions=records));print(args.out)

def measure(args):
    image=load_image(args.input);gray=gray_image(image,args.linearize);cfg=json.loads(Path(args.rois).read_text(encoding='utf-8-sig'));out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    overlay=image.copy();results=[]
    for i,r in enumerate(cfg['regions']):
        name=r['name'];x,y,w,h=map(int,r['rect']);record=dict(name=name,kind=r['kind'],rect=[x,y,w,h])
        if not(0<=x and 0<=y and w>0 and h>0 and x+w<=1280 and y+h<=720):raise ValueError('ROI outside image')
        roi=gray[y:y+h,x:x+w]
        try:
            if r['kind']=='mtf':
                values,f,m,esf=slanted_edge(roi);record.update(values)
                # Local great-circle angular sampling of the virtual pinhole.
                # HDMI reverses the original DDR Y coordinate; rotations preserve
                # the angle between rays. This does not invent optical detail.
                cfg=json.loads((DATA/'baseline_config.json').read_text(encoding='utf-8'))
                balanced=json.loads((DATA/'balanced_config.json').read_text(encoding='utf-8')) if (DATA/'balanced_config.json').exists() else None
                if args.view==7:P=np.array(cfg['output_K'])
                elif balanced:
                    from balanced_geometry import matrix
                    configs=[balanced['fixed_view0']]+[c['config'] for c in balanced['quadrants']]
                    vlocal=(1 if y<360 else 3)+(1 if x>=640 else 0) if args.view==5 else args.view
                    P=matrix(balanced['central_full']['config'] if vlocal==6 else configs[vlocal])
                elif args.view==6:P=np.array(cfg['source_K'])
                else:P=np.array(json.loads((ROOT/'verification_quality/geometry_report.json').read_text(encoding='utf-8'))['output_K'])
                u,v=x+(w-1)/2,719-(y+(h-1)/2)
                normal=np.array(values['edge_normal_image'],float);normal/=np.linalg.norm(normal);normal[1]*=-1
                if balanced and (args.view<5 or args.view==6):
                    origin=640 if args.layout=='compare' else 320
                    if x<origin or x+w>origin+640 or y<180 or y+h>540:raise ValueError('SFR ROI must lie inside the corrected native pane')
                    u=2*(u-origin);v=2*(v-180);normal*=2
                if args.view==5:
                    if x//640!=(x+w-1)//640 or y//360!=(y+h-1)//360:raise ValueError('SFR ROI crosses a four-view seam')
                    u=2*(u%640);v=2*(v%360);normal*=2
                ray=np.array([(u-P[0,2])/P[0,0],(v-P[1,2])/P[1,1],1.]);norm=np.linalg.norm(ray);unit=ray/norm
                differential=np.array([normal[0]/P[0,0],normal[1]/P[1,1],0.]);angular=np.linalg.norm((differential-unit*np.dot(unit,differential))/norm)*180/np.pi
                record['local_degrees_per_output_pixel']=float(angular)
                record['MTF50_cycles_per_degree']=None if values['MTF50_cycles_per_pixel'] is None else float(values['MTF50_cycles_per_pixel']/angular)
                fig,ax=plt.subplots(1,2,figsize=(9,3));ax[0].plot(np.arange(len(esf))*.25,esf);ax[0].set(title='Edge response',xlabel='Distance (pixel)');ax[1].plot(f,m);ax[1].axhline(.5,color='gray',ls='--');ax[1].set(title='SFR',xlabel='Cycles / pixel',ylim=(0,max(1.1,float(m.max())*1.1)));fig.tight_layout();fig.savefig(out/f'roi_{i+1}_sfr.png',dpi=160);plt.close(fig)
                if values['edge_fit_RMS_px']>.3:record['warning']='Edge is curved/noisy; this ROI may not be suitable for slanted-edge SFR'
            else:
                values,points,res=straight_line(roi,r.get('orientation','vertical'));record.update(values)
                fig,ax=plt.subplots(figsize=(6,3));ax.plot(points[:,1],res);ax.set(title='Line deviation',xlabel='Position along selected line (pixel)',ylabel='Perpendicular error (pixel)');fig.tight_layout();fig.savefig(out/f'roi_{i+1}_line.png',dpi=160);plt.close(fig)
            record['status']='measured'
        except ValueError as e:record.update(status='rejected',reason=str(e))
        cv2.rectangle(overlay,(x,y),(x+w-1,y+h-1),(0,255,0) if record['status']=='measured' else (0,0,255),2);cv2.putText(overlay,str(i+1),(x+3,y+18),cv2.FONT_HERSHEY_SIMPLEX,.5,(0,255,255),1)
        results.append(record)
    write_image(out/'regions.png',overlay)
    save_json(out/'measurement.json',dict(input=str(Path(args.input).resolve()),input_sha256=hashlib.sha256(Path(args.input).read_bytes()).hexdigest(),size=[1280,720],linearization=args.linearize,
      view=args.view,baseline_config_sha256=hashlib.sha256((DATA/'baseline_config.json').read_bytes()).hexdigest(),source_calibration_sha256=hashlib.sha256((DATA/'calibration_720p.json').read_bytes()).hexdigest(),
      method='Engineering 4x oversampled slanted-edge check and subpixel dark-line fit; not a certified ISO 12233 implementation',
      scale_warning='Do not compare different FOV, display resize or card positions as equal conditions. cycles/pixel is output-scale dependent.',regions=results))
    fields=sorted(set(k for r in results for k in r if k!='rect'))
    with (out/'results.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fields);writer.writeheader();writer.writerows([{k:v for k,v in r.items() if k!='rect'} for r in results])
    print(json.dumps(results,ensure_ascii=False))

def capture(args):
    cap=cv2.VideoCapture(args.device,cv2.CAP_DSHOW if sys.platform=='win32' else cv2.CAP_ANY);cap.set(cv2.CAP_PROP_FRAME_WIDTH,1280);cap.set(cv2.CAP_PROP_FRAME_HEIGHT,720);cap.set(cv2.CAP_PROP_FPS,60)
    if not cap.isOpened():raise ValueError('Cannot open capture card')
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True);settings={k:cap.get(v) for k,v in [('width',3),('height',4),('fps',5),('FOURCC',6)]};start=time.time();saved=[]
    try:
        while len(saved)<args.frames:
            ok,image=cap.read()
            if not ok:raise ValueError('Capture read failed')
            if image.shape[:2]!=(720,1280):raise ValueError(f'Capture card returned {image.shape[1]}x{image.shape[0]}; no resizing is performed')
            cv2.imshow('Native 720p - SPACE save / ESC exit',image);key=cv2.waitKey(1)&255
            if key==27:break
            if key==32 and time.time()-start>2:
                name=f'capture_{len(saved)+1:03d}.png';write_image(out/name,image);saved.append(dict(file=name,time_unix=time.time()))
    finally:cap.release();cv2.destroyAllWindows()
    save_json(out/'capture_metadata.json',dict(settings=settings,frames=saved,post_resize=False,warning='PNG saves are lossless; the HDMI capture device may already convert colors or subsample chroma.'))

def simulate(args):
    out=Path(args.out);out.mkdir(parents=True,exist_ok=True)
    image=load_image(args.input);source=to565(image)
    if args.input_orientation=='hdmi':source=source[::-1].copy()
    trial=ROOT/'verification_quality/image_trial';trial.mkdir(parents=True,exist_ok=True)
    (trial/'input_frame.mem').write_text(''.join(f'{int(v):04x}\n' for v in source.ravel()),encoding='ascii')
    h=bundle_for(args.view);(trial/'bundle.mem').write_text(f'{pack_bundle(h):0432x}\n',encoding='ascii')
    sx,sy,_,valid=read_maps(args.view);expected=sample_image(source,sx,sy,None,valid,True)
    (trial/'gold.mem').write_text(''.join(f'{int(v):04x}\n' for v in expected.ravel()),encoding='ascii')
    sim=Path(args.modelsim);lib=ROOT/'verification_quality/image_pipeline_work'
    rtl=ROOT/'source/design_fisheye_5frame_720p60_pipeline/rtl'
    names=['stabilized_projection','bilinear_rgb565','pipeline_renderer','pipeline_prefetch','pipeline_source_cache','pipeline_stripe_writer']
    def run(exe,arguments,log):
        process=subprocess.run([str(sim/exe),*arguments],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,errors='replace',creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        (out/log).write_text(process.stdout,encoding='utf-8')
        if process.returncode:raise RuntimeError(f'{exe} failed; see {out/log}')
        return process.stdout
    if not lib.exists():run('vlib.exe',[str(lib)],'vlib.log')
    run('vlog.exe',['-sv','-work',str(lib),*[str(rtl/(n+'.v')) for n in names],str(ROOT/'ipcore/wr_fram_buf/rtl/ipm2l_sdpram_v1_10_wr_fram_buf.v'),*[str(Path(r'D:/fpgapango/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation')/n) for n in ['GTP_DRM18K.v','GTP_DRM36K_E1.v','GTP_GRS.v']],str(ROOT/'verification_pipeline/tb_pipeline_image.sv')],'compile.log')
    text=run('vsim.exe',['-c','-lib',str(lib),'tb_pipeline_image',f'-gVIEW={args.view}','-do','run -all; quit -f'],'simulation.log')
    if '# PASS ' not in text or '** Fatal:' in text or '# Errors: 0, Warnings: 0' not in text:raise RuntimeError('RTL image simulation did not pass')
    references(argparse.Namespace(input=args.input,pattern=False,input_orientation=args.input_orientation,view=args.view,out=str(out/'reference')))
    dump=trial/f'frame_{args.view}.txt';compare(argparse.Namespace(expected=str(out/'reference/fixed_expected_hdmi.png'),dump=str(dump),actual=None,out=str(out/'RTL_comparison')))
    result=json.loads((out/'RTL_comparison/comparison.json').read_text(encoding='utf-8'))
    if result['mismatched_pixels']:raise RuntimeError('RTL pixels differ from the integer reference')
    print('PASS same input image through RTL DDR/cache/interpolation simulation; not a physical-board image upload')

def main():
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='command',required=True)
    s=sub.add_parser('reference');s.add_argument('--input');s.add_argument('--pattern',action='store_true');s.add_argument('--input-orientation',choices=['hdmi','camera'],default='hdmi');s.add_argument('--view',type=int,choices=range(8),default=7);s.add_argument('--out',required=True);s.set_defaults(run=references)
    s=sub.add_parser('compare');s.add_argument('--expected',required=True);s.add_argument('--actual');s.add_argument('--dump');s.add_argument('--out',required=True);s.set_defaults(run=compare)
    s=sub.add_parser('select');s.add_argument('--input',required=True);s.add_argument('--kind',choices=['mtf','line'],required=True);s.add_argument('--orientation',choices=['vertical','horizontal'],default='vertical');s.add_argument('--count',type=int,default=9);s.add_argument('--out',required=True);s.set_defaults(run=select_rois)
    s=sub.add_parser('measure');s.add_argument('--layout',choices=['padded','compare'],default='padded');s.add_argument('--input',required=True);s.add_argument('--rois',required=True);s.add_argument('--view',type=int,choices=range(8),default=7);s.add_argument('--linearize',choices=['none','srgb'],default='none');s.add_argument('--out',required=True);s.set_defaults(run=measure)
    s=sub.add_parser('capture');s.add_argument('--device',type=int,default=0);s.add_argument('--frames',type=int,default=9);s.add_argument('--out',required=True);s.set_defaults(run=capture)
    s=sub.add_parser('simulate');s.add_argument('--input',required=True);s.add_argument('--input-orientation',choices=['hdmi','camera'],default='hdmi');s.add_argument('--view',type=int,choices=range(8),default=7);s.add_argument('--modelsim',default=r'C:\intelFPGA\18.1\modelsim_ase\win32aloem');s.add_argument('--out',required=True);s.set_defaults(run=simulate)
    a=p.parse_args()
    if a.command=='reference' and not a.pattern and not a.input:p.error('reference requires --input or --pattern')
    if a.command=='compare' and bool(a.actual)==bool(a.dump):p.error('compare requires exactly one of --actual, --dump')
    a.run(a)

if __name__=='__main__':main()
