"""Cover the pieces that keep OmaCine's streaming server separate from
Stremio Enhanced: the port patch applied to our vendored bundle, and the
retargeting of stream links cached before the port moved."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge" / "python"))

PATCHER = ROOT / "bridge" / "patch-server-port.py"


def _load_main():
    spec = importlib.util.spec_from_file_location(
        "omamovie_main", ROOT / "bridge" / "python" / "__main__.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["omamovie_main"] = module
    spec.loader.exec_module(module)
    return module


class PortPatchTests(unittest.TestCase):
    """The vendored bundle must move onto 11480, or not be shipped at all."""

    def _patch(self, body: str):
        with tempfile.TemporaryDirectory() as tmp:
            target = pathlib.Path(tmp) / "server.js"
            target.write_text(body, encoding="utf-8")
            done = subprocess.run([sys.executable, str(PATCHER), str(target)],
                                  capture_output=True, text=True)
            return done.returncode, target.read_text(encoding="utf-8")

    def _bundle(self) -> str:
        return (
            'var a, port = 11470; server.listen(port); port++ < 11474 ? x : y;'
            'let ip = "127.0.0.1", port = 11470;'
            'fetch("http://127.0.0.1:11470/subtitles.srt?from=")'
            'let engineUrl = "http://127.0.0.1:11470";'
            'serverPort = serverPort || 11470;'
            'req.headers.origin.match("(127.0.0.1|localhost):11470$")'
        )

    def test_every_engine_self_reference_moves_to_11480(self):
        code, body = self._patch(self._bundle())
        self.assertEqual(code, 0)
        self.assertNotIn("11470", body)
        self.assertEqual(body.count("port = 11480"), 2)
        self.assertIn("port++ < 11484", body)

    def test_patching_twice_is_a_no_op(self):
        code, once = self._patch(self._bundle())
        self.assertEqual(code, 0)
        code, twice = self._patch(once)
        self.assertEqual(code, 0)
        self.assertEqual(once, twice)

    def test_unexpected_bundle_is_refused_and_left_untouched(self):
        # An upstream rewrite must not yield a half-patched server on the
        # wrong port; setup keeps the previous working copy instead.
        original = 'var port = 9999; nothing here matches;'
        code, body = self._patch(original)
        self.assertEqual(code, 1)
        self.assertEqual(body, original)


class CachedLinkRetargetTests(unittest.TestCase):
    """Lists cached before the port move must not hand mpv a dead URL."""

    def setUp(self):
        self.main = _load_main()

    def test_loopback_links_move_to_the_current_server(self):
        items = [{"resourceLink": "http://127.0.0.1:11470/abc/0"}]
        out = self.main._retarget_local_streams(items)
        self.assertEqual(out[0]["resourceLink"], "http://127.0.0.1:11480/abc/0")

    def test_remote_links_are_left_alone(self):
        remote = "https://cdn.example.com/movie.mkv"
        out = self.main._retarget_local_streams([{"resourceLink": remote}])
        self.assertEqual(out[0]["resourceLink"], remote)

    def test_entries_without_links_survive(self):
        out = self.main._retarget_local_streams([{"name": "no link"}, "junk"])
        self.assertEqual(out[0], {"name": "no link"})


class LegacyPathMigrationTests(unittest.TestCase):
    """The setup script must move a shared cacheRoot but respect a custom one."""

    MIGRATION = ROOT / "omamovie-setup.sh"

    def _migrate(self, settings: dict) -> dict:
        script = self.MIGRATION.read_text(encoding="utf-8")
        start = script.index("if jq --arg old_root")
        program = script[script.index("'", start) + 1:]
        program = program[:program.index("'")]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(settings, handle)
            path = handle.name
        done = subprocess.run(
            ["jq", "--arg", "old_root", "/home/u/.stremio-server",
             "--arg", "new_root", "/home/u/.local/share/omamovie/server",
             program, path],
            capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def test_shared_default_path_is_moved(self):
        out = self._migrate({"appPath": "/home/u/.stremio-server",
                             "cacheRoot": "/home/u/.stremio-server",
                             "cacheSize": 2147483648})
        self.assertEqual(out["cacheRoot"], "/home/u/.local/share/omamovie/server")
        self.assertEqual(out["appPath"], "/home/u/.local/share/omamovie/server")
        self.assertEqual(out["cacheSize"], 10737418240)

    def test_custom_path_and_tuning_are_preserved(self):
        out = self._migrate({"appPath": "/mnt/big/stremio",
                             "cacheRoot": "/mnt/big/stremio",
                             "cacheSize": 53687091200,
                             "btMaxConnections": 120})
        self.assertEqual(out["cacheRoot"], "/mnt/big/stremio")
        self.assertEqual(out["cacheSize"], 53687091200)
        self.assertEqual(out["btMaxConnections"], 120)


if __name__ == "__main__":
    unittest.main()
