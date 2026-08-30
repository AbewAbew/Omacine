import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


PLUGIN_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_MAIN = PLUGIN_ROOT / "bridge" / "python" / "__main__.py"
spec = importlib.util.spec_from_file_location("omamovie_bridge_main", BRIDGE_MAIN)
bridge_main = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(BRIDGE_MAIN.parent))
spec.loader.exec_module(bridge_main)


def _json_loads_last_line(text):
    import json
    lines = [line for line in text.strip().splitlines() if line.strip()]
    return json.loads(lines[-1]) if lines else None


class MpvBridgeTests(unittest.TestCase):
    def test_poster_cache_is_bounded_by_age_and_size(self):
        with tempfile.TemporaryDirectory() as cache_dir:
            base = Path(cache_dir)
            old = base / "old.jpg"
            first = base / "first.jpg"
            newest = base / "newest.jpg"
            old.write_bytes(b"x" * 4)
            first.write_bytes(b"x" * 6)
            newest.write_bytes(b"x" * 6)
            now = time.time()
            old_time = now - 1000
            first_time = now - 20
            newest_time = now - 10
            bridge_main.os.utime(old, (old_time, old_time))
            bridge_main.os.utime(first, (first_time, first_time))
            bridge_main.os.utime(newest, (newest_time, newest_time))

            result = bridge_main.prune_poster_cache(base, max_bytes=6, max_age=100)

            self.assertEqual(result["removed"], 2)
            self.assertFalse(old.exists())
            self.assertFalse(first.exists())
            self.assertTrue(newest.exists())

    def test_player_socket_is_scoped_to_runtime_directory(self):
        with tempfile.TemporaryDirectory() as runtime_dir, patch.dict(
            bridge_main.os.environ, {"XDG_RUNTIME_DIR": runtime_dir}
        ):
            valid = str(Path(runtime_dir) / "omamovie-mpv-123.sock")
            self.assertEqual(bridge_main._validated_mpv_socket(valid), valid)
            with self.assertRaises(ValueError):
                bridge_main._validated_mpv_socket(str(Path(runtime_dir) / "unrelated.sock"))
            with self.assertRaises(ValueError):
                bridge_main._validated_mpv_socket("/tmp/omamovie-mpv-123.sock")

    def test_player_commands_are_narrowly_allowlisted(self):
        commands = bridge_main._validated_mpv_commands([
            ["loadfile", "https://media.example.test/e2.mp4", "insert-next", -1, {"force-media-title": "Episode 2"}],
            ["sub-add", "https://subs.example.test/e2.srt", "auto"],
            ["sub-add", "https://subs.example.test/english.srt", "select"],
            ["sub-add", "https://subs.example.test/cached.srt", "cached"],
            ["set", "sid", "no"],
            ["set", "sid", "auto"],
            ["playlist-remove", 1],
            ["playlist-next", "force"],
            ["playlist-clear"],
        ])
        self.assertEqual(len(commands), 9)
        with self.assertRaises(ValueError):
            bridge_main._validated_mpv_commands([["run", "sh", "-c", "true"]])
        with self.assertRaises(ValueError):
            bridge_main._validated_mpv_commands([["loadfile", "file:///etc/passwd"]])
        with self.assertRaises(ValueError):
            bridge_main._validated_mpv_commands([["set", "volume", 100]])
        with self.assertRaises(ValueError):
            bridge_main._validated_mpv_commands(
                [["sub-add", "https://subs.example.test/a.srt", "reload"]])

    def test_multiple_cached_subtitles_keep_command_allowlist_intact(self):
        with tempfile.TemporaryDirectory() as cache_dir, patch.object(
            bridge_main, "subtitle_dir", return_value=Path(cache_dir)
        ):
            first = Path(cache_dir) / "first.srt"
            second = Path(cache_dir) / "second.srt"
            first.write_text("first", encoding="utf-8")
            second.write_text("second", encoding="utf-8")

            commands = bridge_main._validated_mpv_commands([
                ["sub-add", str(first), "auto"],
                ["sub-add", str(second), "auto"],
            ])

            self.assertEqual(len(commands), 2)

    def test_ping_and_watch_save_do_not_load_heavy_modules(self):
        """Cheap commands must not drag in the catalog or TMDB clients.

        Their imports pull requests/urllib3 and dominate one-shot startup, so
        keeping them lazy is what makes a bare command fast.
        """
        import subprocess

        probe = (
            "import sys, json, runpy;"
            "sys.argv=['bridge', json.dumps({'cmd':'ping'})];"
            "runpy.run_path(%r, run_name='__main__');"
            "sys.stderr.write(json.dumps(sorted("
            "m for m in ('stremio','tmdb','requests') if m in sys.modules)))"
            % str(BRIDGE_MAIN)
        )
        out = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True)
        loaded = _json_loads_last_line(out.stderr)
        self.assertEqual(loaded, [], f"ping should import none of these, got {loaded}")


    def test_watch_progress_persists_resume_and_completion(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
            first = bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tt1", "title": "Demo Show",
                "cover": "https://images.example.test/demo.jpg", "stype": 2,
                "season": 1, "episode": 2, "position": 600, "duration": 2400,
            })
            state = bridge_main.watch_state()
            self.assertFalse(first["completed"])
            self.assertEqual(len(state["continueWatching"]), 1)
            self.assertAlmostEqual(state["continueWatching"][0]["progress"], 0.25)

            completed = bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tt1", "title": "Demo Show",
                "stype": 2, "season": 1, "episode": 2, "position": 2300, "duration": 2400,
            })
            self.assertTrue(completed["completed"])
            self.assertEqual(bridge_main.watch_state()["continueWatching"], [])

    def test_watch_progress_remembers_exact_torrent_without_secrets(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
            info_hash = "0123456789abcdef0123456789abcdef01234567"
            first = bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tt1", "title": "Demo Show",
                "stype": 2, "season": 3, "episode": 7, "position": 120,
                "duration": 2400,
                "stream": {
                    "streamKind": "p2p", "infoHash": info_hash.upper(), "fileIdx": 4,
                    "resourceId": info_hash,
                    "resourceLink": "http://127.0.0.1:11480/secret?tr=private-token",
                    "headers": [["Authorization", "Bearer secret"]],
                    "resolution": 1080, "size": 734003200, "mediaLabel": "HEVC",
                    "sourceLabel": "IO Streams", "addonKey": "addon-one",
                },
            })

            self.assertEqual(first["stream"]["infoHash"], info_hash)
            self.assertEqual(first["stream"]["fileIdx"], 4)
            self.assertEqual(first["stream"]["resolution"], 1080)
            self.assertNotIn("resourceLink", first["stream"])
            self.assertNotIn("headers", first["stream"])

            # A later progress-only write must not forget which file supplied
            # the episode (important during upgrades and queued save drains).
            later = bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tt1", "title": "Demo Show",
                "stype": 2, "season": 3, "episode": 7, "position": 180,
                "duration": 2400,
            })
            self.assertEqual(later["stream"]["infoHash"], info_hash)
            self.assertEqual(later["stream"]["fileIdx"], 4)

    def test_watch_progress_rejects_invalid_stream_identity(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
            entry = bridge_main.save_watch_progress({
                "provider": "stremio", "id": "movie|tt2", "title": "Demo Movie",
                "position": 60, "duration": 600,
                "stream": {"streamKind": "p2p", "infoHash": "not-a-hash", "fileIdx": 0},
            })
            self.assertNotIn("stream", entry)

    def test_resources_returns_episode_stream_memory_after_restart(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
            info_hash = "abcdef0123456789abcdef0123456789abcdef01"
            bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tmdb:456", "title": "Demo Show",
                "stype": 2, "season": 37, "episode": 1, "position": 120,
                "duration": 1200,
                "stream": {"streamKind": "p2p", "infoHash": info_hash, "fileIdx": 0},
            })
            candidate = {
                "streamKind": "p2p", "infoHash": info_hash, "fileIdx": 0,
                "resourceLink": f"http://127.0.0.1:11480/{info_hash}/0",
            }
            with patch.object(bridge_main, "stremio_streams_cached", return_value=[candidate]):
                result = bridge_main.run("resources", {
                    "id": "series|tmdb:456", "season": 37, "episode": 1,
                })

            self.assertEqual(result["items"], [candidate])
            self.assertEqual(result["rememberedStream"]["infoHash"], info_hash)
            self.assertEqual(result["rememberedStream"]["fileIdx"], 0)

            with patch.object(bridge_main, "stremio_streams_cached", return_value=[]):
                other = bridge_main.run("resources", {
                    "id": "series|tmdb:456", "season": 37, "episode": 2,
                })
            self.assertIsNone(other["rememberedStream"])

    def test_continue_watching_collapses_series_and_has_a_small_limit(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
            for episode in (4, 5):
                bridge_main.save_watch_progress({
                    "provider": "stremio", "id": "series|tmdb:108978", "title": "Reacher",
                    "stype": 2, "season": 4, "episode": episode,
                    "position": 600 + episode, "duration": 2400,
                })
            for index in range(bridge_main.CONTINUE_WATCHING_LIMIT + 3):
                bridge_main.save_watch_progress({
                    "provider": "stremio", "id": f"movie|tmdb:{index}", "title": f"Movie {index}",
                    "stype": 1, "position": 300, "duration": 1800,
                })

            state = bridge_main.watch_state()
            reacher = [item for item in state["continueWatching"] if item["title"] == "Reacher"]
            self.assertLessEqual(len(state["continueWatching"]), bridge_main.CONTINUE_WATCHING_LIMIT)
            # Reacher is older than the 12 newer movies and is outside the bounded row,
            # but its per-episode history remains intact for episode progress badges.
            self.assertEqual(reacher, [])
            self.assertEqual(len([item for item in state["entries"] if item["title"] == "Reacher"]), 2)

            bridge_main.save_watch_progress({
                "provider": "stremio", "id": "series|tmdb:108978", "title": "Reacher",
                "stype": 2, "season": 4, "episode": 5, "position": 700, "duration": 2400,
            })
            reacher = [
                item for item in bridge_main.watch_state()["continueWatching"]
                if item["title"] == "Reacher"
            ]
            self.assertEqual(len(reacher), 1)
            self.assertEqual(reacher[0]["episode"], 5)

    def test_library_separates_movies_and_series_and_removes_titles(self):
        with tempfile.TemporaryDirectory() as state_dir, patch.object(
            bridge_main, "_STATE_DIR", Path(state_dir)
        ), patch.object(bridge_main, "_LIBRARY_FILE", Path(state_dir) / "library.json"):
            movie = {
                "provider": "stremio", "id": "movie|tt1", "title": "Demo Movie",
                "cover": "https://images.example.test/movie.jpg", "stype": 1,
                "year": "2026", "rating": "8.2", "saved": True,
            }
            show = {
                "provider": "stremio", "id": "show-2", "title": "Demo Show",
                "cover": "https://images.example.test/show.jpg", "stype": 2,
                "year": "2025", "saved": True,
            }
            first = bridge_main.toggle_library(movie)
            second = bridge_main.toggle_library(show)

            self.assertTrue(first["saved"])
            self.assertEqual([entry["title"] for entry in second["movies"]], ["Demo Movie"])
            self.assertEqual([entry["title"] for entry in second["series"]], ["Demo Show"])

            duplicate = bridge_main.toggle_library(movie)
            self.assertEqual(len(duplicate["movies"]), 1)

            removed = bridge_main.toggle_library({**movie, "saved": False})
            self.assertFalse(removed["saved"])
            self.assertEqual(removed["movies"], [])
            self.assertEqual(len(removed["series"]), 1)

    def test_prepare_next_returns_matched_stream(self):
        current = {"streamKind": "direct", "addonKey": "one", "resolution": 1080, "mediaLabel": "HEVC"}
        candidate = {
            "resourceLink": "https://media.example.test/e2.mp4", "streamKind": "direct",
            "addonKey": "one", "resolution": 1080, "mediaLabel": "HEVC",
        }
        with patch.object(bridge_main.stremio, "streams", return_value=[candidate]):
            result = bridge_main.run("prepare_next", {
                "provider": "stremio", "id": "series|demo", "season": 1, "episode": 2,
                "currentStream": current,
            })
        self.assertEqual(result["selected"]["resourceLink"], candidate["resourceLink"])
        self.assertEqual(result["selected"]["continuityMatch"], "format")




class BridgeDaemonTests(unittest.TestCase):
    def test_daemon_correlates_requests_and_preserves_payload_ids(self):
        import json as _json
        import subprocess

        # The daemon is a separate process, so patching _STATE_DIR here would not
        # reach it. Point it at a throwaway XDG_STATE_HOME instead — a test must
        # never write into the user's real watch history.
        state_home = tempfile.TemporaryDirectory()
        env = dict(os.environ, XDG_STATE_HOME=state_home.name)
        proc = subprocess.Popen(
            [sys.executable, str(BRIDGE_MAIN), "--daemon"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1, env=env,
        )
        try:
            handshake = _json.loads(proc.stdout.readline())
            self.assertTrue(handshake["ready"])
            self.assertEqual(handshake["_rid"], 0)

            # A payload field literally named "id" must survive: the correlation
            # key is "_rid" precisely so media ids are not eaten.
            proc.stdin.write(_json.dumps(
                {"_rid": 7, "cmd": "watch_progress", "provider": "stremio",
                 "id": "movie|tmdb:99", "title": "Probe", "position": 30, "duration": 100}) + "\n")
            proc.stdin.flush()
            resp = _json.loads(proc.stdout.readline())
            self.assertEqual(resp["_rid"], 7)
            self.assertTrue(resp["ok"])
            self.assertEqual(resp["entry"]["id"], "movie|tmdb:99")

            # Responses may return out of order; ids keep them straight.
            for rid in (11, 12, 13):
                proc.stdin.write(_json.dumps({"_rid": rid, "cmd": "ping"}) + "\n")
            proc.stdin.flush()
            seen = {_json.loads(proc.stdout.readline())["_rid"] for _ in range(3)}
            self.assertEqual(seen, {11, 12, 13})
        finally:
            proc.stdin.close()
            proc.stdout.close()
            proc.wait(timeout=10)
            state_home.cleanup()

    def test_state_files_are_written_owner_only(self):
        with tempfile.TemporaryDirectory() as state_dir:
            target = Path(state_dir) / "secret.json"
            with patch.object(bridge_main, "_STATE_DIR", Path(state_dir)):
                bridge_main._write_private_json(target, [{"title": "private"}])
            self.assertEqual(oct(target.stat().st_mode)[-3:], "600")


class WatchRemovalTests(unittest.TestCase):
    def test_removing_one_entry_leaves_the_rest(self):
        with tempfile.TemporaryDirectory() as state_dir:
            with patch.object(bridge_main, "_STATE_DIR", Path(state_dir)), \
                 patch.object(bridge_main, "_WATCH_FILE", Path(state_dir) / "watch-progress.json"):
                keep = bridge_main.save_watch_progress({
                    "provider": "stremio", "id": "series|tmdb:1", "title": "Keep",
                    "season": 1, "episode": 2, "position": 400, "duration": 2000})
                drop = bridge_main.save_watch_progress({
                    "provider": "stremio", "id": "movie|tmdb:2", "title": "Drop",
                    "position": 300, "duration": 1000})

                titles = [e["title"] for e in bridge_main.watch_state()["continueWatching"]]
                self.assertCountEqual(titles, ["Keep", "Drop"])

                result = bridge_main.run("watch_remove", {"key": drop["key"]})
                self.assertTrue(result["removed"])

                titles = [e["title"] for e in bridge_main.watch_state()["continueWatching"]]
                self.assertEqual(titles, ["Keep"])

                # Removing something already gone is a no-op, not an error.
                self.assertFalse(bridge_main.run("watch_remove", {"key": drop["key"]})["removed"])

    def test_removal_requires_a_key(self):
        with self.assertRaises(ValueError):
            bridge_main.run("watch_remove", {"key": ""})




class SettingsTests(unittest.TestCase):
    def _isolated(self):
        d = tempfile.TemporaryDirectory()
        return d, patch.object(bridge_main, "_SETTINGS_FILE", Path(d.name) / "settings.json")

    def test_defaults_survive_a_missing_or_corrupt_file(self):
        d, patched = self._isolated()
        with d, patched:
            self.assertEqual(bridge_main.load_settings()["backdropDim"], 0.70)
            Path(d.name, "settings.json").write_text("{ not json")
            self.assertEqual(bridge_main.load_settings()["backdropDim"], 0.70)

    def test_values_are_clamped_and_persisted(self):
        d, patched = self._isolated()
        with d, patched:
            saved = bridge_main.save_settings({"values": {"backdropDim": 9, "spotlightSeconds": 0}})
            self.assertEqual(saved["backdropDim"], 1.0)       # clamped to max
            self.assertEqual(saved["spotlightSeconds"], 3)    # clamped to min
            self.assertEqual(bridge_main.load_settings()["backdropDim"], 1.0)

            # A partial write must not clobber the other keys.
            bridge_main.save_settings({"values": {"heroOverlay": 0.4}})
            reloaded = bridge_main.load_settings()
            self.assertEqual(reloaded["heroOverlay"], 0.4)
            self.assertEqual(reloaded["backdropDim"], 1.0)

    def test_unknown_keys_are_refused(self):
        d, patched = self._isolated()
        with d, patched:
            with self.assertRaises(ValueError):
                bridge_main.save_settings({"values": {"rm -rf": 1}})

    def test_reset_returns_to_defaults(self):
        d, patched = self._isolated()
        with d, patched:
            bridge_main.save_settings({"values": {"backdropDim": 0.1}})
            self.assertEqual(bridge_main.reset_settings()["backdropDim"], 0.70)


class ProviderRemovalTests(unittest.TestCase):
    def test_removed_provider_commands_are_gone(self):
        for cmd in ("genre", "resolve", "subfile", "raw"):
            with self.assertRaises(ValueError, msg=f"{cmd} should no longer exist"):
                bridge_main.run(cmd, {})

    def test_watch_and_library_only_accept_catalog_entries(self):
        for provider in ("moviebox", "fourkhdhub", "", "anything"):
            with self.assertRaises(ValueError):
                bridge_main.save_watch_progress(
                    {"provider": provider, "id": "x", "title": "t", "position": 20, "duration": 100})


class TextScaleTests(unittest.TestCase):
    def test_text_scale_defaults_and_clamps(self):
        with tempfile.TemporaryDirectory() as d, \
             patch.object(bridge_main, "_SETTINGS_FILE", Path(d) / "settings.json"):
            self.assertEqual(bridge_main.load_settings()["textScale"], 1.0)
            self.assertEqual(bridge_main.save_settings({"values": {"textScale": 9}})["textScale"], 1.6)
            self.assertEqual(bridge_main.save_settings({"values": {"textScale": 0}})["textScale"], 0.85)
            # A junk value falls back to the default rather than breaking the UI.
            self.assertEqual(bridge_main.save_settings({"values": {"textScale": "big"}})["textScale"], 1.0)


class OverlayMessageTests(unittest.TestCase):
    """The overlay is driven over the same IPC socket as playback control, so
    the allowlist has to stay narrow."""

    def test_our_overlay_messages_are_accepted(self):
        for command in (["script-message", "omacine-upnext", "S04E06", "1", "7"],
                        ["script-message", "omacine-upnext", "S04E06", "0", ""],
                        ["script-message", "omacine-clear"]):
            self.assertTrue(bridge_main._validated_mpv_commands([command]))

    def test_other_scripts_cannot_be_driven(self):
        for command in (["script-message", "uosc-something", "x"],
                        ["script-message", "osc", "visibility", "always"],
                        ["script-message"],
                        ["script-message", "omacine-upnext", "x" * 400],
                        ["script-message", "omacine-upnext", 1, 2]):
            with self.assertRaises(ValueError, msg=f"{command} should be refused"):
                bridge_main._validated_mpv_commands([command])

    def test_overlay_script_ships_with_the_plugin(self):
        script = PLUGIN_ROOT / "mpv" / "omacine.lua"
        self.assertTrue(script.is_file(), "mpv/omacine.lua must ship with the plugin")
        body = script.read_text(encoding="utf-8")
        # It must never be installed into the user's own mpv config.
        self.assertIn("create_osd_overlay", body)
        self.assertIn("omacine-upnext", body)


class SubtitleSourceTests(unittest.TestCase):
    """Subtitles are downloaded by the bridge because mpv's network timeout is
    shorter than these hosts take, so sub-add must accept our cached files —
    and nothing else."""

    def test_cached_subtitle_files_are_accepted(self):
        cached = os.path.join(str(bridge_main.subtitle_dir()), "abc123.srt")
        self.assertTrue(bridge_main._validated_mpv_commands([["sub-add", cached, "auto"]]))

    def test_remote_subtitles_still_work(self):
        self.assertTrue(bridge_main._validated_mpv_commands(
            [["sub-add", "https://example.test/a.srt", "auto"]]))

    def test_arbitrary_local_files_are_refused(self):
        cache = str(bridge_main.subtitle_dir())
        for bad in ("/etc/passwd",
                    os.path.join(cache, "../../../etc/passwd"),
                    "file:///etc/shadow",
                    "/home/someone/.ssh/id_rsa"):
            with self.assertRaises(ValueError, msg=f"{bad} must be refused"):
                bridge_main._validated_mpv_commands([["sub-add", bad, "auto"]])

    def test_loadfile_is_still_http_only(self):
        cached = os.path.join(str(bridge_main.subtitle_dir()), "x.srt")
        with self.assertRaises(ValueError):
            bridge_main._validated_mpv_commands(
                [["loadfile", cached, "insert-next", -1, {}]])


if __name__ == "__main__":
    unittest.main()
