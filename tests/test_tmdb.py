import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# Match the other suites: run standalone without needing PYTHONPATH set.
PLUGIN_ROOT = Path(__file__).resolve().parents[1]
if str(PLUGIN_ROOT) not in sys.path:
    sys.path.insert(0, str(PLUGIN_ROOT))

from bridge.python import tmdb


class TmdbTests(unittest.TestCase):
    def test_configuration_is_validated_and_saved_privately(self):
        token = "a" * 64
        with tempfile.TemporaryDirectory() as config_dir, patch.object(
            tmdb, "CONFIG_DIR", Path(config_dir)
        ), patch.object(tmdb, "CONFIG_PATH", Path(config_dir) / "tmdb.json"), patch.object(
            tmdb, "_request", return_value={"images": {}}
        ) as request:
            result = tmdb.configure(token)
            mode = (Path(config_dir) / "tmdb.json").stat().st_mode & 0o777

        self.assertTrue(result["configured"])
        self.assertEqual(mode, 0o600)
        request.assert_called_once_with("/configuration", token=token, cache=False)

    def test_enrichment_normalizes_cast_crew_and_episode_plots(self):
        details = {
            "overview": "Series plot",
            "tagline": "A demo",
            "aggregate_credits": {
                "cast": [{"id": 1, "name": "Actor", "roles": [{"character": "Hero"}], "profile_path": "/a.jpg"}],
                "crew": [{"id": 2, "name": "Writer", "jobs": [{"job": "Writer"}], "profile_path": "/w.jpg"}],
            },
        }
        season = {
            "episodes": [{
                "episode_number": 3, "name": "The Test", "overview": "Episode plot",
                "air_date": "2026-08-26", "runtime": 52, "vote_average": 8.4,
                "still_path": "/still.jpg",
            }]
        }

        def fake_request(path, *_args, **_kwargs):
            return season if "/season/" in path else details

        with patch.object(tmdb, "_request", side_effect=fake_request):
            result = tmdb.enrich("series|tmdb:108978", "series", 4)

        self.assertEqual(result["tmdbId"], "108978")
        self.assertEqual(result["cast"][0]["role"], "Hero")
        self.assertEqual(result["crew"][0]["role"], "Writer")
        self.assertEqual(result["episodes"][0]["overview"], "Episode plot")
        self.assertEqual(result["episodes"][0]["still"], "https://image.tmdb.org/t/p/w300/still.jpg")

    def test_imdb_id_can_be_resolved_to_tmdb(self):
        with patch.object(tmdb, "_request", return_value={"tv_results": [{"id": 42}]}):
            self.assertEqual(tmdb._media_parts("series|tt1234567", "series"), ("tv", "42"))

    def test_cinematic_home_normalizes_curated_sections(self):
        def fake_request(path, *_args, **_kwargs):
            is_tv = path.startswith("/tv/")
            return {"results": [{
                "id": 42 if is_tv else 7,
                "media_type": "tv" if is_tv else "movie",
                "name": "Example Show" if is_tv else None,
                "title": None if is_tv else "Example Film",
                "first_air_date": "2026-01-02" if is_tv else None,
                "release_date": None if is_tv else "2025-03-04",
                "vote_average": 8.26,
                "poster_path": "/poster.jpg",
                "backdrop_path": "/backdrop.jpg",
                "overview": "A cinematic example.",
            }]}

        with patch.object(tmdb, "_request", side_effect=fake_request):
            result = tmdb.home()

        self.assertEqual(result["sections"]["movies"][0]["id"], "movie|tmdb:7")
        self.assertEqual(result["sections"]["television"][0]["id"], "series|tmdb:42")
        self.assertTrue(result["hero"]["backdrop"].endswith("/w1280/backdrop.jpg"))

    def test_spotlight_returns_a_rotation_of_titles_with_artwork(self):
        trending = [
            {"id": 1, "media_type": "movie", "title": "No Art", "poster_path": "/p.jpg"},
        ] + [
            {"id": index, "media_type": "movie", "title": f"Slide {index}",
             "backdrop_path": f"/backdrop{index}.jpg"}
            for index in range(2, 12)
        ]

        def fake_request(path, *_args, **_kwargs):
            return {"results": trending} if path == "/trending/all/week" else {"results": []}

        with patch.object(tmdb, "_request", side_effect=fake_request):
            result = tmdb.home()

        heroes = result["heroes"]
        self.assertEqual(len(heroes), tmdb.HERO_ROTATION_LIMIT)
        # Every slide must be distinct, or the spotlight would appear stuck.
        self.assertEqual(len({hero["id"] for hero in heroes}), len(heroes))
        # A title with no backdrop must never become a slide.
        self.assertTrue(all(hero["backdrop"] for hero in heroes))
        self.assertTrue(all(hero["title"] != "No Art" for hero in heroes))
        # The single-hero field stays in sync for older callers.
        self.assertEqual(result["hero"]["id"], heroes[0]["id"])


class PersonTests(unittest.TestCase):
    def test_filmography_is_ranked_and_deduplicated(self):
        payload = {
            "name": "Example Actor",
            "profile_path": "/face.jpg",
            "known_for_department": "Acting",
            "combined_credits": {
                "cast": [
                    {"id": 1, "media_type": "movie", "title": "Obscure",
                     "vote_count": 12, "character": "Extra"},
                    {"id": 2, "media_type": "movie", "title": "Famous",
                     "vote_count": 9000, "character": "Lead"},
                    {"id": 2, "media_type": "movie", "title": "Famous",
                     "vote_count": 9000, "character": "Lead (duplicate credit)"},
                    {"id": 3, "media_type": "person", "title": "Not A Title",
                     "vote_count": 5000},
                ]
            },
        }
        with patch.object(tmdb, "_request", return_value=payload):
            result = tmdb.person("287")

        titles = [work["title"] for work in result["works"]]
        self.assertEqual(titles, ["Famous", "Obscure"])   # best known first
        self.assertNotIn("Not A Title", titles)           # non-media dropped
        self.assertEqual(result["works"][0]["role"], "Lead")
        self.assertTrue(result["image"].endswith("/w185/face.jpg"))

    def test_person_id_must_be_numeric(self):
        for bad in ("", "abc", "../../etc/passwd", "1" * 13):
            with self.assertRaises(ValueError):
                tmdb.person(bad)


class RelatedTitlesTests(unittest.TestCase):
    def test_recommendations_lead_similar_fills_in_and_self_is_excluded(self):
        def meta(i, name, poster="/p.jpg"):
            return {"id": i, "media_type": "tv", "name": name,
                    "first_air_date": "2020-01-01", "poster_path": poster,
                    "backdrop_path": "/b.jpg", "vote_average": 8.0}

        payload = {
            "name": "Anchor",
            "recommendations": {"results": [meta(2, "Rec One"), meta(3, "Rec Two")]},
            "similar": {"results": [
                meta(3, "Rec Two"),          # duplicate across both blocks
                meta(1, "Anchor"),           # the title itself
                meta(4, "Sim One"),
                meta(5, "No Art", poster=None),
            ]},
        }
        related = tmdb._related_titles(payload, "tv", "series|tmdb:1")
        titles = [r["title"] for r in related]

        self.assertEqual(titles, ["Rec One", "Rec Two", "Sim One"])
        self.assertNotIn("Anchor", titles)      # never recommends itself
        self.assertNotIn("No Art", titles)      # blank cards are dropped
        self.assertEqual([r["relation"] for r in related],
                         ["recommendations", "recommendations", "similar"])

    def test_related_list_is_capped(self):
        many = {"results": [
            {"id": i, "media_type": "tv", "name": f"S{i}", "first_air_date": "2020-01-01",
             "poster_path": "/p.jpg", "vote_average": 7.0} for i in range(2, 80)]}
        related = tmdb._related_titles({"recommendations": many}, "tv", "series|tmdb:1")
        self.assertEqual(len(related), tmdb.RELATED_LIMIT)


if __name__ == "__main__":
    unittest.main()
