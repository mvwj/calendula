"""Build a bounded native direct-metro prototype index from the verified PID ZIP."""
import gzip
import json
from datetime import datetime, timedelta
from pathlib import Path
import zipfile
from pid_direct_route import rows, active_services, seconds

ROOT = Path(__file__).resolve().parent.parent
with zipfile.ZipFile(ROOT / 'output/pid/PID_GTFS.zip') as z:
    info = list(rows(z, 'feed_info.txt'))[0]
    first = datetime.strptime(info['feed_start_date'], '%Y%m%d').date()
    last = datetime.strptime(info['feed_end_date'], '%Y%m%d').date()
    calendar, exceptions = list(rows(z, 'calendar.txt')), list(rows(z, 'calendar_dates.txt'))
    days = [first + timedelta(days=i) for i in range((last - first).days + 1)]
    active = [active_services(calendar, exceptions, day) for day in days]
    routes = {r['route_id']: r for r in rows(z, 'routes.txt') if r['route_type'] == '1'}
    trips = {r['trip_id']: r for r in rows(z, 'trips.txt') if r['route_id'] in routes}
    times = {key: [] for key in trips}
    for r in rows(z, 'stop_times.txt'):
        if r['trip_id'] in times:
            times[r['trip_id']].append([r['stop_id'], int(r['stop_sequence']), seconds(r['arrival_time']), seconds(r['departure_time']), int(r.get('pickup_type') or 0), int(r.get('drop_off_type') or 0)])
    used = {t[0] for values in times.values() for t in values}
    stops = {r['stop_id']: r['stop_name'] for r in rows(z, 'stops.txt') if r['stop_id'] in used}
    result = {'start': first.isoformat(), 'end': last.isoformat(), 'source': 'PID / ROPID, CC BY 4.0', 'stops': stops,
              'trips': [[key, routes[r['route_id']]['route_short_name'], r.get('trip_headsign', ''), sum((1 << i) for i, values in enumerate(active) if r['service_id'] in values), sorted(times[key], key=lambda t: t[1])] for key, r in trips.items()]}
dest = ROOT / 'apps/calendula/assets/metro.json.gz'
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(gzip.compress(json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode('utf-8'), mtime=0))
print(json.dumps({'trips': len(trips), 'stops': len(stops), 'compressed_bytes': dest.stat().st_size, 'coverage': [result['start'], result['end']]}))
