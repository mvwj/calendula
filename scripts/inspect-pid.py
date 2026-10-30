"""Download and inspect the public PID timetable without sending private trip data."""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request
import zipfile

PUBLIC_URL = "https://data.pid.cz/PID_GTFS.zip"
MAX_BYTES = 150 * 1024 * 1024
ROOT = Path(__file__).resolve().parent.parent

def read_table(archive, name):
    with archive.open(name) as stream:
        yield from csv.DictReader(io.TextIOWrapper(stream, encoding="utf-8-sig", newline=""))

def inspect(target):
    with zipfile.ZipFile(target) as archive:
        names = set(archive.namelist())
        needed = {"stops.txt", "routes.txt", "trips.txt", "stop_times.txt"}
        if not needed <= names:
            raise ValueError("Missing required GTFS tables")
        if sum(item.file_size for item in archive.infolist()) > 2 * 1024**3:
            raise ValueError("Uncompressed dataset exceeds the inspection limit")
        stops = list(read_table(archive, "stops.txt"))
        routes = list(read_table(archive, "routes.txt"))
        trips = sum(1 for _ in read_table(archive, "trips.txt"))
        feeds = list(read_table(archive, "feed_info.txt")) if "feed_info.txt" in names else []
        agencies = list(read_table(archive, "agency.txt")) if "agency.txt" in names else []
        dates = set()
        if "calendar_dates.txt" in names:
            dates.update(row["date"] for row in read_table(archive, "calendar_dates.txt"))
        if "calendar.txt" in names:
            for row in read_table(archive, "calendar.txt"):
                dates.update([row["start_date"], row["end_date"]])
        after_midnight = 0
        rows = 0
        for row in read_table(archive, "stop_times.txt"):
            rows += 1
            if int((row.get("departure_time") or "00:00:00").split(":")[0]) >= 24:
                after_midnight += 1
        return {
            "source": PUBLIC_URL,
            "checked_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            "compressed_bytes": target.stat().st_size,
            "uncompressed_bytes": sum(item.file_size for item in archive.infolist()),
            "tables": sorted(names),
            "agency": agencies,
            "feed_info": feeds,
            "feed_coverage_start": feeds[0].get("feed_start_date") if feeds else None,
            "feed_coverage_end": feeds[0].get("feed_end_date") if feeds else None,
            "service_date_min": min(dates) if dates else None,
            "service_date_max": max(dates) if dates else None,
            "stop_count": len(stops),
            "route_count": len(routes),
            "trip_count": trips,
            "stop_time_count": rows,
            "stop_times_after_24h": after_midnight,
            "route_types": sorted({row["route_type"] for row in routes}),
            "sample_stops": [row for row in stops if row["stop_name"] in {"Dejvická", "Můstek", "Muzeum"}][:8],
            "limitations": "Inspection only: does not validate all GTFS semantics or calculate real-time delays."
        }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true", help="Download a common public dataset, no itinerary request")
    args = parser.parse_args()
    output = ROOT / "output" / "pid"
    output.mkdir(parents=True, exist_ok=True)
    target = output / "PID_GTFS.zip"
    if args.download:
        request = urllib.request.Request(PUBLIC_URL)
        temporary = output / "PID_GTFS.download"
        try:
            with urllib.request.urlopen(request, timeout=30) as response, temporary.open("wb") as stream:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_BYTES:
                        raise ValueError("Public dataset exceeds the download limit")
                    stream.write(chunk)
            with zipfile.ZipFile(temporary) as archive:
                if archive.testzip() is not None:
                    raise ValueError("Dataset checksum failed")
            temporary.replace(target)
            print(f"Downloaded {total:,} bytes of public city data", flush=True)
        finally:
            if temporary.exists():
                temporary.unlink()
    if not target.exists():
        raise FileNotFoundError("Run with --download first")
    result = inspect(target)
    (output / "inspection.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key not in {"tables", "sample_stops", "agency", "feed_info"}}, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
