"""Camera-relative angles, R=Ry(yaw) Rx(pitch) Rz(roll); degrees."""
import math
import numpy as np
from attitude import rotation

def camera_angles(q,alignment,reference):
    if alignment is None or reference is None:return None
    relative=np.asarray(reference).T@rotation(q)@np.asarray(alignment).T
    pitch=math.asin(float(np.clip(-relative[1,2],-1,1)))
    singular=abs(math.cos(pitch))<1e-5
    yaw=math.atan2(relative[0,2],relative[2,2]) if not singular else math.atan2(-relative[2,0],relative[0,0])
    roll=math.atan2(relative[1,0],relative[1,1]) if not singular else 0.
    return dict(roll=round(math.degrees(roll),1),pitch=round(math.degrees(pitch),1),yaw=round(math.degrees(yaw),1),
                yaw_relative=True,singular=singular,convention='camera-relative Ry(yaw) Rx(pitch) Rz(roll)')
