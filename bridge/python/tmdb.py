"""Credential-safe TMDB discovery and metadata client for OmaCine."""

from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
try:
    import net
except ImportError:
    from bridge.python import net
import datetime
import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "omamovie"
CONFIG_PATH = CONFIG_DIR / "tmdb.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "tmdb"
API_BASE = "https://api.themoviedb.org/3"
IMAGE_BASE = "https://image.tmdb.org/t/p"
CACHE_TTL = 24 * 60 * 60
HERO_ROTATION_LIMIT = 6


def _config() -> dict:
    try:
        value = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def status() -> dict:
    token = str(_config().get("readAccessToken") or "").strip()
    return {"configured": bool(token), "configPath": str(CONFIG_PATH)}


def _validate_token(value: object) -> str:
    token = str(value or "").strip()
    if not 20 <= len(token) <= 4096 or re.search(r"\s", token):
        raise ValueError("enter a valid TMDB API Read Access Token")
    return token


def _write_config(value: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(CONFIG_DIR, 0o700)
    except OSError:
        pass
    tmp = CONFIG_PATH.with_suffix(".new")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"))
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    os.replace(tmp, CONFIG_PATH)
    os.chmod(CONFIG_PATH, 0o600)


def configure(read_access_token: object) -> dict:
    token = _validate_token(read_access_token)
    # Validate before persisting so a typo never replaces a working credential.
    _request("/configuration", token=token, cache=False)
    _write_config({"readAccessToken": token})
    return status()


def clear() -> dict:
    try:
        CONFIG_PATH.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError(f"could not remove TMDB configuration: {exc}") from exc
    return status()


def _cache_path(url: str) -> Path:
    return CACHE_DIR / (hashlib.sha256(url.encode("utf-8")).hexdigest() + ".json")


def _request(path: str, params: dict | None = None, *, token: str = "", cache: bool = True) -> dict:
    auth = token or str(_config().get("readAccessToken") or "").strip()
    if not auth:
        raise RuntimeError("TMDB is not configured")
    query = urlencode(params or {})
    url = API_BASE + path + (("?" + query) if query else "")
    cache_path = _cache_path(url)
    now = time.time()
    if cache:
        try:
            if now - cache_path.stat().st_mtime < CACHE_TTL:
                value = json.loads(cache_path.read_text(encoding="utf-8"))
                if isinstance(value, dict):
                    return value
        except (OSError, ValueError, TypeError):
            pass
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {auth}",
        "User-Agent": "OmaCine/2.0 TMDBClient",
    }
    try:
        raw = net.get_bytes(url, headers, 8.0, 8 * 1024 * 1024)
        value = json.loads(raw.decode("utf-8"))
    except HTTPError as exc:
        if exc.code in (401, 403):
            raise RuntimeError("TMDB rejected the Read Access Token") from exc
        raise RuntimeError(f"TMDB request failed (HTTP {exc.code})") from exc
    except (URLError, TimeoutError, OSError, ValueError, UnicodeError) as exc:
        raise RuntimeError(f"TMDB request failed: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("TMDB returned an invalid response")
    if cache:
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            tmp = cache_path.with_suffix(".new")
            tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
            os.replace(tmp, cache_path)
        except OSError:
            pass
    return value


def _image(path: object, size: str = "w185") -> str:
    value = str(path or "")
    return f"{IMAGE_BASE}/{size}{value}" if value.startswith("/") else ""


def _media_item(item: dict, kind: str = "") -> dict:
    """Normalize a TMDB result into OmaCine's provider-neutral media shape."""
    media_kind = str(kind or item.get("media_type") or "").lower()
    if media_kind not in ("movie", "tv"):
        media_kind = "tv" if item.get("first_air_date") is not None else "movie"
    title = str(item.get("title") or item.get("name") or "").strip()
    release_date = str(item.get("release_date") or item.get("first_air_date") or "")
    try:
        rating = round(float(item.get("vote_average") or 0), 1)
    except (TypeError, ValueError):
        rating = 0.0
    tmdb_id = str(item.get("id") or "")
    return {
        "id": f"{'series' if media_kind == 'tv' else 'movie'}|tmdb:{tmdb_id}",
        "title": title[:300],
        "year": release_date[:4],
        "rating": rating,
        "cover": _image(item.get("poster_path"), "w342"),
        "backdrop": _image(item.get("backdrop_path"), "w1280"),
        "overview": str(item.get("overview") or "")[:4000],
        "stype": 2 if media_kind == "tv" else 1,
        "provider": "stremio",
    }


def _media_list(payload: dict, kind: str = "", limit: int = 20) -> list[dict]:
    out = []
    seen = set()
    for item in payload.get("results", []) if isinstance(payload.get("results"), list) else []:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        if not kind and item.get("media_type") not in ("movie", "tv"):
            continue
        normalized = _media_item(item, kind)
        if not normalized["title"] or normalized["id"] in seen:
            continue
        seen.add(normalized["id"])
        out.append(normalized)
        if len(out) >= limit:
            break
    return out


CALENDAR_DAYS = 28
# A week of history as well as the month ahead: an episode that aired two days
# ago is exactly the one you still need to watch.
CALENDAR_PAST_DAYS = 7


def _cal_entry(kind, date, title, tmdb_id, media, cover, backdrop, extra=None):
    return {
        "kind": kind,                       # episode | premiere | movie
        "date": str(date or "")[:10],
        "title": str(title or "")[:200],
        "id": ("series|tmdb:" if media == "tv" else "movie|tmdb:") + str(tmdb_id),
        "mediaType": media,
        "cover": cover or "",
        "backdrop": backdrop or "",
        **(extra or {}),
    }


def _episode_flags(payload: dict, episode: dict) -> dict:
    """Classify an episode the way an episode calendar needs to.

    A series premiere and a season premiere mean different things to a viewer -
    one is "something new exists", the other is "your show is back" - so they
    are distinguished rather than both being "episode 1".
    """
    season = int(episode.get("season_number") or 0)
    number = int(episode.get("episode_number") or 0)
    total = 0
    for item in payload.get("seasons") or []:
        if isinstance(item, dict) and int(item.get("season_number") or -1) == season:
            total = int(item.get("episode_count") or 0)
            break
    return {
        "season": season,
        "episode": number,
        "isPremiere": season == 1 and number == 1,
        "isSeasonPremiere": season > 1 and number == 1,
        # Finale detection depends on TMDB knowing the episode count, which it
        # does not always; a wrong "finale" is worse than none, so 0 means no.
        "isFinale": total > 0 and number >= total,
    }


def _library_episodes(library: list, watched: set, since: str, horizon: str) -> list[dict]:
    """Episodes of followed series in the window, recent ones included.

    One request per series, run in a pool. next_episode_to_air covers what is
    coming; last_episode_to_air covers the one that just aired, which is
    usually the one still waiting to be watched.
    """
    targets = []
    for entry in library or []:
        raw = str(entry.get("id") or "") if isinstance(entry, dict) else ""
        if not raw.startswith("series|"):
            continue
        try:
            _kind, tmdb_id = _media_parts(raw, "series")
        except (RuntimeError, ValueError):
            continue
        targets.append(tmdb_id)

    def fetch(tmdb_id):
        try:
            return tmdb_id, _request(f"/tv/{tmdb_id}", {"language": "en-US"})
        except RuntimeError:
            return tmdb_id, {}

    out = []
    if not targets:
        return out
    with ThreadPoolExecutor(max_workers=min(10, len(targets))) as pool:
        for tmdb_id, payload in pool.map(fetch, targets):
            for key in ("last_episode_to_air", "next_episode_to_air"):
                episode = payload.get(key)
                if not isinstance(episode, dict) or not episode.get("air_date"):
                    continue
                date = str(episode["air_date"])[:10]
                if not (since <= date <= horizon):
                    continue
                flags = _episode_flags(payload, episode)
                media_id = "series|tmdb:" + str(tmdb_id)
                out.append(_cal_entry(
                    "episode", date, payload.get("name"), tmdb_id, "tv",
                    _image(payload.get("poster_path")),
                    _image(payload.get("backdrop_path"), "w780"),
                    dict(flags,
                         episodeTitle=str(episode.get("name") or "")[:200],
                         inLibrary=True,
                         watched=(media_id, flags["season"], flags["episode"]) in watched)))
    return out


def _resolve_show(name: str) -> dict:
    """Find a TMDB series for a feed's show name. Cached: this is the slow part."""
    try:
        found = _request("/search/tv", {"query": name, "language": "en-US", "page": 1})
    except RuntimeError:
        return {}
    for item in (found.get("results") or [])[:1]:
        if isinstance(item, dict) and item.get("id"):
            return {"id": str(item["id"]),
                    "poster": _image(item.get("poster_path")),
                    "backdrop": _image(item.get("backdrop_path"), "w780")}
    return {}


def _feed_entries(since: str, horizon: str, watched: set, followed: set) -> list[dict]:
    """Episodes from a subscribed ICS feed, resolved to TMDB where possible."""
    try:
        try:
            import icscal
        except ImportError:
            from bridge.python import icscal
        rows = icscal.events()
    except Exception:
        return []
    if not rows:
        return []

    mapping = icscal.name_map()
    unknown = sorted({r["show"] for r in rows
                      if since <= r["date"] <= horizon and r["show"] not in mapping})
    if unknown:
        # Resolve only names never seen before, then persist the whole map.
        with ThreadPoolExecutor(max_workers=min(8, len(unknown))) as pool:
            for name, hit in zip(unknown, pool.map(_resolve_show, unknown)):
                mapping[name] = hit or {}
        icscal.save_name_map(mapping)

    out = []
    for row in rows:
        if not (since <= row["date"] <= horizon):
            continue
        hit = mapping.get(row["show"]) or {}
        tmdb_id = hit.get("id")
        media_id = ("series|tmdb:" + tmdb_id) if tmdb_id else ""
        entry = _cal_entry("episode", row["date"], row["show"], tmdb_id or "0", "tv",
                           hit.get("poster", ""), hit.get("backdrop", ""),
                           {"season": row["season"], "episode": row["episode"],
                            "episodeTitle": row["episodeTitle"],
                            "isPremiere": row["isPremiere"],
                            "isSeasonPremiere": row["isSeasonPremiere"],
                            "isFinale": False,
                            "source": "feed",
                            "playable": bool(tmdb_id),
                            "inLibrary": media_id in followed,
                            "watched": (media_id, row["season"], row["episode"]) in watched})
        if not tmdb_id:
            entry["id"] = ""       # nothing to open; the row stays informational
        out.append(entry)
    return out


def calendar(library: object = None, watch: object = None) -> dict:
    """A dated schedule: episodes of followed shows, plus what is new for anyone.

    Deliberately not library-only. A calendar that can only show what you
    already watch cannot tell you about anything worth adding.
    """
    today = datetime.date.today()
    horizon = (today + datetime.timedelta(days=CALENDAR_DAYS)).isoformat()
    since = (today - datetime.timedelta(days=CALENDAR_PAST_DAYS)).isoformat()
    start = today.isoformat()

    # Which episodes are already watched, so the calendar can grey them out.
    watched = set()
    for entry in (watch if isinstance(watch, list) else []):
        if not isinstance(entry, dict) or not entry.get("completed"):
            continue
        watched.add((str(entry.get("id") or ""),
                     int(entry.get("season") or 0), int(entry.get("episode") or 0)))

    discovery = {
        "premieres": ("/discover/tv", {
            "language": "en-US", "sort_by": "popularity.desc",
            "first_air_date.gte": start, "first_air_date.lte": horizon,
            "with_original_language": "en", "page": 1}),
        "movies": ("/discover/movie", {
            "language": "en-US", "sort_by": "popularity.desc",
            "primary_release_date.gte": start, "primary_release_date.lte": horizon,
            "with_original_language": "en", "page": 1}),
    }
    payloads = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {pool.submit(_request, path, params): key
                   for key, (path, params) in discovery.items()}
        for future in as_completed(futures):
            key = futures[future]
            try:
                payloads[key] = future.result()
            except RuntimeError:
                payloads[key] = {}

    entries = _library_episodes(library if isinstance(library, list) else [],
                                watched, since, horizon)
    followed = {e["id"] for e in entries}
    for entry in library if isinstance(library, list) else []:
        if isinstance(entry, dict) and str(entry.get("id") or "").startswith("series|"):
            followed.add(str(entry["id"]))

    # Merge the feed, keyed on the episode itself and NOT on its date. TMDB
    # reports a network's local broadcast date while the feed carries a real
    # timestamp converted to the viewer's zone, so the same episode legitimately
    # lands a day apart in the two sources. Keying on the date made every weekly
    # show appear twice, on consecutive days.
    feed = _feed_entries(since, horizon, watched, followed)

    def episode_key(entry):
        return (entry["title"].strip().lower(), entry.get("season"), entry.get("episode"))

    seen = {episode_key(e) for e in entries if e.get("season")}
    for entry in feed:
        key = episode_key(entry)
        # An episode already known from TMDB keeps TMDB's air date, which is
        # what the details page shows; only its "followed" flag is taken from
        # the feed, since a subscribed show is one the user tracks.
        if entry.get("season") and key in seen:
            for existing in entries:
                if episode_key(existing) == key:
                    existing["followed"] = True
            continue
        seen.add(key)
        entry["followed"] = True
        entries.append(entry)

    # Anything from the library is followed by definition.
    for entry in entries:
        if entry.get("inLibrary"):
            entry["followed"] = True
        entry.setdefault("followed", False)

    for item in (payloads.get("premieres", {}).get("results") or [])[:40]:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        date = str(item.get("first_air_date") or "")[:10]
        if not (start <= date <= horizon):
            continue
        entry = _cal_entry("premiere", date, item.get("name"), item["id"], "tv",
                           _image(item.get("poster_path")),
                           _image(item.get("backdrop_path"), "w780"),
                           {"inLibrary": ("series|tmdb:" + str(item["id"])) in followed,
                            "isPremiere": True, "season": 1, "episode": 1})
        # Deduped against the feed too: a premiere the user already tracks
        # arrives from both sources, a day apart, and would otherwise appear
        # twice exactly like the weekly episodes did.
        if entry["id"] not in followed and episode_key(entry) not in seen:
            seen.add(episode_key(entry))
            entries.append(entry)

    for item in (payloads.get("movies", {}).get("results") or [])[:40]:
        if not isinstance(item, dict) or not item.get("id"):
            continue
        date = str(item.get("release_date") or "")[:10]
        if not (start <= date <= horizon):
            continue
        entries.append(_cal_entry("movie", date, item.get("title"), item["id"], "movie",
                                  _image(item.get("poster_path")),
                                  _image(item.get("backdrop_path"), "w780"),
                                  {"inLibrary": False}))

    # Group by day so the panel can render date headers without regrouping.
    days = {}
    for entry in entries:
        days.setdefault(entry["date"], []).append(entry)
    # Followed shows lead each day: they are the reason to open this screen.
    order = {"episode": 0, "premiere": 1, "movie": 2}
    grouped = []
    for date in sorted(days):
        rows = sorted(days[date], key=lambda e: (order.get(e["kind"], 9), e["title"].lower()))
        grouped.append({"date": date, "entries": rows[:24]})
    return {"days": grouped, "from": since, "to": horizon, "today": start}


def home() -> dict:
    """Return curated, cache-backed sections for the OmaCine cinematic home."""
    endpoints = {
        "trending": ("/trending/all/week", ""),
        "movies": ("/movie/popular", "movie"),
        "television": ("/tv/popular", "tv"),
        "newMovies": ("/movie/now_playing", "movie"),
        "airing": ("/tv/on_the_air", "tv"),
    }
    payloads = {}
    with ThreadPoolExecutor(max_workers=len(endpoints)) as pool:
        futures = {
            pool.submit(_request, path, {"language": "en-US", "page": 1}): key
            for key, (path, _kind) in endpoints.items()
        }
        for future in as_completed(futures):
            key = futures[future]
            try:
                payloads[key] = future.result()
            except RuntimeError:
                payloads[key] = {}

    sections = {}
    for key, (_path, kind) in endpoints.items():
        sections[key] = _media_list(payloads.get(key, {}), kind)
    if not any(sections.values()):
        raise RuntimeError("TMDB discovery is temporarily unavailable")
    # The spotlight rotates in the UI, so hand back every trending title that
    # has usable backdrop art rather than a single frozen pick.
    heroes = [item for item in sections["trending"] if item.get("backdrop")][:HERO_ROTATION_LIMIT]
    if not heroes and sections["trending"]:
        heroes = sections["trending"][:1]
    return {
        "configured": True,
        "hero": heroes[0] if heroes else None,
        "heroes": heroes,
        "sections": sections,
    }


def _media_parts(value: object, media_type: object = "") -> tuple[str, str]:
    raw = str(value or "")
    kind = str(media_type or "").lower()
    if raw.startswith("series|"):
        kind, raw = "tv", raw.split("|", 1)[1]
    elif raw.startswith("movie|"):
        kind, raw = "movie", raw.split("|", 1)[1]
    elif kind in ("series", "2"):
        kind = "tv"
    elif kind not in ("movie", "tv"):
        kind = "movie"
    match = re.search(r"(?:^|\|)tmdb:(\d+)$", raw)
    if match:
        return kind, match.group(1)
    imdb = re.search(r"tt\d{5,12}", raw)
    if imdb:
        found = _request(f"/find/{imdb.group(0)}", {"external_source": "imdb_id"})
        key = "tv_results" if kind == "tv" else "movie_results"
        results = found.get(key) if isinstance(found.get(key), list) else []
        if results and results[0].get("id"):
            return kind, str(results[0]["id"])
    raise RuntimeError("TMDB could not match this title")


def _reviews(payload: dict) -> list[dict]:
    """Audience reviews, normalised for display.

    TMDB is sparse here - most titles have none and few have more than three -
    so this never pretends to be a feed. Length varies wildly (a few hundred to
    a few thousand characters), which is why the panel clamps and expands
    rather than trying to lay every review out the same way.
    """
    block = payload.get("reviews")
    results = block.get("results") if isinstance(block, dict) else None
    if not isinstance(results, list):
        return []
    out = []
    for item in results[:20]:
        if not isinstance(item, dict):
            continue
        body = str(item.get("content") or "").strip()
        if not body:
            continue
        details = item.get("author_details") or {}
        rating = details.get("rating")
        try:
            rating = float(rating) if rating is not None else None
        except (TypeError, ValueError):
            rating = None
        # Avatars are frequently absent, and TMDB stores gravatar links as a
        # path with a leading slash wrapped around a full URL.
        avatar = str(details.get("avatar_path") or "")
        if avatar.startswith("/http"):
            avatar = avatar[1:]
        elif avatar:
            avatar = _image(avatar)
        out.append({
            "id": str(item.get("id") or "")[:64],
            "author": str(item.get("author") or details.get("username") or "Anonymous")[:120],
            "avatar": avatar if avatar.startswith("http") else "",
            "rating": rating,
            "created": str(item.get("created_at") or "")[:10],
            "url": str(item.get("url") or "")[:400],
            "content": body[:8000],
        })
    return out


def _person(item: dict, subtitle: str) -> dict:
    return {
        "id": str(item.get("id") or ""),
        "name": str(item.get("name") or "")[:160],
        "role": str(subtitle or "")[:200],
        "image": _image(item.get("profile_path")),
    }


def _credits(payload: dict, kind: str) -> tuple[list[dict], list[dict]]:
    source = payload.get("aggregate_credits") if kind == "tv" else payload.get("credits")
    source = source if isinstance(source, dict) else {}
    cast = []
    for item in source.get("cast", []) if isinstance(source.get("cast"), list) else []:
        if not isinstance(item, dict) or not item.get("name"):
            continue
        if kind == "tv":
            roles = item.get("roles") if isinstance(item.get("roles"), list) else []
            role = next((str(role.get("character") or "") for role in roles if isinstance(role, dict)), "")
        else:
            role = str(item.get("character") or "")
        cast.append(_person(item, role))
        if len(cast) >= 12:
            break
    crew = []
    seen = set()
    wanted = {"Director", "Writer", "Screenplay", "Creator", "Executive Producer", "Producer"}
    for item in source.get("crew", []) if isinstance(source.get("crew"), list) else []:
        if not isinstance(item, dict) or not item.get("name"):
            continue
        jobs = item.get("jobs") if isinstance(item.get("jobs"), list) else []
        job = next((str(job.get("job") or "") for job in jobs if isinstance(job, dict) and job.get("job") in wanted), "")
        job = job or str(item.get("job") or "")
        if job not in wanted:
            continue
        key = (item.get("id"), job)
        if key in seen:
            continue
        seen.add(key)
        crew.append(_person(item, job))
        if len(crew) >= 8:
            break
    return cast, crew


def _episodes(payload: dict) -> list[dict]:
    out = []
    for item in payload.get("episodes", []) if isinstance(payload.get("episodes"), list) else []:
        if not isinstance(item, dict):
            continue
        try:
            number = int(item.get("episode_number") or 0)
        except (TypeError, ValueError):
            continue
        if number < 1:
            continue
        out.append({
            "episode": number,
            "name": str(item.get("name") or f"Episode {number}")[:300],
            "overview": str(item.get("overview") or "")[:4000],
            "airDate": str(item.get("air_date") or "")[:20],
            "runtime": int(item.get("runtime") or 0),
            "rating": round(float(item.get("vote_average") or 0), 1),
            "still": _image(item.get("still_path"), "w300"),
        })
    return out


def season(value: object, season_number: object, media_type: object = "tv") -> dict:
    kind, tmdb_id = _media_parts(value, media_type)
    if kind != "tv":
        return {"configured": True, "tmdbId": tmdb_id, "season": 0, "episodes": []}
    try:
        number = max(0, int(season_number or 0))
    except (TypeError, ValueError):
        number = 0
    payload = _request(f"/tv/{tmdb_id}/season/{number}", {"language": "en-US"})
    return {"configured": True, "tmdbId": tmdb_id, "season": number, "episodes": _episodes(payload)}



RELATED_LIMIT = 20


def _related_titles(payload: dict, kind: str, self_id: str) -> list[dict]:
    """Merge TMDB's two notions of "related" into one rail.

    `recommendations` is behavioural (what people who watched this also watched)
    and is the stronger signal, so it leads. `similar` is content-based and only
    fills in behind it, which keeps obscure titles from showing an empty rail.
    Entries without artwork are dropped rather than rendered as blank cards.
    """
    merged = []
    seen = {self_id}
    for source in ("recommendations", "similar"):
        block = payload.get(source)
        for item in _media_list(block if isinstance(block, dict) else {}, kind, limit=RELATED_LIMIT * 2):
            if item["id"] in seen or not item.get("cover"):
                continue
            seen.add(item["id"])
            item["relation"] = source
            merged.append(item)
            if len(merged) >= RELATED_LIMIT:
                return merged
    return merged


def enrich(value: object, media_type: object = "", season_number: object = 0) -> dict:
    kind, tmdb_id = _media_parts(value, media_type)
    # `similar` is TMDB's content-based match (genre, keywords, crew); it fills
    # the gap for obscure titles that have too few user recommendations.
    # Reviews ride along with the details request rather than costing a second
    # round trip: most titles have one or two, so the first page is all there is.
    appended = ("aggregate_credits,recommendations,similar,videos,images,external_ids,reviews" if kind == "tv"
                else "credits,recommendations,similar,videos,images,release_dates,external_ids,reviews")
    payload = _request(f"/{kind}/{tmdb_id}", {
        "language": "en-US",
        "append_to_response": appended,
        "include_image_language": "en,null",
    })
    cast, crew = _credits(payload, kind)
    recommendations = _related_titles(payload, kind, f"{'series' if kind == 'tv' else 'movie'}|tmdb:{tmdb_id}")
    videos = payload.get("videos") if isinstance(payload.get("videos"), dict) else {}
    trailers = []
    for item in videos.get("results", []) if isinstance(videos.get("results"), list) else []:
        if not isinstance(item, dict) or item.get("site") != "YouTube" or not item.get("key"):
            continue
        trailers.append({
            "name": str(item.get("name") or "Trailer")[:300],
            "key": str(item.get("key") or "")[:100],
            "official": item.get("official") is True,
            "type": str(item.get("type") or "")[:80],
        })
        if len(trailers) >= 8:
            break
    # Rank so the card shows a real trailer, not a clip or featurette: official
    # trailers first, then any trailer, then whatever is left.
    def _trailer_rank(item):
        kind = (item.get("type") or "").lower()
        return (0 if kind == "trailer" and item.get("official") else
                1 if kind == "trailer" else
                2 if kind == "teaser" else 3)
    trailers.sort(key=_trailer_rank)
    for item in trailers:
        # YouTube's own still; cached to disk like every other image.
        item["thumb"] = f"https://img.youtube.com/vi/{item['key']}/hqdefault.jpg"
        item["url"] = f"https://www.youtube.com/watch?v={item['key']}"
    logos = []
    images = payload.get("images") if isinstance(payload.get("images"), dict) else {}
    for item in images.get("logos", []) if isinstance(images.get("logos"), list) else []:
        if isinstance(item, dict) and item.get("file_path"):
            logos.append(_image(item.get("file_path"), "w500"))
    result = {
        "configured": True,
        "tmdbId": tmdb_id,
        # OMDb is keyed on the IMDb id, so surface it for the ratings lookup.
        "imdbId": str((payload.get("external_ids") or {}).get("imdb_id")
                      or payload.get("imdb_id") or "")[:20],
        "mediaType": kind,
        "cast": cast,
        "crew": crew,
        "tagline": str(payload.get("tagline") or "")[:500],
        "overview": str(payload.get("overview") or "")[:4000],
        "poster": _image(payload.get("poster_path"), "w500"),
        "backdrop": _image(payload.get("backdrop_path"), "w1280"),
        "logo": logos[0] if logos else "",
        "recommendations": recommendations,
        "reviews": _reviews(payload),
        "trailers": trailers,
    }
    if kind == "tv" and int(season_number or 0) >= 0:
        result.update(season(value, season_number, media_type))
    return result


PERSON_CREDIT_LIMIT = 24


def _credit_weight(item: dict) -> tuple:
    """Rank a credit so a performer's best-known work surfaces first."""
    try:
        votes = float(item.get("vote_count") or 0)
    except (TypeError, ValueError):
        votes = 0.0
    try:
        popularity = float(item.get("popularity") or 0)
    except (TypeError, ValueError):
        popularity = 0.0
    return (votes, popularity)


def person(value: object) -> dict:
    """A performer plus the titles they are best known for."""
    person_id = str(value or "").strip()
    if not person_id.isdigit() or len(person_id) > 12:
        raise ValueError("invalid person id")
    payload = _request(
        f"/person/{person_id}",
        {"language": "en-US", "append_to_response": "combined_credits"},
    )
    credits = payload.get("combined_credits")
    credits = credits if isinstance(credits, dict) else {}
    cast = credits.get("cast") if isinstance(credits.get("cast"), list) else []

    works = []
    seen = set()
    for item in sorted(cast, key=_credit_weight, reverse=True):
        if not isinstance(item, dict) or not item.get("id"):
            continue
        media_kind = str(item.get("media_type") or "").lower()
        if media_kind not in ("movie", "tv"):
            continue
        normalized = _media_item(item, media_kind)
        if not normalized["title"] or normalized["id"] in seen:
            continue
        seen.add(normalized["id"])
        normalized["role"] = str(item.get("character") or "")[:200]
        works.append(normalized)
        if len(works) >= PERSON_CREDIT_LIMIT:
            break

    return {
        "configured": True,
        "id": person_id,
        "name": str(payload.get("name") or "")[:160],
        "image": _image(payload.get("profile_path"), "w185"),
        "biography": str(payload.get("biography") or "")[:2000],
        "knownFor": str(payload.get("known_for_department") or "")[:80],
        "works": works,
    }
