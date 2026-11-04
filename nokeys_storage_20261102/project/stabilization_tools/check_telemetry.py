from protocol import Decoder
from projection_reference import ROOT
import struct,json
d=Decoder();values=bytes(int(s,16) for s in (ROOT/'verification_stabilization/telemetry_bytes.txt').read_text().splitlines())
packets=d.feed(values)
assert d.crc_errors==0 and len(packets)==4 and not d.buffer
assert [k for k,_ in packets]==[2,1,1,3]
assert struct.unpack('<II',packets[0][1])==(37,0x1234)
# Samples deliberately carry distinct signed values, not just zeros.
assert struct.unpack('<HIBB6h',packets[1][1])==(7,0x1234,0x47,1,1,2,3,4,5,6)
assert struct.unpack('<HIBB6h',packets[2][1])==(8,0x12fc,0x47,1,-1,-2,-3,-4,-5,-6)
assert struct.unpack('<6BH',packets[3][1])==(7,0x22,3,1,0,15,0)
(ROOT/'verification_stabilization/telemetry_report.json').write_text(json.dumps({'passed':True,'RTL_to_PC_CRC_and_endianness':True,'packets':4},indent=2))
print('PASS actual RTL UART bytes decoded by PC protocol, including signed axes and timestamps')
