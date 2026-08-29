"""Episode calendar for followed shows, built the way Stremio builds it.

Cinemeta's meta endpoint returns *every* episode of a series with a release
timestamp, in one request. That is the whole trick: a calendar wants the full
schedule, not the one-next-and-one-last that TMDB's summary fields give, which
is why a season that drops nine episodes at once shows nine entries on the day.

Everything here is per-series and cached on disk, so paging between months is
free after the first build.
"""
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import net
except ImportError:
    from bridge.python import net

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "showcal"
CINEMETA = "https://v3-cinemeta.strem.io/meta/series"
META_TTL = 12 * 60 * 60          # airing shows gain episodes; a day is too slow
ID_MAP = CACHE_DIR / "imdb-map.json"
MAX_META_BYTES = 6 * 1024 * 1024


def _read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None


def _write_json(path: Path, value) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def _imdb_for(media_id: str) -> str:
    """Library ids come as tmdb: or tt:. Cinemeta only speaks IMDb."""
    raw = str(media_id or "")
    direct = re.search(r"tt\d{5,12}", raw)
    if direct:
        return direct.group(0)
    match = re.search(r"tmdb:(\d+)", raw)
    if not match:
        return ""
    mapping = _read_json(ID_MAP) or {}
    key = match.group(1)
    if key in mapping:
        return str(mapping[key] or "")
    try:
        try:
            import tmdb as tmdb_module
        except ImportError:
            from bridge.python import tmdb as tmdb_module
        payload = tmdb_module._request(f"/tv/{key}/external_ids", {})
        imdb = str(payload.get("imdb_id") or "")
    except Exception:
        imdb = ""
    mapping[key] = imdb
    _write_json(ID_MAP, mapping)
    return imdb


def _meta_path(imdb_id: str) -> Path:
    return CACHE_DIR / f"{imdb_id}.json"


def episodes_for(imdb_id: str) -> dict:
    """Every dated episode of one series, plus its poster."""
    if not re.fullmatch(r"tt\d{5,12}", imdb_id or ""):
        return {}
    path = _meta_path(imdb_id)
    try:
        if time.time() - path.stat().st_mtime < META_TTL:
            cached = _read_json(path)
            if isinstance(cached, dict):
                return cached
    except OSError:
        pass
    try:
        raw = net.get_bytes(f"{CINEMETA}/{imdb_id}.json", {"Accept": "application/json"},
                            12.0, MAX_META_BYTES)
        meta = (json.loads(raw.decode("utf-8")) or {}).get("meta") or {}
    except Exception:
        cached = _read_json(path)
        return cached if isinstance(cached, dict) else {}

    seasons = {}
    episodes = []
    for video in meta.get("videos") or []:
        if not isinstance(video, dict):
            continue
        released = str(video.get("released") or video.get("firstAired") or "")
        if not released:
            continue
        season = int(video.get("season") or 0)
        number = int(video.get("episode") or video.get("number") or 0)
        if season <= 0 or number <= 0:      # specials carry season 0
            continue
        seasons[season] = max(seasons.get(season, 0), number)
        episodes.append({
            "season": season, "episode": number,
            "name": str(video.get("name") or "")[:200],
            "released": released,
        })
    value = {
        "imdb": imdb_id,
        "title": str(meta.get("name") or "")[:200],
        "poster": str(meta.get("poster") or "")[:400],
        "background": str(meta.get("background") or "")[:400],
        "episodes": episodes,
        # Kept so a finale can be identified without a second lookup.
        "seasonEnds": {str(k): v for k, v in seasons.items()},
    }
    _write_json(path, value)
    return value


def _local_date(stamp: str) -> str:
    text = str(stamp or "")
    try:
        if text.endswith("Z"):
            when = datetime.fromisoformat(text.replace("Z", "+00:00"))
        else:
            when = datetime.fromisoformat(text)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return when.astimezone().date().isoformat()
    except ValueError:
        return text[:10] if len(text) >= 10 else ""


def entries(library: object, watch: object, since: str, until: str) -> list[dict]:
    """Dated episodes of followed series inside a window."""
    from concurrent.futures import ThreadPoolExecutor

    watched = set()
    for row in (watch if isinstance(watch, list) else []):
        if isinstance(row, dict) and row.get("completed"):
            watched.add((str(row.get("id") or ""), int(row.get("season") or 0),
                         int(row.get("episode") or 0)))

    shows = []
    for row in (library if isinstance(library, list) else []):
        if not isinstance(row, dict):
            continue
        media_id = str(row.get("id") or "")
        if not media_id.startswith("series|"):
            continue
        shows.append(media_id)
    if not shows:
        return []

    def build(media_id):
        imdb = _imdb_for(media_id)
        return media_id, (episodes_for(imdb) if imdb else {})

    out = []
    with ThreadPoolExecutor(max_workers=min(10, len(shows))) as pool:
        for media_id, meta in pool.map(build, shows):
            if not meta:
                continue
            ends = meta.get("seasonEnds") or {}
            for episode in meta.get("episodes") or []:
                date = _local_date(episode["released"])
                if not (since <= date <= until):
                    continue
                season, number = episode["season"], episode["episode"]
                out.append({
                    "kind": "episode",
                    "date": date,
                    "id": media_id,
                    "title": meta.get("title") or "",
                    "cover": meta.get("poster") or "",
                    "backdrop": meta.get("background") or "",
                    "season": season,
                    "episode": number,
                    "episodeTitle": episode.get("name") or "",
                    "isPremiere": season == 1 and number == 1,
                    "isSeasonPremiere": season > 1 and number == 1,
                    "isFinale": number >= int(ends.get(str(season)) or 0) > 0,
                    "inLibrary": True,
                    "followed": True,
                    "playable": True,
                    "watched": (media_id, season, number) in watched,
                    "source": "cinemeta",
                })
    return out
