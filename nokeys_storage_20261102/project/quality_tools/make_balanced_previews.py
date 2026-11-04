"""Same-capture software previews. These are not FPGA captures or MTF evidence."""
from pathlib import Path
import sys,json
import numpy as np
import cv2
from PIL import Image,ImageDraw,ImageFont
from quality_lab import load_image,to565,from565
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'verification_quality'
PREVIOUS=Path(r'D:\fpgapango\wyc_no65_stage_20261009')
sys.path.insert(0,str(ROOT/'fusion_tools'))
from fixed_model import adaptive_pixels

raw=load_image(PREVIOUS/'verification_quality/calibration_RAW_720p.png')
source=to565(raw)[::-1]
def render_old(view):
    a=np.array([int(s,16) for s in (PREVIOUS/f'verification_quality/mapping_{view}.mem').read_text(encoding='ascii').split()],np.uint64).reshape(720,1280)
    sx=(a&0xfffff).astype(np.int64);sy=((a>>20)&0xfffff).astype(np.int64);b=((a>>40)&511).astype(np.int64);v=(a>>49)!=0
    ix,iy=sx>>8,sy>>8
    yy=iy[...,None,None]+np.arange(-1,3)[None,None,:,None]
    xx=ix[...,None,None]+np.arange(-1,3)[None,None,None,:]
    windows=source[np.clip(yy,0,719),np.clip(xx,0,1279)]
    result,_=adaptive_pixels(windows,sx&255,sy&255,b,v)
    return result[::-1]
def half(p):
    chans=[(p>>11)&31,(p>>5)&63,p&31];out=[]
    for c in chans:out.append((c[::2,::2].astype(np.uint16)+c[::2,1::2]+c[1::2,::2]+c[1::2,1::2]+2)//4)
    return (out[0]<<11)|(out[1]<<5)|out[2]
def compare(right):
    a=np.zeros((720,1280),np.uint16);a[180:540,:640]=half(to565(raw));a[180:540,640:]=right
    return from565(a)
old6=compare(half(render_old(6)))
new6img=load_image(OUT/'balanced_real_reference6/fixed_expected_hdmi.png')
new6=compare(to565(new6img[180:540,320:960]))
old5=from565(render_old(5));new5=load_image(OUT/'balanced_real_reference5/fixed_expected_hdmi.png')
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',25)
def pair(name,left,right,lt,rt):
    canvas=Image.new('RGB',(2560,780),(20,25,32));canvas.paste(Image.fromarray(cv2.cvtColor(left,cv2.COLOR_BGR2RGB)),(0,60));canvas.paste(Image.fromarray(cv2.cvtColor(right,cv2.COLOR_BGR2RGB)),(1280,60))
    draw=ImageDraw.Draw(canvas);draw.text((20,15),lt,font=font,fill='white');draw.text((1300,15),rt,font=font,fill='white');canvas.save(OUT/name)
pair('preview_quad_before_after.png',old5,new5,'旧四宫格：外围受到计算范围限制','新四宫格：同一标定原图的软件预览')
pair('preview_center_before_after.png',old6,new6,'旧整图对比：矫正后再缩小','新中部整图134°：直接生成对比右侧像素')
cv2.imencode('.png',new6)[1].tofile(OUT/'preview_center_compare.png')
(OUT/'preview_evidence.json').write_text(json.dumps(dict(source=str(PREVIOUS/'verification_quality/calibration_RAW_720p.png'),software_only=True,physical_board_capture=False,source_original_OBS_size=[1920,1080],source_native_conversion=[1280,720],source_K_D_changed=False,pixel_interpolation_changed=False),indent=2),encoding='utf-8')
print('Generated software-only same-capture previews')
