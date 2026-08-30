"""A dragged slider sends one settings_set per movement, and the daemon
answers on eight worker threads. These cover the two ways that raced."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bridge" / "python"))


def _load_main():
    spec = importlib.util.spec_from_file_location(
        "omamovie_settings_main", ROOT / "bridge" / "python" / "__main__.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["omamovie_settings_main"] = module
    spec.loader.exec_module(module)
    return module


class SettingsConcurrencyTests(unittest.TestCase):
    def setUp(self):
        self.main = _load_main()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.main._SETTINGS_FILE = pathlib.Path(self.tmp.name) / "settings.json"

    def test_scratch_paths_never_collide_across_threads(self):
        target = pathlib.Path(self.tmp.name) / "settings.json"
        seen = []
        lock = threading.Lock()

        def make():
            for _ in range(50):
                path = self.main._scratch_path(target)
                with lock:
                    seen.append(str(path))

        threads = [threading.Thread(target=make) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(seen), len(set(seen)))

    def test_concurrent_writes_all_succeed(self):
        # The reported failure: a fixed ".new" sibling, so the second renamer
        # hit ENOENT on a file the first had already moved into place.
        errors = []

        def hammer(start):
            for i in range(20):
                try:
                    self.main.save_settings(
                        {"values": {"cachePostersMB": 50 + ((start + i) % 20) * 25}})
                except Exception as exc:  # noqa: BLE001 - the point is to catch any
                    errors.append(repr(exc))

        threads = [threading.Thread(target=hammer, args=(n,)) for n in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(errors, [])
        self.assertTrue(self.main._SETTINGS_FILE.exists())
        json.loads(self.main._SETTINGS_FILE.read_text(encoding="utf-8"))

    def test_concurrent_writes_of_different_keys_do_not_lose_one(self):
        # Read-modify-write: without the lock two threads could each read the
        # old file and write their own key back, dropping the other.
        def write(key, value):
            self.main.save_settings({"values": {key: value}})

        threads = [
            threading.Thread(target=write, args=("cachePostersMB", 375)),
            threading.Thread(target=write, args=("engineReleaseGraceSeconds", 45)),
            threading.Thread(target=write, args=("cacheThemesMB", 650)),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        saved = json.loads(self.main._SETTINGS_FILE.read_text(encoding="utf-8"))
        self.assertEqual(saved["cachePostersMB"], 375)
        self.assertEqual(saved["engineReleaseGraceSeconds"], 45)
        self.assertEqual(saved["cacheThemesMB"], 650)

    def test_no_scratch_files_are_left_behind(self):
        for value in (100, 200, 300):
            self.main.save_settings({"values": {"cachePostersMB": value}})
        leftovers = [p.name for p in pathlib.Path(self.tmp.name).iterdir()
                     if ".new" in p.name]
        self.assertEqual(leftovers, [])


if __name__ == "__main__":
    unittest.main()
