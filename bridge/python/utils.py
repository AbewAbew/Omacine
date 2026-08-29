import os
from pathlib import Path
import hashlib
import time

POSTER_CACHE_MAX_BYTES = 200 * 1024 * 1024
POSTER_CACHE_MAX_AGE = 45 * 24 * 60 * 60
POSTER_PRUNE_INTERVAL = 6 * 60 * 60

def poster_dir() -> Path:
    home = Path.home()
    dir = home / ".cache" / "omamovie" / "posters"
    # also respect XDG_CACHE_HOME if set? Keep same as Rust: HOME/.cache/omamovie/posters
    # Rust uses HOME/.cache/omamovie/posters regardless of XDG_CACHE_HOME for posters.
    # We'll follow that but also support XDG_CACHE_HOME if HOME not available.
    try:
        dir.mkdir(parents=True, exist_ok=True)
    except:
        pass
    return dir


def prune_poster_cache(path: Path | None = None, max_bytes: int = POSTER_CACHE_MAX_BYTES,
                       max_age: int = POSTER_CACHE_MAX_AGE) -> dict:
    """Bound poster storage by age and least-recently-used modification time.

    Every poster request used to pay a full directory stat sweep. A marker file
    throttles that to one sweep per interval, matching the HTTP cache pruner.
    """
    base = path or poster_dir()
    marker = base / ".pruned"
    try:
        if marker.exists() and time.time() - marker.stat().st_mtime < POSTER_PRUNE_INTERVAL:
            return {"removed": 0, "freed": 0, "skipped": True}
    except OSError:
        pass
    now = time.time()
    entries = []
    removed = 0
    freed = 0
    try:
        candidates = list(base.iterdir())
    except OSError:
        return {"removed": 0, "freed": 0}
    for candidate in candidates:
        if candidate.name == ".pruned":
            continue
        try:
            stat = candidate.stat()
            if not candidate.is_file():
                continue
            if max_age > 0 and now - stat.st_mtime > max_age:
                candidate.unlink()
                removed += 1
                freed += stat.st_size
            else:
                entries.append((stat.st_mtime, stat.st_size, candidate))
        except OSError:
            continue
    total = sum(size for _mtime, size, _candidate in entries)
    for _mtime, size, candidate in sorted(entries):
        if total <= max_bytes:
            break
        try:
            candidate.unlink()
            total -= size
            removed += 1
            freed += size
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass
    return {"removed": removed, "freed": freed}

def detect_ext(data: bytes) -> str:
    if data.startswith(b"\xFF\xD8"):
        return "jpg"
    if data.startswith(b"\x89PNG"):
        return "png"
    if data.startswith(b"RIFF") and len(data) > 12 and data[8:12] == b"WEBP":
        return "webp"
    return "img"

def resolve_subtitle_dir() -> Path:
    home = Path.home()
    storage = home / "storage" / "downloads" / "moviebox_subs"
    if (home / "storage" / "downloads").exists():
        try:
            storage.mkdir(parents=True, exist_ok=True)
        except:
            pass
        return storage
    # fallback to cache_dir/subs
    from .cache import cache_dir
    d = cache_dir() / "subs"
    try:
        d.mkdir(parents=True, exist_ok=True)
    except:
        pass
    return d


SUBTITLE_CACHE_MAX_AGE = 14 * 24 * 60 * 60


def subtitle_dir() -> Path:
    directory = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "subs"
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return directory


def prune_subtitle_cache(max_age: int = SUBTITLE_CACHE_MAX_AGE) -> dict:
    """Subtitles are small but there is one per track per episode."""
    base = subtitle_dir()
    marker = base / ".pruned"
    now = time.time()
    try:
        if marker.exists() and now - marker.stat().st_mtime < POSTER_PRUNE_INTERVAL:
            return {"removed": 0, "skipped": True}
        candidates = list(base.iterdir())
    except OSError:
        return {"removed": 0}
    removed = 0
    for candidate in candidates:
        if candidate.name == ".pruned":
            continue
        try:
            if candidate.is_file() and now - candidate.stat().st_mtime > max_age:
                candidate.unlink()
                removed += 1
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass
    return {"removed": removed}
