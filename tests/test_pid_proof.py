import sys
from pathlib import Path
import unittest
from datetime import date
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from pid_direct_route import active_services, seconds, latest_direct

def stop(name, seq, arrival, departure=None, pickup="0", dropoff="0"):
    return {"stop_id": name, "stop_sequence": str(seq), "arrival_time": arrival, "departure_time": departure or arrival, "pickup_type": pickup, "drop_off_type": dropoff}

class PidProofTests(unittest.TestCase):
    def test_calendar_exception_overrides_weekday(self):
        row = {"service_id": "a", "start_date": "20261003", "end_date": "20261016", "saturday": "1"}
        exceptions = [{"date": "20261003", "service_id": "a", "exception_type": "2"}, {"date": "20261003", "service_id": "b", "exception_type": "1"}]
        self.assertEqual(active_services([row], exceptions, date(2026,10,3)), {"b"})

    def test_night_gtfs_times_are_not_modulo_24(self):
        self.assertEqual(seconds("25:10:00"), 90600)

    def test_arrive_by_selects_latest_feasible_departure(self):
        trips = {"early": [stop("A",1,"09:20:00"),stop("B",2,"09:40:00")], "latest": [stop("A",1,"09:35:00"),stop("B",2,"09:55:00")], "late": [stop("A",1,"09:45:00"),stop("B",2,"10:05:00")]}
        self.assertEqual(latest_direct(trips,{"A"},{"B"},seconds("10:00:00"))["trip_id"], "latest")

    def test_no_boarding_or_dropoff_is_respected(self):
        for rows in [[stop("A",1,"09:30:00",pickup="1"),stop("B",2,"09:50:00")], [stop("A",1,"09:30:00"),stop("B",2,"09:50:00",dropoff="1")]]:
            self.assertIsNone(latest_direct({"trip":rows},{"A"},{"B"},seconds("10:00:00")))

    def test_no_backwards_travel_in_a_trip(self):
        self.assertIsNone(latest_direct({"trip":[stop("B",1,"09:30:00"),stop("A",2,"09:50:00")]},{"A"},{"B"},seconds("10:00:00")))

if __name__ == "__main__":
    unittest.main()
