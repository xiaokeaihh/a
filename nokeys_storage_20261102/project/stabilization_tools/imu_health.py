"""Separate user intent from transient IMU freshness; never reuse stale poses."""
from collections import deque


class ImuHealth:
    STALE_SECONDS=.15
    RECOVERY_SECONDS=.30

    def __init__(self):
        self.paused=False;self.fresh_since=None;self.last_sample=None;self.last_tick=None
        self.pauses=0;self.resumes=0;self.max_host_gap_ms=0.;self.max_sensor_gap_ms=0.
        self.reason='';self.events=deque(maxlen=120)

    def sample(self,now,tick):
        if self.last_sample is not None:
            gap=now-self.last_sample;self.max_host_gap_ms=max(self.max_host_gap_ms,gap*1000)
            if gap>self.STALE_SECONDS:self.fresh_since=now
        if self.last_tick is not None:self.max_sensor_gap_ms=max(self.max_sensor_gap_ms,max(0,tick-self.last_tick)*.01)
        self.last_sample=now;self.last_tick=tick
        if self.fresh_since is None:self.fresh_since=now

    def poll(self,now,wanted,valid,pose_ready):
        if not wanted:
            self.paused=False;self.reason='';return None
        fresh=valid and self.last_sample is not None and now-self.last_sample<=self.STALE_SECONDS
        if not fresh or not pose_ready:
            self.fresh_since=None
            self.reason='IMU回报暂时中断' if valid else 'IMU标识或采样异常'
            if fresh and not pose_ready:self.reason='等待IMU零偏与安装标定恢复'
            if not self.paused:
                self.paused=True;self.pauses+=1
                self.events.append(dict(event='pause',host_monotonic=now,reason=self.reason))
                return 'pause'
        elif self.paused:
            if self.fresh_since is None:self.fresh_since=now
            if now-self.fresh_since>=self.RECOVERY_SECONDS:
                self.paused=False;self.resumes+=1;self.reason=''
                self.events.append(dict(event='resume',host_monotonic=now))
                return 'resume'
        return None

    def status(self,now):
        return dict(paused=self.paused,pauses=self.pauses,resumes=self.resumes,reason=self.reason,
                    last_sample_age_ms=round(max(0,now-self.last_sample)*1000,1) if self.last_sample is not None else None,
                    max_host_gap_ms=round(self.max_host_gap_ms,1),max_sensor_gap_ms=round(self.max_sensor_gap_ms,1),
                    fresh_limit_ms=150,recovery_ms=300,last_event=self.events[-1] if self.events else None)
