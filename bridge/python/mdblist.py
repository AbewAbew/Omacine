"""MDbList ratings client.

Replaces the OMDb integration. Two concrete advantages:

  * it is keyed on the TMDB id OmaCine already holds, so no external_ids
    round trip is needed to reach it;
  * one request returns IMDb, Rotten Tomatoes, Metacritic, Trakt, Letterboxd,
    TMDB and RogerEbert together.

A personal API key authenticates as `?apikey=` — the Bearer header is only for
OAuth-issued access tokens, which are a different credential type. The key is
therefore kept out of cache filenames and error messages by hand. Like TMDB this
is optional: with no key configured every call reports "not configured" and the
UI simply omits the badges.
"""
import json
import os
import re
import time
from urllib.parse import quote
from pathlib import Path

try:
    import net
except ImportError:
    from bridge.python import net

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "omamovie"
CONFIG_PATH = CONFIG_DIR / "mdblist.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "mdblist"
API_BASE = "https://api.mdblist.com"
CACHE_TTL = 7 * 24 * 60 * 60
CACHE_MAX_AGE = 30 * 24 * 60 * 60
PRUNE_INTERVAL = 6 * 60 * 60

# MDbList source name -> the key OmaCine exposes to the panel.
SOURCES = {
    "imdb": "imdb",
    "metacritic": "metacritic",
    "metacriticuser": "metacriticUser",
    "tomatoes": "tomatoes",
    # MDbList names the Rotten Tomatoes audience score "popcorn", after the
    # popcorn-bucket mark; "tomatoesaudience" is accepted as an alias.
    "popcorn": "tomatoesAudience",
    "tomatoesaudience": "tomatoesAudience",
    "trakt": "trakt",
    "letterboxd": "letterboxd",
    "tmdb": "tmdb",
    "rogerebert": "rogerebert",
}


def _config() -> dict:
    try:
        value = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def status() -> dict:
    return {"configured": bool(str(_config().get("apiKey") or "").strip()),
            "configPath": str(CONFIG_PATH)}


def _validate_key(value: object) -> str:
    key = str(value or "").strip()
    if not 8 <= len(key) <= 128 or re.search(r"\s", key):
        raise ValueError("enter a valid MDbList API key")
    return key


def _write_config(value: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass
    tmp = CONFIG_PATH.with_suffix(".new")
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
    os.replace(tmp, CONFIG_PATH)
    os.chmod(CONFIG_PATH, 0o600)


def configure(api_key: object) -> dict:
    key = _validate_key(api_key)
    # /user is the documented way to check a key, and it costs nothing.
    url = f"{API_BASE}/user?apikey={quote(key, safe='')}"
    try:
        net.get_bytes(url, {"Accept": "application/json"}, 8.0, 256 * 1024)
    except RuntimeError as exc:
        raise RuntimeError(_auth_message(str(exc))) from exc
    _write_config({"apiKey": key})
    return status()


def clear() -> dict:
    try:
        CONFIG_PATH.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError(f"could not remove MDbList configuration: {exc}") from exc
    return status()


def _auth_message(message: str) -> str:
    """Translate a transport error without ever echoing the URL back."""
    if "401" in message or "403" in message:
        return "MDbList rejected that API key — copy it from mdblist.com/preferences"
    if "429" in message:
        return "MDbList rate limit reached — try again shortly"
    return "MDbList request failed"


def _cache_path(media_type: str, media_id: str) -> Path:
    return CACHE_DIR / f"{media_type}-{media_id}.json"


def _prune_cache() -> None:
    marker = CACHE_DIR / ".pruned"
    now = time.time()
    try:
        if marker.exists() and now - marker.stat().st_mtime < PRUNE_INTERVAL:
            return
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return
    for candidate in CACHE_DIR.glob("*.json"):
        if candidate.name == ".pruned":
            continue
        try:
            if now - candidate.stat().st_mtime > CACHE_MAX_AGE:
                candidate.unlink()
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass


def _fetch(media_type: str, media_id: str, *, source: str = "tmdb",
           key: str = "", cache: bool = True) -> dict:
    api_key = key or str(_config().get("apiKey") or "").strip()
    if not api_key:
        raise RuntimeError("MDbList is not configured")
    path = _cache_path(media_type, media_id)
    if cache:
        try:
            if time.time() - path.stat().st_mtime < CACHE_TTL:
                value = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(value, dict):
                    return value
        except (OSError, ValueError, TypeError):
            pass

    # Personal API keys authenticate by query parameter; Bearer is for OAuth
    # access tokens only. Never let this URL reach a log line or an exception.
    url = f"{API_BASE}/{source}/{media_type}/{media_id}?apikey={quote(api_key, safe='')}"
    try:
        raw = net.get_bytes(url, {"Accept": "application/json"}, 8.0, 2 * 1024 * 1024)
    except RuntimeError as exc:
        raise RuntimeError(_auth_message(str(exc))) from exc
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("MDbList returned an invalid response")
    if cache:
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".new")
            tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
            os.replace(tmp, path)
        except OSError:
            pass
    return value


def _number(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return None if number <= 0 else number


def _media_parts(value: object, media_type: object = "") -> tuple[str, str, str]:
    """OmaCine ids look like 'series|tmdb:108978' or 'series|tt36303968'.

    Catalogues that come from TMDB carry a tmdb id; Cinemeta and several other
    Stremio addons carry an IMDb one. MDbList indexes both, under different
    path prefixes, so the source is returned alongside the id rather than
    rejecting everything that is not TMDB.
    """
    raw = str(value or "")
    kind = str(media_type or "").lower()
    if raw.startswith("series|"):
        kind, raw = "show", raw.split("|", 1)[1]
    elif raw.startswith("movie|"):
        kind, raw = "movie", raw.split("|", 1)[1]
    elif kind in ("series", "tv", "2"):
        kind = "show"
    elif kind not in ("movie", "show"):
        kind = "movie"
    kind = "show" if kind in ("show", "series", "tv") else "movie"
    match = re.search(r"(?:^|\|)tmdb:(\d+)$", raw)
    if match:
        return kind, match.group(1), "tmdb"
    imdb = re.search(r"tt\d{5,12}", raw)
    if imdb:
        return kind, imdb.group(0), "imdb"
    match = re.fullmatch(r"\s*(\d{1,12})\s*", raw)
    if match:
        return kind, match.group(1), "tmdb"
    raise ValueError("MDbList needs a TMDB or IMDb id")


def ratings(media_id: object, media_type: object = "") -> dict:
    """Every rating MDbList holds for one title, normalized to 0-100."""
    kind, ident, source = _media_parts(media_id, media_type)
    _prune_cache()
    payload = _fetch(kind, ident, source=source)

    scores: dict[str, dict] = {}
    for entry in payload.get("ratings") or []:
        if not isinstance(entry, dict):
            continue
        name = SOURCES.get(str(entry.get("source") or "").strip().lower())
        if not name:
            continue
        value = _number(entry.get("value"))
        score = _number(entry.get("score"))
        if value is None and score is None:
            continue
        scores[name] = {
            "value": value,
            "score": score if score is not None else value,
            "votes": int(_number(entry.get("votes")) or 0),
        }

    def out_of_100(name):
        item = scores.get(name)
        if not item:
            return None
        number = item["score"]
        return int(round(number)) if number is not None else None

    tomatoes = out_of_100("tomatoes")
    metacritic = out_of_100("metacritic")
    return {
        "configured": True,
        "mediaType": kind,
        # MDbList hands back the whole id set, so an IMDb-keyed title still
        # yields the TMDB id everything else here is keyed on.
        "tmdbId": str((payload.get("ids") or {}).get("tmdb") or
                      (ident if source == "tmdb" else "")),
        "imdbId": str((payload.get("ids") or {}).get("imdb") or
                      (ident if source == "imdb" else "")),
        "found": bool(scores),
        "title": str(payload.get("title") or "")[:300],
        # Rotten Tomatoes calls >=60% fresh; Metacritic bands at 61 and 40.
        "tomatoes": tomatoes,
        "tomatoesFresh": None if tomatoes is None else tomatoes >= 60,
        "tomatoesAudience": out_of_100("tomatoesAudience"),
        "metacritic": metacritic,
        "metacriticBand": (None if metacritic is None
                           else "high" if metacritic >= 61
                           else "mixed" if metacritic >= 40 else "low"),
        "imdb": None if "imdb" not in scores else scores["imdb"]["value"],
        "trakt": out_of_100("trakt"),
        "letterboxd": None if "letterboxd" not in scores else scores["letterboxd"]["value"],
        "rogerebert": None if "rogerebert" not in scores else scores["rogerebert"]["value"],
        "sources": sorted(scores),
    }
