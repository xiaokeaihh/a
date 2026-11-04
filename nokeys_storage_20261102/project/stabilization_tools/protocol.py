"""Wire protocol shared with the RTL; all multibyte integers little endian."""
import struct

def crc8(data):
    c=0
    for value in data:
        c^=value
        for _ in range(8):c=((c<<1)^0x07 if c&0x80 else c<<1)&255
    return c

def command(seq,code):
    body=bytes([seq&255,code]);return b'\xa5\x5a'+body+bytes([crc8(body)])

def pose_packet(seq,frame,tick,matrix):
    body=bytes([seq&255,0x90])+struct.pack('<BII9i',1,frame&0xffffffff,tick&0xffffffff,*matrix)
    return b'\xa5\x5a'+body+bytes([crc8(body)])

def pose_bundle(seq,frame,tick,matrices):
    values=[int(x) for h in matrices for x in h.flat]
    if len(values)!=54:raise ValueError('需要基准、四角和中部共六套矩阵')
    body=bytes([seq&255,0x91])+struct.pack('<BII54i',2,frame&0xffffffff,tick&0xffffffff,*values)
    return b'\xa5\x5a'+body+bytes([crc8(body)])

def telemetry(kind,payload):
    body=bytes([kind,len(payload)])+payload
    return b'\xa5\x5a'+body+bytes([crc8(body)])

class Decoder:
    def __init__(self):self.buffer=bytearray();self.crc_errors=0
    def feed(self,data):
        self.buffer.extend(data);packets=[]
        while True:
            p=self.buffer.find(b'\xa5\x5a')
            if p<0:
                self.buffer[:]=self.buffer[-1:] if self.buffer[-1:]==b'\xa5' else b''
                break
            if p:del self.buffer[:p]
            if len(self.buffer)<4:break
            kind,size=self.buffer[2:4]
            if (kind,size) not in [(1,20),(2,8),(3,8),(4,112),(4,160),(5,8),(6,28)]:del self.buffer[0];continue
            total=size+5
            if len(self.buffer)<total:break
            if crc8(self.buffer[2:total-1])!=self.buffer[total-1]:
                self.crc_errors+=1;del self.buffer[0];continue
            packets.append((kind,bytes(self.buffer[4:total-1])));del self.buffer[:total]
        return packets

def active_pose_packet(sequence,frame,tick,view,matrix):
    """50 bytes: one Q8.24 matrix tagged with its render view/command epoch."""
    if view not in (6,7):raise ValueError('IMU only applies to center/follow or baseline')
    values=[int(v) for v in matrix]
    if len(values)!=9:raise ValueError('Expected one 3x3 matrix')
    body=bytes([sequence&255,0x92])+struct.pack('<BII9i',0x30|view,frame&0xffffffff,tick&0xffffffff,*values)
    return b'\xa5\x5a'+body+bytes([crc8(body)])

def attitude_packet(sequence,angles):
    values=[round(float(angles[key])*10) for key in ('roll','pitch','yaw')]
    if not all(-1800<=v<=1800 for v in values):raise ValueError('姿态角超出范围')
    body=bytes([sequence&255,0x93,1])+struct.pack('<3h',*values)
    return b'\xa5\x5a'+body+bytes([crc8(body)])
