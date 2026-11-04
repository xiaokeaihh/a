"""Numerical ground-truth checks; no camera-quality results are fabricated."""
from pathlib import Path
import json,math
import numpy as np
from quality_lab import slanted_edge,straight_line,load_image,write_image

R=Path(__file__).resolve().parents[1]/'verification_quality';R.mkdir(exist_ok=True)
y,x=np.indices((220,180));sigma=1.8;distance=(x-90-.08*(y-110))/np.sqrt(1+.08**2)
roi=.25+.5*np.vectorize(lambda z:(1+math.erf(z/(sigma*np.sqrt(2))))/2)(distance)
v,f,m,e=slanted_edge(roi);expected=np.sqrt(np.log(2))/(np.sqrt(2)*np.pi*sigma)
assert abs(v['MTF50_cycles_per_pixel']/expected-1)<.05,(v,expected)
straight=.8-.6*np.exp(-(x-(90+.03*y))**2/(2*1.2**2));line,_,_=straight_line(straight)
assert line['RMS_px']<.03,line
curved=.8-.6*np.exp(-(x-(90+.03*y+2*np.sin(y/220*2*np.pi)))**2/(2*1.2**2));curve,_,_=straight_line(curved)
assert curve['RMS_px']>.5,curve
write_image(R/'wrong_size.png',np.zeros((360,640,3),np.uint8))
try:load_image(R/'wrong_size.png')
except ValueError:pass
else:raise AssertionError('Silent resizing was accepted')
report=dict(gaussian_sigma_px=sigma,analytic_MTF50=expected,measured=v,straight=line,curved=curve,wrong_size_rejected=True,real_camera_test=False)
(R/'measurement_numeric_test.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print('PASS analytic Gaussian MTF50, straight versus curved lines, and native-size guard')
