"""Manual recordings: stream bounded WebM chunks to disk, never queue frames."""
from pathlib import Path
import json,os,re,shutil,struct,threading,time,uuid

def vint(data,pos,identifier=False):
    first=data[pos];width=next((i for i in range(1,9) if first&(1<<(8-i))),None)
    if width is None or pos+width>len(data):raise ValueError('Invalid EBML integer')
    value=int.from_bytes(data[pos:pos+width],'big')
    return (value if identifier else value&((1<<(7*width))-1)),width

def encode_size(value,width):
    if value>=(1<<(7*width))-1:raise ValueError('EBML size overflow')
    return ((1<<(7*width))|value).to_bytes(width,'big')

def finalize_webm(source,destination,seconds):
    # MediaRecorder uses an unknown-size Segment and usually omits Duration.
    # Add Duration to Info, streaming the remaining file; no video re-encoding.
    with source.open('rb') as f:head=f.read(131072)
    pos=0;segment=None;info=None
    while pos<len(head):
        tag,n=vint(head,pos,True);size,m=vint(head,pos+n);body=pos+n+m
        if tag==0x18538067:segment=(pos,n,m,size);pos=body;continue
        if tag==0x1549a966:info=(pos,n,m,size,body);break
        if body+size>len(head):break
        pos=body+size
    if info is None:raise ValueError('录像缺少有效WebM头，未发布为空白录像')
    pos,n,m,size,body=info;end=body+size
    if end>len(head):raise ValueError('WebM头过大')
    content=bytearray(head[body:end]);offset=0;scale=1000000;duration=None
    while offset<len(content):
        tag,a=vint(content,offset,True);length,b=vint(content,offset+a);start=offset+a+b
        if tag==0x2ad7b1:scale=int.from_bytes(content[start:start+length],'big')
        if tag==0x4489:duration=(start,length)
        offset=start+length
    value=max(.001,float(seconds))*1e9/scale
    if duration:
        start,length=duration
        if length not in (4,8):raise ValueError('Invalid duration field')
        content[start:start+length]=struct.pack('>f' if length==4 else '>d',value)
    else:content.extend(b'\x44\x89\x88'+struct.pack('>d',value))
    replacement=head[pos:pos+n]+encode_size(len(content),m)+content
    prefix=bytearray(head[:pos]);delta=len(replacement)-(end-pos)
    if segment:
        segpos,segn,segm,segsize=segment
        if segsize!=(1<<(segm*7))-1:prefix[segpos+segn:segpos+segn+segm]=encode_size(segsize+delta,segm)
    temporary=destination.with_suffix('.tmp')
    try:
        with temporary.open('wb') as out,source.open('rb') as inp:
            out.write(prefix);out.write(replacement);inp.seek(end);shutil.copyfileobj(inp,out,1024*1024)
        os.replace(temporary,destination)
    finally:
        if temporary.exists():temporary.unlink()

class Recordings:
    MAX_CHUNK=8*1024*1024
    MAX_BYTES=2*1024**3
    LEASE_SECONDS=60
    def __init__(self,root):
        self.root=Path(root);self.lock=threading.RLock();self.active=None

    def folder(self,identity):
        if not re.fullmatch(r'[0-9a-f]{32}',identity):raise ValueError('录像编号无效')
        return self.root/identity

    def save(self,folder,meta):
        temp=folder/'metadata.tmp';temp.write_text(json.dumps(meta,ensure_ascii=False,allow_nan=False),encoding='utf-8');os.replace(temp,folder/'metadata.json')

    def start(self,data):
        with self.lock:
            self.reap_abandoned()
            if self.active:raise ValueError('已有录像正在写入，请先停止当前录像；若原页面已关闭，最后片段后60秒自动释放')
            owner=data.get('client_id','')
            if not isinstance(owner,str) or not 8<=len(owner)<=80:raise ValueError('录像页面标识无效')
            mime=data.get('mime','')
            if mime not in ('video/webm;codecs=vp8','video/webm;codecs=vp9','video/webm'):raise ValueError('请选择浏览器支持的WebM编码')
            identity=uuid.uuid4().hex;folder=self.folder(identity);folder.mkdir(parents=True)
            meta=dict(id=identity,title=str(data.get('title','手动录像'))[:80],created=time.time(),state='recording',mime=mime,
                      width=1280,height=720,target_fps=30,bytes=0,chunks=0,duration=0.,events=[],client_id=owner)
            now=time.monotonic()
            self.save(folder,meta);self.active=dict(meta=meta,folder=folder,started=now,last_activity=now,accepted_duration=0.)
            return self.public(meta)

    def reap_abandoned(self):
        # Chunk uploads renew the lease. Closing/crashing a browser must not
        # permanently hold the recorder; salvage only bytes already on disk.
        with self.lock:
            current=self.active
            if not current or time.monotonic()-current['last_activity']<=self.LEASE_SECONDS:return
            self.finish(dict(id=current['meta']['id'],client_id=current['meta']['client_id'],
                             duration=max(.001,min(1800.,current['accepted_duration'])),frames=0,
                             note='原录像页面已关闭或片段传输超过60秒，已保留收到的片段；恢复时长为估计值'))

    def public(self,meta):return {k:v for k,v in meta.items() if k!='client_id'}

    def session(self,identity,owner):
        if not self.active or self.active['meta']['id']!=identity:raise ValueError('录像会话已结束')
        if self.active['meta']['client_id']!=owner:raise ValueError('此页面不拥有当前录像')
        return self.active

    def append(self,identity,owner,sequence,reader,length):
        if not 0<length<=self.MAX_CHUNK:raise ValueError('录像片段过大')
        with self.lock:
            current=self.session(identity,owner);meta=current['meta']
            if sequence!=meta['chunks']:raise ValueError('录像片段顺序不匹配，请停止并保存已有录像')
            if meta['bytes']+length>self.MAX_BYTES:raise ValueError('单段录像已达到2GiB上限，请停止保存')
            path=current['folder']/'capture.webm.part';start=path.stat().st_size if path.exists() else 0
            try:
                with path.open('ab') as out:
                    remaining=length
                    while remaining:
                        block=reader.read(min(65536,remaining))
                        if not block:raise ValueError('录像片段传输中断')
                        out.write(block);remaining-=len(block)
            except Exception:
                if path.exists():
                    with path.open('r+b') as out:out.truncate(start)
                raise
            meta['bytes']+=length;meta['chunks']+=1
            current['last_activity']=time.monotonic()
            current['accepted_duration']=current['last_activity']-current['started']
            self.save(current['folder'],meta)
            return dict(chunks=meta['chunks'],bytes=meta['bytes'])

    def finish(self,data):
        with self.lock:
            current=self.session(data['id'],data.get('client_id'));meta=current['meta'];folder=current['folder']
            duration=float(data.get('duration',0))
            if not 0<duration<1805:raise ValueError('录像时长无效')
            meta['duration']=duration;meta['frames']=max(0,int(data.get('frames',0)))
            meta['render_fps']=round(meta['frames']/duration,2);meta['note']=str(data.get('note',''))[:250]
            source=folder/'capture.webm.part';dest=folder/'video.webm'
            try:
                if meta['bytes']<100:raise ValueError('没有收到可用录像数据')
                finalize_webm(source,dest,duration)
                meta['state']='partial' if meta['note'] else 'ready';meta['bytes']=dest.stat().st_size
                source.unlink()
            except Exception as error:
                meta['state']='interrupted';meta['note']=str(error)
            self.save(folder,meta);self.active=None
            return self.public(meta)

    def event(self,data):
        with self.lock:
            current=self.session(data['id'],data.get('client_id'));meta=current['meta']
            event=dict(time=max(0,float(data.get('time',0))),type=str(data.get('type','标记'))[:40],note=str(data.get('note',''))[:200])
            if len(meta['events'])<1800:meta['events'].append(event)
            self.save(current['folder'],meta);return event

    def list(self):
        self.reap_abandoned()
        if not self.root.exists():return []
        rows=[]
        for folder in self.root.iterdir():
            if not folder.is_dir():continue
            try:
                meta=json.loads((folder/'metadata.json').read_text(encoding='utf-8'))
                if meta['state']=='recording' and (not self.active or meta['id']!=self.active['meta']['id']):meta['state']='interrupted'
                rows.append(self.public(meta))
            except (OSError,ValueError,KeyError):continue
        return sorted(rows,key=lambda a:a['created'],reverse=True)[:100]

    def video(self,identity):
        path=self.folder(identity)/'video.webm'
        if not path.is_file():raise ValueError('录像尚未完成或文件不存在')
        return path

    def delete(self,identity):
        with self.lock:
            if self.active and self.active['meta']['id']==identity:
                raise ValueError('这段录像仍在录制，停止并保存后才能删除')
            folder=self.folder(identity)
            root=self.root.resolve()
            target=folder.resolve()
            if target.parent!=root or not target.is_dir():raise ValueError('录像不存在')
            try:meta=json.loads((target/'metadata.json').read_text(encoding='utf-8'))
            except (OSError,ValueError) as error:raise ValueError('录像信息无效，未删除') from error
            if meta.get('id')!=identity or meta.get('state') not in ('ready','partial','interrupted','recording'):
                raise ValueError('录像尚未结束或信息不匹配，未删除')
            shutil.rmtree(target)
            return dict(deleted=True,id=identity)
