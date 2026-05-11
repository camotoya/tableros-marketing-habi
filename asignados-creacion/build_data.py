#!/usr/bin/env python3
"""
Builds asignados-creacion/data.json from BQ query output.

Usage:
  build_data.py <bq_query_output.json> <output_data.json>

Input shape (BQ --format=json): list of {"d": "YYYY-MM-DD", "f": "<fuente>", "n": "<int>"}.
"""
import json
import sys
from datetime import datetime, timezone


# Canonical order matches the WBR mart labels; Otro al final.
FUENTE_ORDER = ["Habimetro", "CRM", "Broker", "WEB", "Ventanas", "Leadform", "Comercial", "Otro"]


def main():
    if len(sys.argv) != 3:
        print("Usage: build_data.py <bq_query_output.json> <output_data.json>", file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, 'r', encoding='utf-8') as f:
        raw = json.load(f)

    fuentes_seen = set()
    rows = []
    for r in raw:
        f_ = r["f"]
        fuentes_seen.add(f_)
        rows.append({"d": r["d"], "f": f_, "n": int(r["n"])})

    fuentes_out = [x for x in FUENTE_ORDER if x in fuentes_seen]
    # Append any uncatalogued fuente at the end so nothing gets dropped silently.
    extras = sorted(fuentes_seen - set(FUENTE_ORDER))
    fuentes_out.extend(extras)

    rows.sort(key=lambda r: (r["d"], r["f"]))

    out = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
        "country": "CO",
        "fuentes": fuentes_out,
        "rows": rows,
    }

    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(out, f, separators=(',', ':'), ensure_ascii=False)

    print(f"wrote {out_path}: {len(rows)} rows, {len(fuentes_out)} fuentes", file=sys.stderr)


if __name__ == '__main__':
    main()
