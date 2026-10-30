"""Offline feasibility proof: a scheduled, direct metro journey from a PID ZIP.

Not the production router: no transfers, street walking, delays or accessibility.
Origin/destination and time are used locally; this script has no network calls.
"""
import argparse
import csv
from datetime import date
import io
import json
from pathlib import Path
import unicodedata
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def rows(archive, name):
    with archive.open(name) as stream:
        yield from csv.DictReader(io.TextIOWrapper(stream, encoding="utf-8-sig", newline=""))

def active_services(calendar, exceptions, service_day):
    stamp = service_day.strftime("%Y%m%d")
    weekday = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"][service_day.weekday()]
    result = {row["service_id"] for row in calendar if row["start_date"] <= stamp <= row["end_date"] and row[weekday] == "1"}
    for row in exceptions:
        if row["date"] == stamp:
            if row["exception_type"] == "1":
                result.add(row["service_id"])
            elif row["exception_type"] == "2":
                result.discard(row["service_id"])
    return result

def seconds(value):
    h, m, s = map(int, value.split(":"))
    if h < 0 or not 0 <= m < 60 or not 0 <= s < 60:
        raise ValueError("Invalid GTFS time")
    return h * 3600 + m * 60 + s

def clock(value):
    return f"{value // 3600:02}:{value // 60 % 60:02}:{value % 60:02}"

def normalized(value):
    return "".join(c for c in unicodedata.normalize("NFKD", value).casefold() if not unicodedata.combining(c))

def latest_direct(trip_rows, origins, destinations, target):
    best = None
    # A full trip is sorted by stop_sequence before scanning; a later origin
    # must never be connected to an earlier destination in the same trip.
    for trip_id, stop_times in trip_rows.items():
        boarded = None
        for row in sorted(stop_times, key=lambda item: int(item["stop_sequence"])):
            arrival, departure = seconds(row["arrival_time"]), seconds(row["departure_time"])
            if row["stop_id"] in destinations and row.get("drop_off_type", "0") == "0" and boarded and arrival <= target:
                candidate = {"trip_id": trip_id, "from_stop_id": boarded["stop_id"], "to_stop_id": row["stop_id"], "departure_seconds": seconds(boarded["departure_time"]), "arrival_seconds": arrival}
                if best is None or candidate["departure_seconds"] > best["departure_seconds"]:
                    best = candidate
            if row["stop_id"] in origins and row.get("pickup_type", "0") == "0":
                boarded = row
    return best

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="origin", default="Dejvicka")
    parser.add_argument("--to", dest="destination", default="Muzeum")
    parser.add_argument("--date", default="2026-10-03")
    parser.add_argument("--arrive", default="10:00")
    parser.add_argument("--file", type=Path, default=ROOT / "output/pid/PID_GTFS.zip")
    args = parser.parse_args()
    service_day = date.fromisoformat(args.date)
    target = seconds(args.arrive + ":00" if len(args.arrive) == 5 else args.arrive)
    with zipfile.ZipFile(args.file) as archive:
        feed = list(rows(archive, "feed_info.txt"))[0]
        stamp = service_day.strftime("%Y%m%d")
        if not feed["feed_start_date"] <= stamp <= feed["feed_end_date"]:
            raise ValueError("Requested date is outside feed_info coverage")
        stops = {row["stop_id"]: row for row in rows(archive, "stops.txt")}
        origins = {key for key, row in stops.items() if normalized(row["stop_name"]) == normalized(args.origin)}
        destinations = {key for key, row in stops.items() if normalized(row["stop_name"]) == normalized(args.destination)}
        if not origins or not destinations:
            raise ValueError("Station name not found in this feed")
        active = active_services(rows(archive, "calendar.txt"), rows(archive, "calendar_dates.txt"), service_day)
        routes = {row["route_id"]: row for row in rows(archive, "routes.txt") if row["route_type"] == "1"}
        trips = {row["trip_id"]: row for row in rows(archive, "trips.txt") if row["service_id"] in active and row["route_id"] in routes}
        trip_rows = {key: [] for key in trips}
        for row in rows(archive, "stop_times.txt"):
            if row["trip_id"] in trip_rows:
                trip_rows[row["trip_id"]].append(row)
    result = latest_direct(trip_rows, origins, destinations, target)
    if result is None:
        raise ValueError("No direct metro journey in the supported proof scope")
    trip = trips[result["trip_id"]]
    route = routes[trip["route_id"]]
    result.update({"date": args.date, "time_zone": "Europe/Prague", "origin": stops[result["from_stop_id"]]["stop_name"], "destination": stops[result["to_stop_id"]]["stop_name"], "line": route["route_short_name"], "headsign": trip.get("trip_headsign"), "departure": clock(result["departure_seconds"]), "arrival": clock(result["arrival_seconds"]), "arrive_by": clock(target), "duration_minutes": (result["arrival_seconds"] - result["departure_seconds"]) / 60, "quality": "scheduled-direct-metro-proof", "limitations": "No street walking, transfers, station access, real-time delays or platform accessibility. Service-day wall times only; DST and previous-service-day integration remain production work."})
    output = ROOT / "output/pid/direct-route.json"
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=True, indent=2))

if __name__ == "__main__":
    main()
