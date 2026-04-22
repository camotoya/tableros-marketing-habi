#!/usr/bin/env python3
"""
Combines Google Sheet CSV exports (leads asignados) with BigQuery JSON
(daily investment) into data.json for the OKR Marketing dashboard.

Usage: python build_data.py <co_csv> <mx_csv> <invest_json> <output_json>
"""
import csv, json, sys
from datetime import date, datetime, timedelta

MONTH_SHORT = ['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic']
MONTH_ES = {
    'Enero':1,'Febrero':2,'Marzo':3,'Abril':4,'Mayo':5,'Junio':6,
    'Julio':7,'Agosto':8,'Septiembre':9,'Octubre':10,'Noviembre':11,'Diciembre':12
}
Q_MONTHS = {'Q1':[1,2,3],'Q2':[4,5,6],'Q3':[7,8,9],'Q4':[10,11,12]}

SOURCES_CO = ['TOTAL','Perfo','WEB','lead_forms','Estudio Inmueble','CRM','Broker','Comercial']
SOURCES_MX = ['TOTAL','Perfo','WEB','Lead Forms','Estudio Inmueble','Propiedades','Broker','Comercial']


def parse_num(s):
    s = s.strip()
    if not s or s in ('#N/A', '-', '#REF!', '#VALUE!'):
        return None
    if s.endswith('%'):
        s = s[:-1]
    s = s.replace('.', '')
    try:
        return int(s)
    except ValueError:
        return None


def parse_date_str(s):
    """Parse dd/mm/yyyy to date."""
    s = s.strip()
    if not s:
        return None
    try:
        return datetime.strptime(s, '%d/%m/%Y').date()
    except ValueError:
        return None


def parse_sheet(path, source_names):
    """Parse a 'Cumplimiento Fuentes' CSV into structured leads data."""
    with open(path, 'r', encoding='utf-8') as f:
        rows = list(csv.reader(f))

    offsets = {name: 7 + i * 7 for i, name in enumerate(source_names)}

    section = None
    annual, quarters, months, weeks, cycles = {}, {}, {}, [], []

    for row in rows:
        if len(row) < 7:
            continue
        label = row[0].strip()

        if 'Anuales' in label:
            section = 'annual'; continue
        elif 'Trimestrales' in label:
            section = 'quarterly'; continue
        elif 'Mensuales' in label:
            section = 'monthly'; continue
        elif 'Semanales' in label:
            section = 'weekly'; continue
        elif 'Ciclos' in label:
            section = 'cycles'; continue
        elif 'Diarias' in label:
            break

        if not label.isdigit():
            continue
        period = row[1].strip() if len(row) > 1 else ''
        desde = parse_date_str(row[2]) if len(row) > 2 else None
        hasta = parse_date_str(row[4]) if len(row) > 4 else None

        def extract(row_data):
            d = {}
            for src, off in offsets.items():
                if off + 3 < len(row_data):
                    d[src] = {
                        'meta': parse_num(row_data[off]),
                        'mtd': parse_num(row_data[off+1]),
                        'actual': parse_num(row_data[off+2]),
                        'prev': parse_num(row_data[off+3])
                    }
            return d

        if section == 'annual':
            annual = extract(row)
        elif section == 'quarterly' and period.startswith('Q'):
            quarters[period] = extract(row)
        elif section == 'monthly' and period in MONTH_ES:
            months[MONTH_ES[period]] = extract(row)
        elif section == 'weekly':
            d = extract(row)
            total = d.get('TOTAL', {})
            if total.get('actual') or total.get('mtd'):
                d['_desde'] = desde.isoformat() if desde else None
                d['_hasta'] = hasta.isoformat() if hasta else None
                d['_label'] = f"{desde.strftime('%d/%m') if desde else '?'} - {hasta.strftime('%d/%m') if hasta else '?'}"
                weeks.append(d)
        elif section == 'cycles':
            d = extract(row)
            total = d.get('TOTAL', {})
            if total.get('actual') or total.get('mtd'):
                d['_desde'] = desde.isoformat() if desde else None
                d['_hasta'] = hasta.isoformat() if hasta else None
                d['_label'] = f"{desde.strftime('%d/%m') if desde else '?'} - {hasta.strftime('%d/%m') if hasta else '?'}"
                cycles.append(d)

    return {
        'sources': source_names,
        'annual': annual, 'quarters': quarters,
        'months': months, 'weeks': weeks, 'cycles': cycles
    }


def subtract_source(data, exclude='Propiedades'):
    def sub(total, exc):
        if not total or not exc:
            return total or {}
        return {k: (total.get(k) or 0) - (exc.get(k) or 0) if total.get(k) is not None else None
                for k in total}

    if 'TOTAL' in data['annual'] and exclude in data['annual']:
        data['annual']['TOTAL'] = sub(data['annual']['TOTAL'], data['annual'][exclude])
        del data['annual'][exclude]
    for q_key, q_val in data['quarters'].items():
        if 'TOTAL' in q_val and exclude in q_val:
            q_val['TOTAL'] = sub(q_val['TOTAL'], q_val[exclude])
            del q_val[exclude]
    for m_key, m_val in data['months'].items():
        if 'TOTAL' in m_val and exclude in m_val:
            m_val['TOTAL'] = sub(m_val['TOTAL'], m_val[exclude])
            del m_val[exclude]
    for lst in (data['weeks'], data['cycles']):
        for item in lst:
            if 'TOTAL' in item and exclude in item:
                item['TOTAL'] = sub(item['TOTAL'], item[exclude])
                if exclude in item:
                    del item[exclude]
    if exclude in data['sources']:
        data['sources'].remove(exclude)
    return data


def parse_invest_daily(json_path):
    """Parse daily BQ JSON into {country: {date_str: spend}}."""
    with open(json_path, 'r') as f:
        data = json.load(f)
    out = {'CO': {}, 'MX': {}}
    for row in data:
        c = row['country']
        if c in out:
            out[c][row['dt']] = int(float(row['spend']))
    return out


def invest_range(daily, d_from, d_to):
    """Sum daily investment from d_from to d_to (inclusive)."""
    if not d_from or not d_to:
        return 0
    total = 0
    d = d_from
    while d <= d_to:
        total += daily.get(d.isoformat(), 0)
        d += timedelta(days=1)
    return total


def build_country(leads, invest_daily):
    today = date.today()
    cy, py = today.year, today.year - 1

    def inv_for_range(desde_str, hasta_str, year):
        """Get investment for a date range in a given year."""
        if not desde_str or not hasta_str:
            return 0
        d_from = date.fromisoformat(desde_str)
        d_to = date.fromisoformat(hasta_str)
        if year != d_from.year:
            try:
                d_from = d_from.replace(year=year)
                d_to = d_to.replace(year=year)
            except ValueError:
                return 0
        # Cap to yesterday for current year
        if year == cy:
            cap = today - timedelta(days=1)
            if d_to > cap:
                d_to = cap
            if d_from > cap:
                return 0
        return invest_range(invest_daily, d_from, d_to)

    # --- Annual ---
    ytd_last_day = today - timedelta(days=1)
    ytd_first = date(cy, 1, 1)
    ytd_first_prev = date(py, 1, 1)
    ytd_last_prev = date(py, ytd_last_day.month, ytd_last_day.day)
    inv_ytd = invest_range(invest_daily, ytd_first, ytd_last_day)
    inv_ytd_prev = invest_range(invest_daily, ytd_first_prev, ytd_last_prev)

    annual_row = {
        'label': str(cy),
        'leads': leads['annual'].get('TOTAL', {}),
        'invest': {'actual': inv_ytd, 'prev': inv_ytd_prev}
    }

    # --- Quarters ---
    quarter_rows = []
    for ql, qm in Q_MONTHS.items():
        qd = leads['quarters'].get(ql, {})
        total = qd.get('TOTAL', {})
        if not total.get('actual') and not total.get('mtd'):
            continue
        q_start = date(cy, qm[0], 1)
        q_end_month = qm[-1]
        if q_end_month == 12:
            q_end = date(cy, 12, 31)
        else:
            q_end = date(cy, q_end_month + 1, 1) - timedelta(days=1)
        q_end_cap = min(q_end, ytd_last_day)
        q_start_prev = q_start.replace(year=py)
        try:
            q_end_prev = date(py, q_end_cap.month, q_end_cap.day)
        except ValueError:
            q_end_prev = q_end_cap.replace(year=py, day=28)
        qi_actual = invest_range(invest_daily, q_start, q_end_cap)
        qi_prev = invest_range(invest_daily, q_start_prev, q_end_prev)
        quarter_rows.append({
            'label': ql,
            'leads': total,
            'invest': {'actual': qi_actual, 'prev': qi_prev}
        })

    # --- Months ---
    month_rows = []
    for mn in range(1, 13):
        md = leads['months'].get(mn, {})
        total = md.get('TOTAL', {})
        if not total.get('actual') and not total.get('mtd'):
            continue
        m_start = date(cy, mn, 1)
        if mn == 12:
            m_end = date(cy, 12, 31)
        else:
            m_end = date(cy, mn + 1, 1) - timedelta(days=1)
        m_end_cap = min(m_end, ytd_last_day)
        m_start_prev = m_start.replace(year=py)
        try:
            m_end_prev = date(py, m_end_cap.month, m_end_cap.day)
        except ValueError:
            m_end_prev = m_end_cap.replace(year=py, day=28)
        mi_actual = invest_range(invest_daily, m_start, m_end_cap)
        mi_prev = invest_range(invest_daily, m_start_prev, m_end_prev)
        month_rows.append({
            'label': MONTH_SHORT[mn - 1],
            'leads': total,
            'invest': {'actual': mi_actual, 'prev': mi_prev}
        })

    # --- Weeks ---
    week_rows = []
    for w in leads['weeks']:
        total = w.get('TOTAL', {})
        if not total.get('actual'):
            continue
        wi_actual = inv_for_range(w['_desde'], w['_hasta'], cy)
        wi_prev = inv_for_range(w['_desde'], w['_hasta'], py)
        week_rows.append({
            'label': w['_label'],
            'leads': total,
            'invest': {'actual': wi_actual, 'prev': wi_prev}
        })

    # --- Cycles ---
    cycle_rows = []
    for c in leads['cycles']:
        total = c.get('TOTAL', {})
        if not total.get('actual'):
            continue
        ci_actual = inv_for_range(c['_desde'], c['_hasta'], cy)
        ci_prev = inv_for_range(c['_desde'], c['_hasta'], py)
        cycle_rows.append({
            'label': c['_label'],
            'leads': total,
            'invest': {'actual': ci_actual, 'prev': ci_prev}
        })

    return {
        'sources': leads['sources'],
        'tables': {
            'annual': [annual_row],
            'quarters': quarter_rows,
            'months': month_rows,
            'weeks': week_rows,
            'cycles': cycle_rows
        }
    }


def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <co_csv> <mx_csv> <invest_json> <output>")
        sys.exit(1)

    co_csv, mx_csv, inv_json, output = sys.argv[1:]
    co = parse_sheet(co_csv, SOURCES_CO)
    mx = parse_sheet(mx_csv, SOURCES_MX)
    mx = subtract_source(mx, 'Propiedades')
    inv = parse_invest_daily(inv_json)

    data = {
        'updated': date.today().isoformat(),
        'current_year': date.today().year,
        'CO': build_country(co, inv['CO']),
        'MX': build_country(mx, inv['MX'])
    }

    with open(output, 'w') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    print(f"OK: {output} ({len(json.dumps(data)):,} bytes)")


if __name__ == '__main__':
    main()
