#!/usr/bin/env python3
"""Cluster Django backend error log entries by normalized signature.

Usage:
    python3 cluster_logs.py <path-to-logfile>

Reads a Django log file formatted as
    [LEVEL][YYYY-MM-DD HH:MM:SS,ms]module.py LINE: message
Keeps only ERROR and WARNING entries, merges continuation lines (e.g.
Python tracebacks) into their parent entry up to 20 lines, normalizes the
message to a signature, clusters by signature, and writes a JSON array to
stdout sorted by count descending.

No dependencies beyond the Python 3.12 standard library.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

LINE_RE = re.compile(
    r'^\[(ERROR|WARNING|INFO|DEBUG)\]'
    r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+)\]'
    r'([\w.]+)\.py '
    r'(\d+): '
    r'(.*)$'
)

URL_RE = re.compile(r'''https?://[^\s'"<>]+''', re.IGNORECASE)
HYPHEN_UUID_RE = re.compile(
    r'\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b',
    re.IGNORECASE,
)
HEX32_RE = re.compile(r'\b[a-f0-9]{32}\b', re.IGNORECASE)
QSTR_RE = re.compile(r"'[^']*'")
INT_RE = re.compile(r'\b\d+\b')

MAX_CONTINUATION = 20
SIG_MAX_LEN = 80


def normalize(msg: str) -> str:
    msg = URL_RE.sub('<URL>', msg)
    msg = HYPHEN_UUID_RE.sub('<UUID>', msg)
    msg = HEX32_RE.sub('<UUID>', msg)
    msg = QSTR_RE.sub('<STR>', msg)
    msg = INT_RE.sub('<N>', msg)
    return msg


def parse_entries(path: Path):
    current = None
    continuations = 0
    with path.open(encoding='utf-8', errors='replace') as f:
        for raw in f:
            raw = raw.rstrip('\n')
            m = LINE_RE.match(raw)
            if m:
                if current is not None:
                    yield current
                level, ts, module, line_no, message = m.groups()
                current = {
                    'level': level,
                    'ts': ts,
                    'module': module,
                    'line': int(line_no),
                    'message': message,
                    'full': [raw],
                }
                continuations = 0
            else:
                if current is not None and continuations < MAX_CONTINUATION:
                    current['full'].append(raw)
                    continuations += 1
    if current is not None:
        yield current


def main() -> int:
    if len(sys.argv) != 2:
        print('Usage: cluster_logs.py <logfile>', file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        print(f'File not found: {path}', file=sys.stderr)
        return 2

    clusters = defaultdict(lambda: {
        'count': 0,
        'first_seen': None,
        'last_seen': None,
        'samples': [],
        'meta': None,
    })
    for entry in parse_entries(path):
        if entry['level'] not in ('ERROR', 'WARNING'):
            continue
        norm = normalize(entry['message'])[:SIG_MAX_LEN]
        sig = f"{entry['level']}:{entry['module']}:{entry['line']}:{norm}"
        c = clusters[sig]
        c['count'] += 1
        if c['first_seen'] is None or entry['ts'] < c['first_seen']:
            c['first_seen'] = entry['ts']
        if c['last_seen'] is None or entry['ts'] > c['last_seen']:
            c['last_seen'] = entry['ts']
        if len(c['samples']) < 3:
            c['samples'].append('\n'.join(entry['full']))
        if c['meta'] is None:
            c['meta'] = {
                'level': entry['level'],
                'module': entry['module'],
                'line': entry['line'],
            }

    out = []
    for sig, c in clusters.items():
        out.append({
            'signature': sig,
            'level': c['meta']['level'],
            'module': c['meta']['module'],
            'line': c['meta']['line'],
            'count': c['count'],
            'first_seen': c['first_seen'],
            'last_seen': c['last_seen'],
            'samples': c['samples'],
        })
    out.sort(key=lambda x: -x['count'])
    json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
