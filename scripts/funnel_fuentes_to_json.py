#!/usr/bin/env python3
"""
Builds funnel-fuentes/data.json from BQ query output.

Input shape (from `bq query --format=json`):
  list of {"d": "YYYY-MM-DD", "source": "...", "stage": "...", "n": <int>}

Output shape: see spec §7.1.

Usage:
  funnel_fuentes_to_json.py <bq_query_output.json> <output_data.json>
"""
import json
import sys
from datetime import datetime, timezone


SOURCES = ["web_puro", "help_to_sell", "ayuda_venta"]
SEGMENT_STAGES = [
    "direccion", "zona", "datos_inmueble", "contacto",
    "caracteristicas", "ultimos_detalles", "felicitaciones",
]
ALL_STAGES = SEGMENT_STAGES + ["lead_hubspot"]
LOOKBACK_DAYS = 180


def main():
    if len(sys.argv) != 3:
        print("Usage: funnel_fuentes_to_json.py <bq_input.json> <data_output.json>",
              file=sys.stderr)
        sys.exit(1)

    in_path, out_path = sys.argv[1], sys.argv[2]

    with open(in_path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    # Pivot: (date, source) -> {stage: n, ...}
    pivot = {}
    completions_no_deal = {}
    dates_seen = set()
    sources_seen = set()
    for r in raw:
        d = r["d"]
        s = r["source"]
        stage = r["stage"]
        n = int(r["n"])
        dates_seen.add(d)
        sources_seen.add(s)
        if stage == "completions_no_deal":
            completions_no_deal[(d, s)] = n
        else:
            pivot.setdefault((d, s), {})[stage] = n

    # Ensure all (date, source) combinations exist with proper null/0 semantics.
    daily = []
    for d in sorted(dates_seen, reverse=True):
        for s in SOURCES:
            stages_dict = pivot.get((d, s), {})
            if s == "ayuda_venta":
                # Stages 1-7 quedan null (sin tracking); solo lead_hubspot tiene dato.
                entry_stages = {st: None for st in SEGMENT_STAGES}
                entry_stages["lead_hubspot"] = stages_dict.get("lead_hubspot", 0)
                entry_no_deal = None
            else:
                # Web puro y help-to-sell: completar con 0 los stages faltantes.
                entry_stages = {st: stages_dict.get(st, 0) for st in ALL_STAGES}
                entry_no_deal = completions_no_deal.get((d, s), 0)
            daily.append({
                "date": d,
                "source": s,
                "stages": entry_stages,
                "completions_no_deal": entry_no_deal,
            })

    out = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tz": "America/Bogota",
        "lookback_days": LOOKBACK_DAYS,
        "daily": daily,
    }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))

    print(f"Wrote {len(daily)} daily entries to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
