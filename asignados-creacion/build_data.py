#!/usr/bin/env python3
"""
Builds asignados-creacion/data.json from BQ query output.

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape (BQ --format=json): list of {"d": "YYYY-MM-DD", "n": "<int>"}.
"""
import json
import sys
from datetime import datetime, timezone


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq_query_output.json> <output_data.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        raw = json.load(f)

    rows = [{"d": r["d"], "n": int(r["n"])} for r in raw]
    rows.sort(key=lambda r: r["d"])

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "country": "CO",
        "rows": rows,
    }

    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    print(f"wrote {out_path}: {len(rows)} rows", file=sys.stderr)


if __name__ == '__main__':
    main()
