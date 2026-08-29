"""ThemerrDB client — theme songs for a movie or a TV show.

This is the useful half of the Jellyfin Themerr plugin. ThemerrDB is keyed on
TMDB ids, which OmaCine already stores on every title, so no name matching is
needed — unlike most external catalogues, a lookup here is exact or it is a
clean 404.

A theme belongs to a *title*, never to an episode: the database has only
`movies/` and `tv_shows/` collections. This is unrelated to Skip Intro, which
is per-episode and comes from IntroDB.

Two stages, deliberately separate:

  * `lookup()` resolves a TMDB id to a YouTube URL. Cheap, cached, and caches
    misses too — most of the catalogue simply has no submission.
  * `fetch()` downloads that theme to a local file. The resolved googlevideo
    URLs carry an `expire=` of about an hour, so caching the URL is useless;
    only the audio itself is worth keeping.
"""
import json
import os
import re
import signal
import subprocess
import threading
import time
from pathlib import Path

try:
    import net
except ImportError:
    from bridge.python import net

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "themes"
META_DIR = CACHE_DIR / "meta"
# Overrides are the user's own input, not derived data, so they live in config
# and survive clearing the cache.
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "omamovie"
OVERRIDES_PATH = CONFIG_DIR / "theme-overrides.json"
API_BASE = "https://app.lizardbyte.dev/ThemerrDB"

# Submissions are rare and edits rarer, so a hit can be trusted for a long
# time. A miss is re-checked sooner because the database only ever grows.
HIT_TTL = 30 * 24 * 60 * 60
MISS_TTL = 7 * 24 * 60 * 60
# Some submissions point at videos that have since been removed from YouTube.
# Without this, every visit to that title would re-run a doomed download.
FAIL_TTL = 7 * 24 * 60 * 60
CACHE_MAX_AGE = 120 * 24 * 60 * 60
PRUNE_INTERVAL = 12 * 60 * 60
# Audio is ~1.5 MB but a 1080p H.264 backdrop is ~16 MB, so browsing a lot of
# titles would grow this without bound. Age alone is not enough: cap the total
# and evict least-recently-used, the way the poster cache does.
CACHE_MAX_BYTES = 800 * 1024 * 1024
AUDIO_MAX_BYTES = 96 * 1024 * 1024      # ~1.5 MB per theme, so this is generous
VIDEO_MAX_BYTES = 256 * 1024 * 1024     # a 1080p backdrop runs 5-15 MB

DOWNLOAD_TIMEOUT = 60
SEARCH_TIMEOUT = 25

# About a fifth of ThemerrDB submissions point at videos YouTube has since
# removed, and plenty of titles have no submission at all. Searching recovers
# both, but only inside a shape that is actually a theme: a title sequence runs
# well under five minutes, and anything longer is a full soundtrack or an
# episode rip.
SEARCH_MIN_SECONDS = 15
SEARCH_MAX_SECONDS = 240
SEARCH_RESULTS = 6
# Words that mark a result as the title sequence rather than a cover, a reaction
# or a full album upload.
SEARCH_GOOD = ("theme", "intro", "opening", "main title", "title sequence", "opening credits")
SEARCH_BAD = ("reaction", "cover", "remix", "karaoke", "lyrics", "how to play",
              "tutorial", "piano", "guitar", "full album", "soundtrack list",
              "1 hour", "10 hours", "loop", "extended", "episode", "explained",
              "review", "trailer", "parody")

# The bridge daemon has a small worker pool and the panel calls fetch() while
# a details page opens. Without a cap, browsing a run of uncached titles would
# park every worker on a download and stall the whole panel, so downloads are
# serialised and a caller that cannot get the slot is told "not yet" instead of
# queueing behind one.
_DOWNLOAD_SLOT = threading.BoundedSemaphore(1)

# Only ever hand yt-dlp a YouTube watch URL. ThemerrDB is community-submitted,
# and this value becomes an argument to a subprocess.
_YOUTUBE = re.compile(
    r"^https://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{6,20})(?:&\S*)?$")


def _parts(media_id: object, media_type: object = "") -> tuple[str, str]:
    """OmaCine ids look like 'series|tmdb:1668'. ThemerrDB wants tv_shows/movies."""
    raw = str(media_id or "")
    kind = str(media_type or "").lower()
    if raw.startswith("series|"):
        kind, raw = "tv_shows", raw.split("|", 1)[1]
    elif raw.startswith("movie|"):
        kind, raw = "movies", raw.split("|", 1)[1]
    elif kind in ("series", "tv", "show", "2"):
        kind = "tv_shows"
    elif kind not in ("movies", "tv_shows"):
        kind = "movies"
    kind = "tv_shows" if kind in ("tv_shows", "series", "tv", "show") else "movies"
    match = re.search(r"(?:^|\|)tmdb:(\d+)$", raw) or re.fullmatch(r"\s*(\d{1,12})\s*", raw)
    if match:
        return kind, match.group(1)
    # ThemerrDB is indexed by TMDB id only, but plenty of Stremio catalogues
    # hand out IMDb ids. TMDB's own find endpoint bridges the two, and the
    # answer is cached so this costs one request per title, ever.
    imdb = re.search(r"tt\d{5,12}", raw)
    if imdb:
        resolved = _tmdb_id_for_imdb(imdb.group(0), kind)
        if resolved:
            return kind, resolved
        raise ValueError("no TMDB match for this title")
    raise ValueError("ThemerrDB needs a TMDB or IMDb id")


def _tmdb_id_for_imdb(imdb_id: str, kind: str) -> str:
    """Resolve an IMDb id to a TMDB one, memoised on disk."""
    path = META_DIR / f"imdb-{imdb_id}.json"
    try:
        cached = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(cached, dict) and cached.get("tmdb"):
            return str(cached["tmdb"])
    except (OSError, ValueError, TypeError):
        pass
    try:
        try:
            import tmdb as tmdb_module
        except ImportError:
            from bridge.python import tmdb as tmdb_module
        _kind, resolved = tmdb_module._media_parts(
            imdb_id, "series" if kind == "tv_shows" else "movie")
    except Exception:
        return ""
    if resolved:
        _write_json(path, {"imdb": imdb_id, "tmdb": str(resolved)})
    return str(resolved or "")


def _score_candidate(title: str, duration: float, wanted: str) -> float:
    """Rank a search hit. Negative means reject."""
    lowered = title.lower()
    if any(word in lowered for word in SEARCH_BAD):
        return -1.0
    if not (SEARCH_MIN_SECONDS <= duration <= SEARCH_MAX_SECONDS):
        return -1.0
    score = 0.0
    if any(word in lowered for word in SEARCH_GOOD):
        score += 2.0
    # The show's own name should appear, or it is probably a different title.
    target = wanted.lower().strip()
    tokens = [t for t in re.split(r"\W+", target) if len(t) > 2]
    # A short title is a substring of unrelated things - "Furious" matched
    # "Fast & Furious", "Widow's Bay" matched a Parks & Recreation mashup. For
    # one- and two-word titles, demand the whole name as a contiguous phrase.
    if len(tokens) <= 2:
        if target not in lowered:
            return -1.0
        score += 2.0
        # Checking only that the name appears is not enough: "Furious" is inside
        # "Fast & Furious", with a space before it, so a neighbouring-character
        # test passes. A real upload for a short title leads with that title, so
        # anchor to the start and let leading punctuation through.
        head = lowered.lstrip(" \"'([{-\u2013\u2014*")
        if not head.startswith(target):
            return -1.0
    if tokens:
        hits = sum(1 for t in tokens if t in lowered)
        score += 2.0 * hits / len(tokens)
        if hits == 0:
            return -1.0
    # A title sequence is typically 30-90s; prefer that shape.
    if 25 <= duration <= 120:
        score += 1.0
    return score


def _search_theme(title: str, year: object = "", kind: str = "tv_shows") -> str:
    """Find a plausible theme on YouTube when ThemerrDB cannot supply one."""
    name = str(title or "").strip()
    if not name:
        return ""
    # Several phrasings, pooled. "theme song" is the common one, but a show
    # whose title sequence is not called that is usually found by one of the
    # others, and pooling lets the scorer compare across all of them rather
    # than settling for the best of a single weak result set.
    # The year disambiguates a generic name from an unrelated franchise, which
    # is the single biggest source of a wrong automatic pick.
    stamp = f" {year}" if str(year or "").strip() else ""
    kind_word = "tv series" if kind == "tv_shows" else "movie"
    queries = [
        f"{name}{stamp} theme song",
        f"{name} {kind_word} theme song" if stamp else f"{name} main theme",
        f"{name} opening credits" if kind == "tv_shows" else f"{name} main title",
    ]
    best, best_score = "", 0.0
    for index, query in enumerate(queries):
        command = [
            "yt-dlp", "--quiet", "--no-warnings", "--skip-download", "--flat-playlist",
            "--socket-timeout", "15",
            "--print", "%(id)s\t%(duration)s\t%(title)s",
            f"ytsearch{SEARCH_RESULTS}:{query}",
        ]
        try:
            done = subprocess.run(command, capture_output=True, text=True,
                                  timeout=SEARCH_TIMEOUT, check=False)
        except (OSError, subprocess.SubprocessError):
            continue
        for line in (done.stdout or "").splitlines():
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            video_id, raw_duration, video_title = parts[0], parts[1], "\t".join(parts[2:])
            if not re.fullmatch(r"[A-Za-z0-9_-]{6,20}", video_id):
                continue
            try:
                duration = float(raw_duration)
            except (TypeError, ValueError):
                continue
            score = _score_candidate(video_title, duration, name)
            if score <= 0:
                continue
            # A tie goes to the earlier, more direct phrasing.
            score -= index * 0.15
            if score > best_score:
                best, best_score = f"https://www.youtube.com/watch?v={video_id}", score
        # A confident hit on the first phrasing needs no further searching.
        if best_score >= 4.5:
            break
    return best


def _meta_path(kind: str, tmdb_id: str) -> Path:
    return META_DIR / f"{kind}-{tmdb_id}.json"


def audio_path(kind: str, tmdb_id: str) -> Path:
    return CACHE_DIR / f"{kind}-{tmdb_id}.opus"


def video_path(kind: str, tmdb_id: str) -> Path:
    return CACHE_DIR / f"{kind}-{tmdb_id}.mp4"


def asset_path(kind: str, tmdb_id: str, media_kind: str) -> Path:
    return video_path(kind, tmdb_id) if media_kind == "video" else audio_path(kind, tmdb_id)


def _overrides() -> dict:
    try:
        value = json.loads(OVERRIDES_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def set_override(media_id: object, media_type: object = "", url: object = "") -> dict:
    """Pin a theme by hand. Wins over ThemerrDB, which is how a dead or missing
    submission gets fixed locally without waiting on the database."""
    kind, tmdb_id = _parts(media_id, media_type)
    text = str(url or "").strip()
    stored = _overrides()
    key = f"{kind}-{tmdb_id}"
    if not text:
        stored.pop(key, None)
    else:
        if not _YOUTUBE.match(text):
            raise ValueError("paste a YouTube video link, e.g. https://www.youtube.com/watch?v=…")
        stored[key] = text
    try:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = OVERRIDES_PATH.with_suffix(".new")
        tmp.write_text(json.dumps(stored, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, OVERRIDES_PATH)
    except OSError as exc:
        raise RuntimeError(f"could not save the theme override: {exc}") from exc
    # A new URL invalidates whatever was downloaded and any earlier failure.
    for media_kind in ("audio", "video"):
        for path in (asset_path(kind, tmdb_id, media_kind), _fail_path(kind, tmdb_id, media_kind)):
            try:
                path.unlink()
            except OSError:
                pass
    try:
        _resolved_path(kind, tmdb_id).unlink()
    except OSError:
        pass
    return lookup(media_id, media_type, refresh=True)


def _fail_path(kind: str, tmdb_id: str, media_kind: str = "audio") -> Path:
    return META_DIR / f"{kind}-{tmdb_id}.{media_kind}.fail.json"


def _recent_failure(kind: str, tmdb_id: str, url: str, media_kind: str = "audio") -> str:
    """The last download error for this exact URL, if it is still recent.

    Keyed on the URL rather than the title, so a corrected ThemerrDB submission
    is retried immediately instead of waiting out the cooldown.
    """
    path = _fail_path(kind, tmdb_id, media_kind)
    try:
        if time.time() - path.stat().st_mtime > FAIL_TTL:
            return ""
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return ""
    if not isinstance(record, dict) or record.get("url") != url:
        return ""
    return str(record.get("error") or "the theme download failed")


def _settings_budget() -> int:
    """Theme cache budget from settings, falling back to the built-in default."""
    try:
        path = (Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
                / "omamovie" / "settings.json")
        value = json.loads(path.read_text(encoding="utf-8"))
        mb = float(value.get("cacheThemesMB"))
        if 50 <= mb <= 16000:
            return int(mb) * 1024 * 1024
    except (OSError, ValueError, TypeError):
        pass
    return CACHE_MAX_BYTES


def _prune() -> None:
    marker = CACHE_DIR / ".pruned"
    now = time.time()
    try:
        if marker.exists() and now - marker.stat().st_mtime < PRUNE_INTERVAL:
            return
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        META_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return
    for base in (CACHE_DIR, META_DIR):
        try:
            entries = list(base.iterdir())
        except OSError:
            continue
        for candidate in entries:
            if candidate.name in (".pruned", "meta"):
                continue
            try:
                if candidate.is_file() and now - candidate.stat().st_mtime > CACHE_MAX_AGE:
                    candidate.unlink()
            except OSError:
                continue

    # Then evict oldest-touched media until the total fits. Metadata is tiny and
    # is what makes a miss cheap, so only the audio and video files are counted.
    media = []
    try:
        for candidate in CACHE_DIR.iterdir():
            if candidate.suffix not in (".opus", ".mp4"):
                continue
            try:
                stat = candidate.stat()
            except OSError:
                continue
            media.append((stat.st_mtime, stat.st_size, candidate))
    except OSError:
        media = []
    budget = _settings_budget()
    total = sum(size for _mtime, size, _path in media)
    for _mtime, size, candidate in sorted(media):
        if total <= budget:
            break
        try:
            candidate.unlink()
            total -= size
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass


def _write_json(path: Path, value: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def lookup(media_id: object, media_type: object = "", *, refresh: bool = False) -> dict:
    """Resolve a title to its theme URL. A miss is a normal, cached outcome."""
    kind, tmdb_id = _parts(media_id, media_type)
    _prune()
    pinned = _overrides().get(f"{kind}-{tmdb_id}")
    if pinned:
        return _with_assets({"found": True, "mediaType": kind, "tmdbId": tmdb_id,
                             "themeUrl": pinned, "override": True, "cached": True},
                            kind, tmdb_id)
    path = _meta_path(kind, tmdb_id)
    if not refresh:
        try:
            cached = json.loads(path.read_text(encoding="utf-8"))
            age = time.time() - path.stat().st_mtime
            if isinstance(cached, dict) and age < (HIT_TTL if cached.get("found") else MISS_TTL):
                cached["cached"] = True
                return _with_assets(cached, kind, tmdb_id)
        except (OSError, ValueError, TypeError):
            pass

    result = {"found": False, "mediaType": kind, "tmdbId": tmdb_id, "themeUrl": ""}
    try:
        raw = net.get_bytes(f"{API_BASE}/{kind}/themoviedb/{tmdb_id}.json",
                            {"Accept": "application/json"}, 8.0, 4 * 1024 * 1024)
        payload = json.loads(raw.decode("utf-8"))
    except RuntimeError as exc:
        # A title with no submission is served as a 404 HTML page, which is the
        # common case and not an error worth surfacing.
        if "404" not in str(exc):
            raise
        payload = None
    except (ValueError, UnicodeError):
        payload = None

    if isinstance(payload, dict):
        url = str(payload.get("youtube_theme_url") or "").strip()
        if _YOUTUBE.match(url):
            result = {
                "found": True,
                "mediaType": kind,
                "tmdbId": tmdb_id,
                "themeUrl": url,
                "title": str(payload.get("title") or payload.get("name") or "")[:300],
                "updated": int(payload.get("youtube_theme_edited") or 0),
            }
    _write_json(path, result)
    result["cached"] = False
    return _with_assets(result, kind, tmdb_id)


def _on_disk(path: Path) -> bool:
    try:
        return path.is_file() and path.stat().st_size > 0
    except OSError:
        return False


def _with_assets(result: dict, kind: str, tmdb_id: str) -> dict:
    """Report what is already on disk, so callers can skip fetch() entirely."""
    audio, video = audio_path(kind, tmdb_id), video_path(kind, tmdb_id)
    audio_ready, video_ready = _on_disk(audio), _on_disk(video)
    result = dict(result)
    result["audioReady"] = audio_ready
    result["audioPath"] = str(audio) if audio_ready else ""
    result["videoReady"] = video_ready
    result["videoPath"] = str(video) if video_ready else ""
    return result


def _resolved_path(kind: str, tmdb_id: str) -> Path:
    return META_DIR / f"{kind}-{tmdb_id}.search.json"


def _remembered_search(kind: str, tmdb_id: str) -> str:
    try:
        value = json.loads(_resolved_path(kind, tmdb_id).read_text(encoding="utf-8"))
        return str(value.get("url") or "") if isinstance(value, dict) else ""
    except (OSError, ValueError, TypeError):
        return ""


def fetch(media_id: object, media_type: object = "", media_kind: object = "audio",
          title: object = "", year: object = "") -> dict:
    """Download the theme to the cache. Returns the local path, never a URL.

    `media_kind` is "audio" for the theme song alone, or "video" for the full
    backdrop clip. They are separate files: most titles only ever need the
    audio, and a 1080p backdrop is roughly five times the size.
    """
    media_kind = "video" if str(media_kind or "").lower() == "video" else "audio"
    kind, tmdb_id = _parts(media_id, media_type)
    found = lookup(media_id, media_type)
    if found.get("videoReady" if media_kind == "video" else "audioReady"):
        # A file resolved by the search fallback is on disk, but lookup() only
        # knows about ThemerrDB, so it still reports found=false. Callers treat
        # that as "no theme" and refuse to play something already downloaded.
        if not found.get("found"):
            remembered = _remembered_search(kind, tmdb_id)
            found = dict(found)
            found["found"] = True
            found["source"] = "search" if remembered else "themerrdb"
            if remembered:
                found["themeUrl"] = remembered
        return found

    url = str(found.get("themeUrl") or "")
    source = "themerrdb" if url else ""

    # A ThemerrDB URL that already failed, or no entry at all, falls back to a
    # search. The chosen URL is remembered so this costs one search per title.
    dead = bool(url) and bool(_recent_failure(kind, tmdb_id, url, media_kind))
    if not url or dead:
        remembered = _remembered_search(kind, tmdb_id)
        if remembered:
            url, source = remembered, "search"
        elif title:
            guess = _search_theme(str(title), year, kind=kind)
            if guess:
                _write_json(_resolved_path(kind, tmdb_id), {"url": guess, "title": str(title)[:200]})
                url, source = guess, "search"

    if not url:
        return found

    found = dict(found)
    found["found"] = True
    found["themeUrl"] = url
    found["source"] = source

    stale = _recent_failure(kind, tmdb_id, url, media_kind)
    if stale:
        found["downloadError"] = stale
        return found
    if not _YOUTUBE.match(url):
        raise ValueError("ThemerrDB returned a non-YouTube theme URL")

    if not _DOWNLOAD_SLOT.acquire(blocking=False):
        found = dict(found)
        found["downloadBusy"] = True
        return found

    try:
        return _download(found, kind, tmdb_id, url, media_kind)
    finally:
        _DOWNLOAD_SLOT.release()


def _download(found: dict, kind: str, tmdb_id: str, url: str, media_kind: str) -> dict:
    target = asset_path(kind, tmdb_id, media_kind)
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise RuntimeError(f"could not create the theme cache: {exc}") from exc

    # Written to a temporary name first so a killed download never leaves a
    # truncated file that later looks like a valid cache hit.
    stem = target.with_suffix("")
    command = [
        "yt-dlp", "--quiet", "--no-warnings", "--no-progress", "--no-playlist",
        "--socket-timeout", "20", "--retries", "2",
    ]
    if media_kind == "video":
        command += [
            "--max-filesize", str(VIDEO_MAX_BYTES),
            # H.264 first, deliberately. YouTube's "best" at this size is AV1,
            # which is smaller but the least reliable codec for Qt's backend and
            # the most expensive to decode in software - a bad trade for a clip
            # that loops behind a page. 1080p caps the size.
            "-f", "bestvideo[height<=1080][vcodec^=avc1][ext=mp4]+bestaudio[ext=m4a]/"
                  "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/"
                  "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best",
            "--merge-output-format", "mp4",
        ]
    else:
        command += [
            "--max-filesize", str(AUDIO_MAX_BYTES),
            "-f", "bestaudio", "-x", "--audio-format", "opus", "--audio-quality", "5",
        ]
    command += ["-o", f"{stem}.part.%(ext)s", "--", url]
    suffix = "mp4" if media_kind == "video" else "opus"
    try:
        # start_new_session puts yt-dlp and the ffmpeg it spawns in their own
        # process group, so a timeout can take the whole tree down rather than
        # leaving a child holding the pipe open.
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
    except FileNotFoundError as exc:
        raise RuntimeError("yt-dlp is not installed") from exc
    try:
        _stdout, stderr = process.communicate(timeout=DOWNLOAD_TIMEOUT)
        returncode = process.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            process.kill()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        message = "the theme download timed out"
        _write_json(_fail_path(kind, tmdb_id, media_kind), {"url": url, "error": message})
        raise RuntimeError(message)

    produced = Path(f"{stem}.part.{suffix}")
    if returncode != 0 or not produced.is_file():
        try:
            produced.unlink()
        except OSError:
            pass
        detail = (stderr or "").strip().splitlines()
        message = detail[-1][:200] if detail else "the theme download failed"
        # Remembered so a removed video is not re-attempted on every page open.
        _write_json(_fail_path(kind, tmdb_id, media_kind), {"url": url, "error": message})
        raise RuntimeError(message)
    try:
        os.replace(produced, target)
    except OSError as exc:
        raise RuntimeError(f"could not store the theme: {exc}") from exc
    try:
        _fail_path(kind, tmdb_id, media_kind).unlink()
    except OSError:
        pass
    return _with_assets(found, kind, tmdb_id)


def clear(media_id: object = None, media_type: object = "") -> dict:
    """Drop one cached theme, or the whole cache when no id is given."""
    removed = 0
    if media_id:
        kind, tmdb_id = _parts(media_id, media_type)
        candidates = [audio_path(kind, tmdb_id), _meta_path(kind, tmdb_id)]
    else:
        candidates = []
        for base in (CACHE_DIR, META_DIR):
            try:
                candidates.extend(item for item in base.iterdir() if item.is_file())
            except OSError:
                pass
    for candidate in candidates:
        try:
            candidate.unlink()
            removed += 1
        except OSError:
            continue
    return {"removed": removed}
