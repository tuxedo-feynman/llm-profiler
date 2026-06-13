#!/usr/bin/env python3
"""Parse llama.cpp output and system_metrics.csv to produce summary.json."""

import csv
import json
import os
import re
import sys
from datetime import datetime


def parse_timings(text):
    result = {}

    m = re.search(r'load time\s*=\s*([\d.]+)\s*ms', text)
    if m:
        result['load_time_ms'] = float(m.group(1))

    m = re.search(
        r'prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens[^\n]*?([\d.]+)\s*tokens per second',
        text,
    )
    if m:
        result['prompt_eval_time_ms'] = float(m.group(1))
        result['prompt_eval_tokens_per_sec'] = float(m.group(3))

    m = re.search(
        r'\beval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*runs[^\n]*?([\d.]+)\s*tokens per second',
        text,
    )
    if m:
        result['eval_time_ms'] = float(m.group(1))
        result['eval_tokens_per_sec'] = float(m.group(3))

    return result


def parse_system_metrics(csv_path):
    rows = []
    try:
        with open(csv_path, newline='') as f:
            for row in csv.DictReader(f):
                rows.append(row)
    except FileNotFoundError:
        return {}

    if not rows:
        return {}

    def col_floats(key):
        out = []
        for r in rows:
            try:
                out.append(float(r[key]))
            except (ValueError, KeyError):
                pass
        return out

    stats = {}

    rss = col_floats('rss_mb')
    if rss:
        stats['peak_rss_mb'] = round(max(rss), 2)
        stats['avg_rss_mb'] = round(sum(rss) / len(rss), 2)

    cpu = col_floats('cpu_percent')
    if cpu:
        stats['avg_cpu_percent'] = round(sum(cpu) / len(cpu), 1)
        stats['max_cpu_percent'] = round(max(cpu), 1)

    swapouts = col_floats('swapouts')
    if swapouts:
        stats['start_swapouts'] = int(swapouts[0])
        stats['end_swapouts'] = int(swapouts[-1])
        stats['swapouts_delta'] = int(swapouts[-1]) - int(swapouts[0])

    swapins = col_floats('swapins')
    if swapins:
        stats['start_swapins'] = int(swapins[0])
        stats['end_swapins'] = int(swapins[-1])
        stats['swapins_delta'] = int(swapins[-1]) - int(swapins[0])

    compressed = col_floats('compressed_mb')
    if compressed:
        stats['start_compressed_mb'] = round(compressed[0], 2)
        stats['end_compressed_mb'] = round(compressed[-1], 2)
        stats['compressed_mb_delta'] = round(compressed[-1] - compressed[0], 2)

    stats['peak_swapout_rate_per_min'] = _peak_swapout_rate(rows)

    return stats


def _peak_swapout_rate(rows):
    """Max swapouts/minute seen between any two consecutive samples."""
    timed = []
    for r in rows:
        try:
            ts = datetime.fromisoformat(r['ts'].replace('Z', '+00:00'))
            timed.append((ts, float(r['swapouts'])))
        except (ValueError, KeyError):
            continue

    if len(timed) < 2:
        return 0.0

    max_rate = 0.0
    for i in range(len(timed) - 1):
        dt = (timed[i + 1][0] - timed[i][0]).total_seconds()
        if dt <= 0:
            continue
        delta = timed[i + 1][1] - timed[i][1]
        if delta <= 0:
            continue
        max_rate = max(max_rate, delta / dt * 60)

    return round(max_rate, 2)


def verdict(sys_stats):
    if sys_stats.get('swapouts_delta', 0) > 0:
        return 'memory_pressure_or_swapping'
    return 'fits_without_swap'


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <run_dir>', file=sys.stderr)
        sys.exit(1)

    run_dir = sys.argv[1]

    with open(os.path.join(run_dir, 'run.json')) as f:
        run_data = json.load(f)

    def read(name):
        try:
            with open(os.path.join(run_dir, name)) as f:
                return f.read()
        except FileNotFoundError:
            return ''

    timings = parse_timings(read('stdout.txt') + '\n' + read('stderr.txt'))
    sys_stats = parse_system_metrics(os.path.join(run_dir, 'system_metrics.csv'))

    total_seconds = None
    try:
        start = datetime.fromisoformat(run_data['started_at'].replace('Z', '+00:00'))
        end   = datetime.fromisoformat(run_data['ended_at'].replace('Z', '+00:00'))
        total_seconds = round((end - start).total_seconds(), 2)
    except (TypeError, ValueError, KeyError):
        pass

    summary = {
        'total_seconds':              total_seconds,
        'load_time_ms':               timings.get('load_time_ms'),
        'prompt_eval_time_ms':        timings.get('prompt_eval_time_ms'),
        'prompt_eval_tokens_per_sec': timings.get('prompt_eval_tokens_per_sec'),
        'eval_time_ms':               timings.get('eval_time_ms'),
        'eval_tokens_per_sec':        timings.get('eval_tokens_per_sec'),
        'peak_rss_mb':                sys_stats.get('peak_rss_mb'),
        'avg_rss_mb':                 sys_stats.get('avg_rss_mb'),
        'avg_cpu_percent':            sys_stats.get('avg_cpu_percent'),
        'max_cpu_percent':            sys_stats.get('max_cpu_percent'),
        'start_swapouts':             sys_stats.get('start_swapouts'),
        'end_swapouts':               sys_stats.get('end_swapouts'),
        'swapouts_delta':             sys_stats.get('swapouts_delta'),
        'start_swapins':              sys_stats.get('start_swapins'),
        'end_swapins':                sys_stats.get('end_swapins'),
        'swapins_delta':              sys_stats.get('swapins_delta'),
        'peak_swapout_rate_per_min':  sys_stats.get('peak_swapout_rate_per_min'),
        'start_compressed_mb':        sys_stats.get('start_compressed_mb'),
        'end_compressed_mb':          sys_stats.get('end_compressed_mb'),
        'compressed_mb_delta':        sys_stats.get('compressed_mb_delta'),
        'verdict':                    verdict(sys_stats),
    }

    with open(os.path.join(run_dir, 'summary.json'), 'w') as f:
        json.dump(summary, f, indent=2)

    v = summary['verdict']
    print(f'[profiler] Verdict:          {v}')
    if summary['peak_rss_mb'] is not None:
        print(f'[profiler] Peak RSS:         {summary["peak_rss_mb"]:.1f} MB')
    if summary['swapouts_delta'] is not None:
        print(f'[profiler] Swapouts delta:   {summary["swapouts_delta"]}')
    if summary['peak_swapout_rate_per_min'] is not None:
        print(f'[profiler] Peak swap rate:   {summary["peak_swapout_rate_per_min"]:.1f} swapouts/min')
    if summary['eval_tokens_per_sec'] is not None:
        print(f'[profiler] Generation speed: {summary["eval_tokens_per_sec"]:.1f} tok/s')
    if summary['total_seconds'] is not None:
        print(f'[profiler] Total time:       {summary["total_seconds"]:.1f}s')
    if summary['avg_cpu_percent'] is not None:
        print(f'[profiler] Avg CPU:          {summary["avg_cpu_percent"]:.0f}%  (max {summary["max_cpu_percent"]:.0f}%)')


if __name__ == '__main__':
    main()
