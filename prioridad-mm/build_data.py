#!/usr/bin/env python3
"""Reshape BQ output into compact data.json for prioridad-mm dashboard.

Input: JSON array from bq query (rows: semana, country, n, a, b, c).
Output: {updated_at, weeks: [...], countries: {Colombia: {n, a, b, c}, México: {n, a, b, c}}}
"""
import json
import sys
from datetime import datetime, timezone

if len(sys.argv) != 3:
    print("Usage: build_data.py <bq_raw.json> <out_path>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    raw = json.load(f)

weeks = sorted({r["semana"] for r in raw})
countries = ("Colombia", "México")

by_key = {(r["semana"], r["country"]): r for r in raw}

out = {
    "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "weeks": weeks,
    "countries": {},
}

for c in countries:
    n_list, a_list, b_list, cc_list = [], [], [], []
    for w in weeks:
        r = by_key.get((w, c))
        if r is None:
            n_list.append(None); a_list.append(None); b_list.append(None); cc_list.append(None)
        else:
            n_list.append(int(r["n"]))
            a_list.append(int(r["a"]))
            b_list.append(int(r["b"]))
            cc_list.append(int(r["c"]))
    out["countries"][c] = {"n": n_list, "a": a_list, "b": b_list, "c": cc_list}

with open(sys.argv[2], "w") as f:
    json.dump(out, f, separators=(",", ":"), ensure_ascii=False)

print(f"Weeks: {len(weeks)} | Countries: {list(out['countries'].keys())}")
