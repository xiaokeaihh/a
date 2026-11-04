"""One bounded Windows shared-memory JPEG slot; readers never wait for AI."""
import mmap,struct,time

CAPACITY=2*1024*1024
HEADER=struct.Struct('<QQI12x')


class PreviewBuffer:
    def __init__(self,name):
        self.name=name;self.memory=mmap.mmap(-1,CAPACITY,tagname=name)
        self.sequence=0

    def write(self,jpeg):
        length=len(jpeg)
        if length>CAPACITY-HEADER.size:raise ValueError('Preview JPEG exceeds the fixed shared slot')
        self.sequence+=2;odd=self.sequence-1;stamp=time.time_ns()
        # A sequence check around the copy prevents a reader from returning
        # a half-written JPEG, without blocking capture or AI threads.
        self.memory[:8]=struct.pack('<Q',odd)
        self.memory[8:HEADER.size]=HEADER.pack(odd,stamp,length)[8:]
        self.memory[HEADER.size:HEADER.size+length]=jpeg
        self.memory[:8]=struct.pack('<Q',self.sequence)

    def ready(self):
        try:
            sequence,stamp,length=HEADER.unpack(self.memory[:HEADER.size])
            return sequence>0 and not sequence&1 and 0<length<=CAPACITY-HEADER.size
        except (ValueError,TypeError):return False

    def sample(self,previous=None):
        for _ in range(2):
            try:
                first=self.memory[:HEADER.size];sequence,stamp,length=HEADER.unpack(first)
                if not sequence or sequence&1 or stamp==previous or not 0<length<=CAPACITY-HEADER.size:return None
                jpeg=self.memory[HEADER.size:HEADER.size+length]
                if self.memory[:HEADER.size]==first:return stamp,jpeg
            except (ValueError,TypeError):return None
        return None

    def close(self):
        self.memory.close()
