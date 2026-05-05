#!/usr/bin/env python3
"""
Builds wbr-2-0/data.json by merging:
  - BQ main JSON: weekly metrics (reg/cal/asg/spend) by (week, fuente) for CO
  - Sheet CSV (OKR sheet, CO tab): weekly meta per fuente
  - BQ channels JSON: weekly asg by (week, fuente, channel) for CO

Usage:
  build_data.py <bq_co.json> <sheet_co.csv> <bq_channels.json> <bq_platforms.json> <output.json>
"""
import csv
import json
import sys
from collections import defaultdict
from datetime import date, datetime


SHEET_FUENTES_OFFSET = {
    'TOTAL':            7,
    'Perfo':           14,
    'WEB':             21,
    'lead_forms':      28,
    'Estudio Inmueble': 35,
    'CRM':             42,
    'Broker':          49,
    'Comercial':       56,
}

FUENTES_ROW = ['WEB', 'Estudio Inmueble', 'lead_forms', 'CRM', 'Broker', 'Comercial']


def parse_num(s):
    s = (s or '').strip()
    if not s or s in ('#N/A', '-', '#REF!', '#VALUE!'):
        return None
    if s.endswith('%'):
        s = s[:-1]
    s = s.replace('.', '').replace(',', '')
    try:
        return int(s)
    except ValueError:
        return None


def parse_date(s):
    s = (s or '').strip()
    if not s:
        return None
    try:
        return datetime.strptime(s, '%d/%m/%Y').date()
    except ValueError:
        return None


def parse_sheet_weekly(csv_path):
    """Read OKR CO CSV and extract weekly metas. Returns:
       { 'YYYY-MM-DD' (Monday): { fuente_name: meta } }
    """
    with open(csv_path, 'r', encoding='utf-8') as f:
        rows = list(csv.reader(f))

    out = {}
    in_weekly = False
    for row in rows:
        if not row:
            continue
        label = row[0].strip()
        if 'Semanales' in label:
            in_weekly = True
            continue
        if 'Diarias' in label:
            break
        if not in_weekly:
            continue
        if not label.isdigit():
            continue
        # Weekly data row
        desde = parse_date(row[2]) if len(row) > 2 else None
        if not desde:
            continue
        # The sheet's week 1 is partial (Thu-Sun) when year starts mid-week.
        # Skip rows where Desde is not a Monday.
        if desde.weekday() != 0:
            continue
        week_iso = desde.isoformat()
        metas = {}
        for fuente, off in SHEET_FUENTES_OFFSET.items():
            if off < len(row):
                metas[fuente] = parse_num(row[off])
        out[week_iso] = metas
    return out


def build_country(bq_json, sheet_csv, channels_json, platforms_json):
    rows = json.load(open(bq_json))
    by_week_raw = defaultdict(dict)
    for r in rows:
        by_week_raw[r['week_start']][r['fuente']] = {
            'reg': int(r['reg']),
            'cal': int(r['cal']),
            'asg': int(r['asg']),
            'spend': int(float(r['spend'])) if r.get('spend') is not None else None,
        }

    metas_by_week = parse_sheet_weekly(sheet_csv)

    by_week = {}
    totals_by_week = {}
    all_weeks = sorted(by_week_raw.keys())  # only weeks with actual data
    for w in all_weeks:
        cells = {}
        meta = metas_by_week.get(w, {})
        raw = by_week_raw.get(w, {})
        for fuente in FUENTES_ROW:
            cell = raw.get(fuente, {'reg': 0, 'cal': 0, 'asg': 0, 'spend': None})
            cell['meta'] = meta.get(fuente)
            cells[fuente] = cell
        by_week[w] = cells
        totals_by_week[w] = {
            'TOTAL': {'meta': meta.get('TOTAL')},
            'Perfo': {'meta': meta.get('Perfo')},
        }

    # Channels: by_week_channels[w] = { channel: {reg, cal, asg, spend, fuente} }
    # When the same channel appears under multiple source fuentes (rare data
    # anomaly e.g. Estudio Inmueble lead with WEB-Paid utm), MERGE counts.
    # The displayed `fuente` is derived from the channel name (canonical).
    def channel_to_fuente(ch):
        if ch.startswith('WEB ') or ch == 'WEB': return 'WEB'
        if ch.startswith('Estudio Inmueble'): return 'Estudio Inmueble'
        if ch.startswith('lead_forms') or ch.startswith('Lead Forms') or ch == 'lead_forms': return 'lead_forms'
        if ch.startswith('Broker'): return 'Broker'
        if ch.startswith('CRM'): return 'CRM'
        if ch.lower().startswith('comercial'): return 'Comercial'
        return None  # unclassified (long-tail UTM IDs)

    channels = json.load(open(channels_json))
    by_week_channels = defaultdict(dict)
    for r in channels:
        w = r['week_start']
        ch = r['channel']
        cell = by_week_channels[w].get(ch)
        spend_val = int(float(r['spend'])) if r.get('spend') is not None else None
        if cell is None:
            by_week_channels[w][ch] = {
                'reg':    int(r['reg']),
                'cal':    int(r['cal']),
                'asg':    int(r['asg']),
                'spend':  spend_val,
                'fuente': channel_to_fuente(ch) or r['fuente'],
            }
        else:
            cell['reg'] += int(r['reg'])
            cell['cal'] += int(r['cal'])
            cell['asg'] += int(r['asg'])
            if spend_val is not None:
                cell['spend'] = (cell['spend'] or 0) + spend_val

    # Platforms: by_week_platforms[w] = list of {platform, channel, fuente, reg, cal, asg, spend}
    platforms = json.load(open(platforms_json))
    by_week_platforms = defaultdict(list)
    for r in platforms:
        by_week_platforms[r['week_start']].append({
            'platform': r['platform'],
            'channel':  r['channel'],
            'fuente':   r['fuente'],
            'reg':    int(r['reg']),
            'cal':    int(r['cal']),
            'asg':    int(r['asg']),
            'spend':  int(float(r['spend'])) if r.get('spend') is not None else None,
        })

    return {
        'by_week': by_week,
        'totals_by_week': totals_by_week,
        'by_week_channels': dict(by_week_channels),
        'by_week_platforms': dict(by_week_platforms),
    }


def main():
    if len(sys.argv) != 6:
        print(f"Usage: {sys.argv[0]} <bq_co.json> <sheet_co.csv> <bq_channels.json> <bq_platforms.json> <output.json>")
        sys.exit(1)

    bq_co, sheet_co, bq_channels, bq_platforms, output = sys.argv[1:]

    data = {
        'updated': date.today().isoformat(),
        'co': build_country(bq_co, sheet_co, bq_channels, bq_platforms),
    }

    with open(output, 'w') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))

    n = len(data['co']['by_week'])
    size = len(json.dumps(data))
    print(f"OK: {output} ({size:,} bytes, {n} weeks CO)")


if __name__ == '__main__':
    main()
