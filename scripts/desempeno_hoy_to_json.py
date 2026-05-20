#!/usr/bin/env python3
"""
Construye desempeno-hoy/data.json desde 2 salidas BQ (CO + MX).

Input shape (`bq query --format=json`):
  list of {"metric": "registros"|"calificados",
           "fecha_local": "YYYY-MM-DD", "hora_1_24": int (1..24),
           "fuente_label": str, "n": int}

Uso:
  desempeno_hoy_to_json.py <co_bq.json> <mx_bq.json> <out_data.json>
"""
import json
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

TZ_OFFSET = {"co": -5, "mx": -6}
SOURCES_CO = ["WEB", "Habimetro", "Leadforms", "CRM", "Broker", "Comercial"]
SOURCES_MX = ["WEB", "Habimetro", "Leadforms", "Propiedades", "Broker", "Comercial"]
METRICS = ["registros", "calificados"]


def build_metric(rows, metric, sources, today_local, current_hour_idx):
    """Construye la sección by_hour + totals para una métrica."""
    by_date_src = defaultdict(lambda: [0] * 24)
    for r in rows:
        if r["metric"] != metric:
            continue
        s = r["fuente_label"]
        if s not in sources:
            continue
        d = date.fromisoformat(r["fecha_local"])
        h = int(r["hora_1_24"]) - 1
        by_date_src[(d, s)][h] = int(r["n"])

    by_hour_today = {}
    for s in sources:
        arr = list(by_date_src.get((today_local, s), [0] * 24))
        for i in range(current_hour_idx + 1, 24):
            arr[i] = None
        by_hour_today[s] = arr

    prev_week_date = today_local - timedelta(days=7)
    by_hour_prev = {s: list(by_date_src.get((prev_week_date, s), [0] * 24)) for s in sources}

    avg_dates = [today_local - timedelta(days=14 + 7 * i) for i in range(4)]
    by_hour_avg = {}
    for s in sources:
        sums = [0.0] * 24
        for d in avg_dates:
            arr = by_date_src.get((d, s), [0] * 24)
            for i in range(24):
                sums[i] += arr[i]
        by_hour_avg[s] = [round(v / 4.0, 2) for v in sums]

    def sum_arr(arr):
        return sum(v for v in arr if v is not None)

    totals_today = {s: sum_arr(by_hour_today[s]) for s in sources}
    totals_today["_all"] = sum(totals_today.values())
    totals_prev = {s: sum_arr(by_hour_prev[s]) for s in sources}
    totals_prev["_all"] = sum(totals_prev.values())
    totals_avg = {s: round(sum_arr(by_hour_avg[s]), 2) for s in sources}
    totals_avg["_all"] = round(sum(totals_avg.values()), 2)

    # Última hora del día actual con datos > 0 (para indicador de freshness)
    last_hour_with_data = None
    today_all = [0] * 24
    for s in sources:
        for i in range(24):
            v = by_hour_today[s][i]
            if v is not None and v > 0:
                today_all[i] += v
    for i in range(23, -1, -1):
        if today_all[i] > 0:
            last_hour_with_data = i + 1  # eje 1-24
            break

    return {
        "by_hour": {
            "today": by_hour_today,
            "prev_week": by_hour_prev,
            "avg_4_weekdays": by_hour_avg,
        },
        "totals": {
            "today_so_far": totals_today,
            "prev_week": totals_prev,
            "avg_4_weekdays": totals_avg,
        },
        "last_hour_with_data": last_hour_with_data,
    }


def build_country(rows, country):
    tz = TZ_OFFSET[country]
    now_local = datetime.now(timezone.utc) + timedelta(hours=tz)
    today_local = now_local.date()
    today_weekday = today_local.weekday()
    current_hour_idx = now_local.hour
    sources = SOURCES_CO if country == "co" else SOURCES_MX

    return {
        "today_date": today_local.isoformat(),
        "today_weekday": today_weekday,
        "current_hour_1_24": current_hour_idx + 1,
        "sources": sources,
        "registros":   build_metric(rows, "registros",   sources, today_local, current_hour_idx),
        "calificados": build_metric(rows, "calificados", sources, today_local, current_hour_idx),
    }


def main():
    if len(sys.argv) != 4:
        print("Uso: desempeno_hoy_to_json.py <co_bq.json> <mx_bq.json> <out.json>",
              file=sys.stderr)
        sys.exit(1)
    co_path, mx_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(co_path) as f:
        co_rows = json.load(f)
    with open(mx_path) as f:
        mx_rows = json.load(f)

    now_co = datetime.now(timezone.utc) + timedelta(hours=-5)
    generated_at = now_co.strftime("%Y-%m-%dT%H:%M:%S-05:00")

    out = {
        "generated_at_iso": generated_at,
        "co": build_country(co_rows, "co"),
        "mx": build_country(mx_rows, "mx"),
    }
    with open(out_path, "w") as f:
        json.dump(out, f, separators=(",", ":"))


if __name__ == "__main__":
    main()
