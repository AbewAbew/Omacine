"""IntroDB client — intro timestamps for episodes whose file has no chapters.

Chapters, when a release ships them, are exact: they come from the file itself.
This is the fallback for everything else, and it is crowd-sourced, so the
numbers are treated as a hint rather than truth:

  * a result is only used when it is long enough and lands early enough to
    plausibly be an intro;
  * `submission_count` is surfaced so a single unverified entry can be told
    apart from a corroborated one.

No API key. A 404 means "nobody has submitted this episode", which is the
common case and not an error.
"""
import json
import os
import re
import time
from urllib.parse import urlencode
from pathlib import Path

try:
    import net
except ImportError:
    from bridge.python import net

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "introdb"
API_BASE = "https://api.introdb.app/intro"
CACHE_TTL = 30 * 24 * 60 * 60      # submissions change rarely
MISS_TTL = 3 * 24 * 60 * 60        # re-check misses sooner; the DB grows
CACHE_MAX_AGE = 90 * 24 * 60 * 60
PRUNE_INTERVAL = 12 * 60 * 60

# An "intro" shorter than this is usually just a title card, and skipping it
# is more disruptive than watching it. Longer than this and something is wrong.
MIN_LENGTH = 10
MAX_LENGTH = 300
MAX_START = 900                    # intros do not begin 15 minutes in


def _cache_path(imdb_id: str, season: int, episode: int) -> Path:
    return CACHE_DIR / f"{imdb_id}-{season}-{episode}.json"


def _prune_cache() -> None:
    marker = CACHE_DIR / ".pruned"
    now = time.time()
    try:
        if marker.exists() and now - marker.stat().st_mtime < PRUNE_INTERVAL:
            return
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return
    for candidate in CACHE_DIR.glob("tt*.json"):
        try:
            if now - candidate.stat().st_mtime > CACHE_MAX_AGE:
                candidate.unlink()
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass


def _number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def intro(imdb_id: object, season: object, episode: object) -> dict:
    ident = str(imdb_id or "").strip()
    if not re.fullmatch(r"tt\d{5,12}", ident):
        raise ValueError("invalid IMDb id")
    try:
        season_number = int(season)
        episode_number = int(episode)
    except (TypeError, ValueError):
        raise ValueError("season and episode must be numbers")
    if season_number < 0 or episode_number < 1:
        raise ValueError("season and episode are out of range")

    _prune_cache()
    path = _cache_path(ident, season_number, episode_number)
    try:
        age = time.time() - path.stat().st_mtime
        cached = json.loads(path.read_text(encoding="utf-8"))
        # Misses expire sooner, since the database is still being filled in.
        ttl = CACHE_TTL if cached.get("found") else MISS_TTL
        if age < ttl and isinstance(cached, dict):
            return cached
    except (OSError, ValueError, TypeError):
        pass

    query = urlencode({"imdb_id": ident, "season": season_number, "episode": episode_number})
    result = {"found": False, "imdbId": ident, "season": season_number, "episode": episode_number}
    try:
        raw = net.get_bytes(f"{API_BASE}?{query}", {"Accept": "application/json"}, 6.0, 256 * 1024)
        payload = json.loads(raw.decode("utf-8"))
    except RuntimeError as exc:
        # 404 simply means nobody has submitted this episode yet.
        if "404" not in str(exc):
            raise
        payload = None
    except (ValueError, UnicodeError):
        payload = None

    if isinstance(payload, dict):
        start = _number(payload.get("start_sec"))
        end = _number(payload.get("end_sec"))
        if start is not None and end is not None:
            length = end - start
            plausible = (MIN_LENGTH <= length <= MAX_LENGTH
                         and 0 <= start <= MAX_START)
            if plausible:
                result = {
                    "found": True,
                    "imdbId": ident,
                    "season": season_number,
                    "episode": episode_number,
                    "start": round(start, 3),
                    "end": round(end, 3),
                    "length": round(length, 3),
                    # One submission is a guess; several is a consensus. The UI
                    # can use this to decide how much to trust the timings.
                    "submissions": int(_number(payload.get("submission_count")) or 0),
                    "confidence": _number(payload.get("confidence")) or 0,
                }

    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(result, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass
    return result
