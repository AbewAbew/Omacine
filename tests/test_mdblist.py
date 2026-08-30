import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PLUGIN_ROOT = Path(__file__).resolve().parents[1]
if str(PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(PLUGIN_ROOT))

from bridge.python import mdblist


SAMPLE = {
    "title": "Fight Club",
    "ratings": [
        {"source": "imdb", "value": 8.8, "score": 88, "votes": 2300000},
        {"source": "metacritic", "value": 67, "score": 67, "votes": 35},
        {"source": "tomatoes", "value": 79, "score": 79, "votes": 0},
        {"source": "popcorn", "value": 96, "score": 96, "votes": 0},
        {"source": "trakt", "value": 88, "score": 88, "votes": 0},
        {"source": "letterboxd", "value": 4.2, "score": 84, "votes": 0},
        {"source": "unknown-source", "value": 5, "score": 5},
    ],
}


class MdblistTests(unittest.TestCase):
    def test_all_sources_are_normalized(self):
        with patch.object(mdblist, "_fetch", return_value=SAMPLE):
            r = mdblist.ratings("movie|tmdb:550")
        self.assertTrue(r["found"])
        self.assertEqual(r["tomatoes"], 79)
        self.assertTrue(r["tomatoesFresh"])          # >= 60
        self.assertEqual(r["metacritic"], 67)
        self.assertEqual(r["metacriticBand"], "high")
        self.assertEqual(r["trakt"], 88)
        self.assertEqual(r["letterboxd"], 4.2)       # kept out of 5, not rescaled
        self.assertNotIn("unknown-source", r["sources"])
        # MDbList calls the Rotten Tomatoes audience score "popcorn".
        self.assertEqual(r["tomatoesAudience"], 96)

    def test_our_id_shapes_map_to_mdblist_paths(self):
        self.assertEqual(mdblist._media_parts("series|tmdb:108978"), ("show", "108978", "tmdb"))
        self.assertEqual(mdblist._media_parts("movie|tmdb:550"), ("movie", "550", "tmdb"))
        self.assertEqual(mdblist._media_parts("108978", "series"), ("show", "108978", "tmdb"))
        # Cinemeta and several other Stremio addons carry IMDb ids rather than
        # TMDB ones, and MDbList indexes both under different path prefixes.
        self.assertEqual(mdblist._media_parts("series|tt36303968"), ("show", "tt36303968", "imdb"))
        self.assertEqual(mdblist._media_parts("tt9288030"), ("movie", "tt9288030", "imdb"))
        # "tt1" is too short to be a real IMDb id, so it is still rejected.
        for bad in ("", "series|imdb:tt1"):
            with self.assertRaises(ValueError):
                mdblist._media_parts(bad)

    def test_missing_scores_are_none_not_zero(self):
        with patch.object(mdblist, "_fetch", return_value={"ratings": [
                {"source": "imdb", "value": 8.0, "score": 80},
                {"source": "tomatoes", "value": None, "score": None},
        ]}):
            r = mdblist.ratings("movie|tmdb:550")
        self.assertIsNone(r["tomatoes"])
        self.assertIsNone(r["metacritic"])

    def test_rotten_and_mixed_bands(self):
        with patch.object(mdblist, "_fetch", return_value={"ratings": [
                {"source": "tomatoes", "value": 31, "score": 31},
                {"source": "metacritic", "value": 45, "score": 45},
        ]}):
            r = mdblist.ratings("movie|tmdb:1")
        self.assertFalse(r["tomatoesFresh"])
        self.assertEqual(r["metacriticBand"], "mixed")

    def test_empty_payload_is_not_an_error(self):
        with patch.object(mdblist, "_fetch", return_value={"ratings": []}):
            self.assertFalse(mdblist.ratings("movie|tmdb:1")["found"])

    def test_key_validated_and_stored_private(self):
        with tempfile.TemporaryDirectory() as d, \
             patch.object(mdblist, "CONFIG_DIR", Path(d)), \
             patch.object(mdblist, "CONFIG_PATH", Path(d) / "mdblist.json"), \
             patch.object(mdblist.net, "get_bytes", return_value=b'{"username":"x"}'):
            mdblist.configure("abcdef123456")
            self.assertEqual((Path(d) / "mdblist.json").stat().st_mode & 0o777, 0o600)
        for bad in ("", "short", "has space", "x" * 200):
            with self.assertRaises(ValueError):
                mdblist._validate_key(bad)

    def test_bad_key_never_replaces_a_good_one(self):
        with tempfile.TemporaryDirectory() as d, \
             patch.object(mdblist, "CONFIG_DIR", Path(d)), \
             patch.object(mdblist, "CONFIG_PATH", Path(d) / "mdblist.json"), \
             patch.object(mdblist.net, "get_bytes", side_effect=RuntimeError("HTTP 403")):
            with self.assertRaises(RuntimeError):
                mdblist.configure("abcdef123456")
            self.assertFalse((Path(d) / "mdblist.json").exists())


    def test_auth_errors_are_translated_and_never_leak_the_key(self):
        # A rejected key answers 403 (not 401), and the message must not carry
        # the URL, which contains ?apikey=.
        for code in ("HTTP 401", "HTTP 403"):
            message = mdblist._auth_message(code)
            self.assertIn("rejected that API key", message)
            self.assertNotIn("apikey", message)
        self.assertIn("rate limit", mdblist._auth_message("HTTP 429"))


if __name__ == "__main__":
    unittest.main()
