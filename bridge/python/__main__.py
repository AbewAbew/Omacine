#!/usr/bin/env python3
"""Python bridge for OmaCine - pure Python backend."""
import sys
import json
import os
import threading
import re
import datetime
import hashlib
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

# Make imports work for both:
#   python3 /path/bridge/python/__main__.py
#   python3 /path/bridge/python '{"cmd":...}'   (dir exec, __main__)
#   python3 -m bridge.python  (when plugin root in PYTHONPATH)
_this = Path(__file__).resolve()
_py_dir = _this.parent  # bridge/python
_bridge_dir = _py_dir.parent  # bridge
_plugin_root = _bridge_dir.parent  # omamovie
for p in [str(_py_dir), str(_bridge_dir), str(_plugin_root)]:
    if p not in sys.path:
        sys.path.insert(0, p)

# Now try imports - prefer direct sibling imports
try:
    from cache import get_provider_stream_cache, set_provider_stream_cache
    import net
    from utils import poster_dir, prune_poster_cache, detect_ext, subtitle_dir, prune_subtitle_cache
except ImportError as e:
    # fallback package style
    try:
        from bridge.python.cache import get_provider_stream_cache, set_provider_stream_cache
        from bridge.python import net
        from bridge.python.utils import poster_dir, prune_poster_cache, detect_ext, subtitle_dir, prune_subtitle_cache
    except ImportError:
        raise e


# Global service singletons similar to Rust OnceLock
_STREMIO_MODULE = None
_TMDB_MODULE = None
_MDBLIST_MODULE = None
_THEMERR_MODULE = None
_ICSCAL_MODULE = None
_SHOWCAL_MODULE = None
_INTRODB_MODULE = None
_STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")) / "omamovie"
_WATCH_FILE = _STATE_DIR / "watch-progress.json"
_LIBRARY_FILE = _STATE_DIR / "library.json"
_HOME_SNAPSHOT_FILE = _STATE_DIR / "home-snapshot.json"
CONTINUE_WATCHING_LIMIT = 12
HOME_SNAPSHOT_MAX_AGE = 7 * 24 * 60 * 60


def _scratch_path(path: Path) -> Path:
    """A temp name no other writer can collide with.

    A fixed ".new" sibling is not safe here: the daemon answers on eight
    worker threads and the one-shot fallback runs as its own process, so two
    writers could share the path and whichever renamed second would fail with
    ENOENT on a file the first had already moved into place.
    """
    return path.with_suffix(f".new-{os.getpid()}-{threading.get_ident()}-{time.time_ns()}")


def _write_private_json(path: Path, value) -> None:
    """Persist owner-readable state atomically. Viewing history and saved
    titles are private, so the file is never briefly world-readable."""
    _STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = _scratch_path(path)
    handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(value, stream, separators=(",", ":"))
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _watch_entries() -> list[dict]:
    try:
        value = json.loads(_WATCH_FILE.read_text(encoding="utf-8"))
        return [entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []
    except (OSError, ValueError, TypeError):
        return []


def _write_watch_entries(entries: list[dict]) -> None:
    _write_private_json(_WATCH_FILE, entries[:200])


def _watch_number(value, *, integer: bool = False):
    try:
        number = max(0.0, float(value or 0))
    except (TypeError, ValueError, OverflowError):
        number = 0.0
    return int(number) if integer else number


def save_watch_progress(req: dict) -> dict:
    provider = str_arg(req, "provider").strip().lower()
    if provider != "stremio":
        raise ValueError("invalid watch provider")
    media_id = str_arg(req, "id")[:512]
    title = str_arg(req, "title")[:300]
    if not media_id or not title:
        raise ValueError("missing watch identity")
    season = _watch_number(req.get("season"), integer=True)
    episode = _watch_number(req.get("episode"), integer=True)
    position = _watch_number(req.get("position"))
    duration = _watch_number(req.get("duration"))
    ratio = min(1.0, position / duration) if duration > 0 else 0.0
    completed = req.get("completed") is True or ratio >= 0.92
    entry = {
        "key": hashlib.sha256(f"{provider}|{media_id}|{season}|{episode}".encode("utf-8")).hexdigest()[:24],
        "provider": provider,
        "id": media_id,
        "title": title,
        "cover": safe_http_url(req.get("cover")),
        "stype": 2 if _watch_number(req.get("stype"), integer=True) == 2 else 1,
        "season": season,
        "episode": episode,
        "position": round(position, 3),
        "duration": round(duration, 3),
        "progress": round(ratio, 4),
        "completed": completed,
        "updated": int(time.time()),
    }
    entries = [existing for existing in _watch_entries() if existing.get("key") != entry["key"]]
    entries.insert(0, entry)
    entries.sort(key=lambda value: int(value.get("updated") or 0), reverse=True)
    _write_watch_entries(entries)
    return entry


def watch_state() -> dict:
    entries = sorted(_watch_entries(), key=lambda value: int(value.get("updated") or 0), reverse=True)
    # Keep detailed progress for every episode, but represent a series only once
    # on the home screen. Since entries are newest-first, the first record for a
    # title is its authoritative resume point; a completed latest episode must
    # not expose an older unfinished episode as a second card.
    latest_by_title = {}
    for entry in entries:
        identity = (str(entry.get("provider") or ""), str(entry.get("id") or ""))
        if identity not in latest_by_title:
            latest_by_title[identity] = entry
    continuing = [
        entry for entry in latest_by_title.values()
        if not entry.get("completed") and float(entry.get("position") or 0) >= 15
    ][:CONTINUE_WATCHING_LIMIT]
    return {"entries": entries[:200], "continueWatching": continuing}


def _library_entries() -> list[dict]:
    try:
        value = json.loads(_LIBRARY_FILE.read_text(encoding="utf-8"))
        return [entry for entry in value if isinstance(entry, dict)] if isinstance(value, list) else []
    except (OSError, ValueError, TypeError):
        return []


def _write_library_entries(entries: list[dict]) -> None:
    _write_private_json(_LIBRARY_FILE, entries[:500])


def _save_home_snapshot(payload: dict) -> None:
    """Keep the last good home feed so the next launch paints before any
    network call returns."""
    try:
        _write_private_json(_HOME_SNAPSHOT_FILE, {"saved": int(time.time()), "payload": payload})
    except OSError:
        pass


def _load_home_snapshot() -> dict:
    try:
        value = json.loads(_HOME_SNAPSHOT_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {"cached": False}
    payload = value.get("payload")
    saved = int(value.get("saved") or 0)
    if not isinstance(payload, dict) or time.time() - saved > HOME_SNAPSHOT_MAX_AGE:
        return {"cached": False}
    result = dict(payload)
    result["cached"] = True
    result["savedAt"] = saved
    return result


def _library_key(provider: str, media_id: str) -> str:
    return hashlib.sha256(f"{provider}|{media_id}".encode("utf-8")).hexdigest()[:24]


def library_state() -> dict:
    entries = sorted(
        _library_entries(),
        key=lambda value: _watch_number(value.get("added"), integer=True),
        reverse=True,
    )
    return {
        "entries": entries[:500],
        "movies": [entry for entry in entries if _watch_number(entry.get("stype"), integer=True) != 2],
        "series": [entry for entry in entries if _watch_number(entry.get("stype"), integer=True) == 2],
    }


def toggle_library(req: dict) -> dict:
    provider = str_arg(req, "provider").strip().lower()
    if provider != "stremio":
        raise ValueError("invalid library provider")
    media_id = str_arg(req, "id")[:512]
    title = str_arg(req, "title")[:300]
    if not media_id or not title:
        raise ValueError("missing library identity")
    key = _library_key(provider, media_id)
    entries = _library_entries()
    existing = next((entry for entry in entries if entry.get("key") == key), None)
    saved = req.get("saved") is True
    entry = None
    if saved:
        entry = {
            "key": key,
            "provider": provider,
            "id": media_id,
            "title": title,
            "cover": safe_http_url(req.get("cover")),
            "stype": 2 if _watch_number(req.get("stype"), integer=True) == 2 else 1,
            "year": str(req.get("year") or "")[:20],
            "rating": str(req.get("rating") or "")[:20],
            "added": (_watch_number(existing.get("added"), integer=True) or int(time.time()))
                     if existing else int(time.time()),
        }
        entries = [value for value in entries if value.get("key") != key]
        entries.insert(0, entry)
    else:
        entries = [value for value in entries if value.get("key") != key]
    _write_library_entries(entries)
    return {**library_state(), "saved": saved, "entry": entry}



_SETTINGS_FILE = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "omamovie" / "settings.json"

# name -> (default, minimum, maximum). Everything is a plain number or bool so
# the panel can bind directly and a corrupt file can never inject anything odd.
SETTINGS_SCHEMA = {
    "backdropOpacity":   (0.18, 0.0, 1.0),
    "backdropDim":       (0.70, 0.0, 1.0),
    "heroOverlay":       (0.16, 0.0, 1.0),
    "spotlightRotate":   (True, None, None),
    "spotlightSeconds":  (7, 3, 60),
    "railHoverPreview":  (True, None, None),
    # OmaCine-local text scale. The shell's own font size is a system-wide
    # setting, so this multiplies only this plugin's type.
    "textScale":         (1.0, 0.85, 1.6),
    # ThemerrDB theme songs on a title's page. A theme belongs to the show or
    # the movie, never to an episode, so this only ever plays on details.
    "themeSongs":        (True, None, None),
    "themeVolume":       (45, 0, 100),
    # The Netflix move: the still backdrop holds, then the clip fades in over it.
    "themeVideo":        (True, None, None),
    "themeVideoDelay":   (1.8, 0.0, 10.0),
    # Reviews modal: how solid its panel sits over the page behind it.
    "reviewOpacity":     (0.94, 0.60, 1.0),
    # Cache budgets, in megabytes. Each is enforced by that cache's own LRU
    # pruner, so lowering one takes effect at its next sweep rather than
    # deleting anything the moment you move the slider.
    "cachePostersMB":    (200, 50, 4000),
    "cacheThemesMB":     (800, 100, 8000),
    "cacheTorrentGB":    (11, 1, 200),
    # Ambient keyboard/underglow lighting during playback. Off by default: it
    # drives the laptop's LEDs, which is not something to switch on unasked.
    "cinematicMode":     (False, None, None),
    # Start the chosen stream's torrent engine while the picker is still open,
    # so peer discovery overlaps with choosing instead of following it. Costs
    # up to a megabyte for a stream that is then not played, which is why it
    # can be turned off on a metered connection.
    "prefetchStreams":   (True, None, None),
    # How long a torrent engine keeps running after the player closes. Engines
    # go on talking to peers once playback stops, which on a metered link is
    # real money: roughly 14 MiB per 30s at the rates observed here. The grace
    # buys a fast resume for someone who closes and reopens; 0 releases at once.
    "engineReleaseGraceSeconds": (30, 0, 120),
}


# The one string setting. Kept apart from the numeric schema so the rule there
# - everything is a number or a bool - still holds for that table, and so this
# value gets the validation a free string needs.
SETTINGS_TEXT_SCHEMA = {
    "uiFontFamily": "Adwaita Sans",
}

_FONT_FAMILIES: set | None = None


def _installed_font_families() -> set:
    """Families fontconfig actually knows about.

    Qt resolves an unknown family to a silent fallback rather than failing, so
    an unvalidated name looks exactly like the setting doing nothing. Checking
    here means a saved font is always a font that will really render.
    """
    global _FONT_FAMILIES
    if _FONT_FAMILIES is None:
        families = set()
        try:
            listed = subprocess.run(["fc-list", ":", "family"], capture_output=True,
                                    text=True, timeout=10, check=False)
            for line in listed.stdout.splitlines():
                for part in line.split(","):
                    part = part.strip()
                    if part:
                        families.add(part)
        except (OSError, subprocess.SubprocessError):
            pass
        _FONT_FAMILIES = families
    return _FONT_FAMILIES


def _coerce_text_setting(name, value):
    default = SETTINGS_TEXT_SCHEMA[name]
    text = str(value or "").strip()
    if not text or len(text) > 64:
        return default
    installed = _installed_font_families()
    # An empty set means fc-list was unavailable; fall back to the default
    # rather than trusting an unverifiable name.
    return text if text in installed else default


THUMB_DIR = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "omamovie-thumbs"


_CACHE_ROOT = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie"

# name -> (directory, whether a size budget applies)
CACHE_DIRS = {
    "posters":   (_CACHE_ROOT / "posters",  True),
    "themes":    (_CACHE_ROOT / "themes",   True),
    "subtitles": (_CACHE_ROOT / "subs",     False),
    "stremio":   (_CACHE_ROOT / "stremio",  False),
    "tmdb":      (_CACHE_ROOT / "tmdb",     False),
    "mdblist":   (_CACHE_ROOT / "mdblist",  False),
    "introdb":   (_CACHE_ROOT / "introdb",  False),
    "mpv":       (_CACHE_ROOT / "mpv-cache", False),
}


def _dir_bytes(path: Path) -> int:
    total = 0
    try:
        for root, _dirs, files in os.walk(path):
            for name in files:
                try:
                    total += os.path.getsize(os.path.join(root, name))
                except OSError:
                    continue
    except OSError:
        pass
    return total


def cache_usage() -> dict:
    settings = load_settings()
    budgets = {"posters": int(settings["cachePostersMB"]) * 1024 * 1024,
               "themes": int(settings["cacheThemesMB"]) * 1024 * 1024}
    entries = []
    for name, (path, sized) in CACHE_DIRS.items():
        entries.append({"name": name, "path": str(path), "bytes": _dir_bytes(path),
                        "budget": budgets.get(name, 0) if sized else 0})
    # The torrent cache belongs to the streaming server, not to us; it is
    # reported so one screen shows the whole disk footprint.
    torrent = Path.home() / ".local" / "share" / "omamovie" / "server"
    entries.append({"name": "torrent", "path": str(torrent), "bytes": _dir_bytes(torrent),
                    "budget": int(settings["cacheTorrentGB"]) * 1024 * 1024 * 1024})
    return {"caches": entries}


def cache_clear(name: object) -> dict:
    """Empty one cache. The torrent cache is the streaming server's to manage."""
    key = str(name or "")
    if key not in CACHE_DIRS:
        raise ValueError("unknown cache")
    path, _sized = CACHE_DIRS[key]
    removed = freed = 0
    try:
        for root, _dirs, files in os.walk(path):
            for item in files:
                target = os.path.join(root, item)
                try:
                    size = os.path.getsize(target)
                    os.unlink(target)
                    removed += 1
                    freed += size
                except OSError:
                    continue
    except OSError:
        pass
    return {"name": key, "removed": removed, "freed": freed}


def thumb_raw(source: object, width: object = 320, height: object = 180) -> dict:
    """Convert a cached still to the raw BGRA that mpv's overlay-add wants.

    mpv cannot decode a JPEG into an overlay: overlay-add takes raw pixels and
    a stride. ffmpeg does the decode and scale once, and the result is written
    under the runtime directory so it never outlives the session.
    """
    raw_source = str(source or "")
    if raw_source.startswith("file://"):
        raw_source = raw_source[7:]
    resolved = os.path.realpath(raw_source)
    # Only images this bridge itself cached - the path becomes an ffmpeg
    # argument and then a file mpv reads.
    cache_root = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie"
    allowed = [os.path.realpath(str(poster_dir())), os.path.realpath(str(cache_root))]
    if not any(os.path.commonpath([resolved, base]) == base for base in allowed):
        raise ValueError("thumbnails must come from the OmaCine cache")
    if not os.path.isfile(resolved):
        raise ValueError("that image is not in the cache")
    try:
        w = max(32, min(640, int(width)))
        h = max(18, min(360, int(height)))
    except (TypeError, ValueError):
        raise ValueError("invalid thumbnail size")

    THUMB_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = hashlib.sha256(f"{resolved}|{w}x{h}".encode("utf-8")).hexdigest()[:20]
    target = THUMB_DIR / f"{stem}.bgra"
    expected = w * h * 4
    try:
        if target.stat().st_size == expected:
            return {"path": str(target), "width": w, "height": h, "stride": w * 4}
    except OSError:
        pass
    command = [
        "ffmpeg", "-loglevel", "error", "-y", "-i", resolved,
        "-vf", f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h}",
        "-f", "rawvideo", "-pix_fmt", "bgra", str(target),
    ]
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg is not installed") from exc
    except subprocess.SubprocessError as exc:
        raise RuntimeError("the thumbnail conversion timed out") from exc
    if done.returncode != 0 or not target.is_file() or target.stat().st_size != expected:
        try:
            target.unlink()
        except OSError:
            pass
        raise RuntimeError("could not prepare that thumbnail")
    return {"path": str(target), "width": w, "height": h, "stride": w * 4}


def font_families() -> dict:
    """The installed families, so the panel can offer only real choices."""
    return {"families": sorted(_installed_font_families())[:2000]}


def _coerce_setting(name, value):
    default, low, high = SETTINGS_SCHEMA[name]
    if isinstance(default, bool):
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            return value.strip().lower() in ("1", "true", "yes", "on")
        return bool(value)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    number = max(low, min(high, number))
    return int(round(number)) if isinstance(default, int) else round(number, 3)


def load_settings() -> dict:
    try:
        stored = json.loads(_SETTINGS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        stored = {}
    if not isinstance(stored, dict):
        stored = {}
    values = {
        name: _coerce_setting(name, stored[name]) if name in stored else default
        for name, (default, _low, _high) in SETTINGS_SCHEMA.items()
    }
    values.update({
        name: _coerce_text_setting(name, stored[name]) if name in stored else default
        for name, default in SETTINGS_TEXT_SCHEMA.items()
    })
    return values


_SETTINGS_LOCK = threading.Lock()


def save_settings(req: dict) -> dict:
    values = req.get("values")
    if not isinstance(values, dict):
        raise ValueError("missing settings values")
    unknown = set(values) - set(SETTINGS_SCHEMA) - set(SETTINGS_TEXT_SCHEMA)
    if unknown:
        raise ValueError(f"unknown setting: {sorted(unknown)[0]}")
    with _SETTINGS_LOCK:
        return _save_settings_locked(values)


def _save_settings_locked(values: dict) -> dict:
    merged = load_settings()
    for name, value in values.items():
        merged[name] = (_coerce_text_setting(name, value) if name in SETTINGS_TEXT_SCHEMA
                        else _coerce_setting(name, value))
    _SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = _scratch_path(_SETTINGS_FILE)
    tmp.write_text(json.dumps(merged, separators=(",", ":")), encoding="utf-8")
    os.replace(tmp, _SETTINGS_FILE)
    return merged


def reset_settings() -> dict:
    try:
        _SETTINGS_FILE.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError(f"could not reset settings: {exc}") from exc
    return load_settings()


def _validated_mpv_socket(value) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("missing player session")
    runtime_dir = os.path.realpath(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir())
    path = os.path.realpath(value)
    if os.path.dirname(path) != runtime_dir or not os.path.basename(path).startswith("omamovie-mpv-") or not path.endswith(".sock"):
        raise ValueError("invalid player session")
    return path


def _validated_mpv_commands(value) -> list[list]:
    if not isinstance(value, list) or not value or len(value) > 16:
        raise ValueError("invalid player command list")
    allowed_commands = {"loadfile", "sub-add", "set", "playlist-clear", "playlist-remove",
                        "playlist-next", "script-message"}
    commands = []
    for command in value:
        if not isinstance(command, list) or not command or command[0] not in allowed_commands:
            raise ValueError("unsupported player command")
        name = command[0]
        if name == "loadfile":
            if len(command) < 2 or not safe_http_url(command[1]):
                raise ValueError("player media URLs must be http(s)")
        if name == "sub-add":
            # Subtitles may also be files this bridge downloaded itself, since
            # mpv's network timeout is too short for these hosts. Only paths
            # inside our own subtitle cache are accepted.
            if len(command) < 2 or not isinstance(command[1], str):
                raise ValueError("invalid subtitle source")
            source = command[1]
            if not safe_http_url(source):
                resolved = os.path.realpath(source[7:] if source.startswith("file://") else source)
                subtitle_cache = os.path.realpath(str(subtitle_dir()))
                if os.path.commonpath([resolved, subtitle_cache]) != subtitle_cache:
                    raise ValueError("subtitle files must come from the OmaCine cache")
        if name == "loadfile":
            if len(command) != 5 or command[2] != "insert-next" or command[3] != -1 or not isinstance(command[4], dict):
                raise ValueError("invalid playlist item")
            options = command[4]
            # "start" is allowed so a queued episode can override the global
            # --start used to resume the current one.
            if set(options) - {"force-media-title", "http-header-fields", "start"} or not all(isinstance(value, str) for value in options.values()):
                raise ValueError("unsupported playlist option")
        elif name == "sub-add" and (len(command) not in (2, 3) or (len(command) == 3 and command[2] not in ("auto", "select"))):
            raise ValueError("invalid subtitle command")
        elif name == "set" and (len(command) != 3 or command[1] != "sid" or command[2] not in ("no", "auto")):
            raise ValueError("invalid player property command")
        elif name == "playlist-clear" and len(command) != 1:
            raise ValueError("invalid playlist command")
        elif name == "playlist-remove" and (len(command) != 2 or not isinstance(command[1], int) or command[1] < 0):
            raise ValueError("invalid playlist removal")
        elif name == "playlist-next" and (len(command) != 2 or command[1] != "force"):
            raise ValueError("invalid playlist advance")
        elif name == "script-message":
            # Only messages addressed to OmaCine's own overlay script, with
            # short string arguments. Nothing else may be driven this way.
            if not 2 <= len(command) <= 6 or command[1] not in ("omacine-upnext", "omacine-clear",
                                                                "omacine-intro", "omacine-thumb",
                                                                "omacine-loading"):
                raise ValueError("unsupported script message")
            if not all(isinstance(part, str) and len(part) <= 200 for part in command[1:]):
                raise ValueError("invalid script message argument")
        commands.append(command)
    return commands


def _mpv_exchange(socket_path: str, commands: list[list]) -> list[dict]:
    path = _validated_mpv_socket(socket_path)
    pending = set(range(1, len(commands) + 1))
    responses = {}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2.0)
        client.connect(path)
        for request_id, command in enumerate(commands, 1):
            payload = json.dumps({"command": command, "request_id": request_id}, separators=(",", ":"))
            client.sendall(payload.encode("utf-8") + b"\n")
        buffer = b""
        while pending:
            chunk = client.recv(65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    response = json.loads(line.decode("utf-8"))
                except (ValueError, UnicodeError):
                    continue
                request_id = response.get("request_id") if isinstance(response, dict) else None
                if request_id in pending:
                    responses[request_id] = response
                    pending.remove(request_id)
    if pending:
        raise RuntimeError("player session did not respond")
    return [responses[index] for index in range(1, len(commands) + 1)]

def _stremio_module():
    global _STREMIO_MODULE
    if _STREMIO_MODULE is None:
        try:
            import stremio as module
        except ImportError:
            from bridge.python import stremio as module
        _STREMIO_MODULE = module
    return _STREMIO_MODULE


class _LazyStremioModule:
    def __getattr__(self, name):
        return getattr(_stremio_module(), name)


stremio = _LazyStremioModule()


def _introdb_module():
    global _INTRODB_MODULE
    if _INTRODB_MODULE is None:
        try:
            import introdb as module
        except ImportError:
            from bridge.python import introdb as module
        _INTRODB_MODULE = module
    return _INTRODB_MODULE


def _mdblist_module():
    global _MDBLIST_MODULE
    if _MDBLIST_MODULE is None:
        try:
            import mdblist as module
        except ImportError:
            from bridge.python import mdblist as module
        _MDBLIST_MODULE = module
    return _MDBLIST_MODULE


def _showcal_module():
    global _SHOWCAL_MODULE
    if _SHOWCAL_MODULE is None:
        try:
            import showcal as module
        except ImportError:
            from bridge.python import showcal as module
        _SHOWCAL_MODULE = module
    return _SHOWCAL_MODULE


def _icscal_module():
    global _ICSCAL_MODULE
    if _ICSCAL_MODULE is None:
        try:
            import icscal as module
        except ImportError:
            from bridge.python import icscal as module
        _ICSCAL_MODULE = module
    return _ICSCAL_MODULE


def _themerr_module():
    global _THEMERR_MODULE
    if _THEMERR_MODULE is None:
        try:
            import themerr as module
        except ImportError:
            from bridge.python import themerr as module
        _THEMERR_MODULE = module
    return _THEMERR_MODULE


def _tmdb_module():
    global _TMDB_MODULE
    if _TMDB_MODULE is None:
        try:
            import tmdb as module
        except ImportError:
            from bridge.python import tmdb as module
        _TMDB_MODULE = module
    return _TMDB_MODULE


def str_arg(req: dict, key: str) -> str:
    v = req.get(key)
    return str(v) if isinstance(v, str) else ""

def usz_arg(req: dict, key: str, default: int) -> int:
    v = req.get(key)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        try:
            return int(v)
        except:
            return default
    if isinstance(v, str) and v.isdigit():
        try:
            return int(v)
        except:
            return default
    return default

def safe_http_url(u) -> str:
    if isinstance(u, str) and (u.startswith("https://") or u.startswith("http://")):
        return u
    return ""

def sanitize_details_value(value):
    # Enforce http(s) scheme on any URL that can reach QML Image.source
    if not isinstance(value, dict):
        return value
    for key in ("cover", "stills", "trailer"):
        node = value.get(key)
        if isinstance(node, dict) and isinstance(node.get("url"), str):
            node["url"] = safe_http_url(node["url"])
    return value

def run(cmd: str, req: dict):
    # Catalog add-ons are the only provider; callers may still send `provider`
    # for compatibility but it no longer selects anything.
    if cmd == "ping":
        return {"pong": True}

    elif cmd == "suggest":
        q = str_arg(req, "q")
        return {"suggestions": stremio.suggest(q) if q.strip() else []}

    elif cmd == "search":
        q = str_arg(req, "q")
        if not q:
            raise ValueError("missing q")
        return {"items": stremio.search(q), "provider": "stremio"}

    elif cmd == "details":
        idv = str_arg(req, "id")
        if not idv:
            raise ValueError("missing id")
        return {"value": sanitize_details_value(stremio.details(idv)), "provider": "stremio"}

    elif cmd == "resources":
        idv = str_arg(req, "id")
        season = usz_arg(req, "season", 0)
        episode = usz_arg(req, "episode", 0)
        if not idv:
            raise ValueError("missing id")
        items = stremio_streams_cached(idv, season, episode)
        return {"items": items, "value": {"list": items}, "provider": "stremio", "resolvedId": idv}

    elif cmd == "prepare_next":
        idv = str_arg(req, "id")
        season = usz_arg(req, "season", 0)
        episode = usz_arg(req, "episode", 0)
        current_stream = req.get("currentStream")
        if not idv or season < 1 or episode < 1 or not isinstance(current_stream, dict):
            raise ValueError("missing next episode context")
        items = stremio_streams_cached(idv, season, episode)
        selected = stremio.select_continuation(current_stream, items)
        return {
            "selected": selected,
            "candidateCount": len(items),
            "season": season,
            "episode": episode,
            "provider": "stremio",
        }

    elif cmd == "mpv_status":
        socket_path = _validated_mpv_socket(req.get("socketPath"))
        # demuxer-cache-duration is the honest buffer number: seconds of
        # contiguous content ahead of the playhead. The torrent engine's
        # streamProgress counts pieces anywhere in the file, so it can read
        # "cached" while the very next piece needed is still missing.
        properties = ("path", "playlist-pos", "playlist-count", "time-pos", "time-remaining", "duration", "pause", "idle-active",
                      "paused-for-cache", "demuxer-cache-duration", "cache-speed")
        try:
            responses = _mpv_exchange(socket_path, [["get_property", name] for name in properties])
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
            return {"value": {"available": False}}
        values = {}
        for name, response in zip(properties, responses):
            if response.get("error") == "success":
                values[name] = response.get("data")
        values["available"] = True
        return {"value": values}

    elif cmd == "mpv_command":
        socket_path = _validated_mpv_socket(req.get("socketPath"))
        commands = _validated_mpv_commands(req.get("commands"))
        responses = _mpv_exchange(socket_path, commands)
        errors = [response.get("error") for response in responses if response.get("error") != "success"]
        if errors:
            raise RuntimeError("player rejected command: " + str(errors[0]))
        return {"value": {"accepted": len(responses)}}

    elif cmd == "release_stream":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        return {"value": stremio.release_stream(url), "provider": "stremio"}

    elif cmd == "warm_stream":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        return {"value": stremio.warm_stream(url), "provider": "stremio"}

    elif cmd == "stream_status":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        return {"value": stremio.stream_status(url), "provider": "stremio"}

    elif cmd == "captions":
        idv = str_arg(req, "id")
        season = usz_arg(req, "season", 0)
        episode = usz_arg(req, "episode", 0)
        return {"options": stremio.subtitles(idv, season, episode)}

    elif cmd == "subtitle_fetch":
        # mpv aborts network reads at --network-timeout, and these subtitle
        # hosts routinely take 5-16 s. Fetch them here instead, where the
        # pooled session can wait, then hand mpv a local file.
        urls = req.get("urls")
        if not isinstance(urls, list) or not urls:
            return {"paths": {}}
        prune_subtitle_cache()
        target = subtitle_dir()
        wanted = []
        seen = set()
        for value in urls[:12]:
            safe = safe_http_url(value)
            if safe and safe not in seen:
                seen.add(safe)
                wanted.append(safe)

        def _fetch_one(url):
            name = hashlib.sha256(url.encode("utf-8")).hexdigest()[:20] + ".srt"
            path = target / name
            if path.exists() and path.stat().st_size > 0:
                return url, str(path)
            data = net.fetch_image(url, timeout=25.0, limit=8 * 1024 * 1024)
            if not data:
                return url, ""
            try:
                tmp = path.with_suffix(".new")
                tmp.write_bytes(data)
                os.replace(tmp, path)
            except OSError:
                return url, ""
            return url, str(path)

        out = {}
        try:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=6) as pool:
                for url, path in pool.map(_fetch_one, wanted):
                    if path:
                        out[url] = path
        except Exception:
            for url in wanted:
                _, path = _fetch_one(url)
                if path:
                    out[url] = path
        return {"paths": out}

    elif cmd == "poster":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing url")
        url = safe_http_url(url)
        if not url:
            raise ValueError("poster url must be http(s)")
        prune_poster_cache(max_bytes=int(load_settings()["cachePostersMB"]) * 1024 * 1024)
        short = hashlib.md5(url.encode()).hexdigest()[:16]
        pdir = poster_dir()
        for ext in ["jpg", "png", "webp", "img"]:
            path = pdir / f"{short}.{ext}"
            if path.exists():
                return {"path": str(path)}
        data = net.fetch_image(url)
        if not data:
            raise RuntimeError("poster download failed")
        if not data:
            raise RuntimeError("poster download returned no data")
        ext = detect_ext(data)
        path = pdir / f"{short}.{ext}"
        try:
            path.write_bytes(data)
        except Exception as e:
            raise RuntimeError(str(e))
        return {"path": str(path)}

    elif cmd == "posters":
        prune_poster_cache(max_bytes=int(load_settings()["cachePostersMB"]) * 1024 * 1024)
        urls = req.get("urls")
        if not isinstance(urls, list) or not urls:
            return {"paths": {}}
        # dedupe, http(s) only
        seen = set()
        uniq = []
        for u in urls:
            if not isinstance(u, str) or u in seen:
                continue
            seen.add(u)
            s = safe_http_url(u)
            if s:
                uniq.append(s)
        out = {}
        def _one(u):
            short = hashlib.md5(u.encode()).hexdigest()[:16]
            pdir = poster_dir()
            for ext in ("jpg", "png", "webp", "img"):
                p = pdir / f"{short}.{ext}"
                if p.exists():
                    return u, str(p)
            data = net.fetch_image(u)
            if not data:
                return u, ""
            p = pdir / f"{short}.{detect_ext(data)}"
            try:
                p.write_bytes(data)
                return u, str(p)
            except:
                return u, ""
        # parallel downloads, single python process
        try:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(max_workers=8) as ex:
                for u, p in ex.map(_one, uniq):
                    if p:
                        out[u] = p
        except Exception:
            for u in uniq:
                _, p = _one(u)
                if p:
                    out[u] = p
        return {"paths": out}

    elif cmd in ("homepage", "discover", "home"):
        return stremio.discover(
            media_type=str_arg(req, "mediaType") or "all",
            catalog_key=str_arg(req, "catalogKey"),
            genre=str_arg(req, "genre"),
            year=str_arg(req, "year"),
            sort=str_arg(req, "sort") or "popular",
            limit=usz_arg(req, "perPage", 80),
            page=usz_arg(req, "page", 1),
        )

    elif cmd == "watch_list":
        return watch_state()

    elif cmd == "watch_progress":
        return {"entry": save_watch_progress(req)}

    elif cmd == "watch_remove":
        key = str_arg(req, "key")
        if not key:
            raise ValueError("missing watch entry")
        entries = _watch_entries()
        kept = [entry for entry in entries if entry.get("key") != key]
        _write_watch_entries(kept)
        return {"removed": len(kept) != len(entries)}

    elif cmd == "library_list":
        return library_state()

    elif cmd == "library_toggle":
        return toggle_library(req)

    elif cmd == "addons":
        return stremio.addon_status()

    elif cmd == "addon_add":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing manifest URL")
        return {"addon": stremio.add_manifest(url)}

    elif cmd == "addon_remove":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing manifest URL")
        return stremio.remove_manifest(url)

    elif cmd == "addon_toggle":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing manifest URL")
        return stremio.toggle_manifest(url, req.get("enabled") is True)

    elif cmd == "resolver_add":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing resolver URL")
        return {"resolver": stremio.add_resolver(url)}

    elif cmd == "resolver_remove":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing resolver URL")
        return stremio.remove_resolver(url)

    elif cmd == "resolver_toggle":
        url = str_arg(req, "url")
        if not url:
            raise ValueError("missing resolver URL")
        return stremio.toggle_resolver(url, req.get("enabled") is True)

    elif cmd == "tmdb_status":
        return _tmdb_module().status()

    elif cmd == "tmdb_configure":
        return _tmdb_module().configure(req.get("readAccessToken"))

    elif cmd == "tmdb_clear":
        return _tmdb_module().clear()

    elif cmd == "tmdb_home":
        payload = _tmdb_module().home()
        _save_home_snapshot(payload)
        return payload

    elif cmd == "cache_usage":
        return cache_usage()

    elif cmd == "cache_clear":
        return cache_clear(req.get("name"))

    elif cmd == "thumb_raw":
        return thumb_raw(req.get("source"), req.get("width"), req.get("height"))

    elif cmd == "font_families":
        return font_families()

    elif cmd == "settings_get":
        return {"settings": load_settings()}

    elif cmd == "settings_set":
        return {"settings": save_settings(req)}

    elif cmd == "settings_reset":
        return {"settings": reset_settings()}

    elif cmd == "home_snapshot":
        # Pure disk read: lets the panel paint the last known feed on frame one
        # while tmdb_home revalidates behind it.
        return _load_home_snapshot()

    elif cmd == "tmdb_enrich":
        return _tmdb_module().enrich(req.get("id"), req.get("mediaType"), req.get("season", 0))

    elif cmd == "tmdb_season":
        return _tmdb_module().season(req.get("id"), req.get("season", 0), req.get("mediaType"))

    elif cmd == "intro_lookup":
        return _introdb_module().intro(req.get("imdbId"), req.get("season"), req.get("episode"))

    elif cmd == "mdblist_status":
        return _mdblist_module().status()

    elif cmd == "mdblist_configure":
        return _mdblist_module().configure(req.get("apiKey"))

    elif cmd == "mdblist_clear":
        return _mdblist_module().clear()

    elif cmd == "mdblist_ratings":
        return _mdblist_module().ratings(req.get("id"), req.get("mediaType"))

    elif cmd == "theme_lookup":
        return _themerr_module().lookup(req.get("id"), req.get("mediaType"),
                                        refresh=req.get("refresh") is True)

    elif cmd == "theme_fetch":
        return _themerr_module().fetch(req.get("id"), req.get("mediaType"),
                                       req.get("mediaKind"), req.get("title"),
                                       req.get("year"))

    elif cmd == "theme_set_url":
        return _themerr_module().set_override(req.get("id"), req.get("mediaType"),
                                              req.get("url"))

    elif cmd == "theme_clear":
        return _themerr_module().clear(req.get("id"), req.get("mediaType"))

    elif cmd == "calendar_feed_status":
        return _icscal_module().status()

    elif cmd == "calendar_feed_set":
        return _icscal_module().configure(req.get("url"))

    elif cmd == "calendar_month":
        # A whole month of the user's own shows, the way Stremio does it:
        # every dated episode from Cinemeta, not just the next one.
        month = str(req.get("month") or "")
        if not re.fullmatch(r"\d{4}-\d{2}", month):
            month = datetime.date.today().strftime("%Y-%m")
        year, mon = int(month[:4]), int(month[5:7])
        first = datetime.date(year, mon, 1)
        last = datetime.date(year + (mon == 12), (mon % 12) + 1, 1) - datetime.timedelta(days=1)
        rows = _showcal_module().entries(_library_entries(), _watch_entries(),
                                         first.isoformat(), last.isoformat())
        days = {}
        for row in rows:
            days.setdefault(row["date"], []).append(row)
        for value in days.values():
            value.sort(key=lambda r: (r["title"].lower(), r["season"], r["episode"]))

        # The side rail looks forward from today regardless of the month shown,
        # so "what is next" is always answerable without paging.
        today = datetime.date.today()
        ahead = _showcal_module().entries(
            _library_entries(), _watch_entries(), today.isoformat(),
            (today + datetime.timedelta(days=90)).isoformat())
        upcoming = {}
        for row in ahead:
            upcoming.setdefault(row["date"], []).append(row)
        rail = [{"date": d, "entries": sorted(upcoming[d], key=lambda r: (r["title"].lower(), r["episode"]))}
                for d in sorted(upcoming)][:40]
        return {"month": month, "first": first.isoformat(), "last": last.isoformat(),
                "today": today.isoformat(),
                "days": [{"date": d, "entries": days[d]} for d in sorted(days)],
                "upcoming": rail}

    elif cmd == "tmdb_calendar":
        # The library is passed in rather than read inside tmdb.py: that module
        # knows about TMDB, not about where OmaCine keeps its state.
        return _tmdb_module().calendar(_library_entries(), _watch_entries())

    elif cmd == "tmdb_person":
        return _tmdb_module().person(req.get("id"))

    else:
        raise ValueError(f"unknown command: {cmd}")

_STREAM_MEMO: dict = {}


def _retarget_local_streams(items: list) -> list:
    """Point cached loopback links at the streaming server we run today.

    A cached list stores absolute http://127.0.0.1:<port>/... links. OmaCine
    moved off Stremio Enhanced's 11470 onto its own port, so any list cached
    before that move hands mpv a URL nothing is listening on and playback
    fails with "Could not load this stream". The rest of the entry is still
    perfectly good, so rewrite the origin on read instead of discarding it.
    """
    try:
        cfg = stremio.load_config()
        server = stremio._safe_url(cfg.get("streamingServer")) or stremio.DEFAULT_SERVER
    except Exception:
        server = stremio.DEFAULT_SERVER
    wanted = urlparse(server)
    if wanted.scheme != "http" or not wanted.netloc:
        return items
    origin = f"{wanted.scheme}://{wanted.netloc}"
    for item in items:
        if not isinstance(item, dict):
            continue
        link = item.get("resourceLink")
        if not isinstance(link, str) or not link:
            continue
        bits = urlparse(link)
        if bits.hostname not in ("127.0.0.1", "localhost", "::1"):
            continue
        current = f"{bits.scheme}://{bits.netloc}"
        if current != origin:
            item["resourceLink"] = origin + link[len(current):]
    return items


def stremio_streams_cached(media_id: str, season: int, episode: int) -> list:
    """Cache the assembled stream list, not just the add-on HTTP responses.

    The per-add-on responses were already disk-cached, but every call still
    re-parsed, normalized and re-sorted them. Re-selecting an episode is a very
    common action, so memoize the finished list: in-process first (instant in
    daemon mode), then the shared on-disk provider cache across restarts.
    """
    key = (media_id, int(season), int(episode))
    hit = _STREAM_MEMO.get(key)
    if hit is not None and time.time() - hit[0] < 1800:
        return _retarget_local_streams(hit[1])

    stored = get_provider_stream_cache("stremio", media_id, season, episode)
    if isinstance(stored, dict) and isinstance(stored.get("list"), list):
        cached = _retarget_local_streams(stored["list"])
        _STREAM_MEMO[key] = (time.time(), cached)
        return cached

    items = stremio.streams(media_id, season, episode)
    if items:
        _STREAM_MEMO[key] = (time.time(), items)
        try:
            set_provider_stream_cache("stremio", media_id, season, episode, {"list": items})
        except Exception:
            pass
    return items


def _dispatch(raw: str) -> dict:
    """Turn one request line into a response dict. Shared by one-shot and
    daemon modes so both behave identically."""
    try:
        req = json.loads(raw)
        if not isinstance(req, dict):
            raise ValueError("bad request: not an object")
        cmd = req.get("cmd")
        if not isinstance(cmd, str):
            raise ValueError("missing cmd")
        rest = {k: v for k, v in req.items() if k not in ("cmd", "_rid")}
        data = run(cmd, rest)
        resp = {"ok": True, "error": None}
        resp.update(data)
        return resp
    except Exception as exc:
        err = str(exc)
        return {"ok": False, "error": err if "bad request" in err else f"bad request: {err}"}


def _source_stamp() -> str:
    """Identity of the installed bridge. A plugin update rewrites these files,
    and a daemon still holding the old code must not keep serving it."""
    try:
        newest = 0.0
        for path in sorted(_py_dir.glob("*.py")):
            newest = max(newest, path.stat().st_mtime)
        return f"{newest:.3f}"
    except OSError:
        return ""


DAEMON_IDLE_TIMEOUT = 15 * 60


def _serve_daemon() -> None:
    """Persistent stdio server.

    Requests and responses are newline-delimited JSON correlated by `id`, so the
    panel can keep several calls in flight and a slow stream scrape never blocks
    a poster fetch behind it.
    """
    import threading
    from concurrent.futures import ThreadPoolExecutor

    write_lock = threading.Lock()
    stamp = _source_stamp()
    last_activity = [time.time()]

    def emit(payload: dict) -> None:
        line = json.dumps(payload, separators=(",", ":"))
        with write_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def handle(request_id, raw: str) -> None:
        try:
            resp = _dispatch(raw)
        except Exception as exc:  # never let a worker kill the daemon
            resp = {"ok": False, "error": f"bad request: {exc}"}
        resp["_rid"] = request_id
        emit(resp)

    def watchdog() -> None:
        while True:
            time.sleep(30)
            if _source_stamp() != stamp:
                emit({"_rid": 0, "ok": False, "error": "bridge updated", "reload": True})
                os._exit(0)
            if time.time() - last_activity[0] > DAEMON_IDLE_TIMEOUT:
                os._exit(0)

    threading.Thread(target=watchdog, daemon=True).start()
    emit({"_rid": 0, "ok": True, "error": None, "ready": True, "stamp": stamp})

    with ThreadPoolExecutor(max_workers=8) as pool:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            if len(line) > 262144:
                emit({"_rid": 0, "ok": False, "error": "bad request: input is too large"})
                continue
            last_activity[0] = time.time()
            try:
                request_id = json.loads(line).get("_rid")
            except (ValueError, AttributeError):
                request_id = None
            pool.submit(handle, request_id, line)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--daemon":
        _serve_daemon()
        return
    if len(sys.argv) > 1:
        raw = sys.argv[1]
    else:
        raw_bytes = sys.stdin.buffer.readline(16385)
        if len(raw_bytes) > 16384:
            raw = ""
            print(json.dumps({"ok": False, "error": "bad request: input is too large"}, separators=(',', ':')))
            return
        raw = raw_bytes.decode("utf-8", errors="strict")
    try:
        req = json.loads(raw)
        if not isinstance(req, dict):
            raise ValueError("bad request: not an object")
        cmd = req.get("cmd")
        if not isinstance(cmd, str):
            raise ValueError("missing cmd")
        rest = {k: v for k, v in req.items() if k != "cmd"}
        data = run(cmd, rest)
        resp = {"ok": True, "error": None}
        resp.update(data)
        print(json.dumps(resp, separators=(',', ':')))
    except Exception as e:
        err = str(e)
        try:
            print(json.dumps({"ok": False, "error": f"bad request: {err}" if "bad request" not in err else err}, separators=(',', ':')))
        except:
            print(json.dumps({"ok": False, "error": err}))
        return

if __name__ == "__main__":
    main()
