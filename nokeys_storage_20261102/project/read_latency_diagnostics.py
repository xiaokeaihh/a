"""Read the existing control service; never sends a board command."""
from pathlib import Path
import argparse
import collections
import datetime
import json
import statistics
import time
import urllib.error
import urllib.request


def collect(url, seconds, interval):
    samples = []
    deadline = time.monotonic() + seconds
    while True:
        with urllib.request.urlopen(url.rstrip('/') + '/api/status', timeout=5) as response:
            status = json.load(response)
        now = time.time()
        diagnostics = status.get('diagnostics') or {}
        sync = status.get('output_sync') or {}
        samples.append(dict(
            time=now, connected=status.get('connected', False),
            control_version=status.get('control_version'), project_root=status.get('project_root'),
            image_controls=status.get('image_controls'), hardware=status.get('hardware'),
            diagnostics=diagnostics, output_sync=sync,
            fresh=not status.get('diagnostics_stale', True) and now - diagnostics.get('host_time', 0) <= 2,
            sync_fresh=now - sync.get('host_time', 0) <= 2))
        if time.monotonic() >= deadline:
            return samples
        time.sleep(min(interval, max(0, deadline - time.monotonic())))


def summarize(samples):
    fresh = [s for s in samples if s['fresh'] and s['connected']]
    unique = {}
    for s in fresh:
        d = s['diagnostics']
        key=(d.get('frame_id'),d.get('view'),d.get('mode'),d.get('stabilized'))
        old=unique.get(key)
        if old is None or old.get('diagnostic_partial') or not d.get('diagnostic_partial'):
            unique[key] = d
    diagnostics = list(unique.values())
    result = dict(scope='Board telemetry samples; not a PC-to-monitor stopwatch measurement',
                  api_samples=len(samples), fresh_diagnostic_reports=len(diagnostics))
    contexts = collections.Counter(
        ((s.get('image_controls') or {}).get('input_source'),
         (s.get('hardware') or {}).get('view'), (s.get('hardware') or {}).get('mode'),
         (s.get('hardware') or {}).get('stabilized')) for s in fresh)
    result['contexts'] = [dict(input_source=k[0], view=k[1], mode=k[2], stabilized=k[3], samples=v)
                          for k, v in contexts.items()]
    result['mixed_modes'] = len(contexts) > 1
    result['latency_ms'] = {}
    for key in ['latency_ms', 'capture_ms', 'queue_ms', 'render_ms', 'display_ms', 'overlap_ms']:
        values = sorted(d[key] for d in diagnostics if isinstance(d.get(key), (int, float)) and
                        (key in ('latency_ms','queue_ms') or not d.get('diagnostic_partial')))
        if values:
            result['latency_ms'][key] = dict(mean=statistics.mean(values), min=values[0], max=values[-1])
    result['first_before_render_done_reports'] = sum(bool(d.get('first_before_render_done')) for d in diagnostics)
    syncs = [s['output_sync'] for s in fresh if s['sync_fresh']]
    result['sync_samples'] = len(syncs)
    result['phase_locked_samples'] = sum(bool(s.get('phase_locked')) for s in syncs)
    result['phase_states'] = dict(collections.Counter(str(s.get('phase_state', 'unavailable_v1')) for s in syncs))
    result['admission_flag_sample_counts'] = dict(collections.Counter(
        k for s in syncs for k, value in (s.get('early_admission') or {}).items() if value))
    result['has_version2_diagnostics'] = any(s.get('version', 0) >= 2 for s in syncs)
    live_syncs = [s['output_sync'] for s in samples if s['connected'] and s['sync_fresh']]
    result['last_sync_version'] = live_syncs[-1].get('version') if live_syncs else None
    result['certified_profile_samples'] = sum(bool(s.get('certified_base_profile')) for s in live_syncs)
    result['last_certified_base_profile'] = live_syncs[-1].get('certified_base_profile') if live_syncs else None
    result['last_nominal_phase_ms'] = live_syncs[-1].get('target_phase_pixels', 0) / 74250 if live_syncs else None
    result['last_observed_ready_ms'] = live_syncs[-1].get('worst_ready_ms') if live_syncs else None
    result['last_receiver_recovery'] = next((s['receiver_recovery'] for s in reversed(live_syncs) if 'receiver_recovery' in s), None)
    result['last_input_activity'] = next((s['input_activity'] for s in reversed(live_syncs) if 'input_activity' in s), None)
    result['last_stability'] = next((s['stability'] for s in reversed(live_syncs) if 'stability' in s), None)
    result['counter_changes'] = {}
    if fresh:
        for key in ('repeat_frames','render_errors','capture_drops'):
            a=fresh[0]['diagnostics'].get(key);b=fresh[-1]['diagnostics'].get(key)
            if isinstance(a,int) and isinstance(b,int):result['counter_changes'][key]=b-a if b>=a else None
    result['note'] = 'Incomplete reports are excluded from completed processing means. New-frame latency does not bound the age of repeated scans. Pipeline parts overlap.'
    return result


def main():
    parser = argparse.ArgumentParser(description='只读取当前网页控制服务的延迟与同步状态，不改变开发板模式。')
    parser.add_argument('--url', default='http://127.0.0.1:8772')
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--interval', type=float, default=0.25)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.seconds < 0 or args.interval <= 0:
        parser.error('seconds must be nonnegative; interval must be positive')
    print('正在读取板内延迟与同步状态；不会改变输入、视角或图像设置。', flush=True)
    try:
        samples = collect(args.url, args.seconds, args.interval)
    except (OSError, urllib.error.URLError, ValueError) as exc:
        print('无法读取控制服务，请先从本目录启动网页并连接串口：' + str(exc))
        raise SystemExit(1)
    summary = summarize(samples)
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    target = args.out or Path(__file__).resolve().parent / 'measurement_reports' / ('latency_' + stamp + '.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(dict(summary=summary, samples=samples), ensure_ascii=False, indent=2), encoding='utf-8')
    latency = summary['latency_ms'].get('latency_ms')
    if latency:
        print('板内延迟：平均 %.2f ms，范围 %.2f～%.2f ms' % (latency['mean'], latency['min'], latency['max']))
    else:
        print('未读到新鲜的开发板延迟，请确认网页已连接串口。')
    print('提前于矫正完成显示的报告：%d / %d' % (summary['first_before_render_done_reports'], summary['fresh_diagnostic_reports']))
    print('同步锁定快照：%d / %d' % (summary['phase_locked_samples'], summary['sync_samples']))
    if (summary['last_sync_version'] or 0) >= 4:
        print('固件遥测版本%d已确认，基准预算相位启用：%s' % (summary['last_sync_version'],summary['last_certified_base_profile']))
        if summary['last_certified_base_profile']:
            print('目标相位（按74.25MHz）：%.3f ms；准备时间观测上限：%.3f ms' % (summary['last_nominal_phase_ms'], summary['last_observed_ready_ms']))
            print('准备时间观测包含帧槽等待；当前延迟以本帧latency和实际提前显示统计为准。')
    else:
        print('尚未确认版本4固件；新网页已打开并不代表开发板已烧录本版。')
    if summary['mixed_modes']:
        print('采样期间模式发生了变化，请保持同一输入和视角重新采样后比较。')
    if not summary['has_version2_diagnostics']:
        print('尚未读到版本 2 同步状态；请确认已烧录恢复版并从该目录启动控制网页。')
    if summary['last_input_activity'] is not None:
        a=summary['last_input_activity'];r=summary['last_receiver_recovery'] or {}
        print('HDMI原始输入：像素时钟=%s，帧同步=%s，有效像素=%s，格式合格=%s' % (a['pixel_clock'],a['vsync'],a['data_enable'],a['qualified']))
        print('接收器恢复：累计=%s，本次尝试=%s，达到上限=%s' % (r.get('total'),r.get('attempts'),r.get('limited')))
    if summary['last_stability'] is not None:
        stability=summary['last_stability']
        print('短时抖动用量峰值：%d / %d 周期；最近失败原因：%s' % (stability['jitter_peak_cycles'],stability['jitter_allowance_cycles'],stability['last_failure_reasons']))
    print('采样期间计数变化：'+str(summary['counter_changes']))
    print('详细记录：' + str(target))
    print('以上是板内首像素统计；整机需比较同一画面实际出现的时刻，不能直接相减30帧素材中的秒表数字。')


if __name__ == '__main__':
    main()
