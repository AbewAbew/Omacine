from pathlib import Path
import json
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN_ROOT / "bridge" / "python"))

import stremio  # noqa: E402


class ResolverTests(unittest.TestCase):
    def test_expired_http_cache_is_removed_before_refetch(self):
        url = "https://catalog.example.test/catalog/movie/demo.json"
        with tempfile.TemporaryDirectory() as cache_dir, patch.object(
            stremio, "CACHE_DIR", Path(cache_dir)
        ), patch.object(stremio, "urlopen", side_effect=OSError("offline")):
            path = stremio._cache_path(url)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"metas": [{"id": "old"}]}), encoding="utf-8")
            old = time.time() - 3600
            os.utime(path, (old, old))
            stremio._MEM_CACHE.pop(url, None)
            with self.assertRaises(RuntimeError):
                stremio._get_json(url, ttl=60)
            self.assertFalse(path.exists())

    def test_abandoned_http_cache_is_pruned_without_touching_metadata(self):
        now = time.time()
        with tempfile.TemporaryDirectory() as cache_dir, patch.object(
            stremio, "CACHE_DIR", Path(cache_dir)
        ):
            http_path = Path(cache_dir) / ("a" * 64 + ".json")
            meta_path = Path(cache_dir) / "meta-series-demo.json"
            http_path.write_text("{}", encoding="utf-8")
            meta_path.write_text("{}", encoding="utf-8")
            old = now - stremio.HTTP_CACHE_MAX_AGE - 1
            os.utime(http_path, (old, old))
            os.utime(meta_path, (old, old))

            result = stremio._prune_http_cache(now)

            self.assertEqual(result["removed"], 1)
            self.assertFalse(http_path.exists())
            self.assertTrue(meta_path.exists())

    def test_discovery_series_preview_is_enriched_with_full_seasons(self):
        manifest_url = "https://meta.example.test/manifest.json"
        preview = {
            "id": "tt27846061", "type": "series", "name": "Ludwig",
            "moviedb_id": 243360, "videos": [],
        }
        full = {
            "id": "tmdb:243360", "type": "series", "name": "Ludwig",
            "imdb_id": "tt27846061",
            "videos": [
                {"id": "tt27846061:1:1", "season": 1, "episode": 1},
                {"id": "tt27846061:1:6", "season": 1, "episode": 6},
                {"id": "tt27846061:2:1", "season": 2, "episode": 1},
                {"id": "tt27846061:2:6", "season": 2, "episode": 6},
            ],
        }
        cfg = stremio.default_config()
        cfg["metadataManifest"] = ""
        cfg["addons"] = [{"name": "Metadata", "manifestUrl": manifest_url, "enabled": True}]
        requested = []

        def fake_get(url, **_kwargs):
            requested.append(url)
            if url == manifest_url:
                return {
                    "name": "Metadata",
                    "resources": [{"name": "meta", "types": ["series"], "idPrefixes": ["tmdb:"]}],
                    "types": ["series"],
                }
            if "/meta/series/tmdb:243360.json" in url:
                return {"meta": full}
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_recall_meta", return_value=preview
        ), patch.object(stremio, "_get_json", side_effect=fake_get), patch.object(
            stremio, "_remember_meta"
        ), patch.object(stremio, "_remember_resolved_ids"):
            details = stremio.details("series|tt27846061")

        self.assertEqual(details["seasons"]["seasons"], [{"se": 1, "maxEp": 6}, {"se": 2, "maxEp": 6}])
        self.assertTrue(any("/meta/series/tmdb:243360.json" in url for url in requested))

    def test_catalog_preview_does_not_replace_cached_episode_list(self):
        with tempfile.TemporaryDirectory() as cache_dir, patch.object(stremio, "CACHE_DIR", Path(cache_dir)):
            full = {
                "id": "tt1", "type": "series", "name": "Demo",
                "videos": [{"id": "tt1:1:1", "season": 1, "episode": 1}],
            }
            stremio._remember_meta(full)
            stremio._remember_meta({"id": "tt1", "type": "series", "name": "Demo Updated"})
            cached = stremio._recall_meta("series", "tt1")

        self.assertEqual(cached["name"], "Demo Updated")
        self.assertEqual(len(cached["videos"]), 1)

    def test_discovery_aggregates_catalogs_and_filters(self):
        manifest_url = "https://catalog.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["metadataManifest"] = ""
        cfg["builtinFreeMedia"] = False
        cfg["addons"] = [{"name": "Streaming Catalogs", "manifestUrl": manifest_url, "enabled": True}]

        def fake_get(url, **_kwargs):
            if url == manifest_url:
                return {
                    "name": "Streaming Catalogs",
                    "resources": ["catalog"],
                    "catalogs": [
                        {"type": "movie", "id": "demo", "name": "Demo Service"},
                        {"type": "series", "id": "demo", "name": "Demo Service"},
                    ],
                }
            if "/catalog/movie/demo.json" in url:
                return {"metas": [
                    {"id": "tt1", "type": "movie", "name": "Older Drama", "releaseInfo": "2022", "genres": ["Drama"], "imdbRating": "8.8"},
                    {"id": "tt2", "type": "movie", "name": "New Action", "releaseInfo": "2026", "genres": ["Action"], "imdbRating": "7.1"},
                ]}
            if "/catalog/series/demo.json" in url:
                return {"metas": [
                    {"id": "tt3", "type": "series", "name": "New Drama", "releaseInfo": "2025", "genres": ["Drama"], "imdbRating": "9.1"},
                ]}
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ), patch.object(stremio, "_remember_meta"):
            result = stremio.discover(genre="drama", sort="new")

        self.assertEqual([item["title"] for item in result["items"]], ["New Drama", "Older Drama"])
        self.assertEqual(result["items"][0]["provider"], "stremio")
        self.assertEqual(result["items"][0]["catalogName"], "Demo Service")
        self.assertEqual(len(result["catalogs"]), 1)

    def test_discovery_uses_skip_and_keeps_catalog_named_search(self):
        manifest_url = "https://catalog.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["metadataManifest"] = ""
        cfg["addons"] = [{"name": "Catalog", "manifestUrl": manifest_url, "enabled": True}]
        requested = []

        def fake_get(url, **_kwargs):
            requested.append(url)
            if url == manifest_url:
                return {
                    "name": "Catalog",
                    "resources": ["catalog"],
                    "catalogs": [{
                        "type": "movie", "id": "real-search", "name": "Search",
                        "extra": [{"name": "skip", "isRequired": False}],
                    }],
                }
            if "/catalog/movie/real-search/skip=24.json" in url:
                return {"metas": [{"id": "tt-page-2", "type": "movie", "name": "Page Two"}]}
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ), patch.object(stremio, "_remember_meta"):
            result = stremio.discover(limit=24, page=2)

        self.assertEqual([item["title"] for item in result["items"]], ["Page Two"])
        self.assertEqual(result["catalogs"][0]["name"], "Search")
        self.assertEqual(result["page"], 2)
        self.assertTrue(result["hasMore"])
        self.assertTrue(any("/skip=24.json" in url for url in requested))

    def test_stream_continuity_group_is_opaque(self):
        item = stremio._stream_item(
            {
                "url": "https://media.example.test/e1.mp4",
                "name": "1080p HEVC",
                "behaviorHints": {"bingeGroup": "show-pack-1080p-hevc"},
            },
            "Community Provider",
            stremio.DEFAULT_SERVER,
            addon_key="addon-one",
        )

        self.assertEqual(item["addonKey"], "addon-one")
        self.assertTrue(item["continuityGroup"])
        self.assertNotEqual(item["continuityGroup"], "show-pack-1080p-hevc")
        self.assertNotIn("show-pack", str(item))

    def test_exact_continuity_group_wins_before_peer_count(self):
        current = {
            "streamKind": "p2p", "addonKey": "addon-one", "continuityGroup": "group-a",
            "resolution": 1080, "mediaLabel": "HEVC", "peerCount": 10,
        }
        candidates = [
            {
                "resourceLink": "http://127.0.0.1:11480/other/0", "streamKind": "p2p",
                "addonKey": "addon-one", "continuityGroup": "group-b", "resolution": 1080,
                "mediaLabel": "HEVC", "peerCount": 500,
            },
            {
                "resourceLink": "http://127.0.0.1:11480/exact/0", "streamKind": "p2p",
                "addonKey": "addon-one", "continuityGroup": "group-a", "resolution": 720,
                "mediaLabel": "AVC", "peerCount": 2,
            },
        ]

        selected = stremio.select_continuation(current, candidates)

        self.assertEqual(selected["resourceLink"], candidates[1]["resourceLink"])
        self.assertEqual(selected["continuityMatch"], "exact")

    def test_continuity_fallback_stays_with_provider_and_format(self):
        current = {
            "streamKind": "direct", "addonKey": "addon-one", "continuityGroup": "",
            "resolution": 720, "mediaLabel": "HEVC",
        }
        candidates = [
            {"resourceLink": "https://other.test/e2", "streamKind": "direct", "addonKey": "addon-two", "resolution": 720, "mediaLabel": "HEVC", "peerCount": 999},
            {"resourceLink": "https://same.test/low", "streamKind": "direct", "addonKey": "addon-one", "resolution": 720, "mediaLabel": "HEVC", "peerCount": 5},
            {"resourceLink": "https://same.test/high", "streamKind": "direct", "addonKey": "addon-one", "resolution": 720, "mediaLabel": "HEVC", "peerCount": 25},
        ]

        selected = stremio.select_continuation(current, candidates)

        self.assertEqual(selected["resourceLink"], "https://same.test/high")
        self.assertEqual(selected["continuityMatch"], "format")
        self.assertIsNone(stremio.select_continuation(current, [candidates[0]]))

    def test_builtin_public_domain_resolver(self):
        cfg = stremio.default_config()
        cfg["addons"] = []
        cfg["resolverManifests"] = []
        with patch.object(stremio, "load_config", return_value=cfg):
            item = stremio.search("sintel")[0]
            self.assertEqual(item["id"], "movie|omamovie:catalog:sintel")
            streams = stremio.streams(item["id"])
        self.assertEqual(len(streams), 1)
        self.assertEqual(streams[0]["infoHash"], stremio.SINTEL_HASH)
        self.assertIn("Public Domain Demo", streams[0]["sourceLabel"])
        self.assertEqual(streams[0]["resolverProvenance"], "Public Domain Demo")

    def test_custom_series_resolver_preserves_episode(self):
        resolver_url = "https://example.test/resolver.json"
        addon_url = "https://media.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["builtinFreeResolver"] = False
        cfg["resolverManifests"] = [
            {"name": "Demo Bridge", "resolverUrl": resolver_url, "enabled": True}
        ]
        cfg["addons"] = [
            {"name": "Demo Streams", "manifestUrl": addon_url, "enabled": True}
        ]
        requested = []

        def fake_get(url, **_kwargs):
            requested.append(url)
            if url == resolver_url:
                return {
                    "schemaVersion": 1,
                    "id": "demo.bridge",
                    "name": "Demo Bridge",
                    "mappings": [
                        {"type": "series", "from": "catalog:show", "to": "archive:show"}
                    ],
                }
            if url == addon_url:
                return {
                    "id": "demo.streams",
                    "name": "Demo Streams",
                    "resources": ["stream"],
                    "idPrefixes": ["archive:"],
                }
            if "/stream/series/archive:show:2:3.json" in url:
                return {
                    "streams": [
                        {"url": "https://media.example.test/episode.mp4", "name": "Public demo 1080p"}
                    ]
                }
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ):
            streams = stremio.streams("series|catalog:show", 2, 3)

        self.assertEqual(len(streams), 1)
        self.assertEqual(streams[0]["sourceLabel"], "Demo Streams via Demo Bridge")
        self.assertEqual(streams[0]["resolverProvenance"], "Demo Bridge")
        self.assertTrue(any("/stream/series/archive:show:2:3.json" in url for url in requested))

    def test_stream_lookup_does_not_wait_for_separate_caption_lookup(self):
        addon_url = "https://media.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["builtinFreeMedia"] = False
        cfg["builtinFreeResolver"] = False
        cfg["resolverManifests"] = []
        cfg["addons"] = [{"name": "Demo Streams", "manifestUrl": addon_url, "enabled": True}]

        def fake_get(url, **_kwargs):
            if url == addon_url:
                return {
                    "id": "demo.streams", "name": "Demo Streams", "types": ["movie"],
                    "resources": [{"name": "stream", "types": ["movie"], "idPrefixes": ["tt"]}],
                }
            if "/stream/movie/tt0137523.json" in url:
                return {"streams": [{"url": "https://media.example.test/movie.mp4", "name": "1080p"}]}
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ), patch.object(stremio, "_recall_meta", return_value={}), patch.object(
            stremio, "_recall_resolved_ids", return_value=[]
        ), patch.object(stremio, "subtitles") as subtitles_mock:
            streams = stremio.streams("movie|tt0137523")

        self.assertEqual(len(streams), 1)
        subtitles_mock.assert_not_called()

    def test_addon_capability_routing(self):
        # Resource-level types and idPrefixes
        manifest_complex = {
            "id": "test.addon",
            "name": "Test Addon",
            "resources": [
                "catalog",
                {"name": "meta", "types": ["movie"], "idPrefixes": ["tmdb:"]},
                {"name": "stream", "types": ["movie", "series"], "idPrefixes": ["tt", "kitsu:"]},
            ],
            "types": ["movie", "series"],
        }
        self.assertTrue(stremio._addon_supports_resource(manifest_complex, "meta", "movie", "tmdb:123"))
        self.assertFalse(stremio._addon_supports_resource(manifest_complex, "meta", "series", "tmdb:123"))
        self.assertFalse(stremio._addon_supports_resource(manifest_complex, "meta", "movie", "tt1234567"))
        self.assertTrue(stremio._addon_supports_resource(manifest_complex, "stream", "series", "tt1234567:1:1"))
        self.assertTrue(stremio._addon_supports_resource(manifest_complex, "stream", "movie", "kitsu:99"))
        self.assertFalse(stremio._addon_supports_resource(manifest_complex, "stream", "series", "tmdb:123:1:1"))
        self.assertFalse(stremio._addon_supports_resource(manifest_complex, "subtitles", "movie", "tt1234567"))

    def test_dynamic_metadata_alias_extraction(self):
        meta_series = {
            "id": "tmdb:1436",
            "type": "series",
            "name": "Justified",
            "imdb_id": "tt1489428",
            "videos": [
                {"id": "tt1489428:1:1", "season": 1, "episode": 1, "name": "Fire in the Hole"},
                {"id": "tt1489428:1:2", "season": 1, "episode": 2, "name": "Riverbrook"},
            ],
        }
        aliases = stremio._extract_meta_aliases(meta_series, "series", "tmdb:1436", "TMDB Addon")
        alias_ids = [target for target, src in aliases]
        self.assertIn("tt1489428", alias_ids)
        self.assertEqual(aliases[0][1], "TMDB Addon")

        # Cinemeta style movie with moviedb_id
        meta_movie = {
            "id": "tt0137523",
            "type": "movie",
            "name": "Fight Club",
            "moviedb_id": 550,
        }
        aliases_cinemeta = stremio._extract_meta_aliases(meta_movie, "movie", "tt0137523", "Cinemeta")
        self.assertIn(("tmdb:550", "Cinemeta"), aliases_cinemeta)

    def test_dynamic_metadata_resolver_routes_to_stream_addon(self):
        meta_addon_url = "https://tmdb.example.test/manifest.json"
        stream_addon_url = "https://torrentio.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["builtinFreeResolver"] = False
        cfg["resolverManifests"] = []
        cfg["addons"] = [
            {"name": "TMDB Addon", "manifestUrl": meta_addon_url, "enabled": True},
            {"name": "Torrentio", "manifestUrl": stream_addon_url, "enabled": True},
        ]

        def fake_get(url, **_kwargs):
            if url == meta_addon_url:
                return {
                    "id": "tmdb.addon",
                    "name": "TMDB Addon",
                    "resources": [{"name": "meta", "types": ["series"], "idPrefixes": ["tmdb:"]}],
                    "types": ["series"],
                }
            if url == stream_addon_url:
                return {
                    "id": "torrentio.addon",
                    "name": "Torrentio",
                    "resources": [{"name": "stream", "types": ["series"], "idPrefixes": ["tt"]}],
                    "types": ["series"],
                }
            if "/meta/series/tmdb:1436.json" in url:
                return {
                    "meta": {
                        "id": "tmdb:1436",
                        "type": "series",
                        "name": "Justified",
                        "imdb_id": "tt1489428",
                        "videos": [{"id": "tt1489428:1:1", "season": 1, "episode": 1}],
                    }
                }
            if "/stream/series/tt1489428:1:1.json" in url:
                return {
                    "streams": [
                        {
                            "name": "Torrentio 1080p",
                            "title": "Justified.S01E01.1080p",
                            "infoHash": "0123456789abcdef0123456789abcdef01234567",
                            "fileIdx": 0,
                        }
                    ]
                }
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ), patch.object(stremio, "_recall_meta", return_value=None), patch.object(
            stremio, "_recall_resolved_ids", return_value=[]
        ):
            streams = stremio.streams("series|tmdb:1436", 1, 1)

        self.assertEqual(len(streams), 1)
        self.assertEqual(streams[0]["sourceLabel"], "IO Streams via TMDB Addon")
        self.assertEqual(streams[0]["resolverProvenance"], "TMDB Addon")
        self.assertEqual(streams[0]["resolvedId"], "tt1489428:1:1")

    def test_stream_display_metadata_is_neutral_and_discovery_is_eager(self):
        raw_hash = "0123456789abcdef0123456789abcdef01234567"
        item = stremio._stream_item(
            {
                "name": "Torrentio 1080p HEVC AAC",
                "title": f"42 seeds {raw_hash}",
                "infoHash": raw_hash,
                "fileIdx": 0,
                "sources": ["tracker:udp://custom.example.test:80/announce"],
            },
            "TorrentsDB via Torrentio",
            stremio.DEFAULT_SERVER,
        )

        self.assertIsNotNone(item)
        self.assertEqual(item["streamKind"], "p2p")
        self.assertEqual(item["sourceLabel"], "FastDB via IO Streams")
        self.assertEqual(item["peerCount"], 42)
        self.assertEqual(item["mediaLabel"], "AAC / HEVC")
        self.assertEqual(item["streamBadge"], "Cached Stream")
        self.assertNotIn(raw_hash, item["description"])
        self.assertNotRegex(item["name"].lower(), r"torrent(?:io|s)?")
        self.assertIn("tr=tracker%3Audp", item["resourceLink"])
        for source in stremio.FALLBACK_PEER_SOURCES:
            self.assertIn(source, stremio._peer_sources({"sources": []}, raw_hash))
        self.assertIn(f"dht:{raw_hash}", stremio._peer_sources({"sources": []}, raw_hash))

    def test_warm_stream_uses_head_then_priority_range(self):
        requests = []

        class FakeResponse:
            def __init__(self, method):
                self.headers = {"Content-Length": "200000000"}
                self.method = method
                self.remaining = 1048577 if method == "GET" else 0

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, size):
                count = min(size, self.remaining)
                self.remaining -= count
                return b"x" * count

        def fake_open(request, timeout):
            requests.append((request, timeout))
            return FakeResponse(request.get_method())

        with patch.object(stremio, "urlopen", side_effect=fake_open):
            result = stremio.warm_stream("http://127.0.0.1:11480/example/0")

        self.assertTrue(result["ready"])
        self.assertEqual(result["bytes"], 1048577)
        # HEAD for the length, then the head range, then the tail range that
        # carries the MKV seek index.
        self.assertEqual([request.get_method() for request, _timeout in requests], ["HEAD", "GET", "GET"])
        self.assertEqual(requests[1][0].get_header("Range"), "bytes=0-1048576")
        self.assertEqual(requests[1][0].get_header("Enginefs-prio"), "255")
        self.assertEqual(requests[2][0].get_header("Range"),
                         f"bytes={200000000 - stremio.TAIL_WARM_BYTES}-{200000000 - 1}")
        self.assertEqual(requests[2][0].get_header("Enginefs-prio"), "255")
        self.assertEqual(result["priorityWindowBytes"], 10000000)

    def test_warm_stream_also_fetches_the_tail(self):
        # An MKV keeps its Cues at the end. Warming only the head leaves the
        # one thing that blocks first frame un-fetched.
        ranges = []

        class FakeResponse:
            def __init__(self, method, length):
                self._method = method
                self.headers = {"Content-Length": str(length)}
                self._left = 0 if method == "HEAD" else 1 << 30

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, count):
                take = min(count, self._left)
                self._left -= take
                return b"x" * take

        def fake_open(request, timeout):
            rng = request.get_header("Range")
            if rng:
                ranges.append(rng)
            return FakeResponse(request.get_method(), 100 * 1024 * 1024)

        with patch.object(stremio, "urlopen", side_effect=fake_open):
            result = stremio.warm_stream("http://127.0.0.1:11480/example/0")

        total = 100 * 1024 * 1024
        tail = stremio.TAIL_WARM_BYTES
        self.assertEqual(ranges[0], "bytes=0-1048576")
        self.assertEqual(ranges[1], f"bytes={total - tail}-{total - 1}")
        self.assertTrue(result["tailReady"])
        self.assertTrue(result["tailAttempted"])
        self.assertEqual(result["tailBytes"], tail)
        self.assertEqual(result["tailExpectedBytes"], tail)

    def test_warm_stream_reports_an_unreachable_tail(self):
        # The real failure: head cached and instant, tail unavailable, so
        # playback never starts however high the cached percentage looks.
        class HeadOnly:
            def __init__(self, method):
                self._method = method
                self.headers = {"Content-Length": str(100 * 1024 * 1024)}
                self._left = 0 if method == "HEAD" else 1 << 30

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, count):
                take = min(count, self._left)
                self._left -= take
                return b"x" * take

        def fake_open(request, timeout):
            rng = request.get_header("Range") or ""
            if rng.startswith("bytes=0-"):
                return HeadOnly(request.get_method())
            if request.get_method() == "HEAD":
                return HeadOnly("HEAD")
            raise TimeoutError("tail never arrives")

        with patch.object(stremio, "urlopen", side_effect=fake_open):
            result = stremio.warm_stream("http://127.0.0.1:11480/example/0")

        self.assertTrue(result["ready"])          # head is fine
        self.assertFalse(result["tailReady"])     # the part that blocks start
        self.assertEqual(result["tailBytes"], 0)

    def test_partial_tail_is_not_reported_ready(self):
        # A first chunk can arrive while the actual end of file - where the
        # index lives - is still missing, so anything short of the whole
        # requested range counts as not ready.
        class Partial:
            def __init__(self, method, head):
                self.headers = {"Content-Length": str(100 * 1024 * 1024)}
                self._left = 0 if method == "HEAD" else (1 << 30 if head else 4096)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, count):
                take = min(count, self._left)
                self._left -= take
                return b"x" * take

        def fake_open(request, timeout):
            rng = request.get_header("Range") or ""
            return Partial(request.get_method(), rng.startswith("bytes=0-"))

        with patch.object(stremio, "urlopen", side_effect=fake_open):
            result = stremio.warm_stream("http://127.0.0.1:11480/example/0")

        self.assertEqual(result["tailBytes"], 4096)
        self.assertTrue(result["tailAttempted"])
        self.assertFalse(result["tailReady"])

    def test_warm_stream_skips_the_tail_on_a_tiny_file(self):
        # Nothing to split: head and tail would overlap.
        class Tiny:
            headers = {"Content-Length": "1024"}

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self, count):
                return b""

        with patch.object(stremio, "urlopen", side_effect=lambda r, timeout: Tiny()):
            result = stremio.warm_stream("http://127.0.0.1:11480/example/0")
        # Nothing was asked for, so this is "not applicable", not "missing".
        self.assertEqual(result["tailBytes"], 0)
        self.assertFalse(result["tailAttempted"])
        self.assertEqual(result["tailExpectedBytes"], 0)

    def test_release_stream_uses_the_engine_remove_route(self):
        raw_hash = "0123456789abcdef0123456789abcdef01234567"
        asked = []

        class FakeResponse:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_open(request, timeout):
            asked.append(request.full_url)
            return FakeResponse()

        with patch.object(stremio, "urlopen", side_effect=fake_open):
            result = stremio.release_stream(f"http://127.0.0.1:11480/{raw_hash}/2")

        self.assertTrue(result["released"])
        # /:id/destroy belongs to the HLS converter and answers 200 while
        # leaving the swarm running, so it must never be used here.
        self.assertEqual(asked, [f"http://127.0.0.1:11480/{raw_hash}/remove"])

    def test_release_stream_reports_failure_rather_than_raising(self):
        raw_hash = "0123456789abcdef0123456789abcdef01234567"

        with patch.object(stremio, "urlopen", side_effect=OSError("engine gone")):
            result = stremio.release_stream(f"http://127.0.0.1:11480/{raw_hash}/2")

        self.assertFalse(result["released"])

    def test_release_stream_refuses_non_local_targets(self):
        with self.assertRaises(ValueError):
            stremio.release_stream("http://example.com/0123456789abcdef0123456789abcdef01234567/2")

    def test_stream_status_returns_safe_connection_telemetry(self):
        raw_hash = "0123456789abcdef0123456789abcdef01234567"
        payload = {
            "infoHash": raw_hash,
            "peers": 7,
            "unchoked": 3,
            "connectionTries": 18,
            "downloadSpeed": 5242880,
            "downloaded": 12582912,
            "streamProgress": 0.031,
            "wires": [{"address": "192.0.2.1:1234"}],
        }
        requested = []

        class FakeResponse:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _size):
                import json

                return json.dumps(payload).encode("utf-8")

        def fake_open(request, timeout):
            requested.append((request.full_url, timeout))
            return FakeResponse()

        url = f"http://127.0.0.1:11480/{raw_hash}/0?tr=example"
        with patch.object(stremio, "urlopen", side_effect=fake_open):
            status = stremio.stream_status(url)

        self.assertEqual(requested[0][0], f"http://127.0.0.1:11480/{raw_hash}/0/stats.json")
        self.assertEqual(status, {
            "available": True,
            "sources": 7,
            "active": 3,
            "attempts": 18,
            "receiveRate": 5242880,
            "downloaded": 12582912,
            "cachedProgress": 0.031,
        })
        self.assertNotIn(raw_hash, str(status))

    def test_resolved_id_caching(self):
        tmp_dir = Path("/tmp/omamovie-test-cache")
        tmp_dir.mkdir(parents=True, exist_ok=True)
        with patch.object(stremio, "CACHE_DIR", tmp_dir):
            stremio._remember_resolved_ids("series", "custom:123", [("tt9999999", "Test Resolver")])
            recalled = stremio._recall_resolved_ids("series", "custom:123")
            self.assertEqual(recalled, [("tt9999999", "Test Resolver")])

    def test_resolver_manifest_validation(self):
        valid_resolver = {
            "schemaVersion": 1,
            "id": "my.resolver",
            "name": "My Resolver",
            "mappings": [{"type": "movie", "from": "foo:1", "to": "bar:1"}],
        }
        with patch.object(stremio, "_get_json", return_value=valid_resolver):
            url, res = stremio.validate_resolver_manifest("https://example.test/resolver.json")
            self.assertEqual(res["id"], "my.resolver")
            self.assertEqual(len(res["mappings"]), 1)

    def test_seeders_extraction(self):
        self.assertEqual(
            stremio._seeders_hint({}, "Justified S01E01 👤 153 💾 827 MB ⚙️ RARBG"),
            153,
        )
        self.assertEqual(
            stremio._seeders_hint({}, "Fight Club [1080p] 42 seeds"),
            42,
        )
        self.assertEqual(
            stremio._seeders_hint({"behaviorHints": {"seeders": 99}}, "stream"),
            99,
        )
        self.assertEqual(
            stremio._seeders_hint({"seeders": 12}, "stream"),
            12,
        )

    def test_subtitles_from_subtitle_addon(self):
        subs_addon_url = "https://opensubs.example.test/manifest.json"
        cfg = stremio.default_config()
        cfg["addons"] = [
            {"name": "OpenSubs Addon", "manifestUrl": subs_addon_url, "enabled": True}
        ]

        def fake_get(url, **_kwargs):
            if url == subs_addon_url:
                return {
                    "id": "opensubs.addon",
                    "name": "OpenSubs Addon",
                    "resources": [{"name": "subtitles", "types": ["movie", "series"], "idPrefixes": ["tt"]}],
                    "types": ["movie", "series"],
                }
            if "/subtitles/movie/tt0137523.json" in url:
                return {
                    "subtitles": [
                        {
                            "id": "sub-1",
                            "lang": "eng",
                            "lang_code": "en",
                            "title": "Fight Club (1999) Bluray-1080p",
                            "url": "https://opensubs.example.test/sub.vtt/?sub_id=1",
                        }
                    ]
                }
            raise RuntimeError(f"unexpected URL: {url}")

        with patch.object(stremio, "load_config", return_value=cfg), patch.object(
            stremio, "_get_json", side_effect=fake_get
        ):
            subs = stremio.subtitles("movie|tt0137523")

        self.assertEqual(len(subs), 1)
        self.assertEqual(subs[0]["lang"], "eng")
        self.assertEqual(subs[0]["name"], "eng (Fight Club (1999) Bluray-1080p)")
        self.assertEqual(subs[0]["url"], "https://opensubs.example.test/sub.vtt/?sub_id=1")
        self.assertEqual(subs[0]["source"], "OpenSubs Addon")

    def test_rejects_wildcards_and_non_https_remote_urls(self):
        with self.assertRaises(ValueError):
            stremio._validated_mappings(
                [{"type": "movie", "from": "catalog:*", "to": "archive:movie"}]
            )
        with self.assertRaises(ValueError):
            stremio.validate_resolver_manifest("http://example.test/resolver.json")


if __name__ == "__main__":
    unittest.main()
