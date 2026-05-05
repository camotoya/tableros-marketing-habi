#!/usr/bin/env python3
"""
Combines BigQuery JSON outputs (leads + spend) into compact data.json
for the Marketing WBR dashboard.

Usage:
  build_data.py <leads_co.json> <spend_co.json> <output.json>

Output shape:
  {
    "updated": "YYYY-MM-DD",
    "co": {
      "by_day": {
        "YYYY-MM-DD": {
          "<channel>": {"reg": int, "cal": int, "spend": int|null}
        }
      }
    },
    "mx": {"by_day": {}}
  }
"""
import json
import sys
from collections import defaultdict
from datetime import date


def load_country(leads_path, spend_path):
    leads = json.load(open(leads_path))
    spend = json.load(open(spend_path))

    by_day = defaultdict(dict)

    for r in leads:
        cell = by_day[r['dia']].setdefault(r['channel'], {'reg': 0, 'cal': 0, 'spend': None})
        cell['reg'] = int(r['reg'])
        cell['cal'] = int(r['cal'])

    for s in spend:
        cell = by_day[s['dia']].setdefault(s['channel'], {'reg': 0, 'cal': 0, 'spend': None})
        cell['spend'] = int(float(s['spend']))

    return {'by_day': dict(by_day)}


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <leads_co.json> <spend_co.json> <output.json>")
        sys.exit(1)

    leads_co, spend_co, output = sys.argv[1:]

    data = {
        'updated': date.today().isoformat(),
        'co': load_country(leads_co, spend_co),
        'mx': {'by_day': {}},
    }

    with open(output, 'w') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))

    n_days = len(data['co']['by_day'])
    n_cells = sum(len(d) for d in data['co']['by_day'].values())
    size = len(json.dumps(data))
    print(f"OK: {output} ({size:,} bytes, {n_days} days CO, {n_cells} cells)")


if __name__ == '__main__':
    main()
