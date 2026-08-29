import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PLUGIN_ROOT = Path(__file__).resolve().parents[1]
if str(PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(PLUGIN_ROOT))

from bridge.python import introdb


def payload(start, end, submissions=3):
    import json
    return json.dumps({"start_sec": start, "end_sec": end,
                       "submission_count": submissions, "confidence": 1}).encode()


class IntroDbTests(unittest.TestCase):
    def _isolated(self):
        d = tempfile.TemporaryDirectory()
        return d, patch.object(introdb, "CACHE_DIR", Path(d.name))

    def test_a_plausible_intro_is_returned(self):
        d, cache = self._isolated()
        with d, cache, patch.object(introdb.net, "get_bytes", return_value=payload(40, 95)):
            r = introdb.intro("tt9288030", 1, 1)
        self.assertTrue(r["found"])
        self.assertEqual((r["start"], r["end"], r["length"]), (40.0, 95.0, 55.0))
        self.assertEqual(r["submissions"], 3)

    def test_implausible_windows_are_rejected(self):
        # A 3-second "intro" is a title card; a 10-minute one is bad data; and
        # an intro does not start 20 minutes into the episode.
        for start, end, why in ((40, 43, "too short"),
                                (40, 700, "too long"),
                                (1200, 1260, "starts too late")):
            d, cache = self._isolated()
            with d, cache, patch.object(introdb.net, "get_bytes", return_value=payload(start, end)):
                self.assertFalse(introdb.intro("tt9288030", 1, 1)["found"], why)

    def test_a_miss_is_not_an_error(self):
        d, cache = self._isolated()
        with d, cache, patch.object(introdb.net, "get_bytes",
                                    side_effect=RuntimeError("HTTP 404")):
            self.assertFalse(introdb.intro("tt9288030", 1, 1)["found"])

    def test_real_transport_errors_still_raise(self):
        d, cache = self._isolated()
        with d, cache, patch.object(introdb.net, "get_bytes",
                                    side_effect=RuntimeError("HTTP 500")):
            with self.assertRaises(RuntimeError):
                introdb.intro("tt9288030", 1, 1)

    def test_results_are_cached_so_playback_does_not_refetch(self):
        d, cache = self._isolated()
        with d, cache, patch.object(introdb.net, "get_bytes",
                                    return_value=payload(40, 95)) as fetch:
            introdb.intro("tt9288030", 1, 1)
            introdb.intro("tt9288030", 1, 1)
            self.assertEqual(fetch.call_count, 1)

    def test_inputs_are_validated(self):
        for bad in ("", "9288030", "../../etc/passwd", "tt" + "9" * 20):
            with self.assertRaises(ValueError):
                introdb.intro(bad, 1, 1)
        for season, episode in ((1, 0), (-1, 1), ("x", 1)):
            with self.assertRaises(ValueError):
                introdb.intro("tt9288030", season, episode)


if __name__ == "__main__":
    unittest.main()
