from projection_reference import ROOT,DATA,matrix,rotation,CFG,view_matrices
import numpy as np
import json
OUT=ROOT/'verification_stabilization'

def source(index):
    return ((index*251)^(index>>3)^0x5a96)&65535

def fixed_map(h,u=None,v=None):
    if u is None:v,u=np.indices((720,1280),dtype=np.int64)
    x=h[0,0]*u+h[0,1]*v+h[0,2];y=h[1,0]*u+h[1,1]*v+h[1,2];z=h[2,0]*u+h[2,1]*v+h[2,2]
    good=(z>=262144)&(z<67108864)
    e=np.full_like(z,-6)
    for bit in range(18,31):e=np.where((z&(1<<bit))!=0,bit-24,e)
    n=np.where(e>=0,z>>np.maximum(e,0),z<<np.maximum(-e,0))
    seeds=np.array([round((1<<24)/(1+(i+.5)/1024)) for i in range(1024)],np.int64)
    seed=seeds[(n>>14)&1023]
    inv=(seed*((1<<25)-((n*seed)>>24)))>>24
    inv=np.where(e>=0,inv>>np.maximum(e,0),inv<<np.maximum(-e,0))
    nx=(x*inv+(1<<31))>>32;ny=(y*inv+(1<<31))>>32
    good&=(abs(nx)<=4194304)&(abs(ny)<=4194304)
    # Emulate the signed 24-bit coordinate registers for invalid rays too.
    nx=((nx+(1<<23))&((1<<24)-1))-(1<<23);ny=((ny+(1<<23))&((1<<24)-1))-(1<<23)
    r2=nx*nx+ny*ny;radius_ok=r2<4096*(1<<32);good&=radius_ok
    far=radius_ok&(r2>=64*(1<<32))
    index=np.where(radius_ok,np.where(far,(r2>>32)-64,r2>>26),0);frac=np.where(far,r2>>24,r2>>18)&255
    words=np.array([int(s,16) for s in (DATA/'stabilization_gain_even.mem').read_text().splitlines()],np.int64)
    odd=np.array([int(s,16) for s in (DATA/'stabilization_gain_odd.mem').read_text().splitlines()],np.int64)
    last=int((DATA/'stabilization_gain_last.mem').read_text(),16)
    words=np.r_[words,last];odd=np.r_[odd,last]
    a=np.where(index&1,odd[index//2],words[index//2]);b=np.where(index&1,words[index//2+1],odd[index//2])
    fe=np.array([int(s,16) for s in (DATA/'stabilization_far_even.mem').read_text().splitlines()],np.int64)
    fo=np.array([int(s,16) for s in (DATA/'stabilization_far_odd.mem').read_text().splitlines()],np.int64)
    # Mask indexes before gathering; the near table's terminal node is separate.
    fi=np.where(far,index,0)
    fa=np.where(fi&1,fo[fi//2],fe[fi//2]);fb=np.where(fi&1,fe[fi//2+1],fo[fi//2])
    a=np.where(far,fa,a);b=np.where(far,fb,b)
    coords=[]
    for axis,q in enumerate([nx,ny]):
        ga=(a>>(axis*22))&((1<<22)-1);gb=(b>>(axis*22))&((1<<22)-1)
        g=ga+(((gb-ga)*frac+128)>>8)
        s=q*g+round(CFG['source_K'][axis][2]*(1<<28))+(1<<19)
        good&=(s>=0)&(s<([1279,719][axis]<<28));coords.append((s>>20)&((1<<20)-1))
    return *coords,good

def frame(h,u=None,v=None,canvas=None):
    x,y,good=fixed_map(h,u,v)
    if canvas is not None:good&=canvas
    ix=x>>8;iy=y>>8;fx=x&255;fy=y&255
    pixels=[source((iy+dy)*1280+ix+dx) for dy,dx in [(0,0),(0,1),(1,0),(1,1)]]
    channels=[]
    for shift,mask in [(11,31),(5,63),(0,31)]:
        a,b,c,d=[(p>>shift)&mask for p in pixels]
        value=((a*(256-fx)+b*fx)*(256-fy)+(c*(256-fx)+d*fx)*fy+32768)>>16
        channels.append(value<<shift)
    return np.where(good,channels[0]|channels[1]|channels[2],0)

if __name__=='__main__':
    cases=[(0,0,0,1),(90,0,0,1),(180,0,0,1),(45,20,-25,1),(0,85,0,1),(0,180,0,1),(25,0,0,.1)]
    hs=[]
    for i,angles in enumerate(cases):
        h=matrix(rotation(*angles[:3]),zoom=angles[3]);hs.append(sum((int(a)&0xffffffff)<<(32*j) for j,a in enumerate(h.flat)))
        image=frame(h)
        (OUT/f'stable_gold_{i}.mem').write_text(''.join(f'{int(p):04x}\n' for p in image.flat))
    (OUT/'frame_matrices.mem').write_text(''.join(f'{h:072x}\n' for h in hs))
    (OUT/'frame_cases.json').write_text(json.dumps(cases))
    print('Generated independent DDR pixel references for',len(cases),'full frames')
    bundles=[];metadata=[]
    # Include identity and rotation for every displayed corrected layout.
    for angle in [0,90]:
        hs=view_matrices(rotation(angle));packed=sum((int(a)&0xffffffff)<<(32*j) for j,a in enumerate(np.asarray(hs).ravel()))
        for view in [1,2,3,4,5,6,7]:
            v,u=np.indices((720,1280),dtype=np.int64)
            if view==7:image=frame(hs[0])
            elif view==5:
                image=np.zeros((720,1280),np.int64)
                for slot,ys,xs in [(3,slice(0,360),slice(0,640)),(4,slice(0,360),slice(640,1280)),(1,slice(360,720),slice(0,640)),(2,slice(360,720),slice(640,1280))]:
                    py,px=np.indices((360,640),dtype=np.int64);image[ys,xs]=frame(hs[slot],px,py)
            else:
                mask=(u>=320)&(u<960)&(v>=180)&(v<540)
                image=frame(hs[5 if view==6 else view],np.where(mask,u-320,0),np.where(mask,v-180,0),mask)
            case=len(bundles);bundles.append(packed);metadata.append({'case':case,'view':view,'roll':angle})
            (OUT/f'allviews_gold_{case}.mem').write_text(''.join(f'{int(p):04x}\n' for p in image.flat))
    (OUT/'allviews_bundles.mem').write_text(''.join(f'{h:0432x}\n' for h in bundles))
    (OUT/'allviews_cases.json').write_text(json.dumps(metadata,indent=2))
    print('Generated',len(bundles),'all-view DDR references')
