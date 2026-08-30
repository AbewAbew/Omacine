"""The calendar is rebuilt from every followed show's metadata, which goes to
the network once that metadata expires. These cover the on-disk month so the
grid can paint before any of that happens."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge" / "python"))


def _load_main():
    spec = importlib.util.spec_from_file_location(
        "omamovie_cal_main", ROOT / "bridge" / "python" / "__main__.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["omamovie_cal_main"] = module
    spec.loader.exec_module(module)
    return module


class CalendarSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.main = _load_main()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.main._CALENDAR_SNAPSHOT_DIR = pathlib.Path(self.tmp.name) / "calendar-months"
        self.main._STATE_DIR = pathlib.Path(self.tmp.name)
        self.payload = {"month": "2026-08", "first": "2026-08-01", "last": "2026-08-31",
                        "today": "2026-08-30",
                        "days": [{"date": "2026-08-13", "entries": [{"title": "X"}]}],
                        "upcoming": []}

    def test_round_trip(self):
        self.main._save_calendar_snapshot("2026-08", self.payload)
        got = self.main._load_calendar_snapshot("2026-08")
        self.assertTrue(got["cached"])
        self.assertEqual(got["days"], self.payload["days"])
        self.assertEqual(got["month"], "2026-08")

    def test_months_do_not_share_a_file(self):
        # Paging back and forth must not re-derive a month already built.
        self.main._save_calendar_snapshot("2026-08", self.payload)
        other = dict(self.payload, month="2026-09", days=[])
        self.main._save_calendar_snapshot("2026-09", other)
        self.assertEqual(self.main._load_calendar_snapshot("2026-08")["days"],
                         self.payload["days"])
        self.assertEqual(self.main._load_calendar_snapshot("2026-09")["days"], [])

    def test_missing_month_reports_not_cached(self):
        got = self.main._load_calendar_snapshot("2030-01")
        self.assertFalse(got["cached"])

    def test_expired_snapshot_is_not_served(self):
        self.main._save_calendar_snapshot("2026-08", self.payload)
        path = self.main._calendar_snapshot_path("2026-08")
        stale = json.loads(path.read_text(encoding="utf-8"))
        stale["saved"] = int(time.time()) - self.main.CALENDAR_SNAPSHOT_MAX_AGE - 60
        path.write_text(json.dumps(stale), encoding="utf-8")
        self.assertFalse(self.main._load_calendar_snapshot("2026-08")["cached"])

    def test_malformed_month_is_rejected_both_ways(self):
        # The month reaches a file path, so it must never be free text.
        self.main._save_calendar_snapshot("../../escape", self.payload)
        self.assertFalse(self.main._load_calendar_snapshot("../../escape")["cached"])
        self.assertEqual(list(pathlib.Path(self.tmp.name).glob("**/*escape*")), [])

    def test_corrupt_file_is_not_fatal(self):
        self.main._CALENDAR_SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
        self.main._calendar_snapshot_path("2026-08").write_text("{not json", encoding="utf-8")
        self.assertFalse(self.main._load_calendar_snapshot("2026-08")["cached"])


if __name__ == "__main__":
    unittest.main()
