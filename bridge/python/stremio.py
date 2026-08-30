"""Small Stremio Addon Protocol client for OmaCine.

Only addon manifests the user explicitly enables are queried.  The shipped
configuration contains Stremio's local addon plus a known Creative Commons
test movie, so the feature is useful without silently importing third-party
indexes from another application.
"""

from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
try:
    import net
except ImportError:
    from bridge.python import net
import json
import os
import re
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, urlopen

_MEM_CACHE: dict[str, tuple[float, dict]] = {}


CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omamovie"
CONFIG_PATH = CONFIG_DIR / "addons.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "omamovie" / "stremio"
HTTP_CACHE_MAX_AGE = 24 * 60 * 60
HTTP_CACHE_PRUNE_INTERVAL = 6 * 60 * 60
DEFAULT_METADATA = ""
PUBLIC_DOMAIN_MANIFEST = "https://caching.stremio.net/publicdomainmovies.now.sh/manifest.json"
# OmaCine runs its own copy of the streaming server on 11480. Stremio
# Enhanced keeps 11470, so both can be installed and run at once.
DEFAULT_SERVER = "http://127.0.0.1:11480"
SINTEL_CATALOG_ID = "omamovie:catalog:sintel"
SINTEL_ID = "omamovie:free:sintel"
SINTEL_HASH = "08ada5a7a6183aae1e09d831df6748d566095a10"
FALLBACK_PEER_SOURCES = [
    "tracker:udp://tracker.opentrackr.org:1337/announce",
    "tracker:udp://tracker.openbittorrent.com:80/announce",
    "tracker:udp://tracker.qu.ax:6969/announce",
    "tracker:wss://tracker.webtorrent.dev:443",
    "tracker:wss://tracker.openwebtorrent.com:443",
    "tracker:wss://open.ftorrent.com:443",
]
SINTEL_TRACKERS = [f"dht:{SINTEL_HASH}", *FALLBACK_PEER_SOURCES]


def default_config() -> dict:
    return {
        "schemaVersion": 2,
        "metadataManifest": DEFAULT_METADATA,
        "streamingServer": DEFAULT_SERVER,
        "cacheSizeBytes": 10 * 1024 * 1024 * 1024,
        "builtinFreeMedia": True,
        "builtinFreeResolver": True,
        "resolverManifests": [],
        "addons": [
            {
                "name": "Public Domain Movies",
                "manifestUrl": PUBLIC_DOMAIN_MANIFEST,
                "enabled": True,
            },
            {
                "name": "Stremio Local Files",
                "manifestUrl": "http://127.0.0.1:11480/local-addon/manifest.json",
                "enabled": True,
            },
        ],
    }


def load_config() -> dict:
    cfg = default_config()
    try:
        value = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            for key in cfg:
                if key in value:
                    cfg[key] = value[key]
    except (OSError, ValueError, TypeError):
        pass
    return cfg


def _safe_url(value: object, *, manifest: bool = False) -> str:
    if not isinstance(value, str) or len(value) > 4096:
        return ""
    parsed = urlparse(value)
    if parsed.scheme == "https":
        pass
    elif parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1"):
        pass
    else:
        return ""
    if manifest and not parsed.path.endswith("/manifest.json"):
        return ""
    return value.rstrip("/")


def _safe_resolver_url(value: object) -> str:
    url = _safe_url(value)
    if not url or not urlparse(url).path.endswith("/resolver.json"):
        return ""
    return url


def _addon_base(manifest_url: str) -> str:
    return manifest_url[: -len("/manifest.json")]


def _cache_path(url: str) -> Path:
    return CACHE_DIR / (hashlib.sha256(url.encode("utf-8")).hexdigest() + ".json")


def _prune_http_cache(now: float | None = None) -> dict:
    """Remove abandoned HTTP responses after the longest response TTL."""
    current = time.time() if now is None else now
    marker = CACHE_DIR / ".http-cache-pruned"
    try:
        if marker.exists() and current - marker.stat().st_mtime < HTTP_CACHE_PRUNE_INTERVAL:
            return {"removed": 0, "freed": 0}
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
    except OSError:
        return {"removed": 0, "freed": 0}
    removed = 0
    freed = 0
    try:
        candidates = list(CACHE_DIR.glob("*.json"))
    except OSError:
        candidates = []
    for candidate in candidates:
        if not re.fullmatch(r"[0-9a-f]{64}\.json", candidate.name):
            continue
        try:
            stat = candidate.stat()
            if current - stat.st_mtime <= HTTP_CACHE_MAX_AGE:
                continue
            candidate.unlink()
            removed += 1
            freed += stat.st_size
        except OSError:
            continue
    try:
        marker.touch()
    except OSError:
        pass
    return {"removed": removed, "freed": freed}


def _meta_cache_path(media_type: str, media_id: str) -> Path:
    key = hashlib.sha256(f"{media_type}|{media_id}".encode("utf-8")).hexdigest()
    return CACHE_DIR / f"meta-{key}.json"


def _resolved_cache_path(media_type: str, media_id: str) -> Path:
    key = hashlib.sha256(f"{media_type}|{media_id}".encode("utf-8")).hexdigest()
    return CACHE_DIR / f"resolved-{key}.json"


def _remember_meta(meta: dict) -> None:
    media_type = str(meta.get("type") or "movie").lower()
    media_id = str(meta.get("id") or "")
    if media_type not in ("movie", "series") or not media_id:
        return
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path = _meta_cache_path(media_type, media_id)
        value = dict(meta)
        try:
            existing = json.loads(path.read_text(encoding="utf-8"))
            existing_videos = existing.get("videos") if isinstance(existing, dict) else None
            incoming_videos = value.get("videos")
            if isinstance(existing_videos, list) and existing_videos and not incoming_videos:
                value = {**existing, **value, "videos": existing_videos}
        except (OSError, ValueError, TypeError):
            pass
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def _recall_meta(media_type: str, media_id: str) -> dict | None:
    try:
        value = json.loads(_meta_cache_path(media_type, media_id).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, TypeError):
        return None


def _remember_resolved_ids(media_type: str, media_id: str, entries: list[tuple[str, str]]) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path = _resolved_cache_path(media_type, media_id)
        data = [{"id": target_id, "source": source} for target_id, source in entries]
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass


def _recall_resolved_ids(media_type: str, media_id: str) -> list[tuple[str, str]]:
    try:
        data = json.loads(_resolved_cache_path(media_type, media_id).read_text(encoding="utf-8"))
        if isinstance(data, list):
            out = []
            for item in data:
                if isinstance(item, dict) and item.get("id"):
                    out.append((str(item["id"]), str(item.get("source") or "")))
            return out
    except (OSError, ValueError, TypeError):
        pass
    return []


def _get_json(url: str, ttl: int = 900, timeout: float = 4.0, stale_ok: bool = True) -> dict:
    now = time.time()
    if url in _MEM_CACHE:
        cache_time, value = _MEM_CACHE[url]
        if ttl <= 0 or (now - cache_time < ttl):
            return value
        _MEM_CACHE.pop(url, None)

    path = _cache_path(url)
    try:
        if ttl > 0 and path.exists():
            mtime = path.stat().st_mtime
            if now - mtime < ttl:
                value = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(value, dict):
                    _MEM_CACHE[url] = (mtime, value)
                    return value
            else:
                path.unlink()
    except (OSError, ValueError, TypeError):
        pass

    try:
        raw = net.get_bytes(
            url,
            {"User-Agent": "OmaCine/2.0 StreamingCatalogClient"},
            timeout,
            4 * 1024 * 1024,
        )
        value = json.loads(raw.decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
        if stale_ok:
            if url in _MEM_CACHE:
                return _MEM_CACHE[url][1]
            try:
                if path.exists():
                    value = json.loads(path.read_text(encoding="utf-8"))
                    if isinstance(value, dict):
                        _MEM_CACHE[url] = (now, value)
                        return value
            except (OSError, ValueError, TypeError):
                pass
        raise RuntimeError(str(exc)) from exc

    if not isinstance(value, dict):
        raise RuntimeError("addon returned non-object JSON")

    _MEM_CACHE[url] = (now, value)
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".new")
        tmp.write_text(json.dumps(value, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        pass
    return value


def _resource_url(manifest_url: str, resource: str, media_type: str, media_id: str, extra: str = "") -> str:
    parts = [quote(resource, safe=""), quote(media_type, safe=""), quote(media_id, safe=":")]
    if extra:
        parts.append(extra)
    return _addon_base(manifest_url) + "/" + "/".join(parts) + ".json"


def _meta_to_item(meta: dict) -> dict:
    media_type = str(meta.get("type") or "movie").lower()
    stype = 2 if media_type == "series" else 1
    raw_id = str(meta.get("id") or "")
    year = str(meta.get("releaseInfo") or meta.get("year") or "")[:4]
    rating = meta.get("imdbRating")
    try:
        rating = float(rating) if rating not in (None, "") else None
    except (TypeError, ValueError):
        rating = None
    return {
        "id": f"{media_type}|{raw_id}",
        "title": str(meta.get("name") or meta.get("title") or raw_id),
        "stype": stype,
        "year": year,
        "cover": _safe_url(meta.get("poster")),
        "rating": rating,
        "duration": str(meta.get("runtime") or ""),
        "genre": ", ".join(str(x) for x in (meta.get("genres") or []) if isinstance(x, str)),
        "provider": "stremio",
    }


def _split_id(value: str) -> tuple[str, str]:
    media_type, sep, media_id = value.partition("|")
    if not sep or media_type not in ("movie", "series") or not media_id:
        raise ValueError("invalid Addons media id")
    return media_type, media_id


def _sintel_item() -> dict:
    return {
        # Deliberately use a catalog namespace which differs from the stream
        # namespace. The bundled public-domain resolver demonstrates the same
        # ID bridge used by user-added resolver manifests.
        "id": f"movie|{SINTEL_CATALOG_ID}",
        "title": "Sintel (Creative Commons)",
        "stype": 1,
        "year": "2010",
        "cover": "",
        "rating": None,
        "duration": "15 min",
        "genre": "Animation, Fantasy",
        "provider": "stremio",
    }


def _manifest_resource_defs(manifest: dict, resource_name: str) -> list[dict]:
    """Return resource capability definitions matching resource_name from manifest."""
    defs = []
    root_types = [str(t) for t in manifest.get("types", []) if isinstance(t, str)]
    root_prefixes = [str(p) for p in manifest.get("idPrefixes", []) if isinstance(p, str)]
    for entry in manifest.get("resources", []):
        if isinstance(entry, str) and entry == resource_name:
            defs.append({"name": entry, "types": root_types, "idPrefixes": root_prefixes})
        elif isinstance(entry, dict) and entry.get("name") == resource_name:
            types = (
                [str(t) for t in entry.get("types", []) if isinstance(t, str)]
                if "types" in entry
                else root_types
            )
            prefixes = (
                [str(p) for p in entry.get("idPrefixes", []) if isinstance(p, str)]
                if "idPrefixes" in entry
                else root_prefixes
            )
            defs.append({"name": resource_name, "types": types, "idPrefixes": prefixes})
    return defs


def _addon_supports_resource(
    manifest: dict,
    resource: str,
    media_type: str = "",
    media_id: str = "",
) -> bool:
    """Check if an addon manifest supports the given resource, media_type, and media_id."""
    defs = _manifest_resource_defs(manifest, resource)
    if not defs:
        return False
    for d in defs:
        if media_type and d["types"] and media_type not in d["types"]:
            continue
        if media_id and d["idPrefixes"] and not any(media_id.startswith(p) for p in d["idPrefixes"]):
            continue
        return True
    return False


def _manifest_resources(manifest: dict) -> list[str]:
    names = []
    for value in manifest.get("resources", []):
        name = value if isinstance(value, str) else value.get("name") if isinstance(value, dict) else ""
        if name in ("catalog", "meta", "stream", "subtitles") and name not in names:
            names.append(name)
    return names


def _extract_meta_aliases(
    meta: dict,
    media_type: str,
    media_id: str,
    addon_name: str = "",
) -> list[tuple[str, str]]:
    """Extract alternative identifier aliases from a Stremio metadata object."""
    aliases: list[tuple[str, str]] = []
    seen = {media_id}

    def _add(target_id: str, source_label: str) -> None:
        target_id = target_id.strip()
        if not target_id or target_id in seen or len(target_id) > 512:
            return
        if any(c in target_id for c in ("/", "?", "#", "*", "\n", "\r")):
            return
        seen.add(target_id)
        aliases.append((target_id, source_label))

    source_label = addon_name or "Metadata"

    # 1. Standard IMDb id
    imdb_id = meta.get("imdb_id")
    if isinstance(imdb_id, str) and re.match(r"^tt\d+$", imdb_id.strip()):
        _add(imdb_id.strip(), source_label)

    # 2. Canonical metadata ID if different from queried ID
    meta_id = str(meta.get("id") or "").strip()
    if meta_id and meta_id != media_id:
        _add(meta_id, source_label)

    # 3. TMDB numeric ID
    tmdb_val = meta.get("moviedb_id") or meta.get("tmdb_id")
    if tmdb_val is not None:
        val_str = str(tmdb_val).strip()
        if val_str.isdigit():
            _add(f"tmdb:{val_str}", source_label)

    # 4. TVDB numeric ID
    tvdb_val = meta.get("thetvdb_id") or meta.get("tvdb_id")
    if tvdb_val is not None:
        val_str = str(tvdb_val).strip()
        if val_str.isdigit():
            _add(f"tvdb:{val_str}", source_label)

    # 5. Kitsu ID
    kitsu_val = meta.get("kitsu_id") or meta.get("kitsuId")
    if kitsu_val is not None:
        val_str = str(kitsu_val).strip()
        if val_str:
            _add(f"kitsu:{val_str}" if not val_str.startswith("kitsu:") else val_str, source_label)

    # 6. Links and external reference list
    links = meta.get("links", [])
    if isinstance(links, list):
        for link in links:
            if isinstance(link, dict):
                cat = str(link.get("category") or link.get("name") or "").lower()
                link_id = str(link.get("id") or "").strip()
                url = str(link.get("url") or "").strip()
                if "imdb" in cat or "imdb.com" in url:
                    match = re.search(r"tt\d+", link_id or url)
                    if match:
                        _add(match.group(0), source_label)
                elif "tmdb" in cat or "themoviedb.org" in url:
                    match = re.search(r"\b(movie|tv)/(\d+)\b", url)
                    if match:
                        _add(f"tmdb:{match.group(2)}", source_label)

    # 7. Videos array (for series episodes)
    if media_type == "series":
        for video in meta.get("videos", []):
            if isinstance(video, dict):
                vid = str(video.get("id") or "").strip()
                if vid:
                    base = vid.split(":", 1)[0]
                    if re.match(r"^tt\d+$", base):
                        _add(base, source_label)

    return aliases


def search(query: str) -> list[dict]:
    cfg = load_config()
    q = query.strip()
    if not q:
        return []
    out: list[dict] = []
    if cfg.get("builtinFreeMedia", True) and any(
        part in "sintel creative commons free movie" for part in q.lower().split()
    ):
        out.append(_sintel_item())

    manifests = []
    metadata_manifest = _safe_url(cfg.get("metadataManifest"), manifest=True)
    if metadata_manifest:
        manifests.append(("Metadata", metadata_manifest))
    manifests.extend(_enabled_addons(cfg))

    seen_manifests = set()
    manifest_tasks = []
    for _name, manifest_url in manifests:
        if manifest_url not in seen_manifests:
            seen_manifests.add(manifest_url)
            manifest_tasks.append((_name, manifest_url))

    catalog_targets = []
    with ThreadPoolExecutor(max_workers=min(12, len(manifest_tasks) or 1)) as pool:
        futures = {pool.submit(_get_json, url): (name, url) for name, url in manifest_tasks}
        for fut in as_completed(futures):
            name, url = futures[fut]
            try:
                manifest = fut.result()
            except RuntimeError:
                continue
            for catalog in manifest.get("catalogs", []):
                if not isinstance(catalog, dict):
                    continue
                media_type = str(catalog.get("type") or "")
                catalog_id = str(catalog.get("id") or "")
                if media_type not in ("movie", "series") or not catalog_id:
                    continue
                extras = catalog.get("extra") or catalog.get("extraSupported") or []
                supports_search = any(
                    value == "search" or (isinstance(value, dict) and value.get("name") == "search")
                    for value in extras
                )
                if not supports_search:
                    continue
                extra = "search=" + quote(q, safe="")
                target_url = _resource_url(url, "catalog", media_type, catalog_id, extra)
                catalog_targets.append((target_url, media_type))

    if catalog_targets:
        with ThreadPoolExecutor(max_workers=min(24, len(catalog_targets))) as pool:
            futures = {pool.submit(_get_json, t_url): m_type for t_url, m_type in catalog_targets}
            for fut in as_completed(futures):
                m_type = futures[fut]
                try:
                    payload = fut.result()
                except RuntimeError:
                    continue
                for meta in payload.get("metas", []):
                    if isinstance(meta, dict) and meta.get("id"):
                        meta.setdefault("type", m_type)
                        _remember_meta(meta)
                        out.append(_meta_to_item(meta))

    seen = set()
    unique = []
    for item in out:
        key = item["id"]
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique[:40]


def discover(
    media_type: str = "all",
    catalog_key: str = "",
    genre: str = "",
    year: str = "",
    sort: str = "popular",
    limit: int = 80,
    page: int = 1,
) -> dict:
    """Aggregate enabled add-on catalogs into a neutral discovery feed."""
    _prune_http_cache()
    media_type = media_type if media_type in ("all", "movie", "series") else "all"
    sort = sort if sort in ("popular", "new", "rating", "title") else "popular"
    genre = genre.strip().casefold()
    year = year.strip()
    limit = max(12, min(int(limit or 80), 120))
    page = max(1, int(page or 1))
    manifests = []
    cfg = load_config()
    metadata_manifest = _safe_url(cfg.get("metadataManifest"), manifest=True)
    if metadata_manifest:
        manifests.append(("Metadata", metadata_manifest))
    manifests.extend(_enabled_addons(cfg))

    definitions = []
    catalog_options = []
    seen_manifests = set()
    with ThreadPoolExecutor(max_workers=min(12, len(manifests) or 1)) as pool:
        futures = {
            pool.submit(_get_json, url, ttl=3600, timeout=3.0): (configured_name, url)
            for configured_name, url in manifests
            if not (url in seen_manifests or seen_manifests.add(url))
        }
        for future in as_completed(futures):
            configured_name, manifest_url = futures[future]
            try:
                manifest = future.result()
            except RuntimeError:
                continue
            addon_name = _friendly_provider(manifest.get("name") or configured_name)
            for catalog in manifest.get("catalogs", []):
                if not isinstance(catalog, dict):
                    continue
                item_type = str(catalog.get("type") or "")
                catalog_id = str(catalog.get("id") or "")
                if item_type not in ("movie", "series") or not catalog_id:
                    continue
                extras = catalog.get("extra") or catalog.get("extraSupported") or []
                extra_names = [
                    str(extra.get("name") if isinstance(extra, dict) else extra)
                    for extra in extras
                    if (isinstance(extra, str) and extra) or (isinstance(extra, dict) and extra.get("name"))
                ]
                if any(
                    isinstance(extra, dict) and extra.get("isRequired") is True
                    for extra in extras
                ):
                    continue
                key = hashlib.sha256(f"{manifest_url}|{catalog_id}".encode("utf-8")).hexdigest()[:16]
                catalog_name = _friendly_provider(catalog.get("name") or addon_name or catalog_id)
                definitions.append({
                    "key": key,
                    "name": catalog_name,
                    "type": item_type,
                    "id": catalog_id,
                    "manifestUrl": manifest_url,
                    "addon": addon_name,
                    "extraSupported": extra_names,
                })

    seen_options = set()
    for definition in sorted(definitions, key=lambda value: (value["name"].casefold(), value["key"])):
        if definition["key"] in seen_options:
            continue
        seen_options.add(definition["key"])
        catalog_options.append({"key": definition["key"], "name": definition["name"]})

    selected = [
        definition for definition in definitions
        if (media_type == "all" or definition["type"] == media_type)
        and (not catalog_key or definition["key"] == catalog_key)
    ]
    if not catalog_key:
        # A broad but bounded initial feed: up to twelve services for both media types.
        def _catalog_priority(value):
            name = value["name"].casefold()
            preferred = (
                (sort == "new" and "latest" in name)
                or (sort != "new" and ("trending" in name or "popular" in name))
            )
            return (0 if preferred else 1, name, value["type"])
        selected = sorted(selected, key=_catalog_priority)[:24]

    targets = []
    for definition in selected:
        supports_skip = "skip" in definition["extraSupported"]
        if page > 1 and not supports_skip:
            continue
        extra = f"skip={(page - 1) * limit}" if page > 1 else ""
        target_url = _resource_url(
            definition["manifestUrl"], "catalog", definition["type"], definition["id"], extra
        )
        targets.append((target_url, definition))

    item_by_id = {}
    popularity = {}
    page_returned_items = False
    if targets:
        with ThreadPoolExecutor(max_workers=min(24, len(targets))) as pool:
            futures = {
                pool.submit(_get_json, target_url, ttl=900, timeout=5.0): definition
                for target_url, definition in targets
            }
            for future in as_completed(futures):
                definition = futures[future]
                try:
                    payload = future.result()
                except RuntimeError:
                    continue
                metas = payload.get("metas", [])
                if isinstance(metas, list) and metas:
                    page_returned_items = True
                for rank, meta in enumerate(metas):
                    if not isinstance(meta, dict) or not meta.get("id"):
                        continue
                    meta = dict(meta)
                    meta.setdefault("type", definition["type"])
                    item = _meta_to_item(meta)
                    item_genres = {
                        value.strip().casefold()
                        for value in str(item.get("genre") or "").split(",")
                        if value.strip()
                    }
                    item_year = str(item.get("year") or "")[:4]
                    if genre and genre not in item_genres:
                        continue
                    if year:
                        if year.endswith("s") and len(year) == 5:
                            if not item_year.startswith(year[:3]):
                                continue
                        elif item_year != year:
                            continue
                    key = item["id"]
                    popularity[key] = popularity.get(key, 0.0) + 1.0 / (rank + 3)
                    if key not in item_by_id:
                        item["catalogName"] = definition["name"]
                        item_by_id[key] = item
                        _remember_meta(meta)

    items = list(item_by_id.values())
    if sort == "new":
        items.sort(key=lambda item: (str(item.get("year") or ""), popularity.get(item["id"], 0.0)), reverse=True)
    elif sort == "rating":
        items.sort(key=lambda item: (float(item.get("rating") or 0), popularity.get(item["id"], 0.0)), reverse=True)
    elif sort == "title":
        items.sort(key=lambda item: str(item.get("title") or "").casefold())
    else:
        items.sort(key=lambda item: popularity.get(item["id"], 0.0), reverse=True)
    has_more = any("skip" in definition["extraSupported"] for definition in selected)
    if page > 1:
        has_more = has_more and page_returned_items
    return {"items": items[:limit], "catalogs": catalog_options, "page": page, "hasMore": has_more}


def suggest(query: str) -> list[dict]:
    q = query.strip()
    if len(q) < 2:
        return []
    local_matches = []
    seen = set()
    try:
        for f in CACHE_DIR.glob("meta-*.json"):
            try:
                m = json.loads(f.read_text(encoding="utf-8"))
                name = str(m.get("name") or m.get("title") or "")
                if name and q.lower() in name.lower() and name.lower() not in seen:
                    seen.add(name.lower())
                    item = _meta_to_item(m)
                    local_matches.append({"name": item["title"], "id": item["id"], "cover": item["cover"]})
                    if len(local_matches) >= 8:
                        break
            except Exception:
                continue
    except Exception:
        pass
    if len(local_matches) >= 4:
        return local_matches[:8]

    search_results = search(query)
    for item in search_results:
        n = item["title"]
        if n.lower() not in seen:
            seen.add(n.lower())
            local_matches.append({"name": item["title"], "id": item["id"], "cover": item["cover"]})
            if len(local_matches) >= 8:
                break
    return local_matches[:8]


def details(value: str) -> dict:
    media_type, media_id = _split_id(value)
    if media_id in (SINTEL_CATALOG_ID, SINTEL_ID):
        return {
            "subjectId": value,
            "title": "Sintel (Creative Commons)",
            "subjectType": 1,
            "releaseDate": "2010",
            "cover": {"url": ""},
            "description": (
                "An independently produced animated short film released under the"
                " Creative Commons Attribution 3.0 license."
            ),
            "genre": "Animation, Fantasy",
            "duration": "15 min",
            "seasons": {"seasons": []},
            "stremioId": media_id,
            "stremioType": media_type,
        }
    cfg = load_config()
    meta = _recall_meta(media_type, media_id)
    needs_episode_metadata = media_type == "series" and not (
        isinstance(meta, dict) and isinstance(meta.get("videos"), list) and meta.get("videos")
    )
    if meta is None or needs_episode_metadata:
        manifests = []
        metadata_manifest = _safe_url(cfg.get("metadataManifest"), manifest=True)
        if metadata_manifest:
            manifests.append(("Metadata", metadata_manifest))
        manifests.extend(_enabled_addons(cfg))

        candidate_ids = [media_id]
        if isinstance(meta, dict):
            for alias_id, _name in _extract_meta_aliases(meta, media_type, media_id, "Catalog Metadata"):
                if alias_id not in candidate_ids:
                    candidate_ids.append(alias_id)
        for alias_id, _name in _recall_resolved_ids(media_type, media_id):
            if alias_id not in candidate_ids:
                candidate_ids.append(alias_id)

        resolved_metadata = False
        for _name, manifest_url in manifests:
            try:
                manifest = _get_json(manifest_url, ttl=3600, timeout=3.0)
            except RuntimeError:
                continue

            for cand_id in candidate_ids:
                if not _addon_supports_resource(manifest, "meta", media_type, cand_id):
                    continue
                try:
                    payload = _get_json(_resource_url(manifest_url, "meta", media_type, cand_id), ttl=86400)
                    candidate = payload.get("meta")
                    if isinstance(candidate, dict):
                        meta = candidate
                        _remember_meta(meta)
                        if cand_id != media_id:
                            _remember_meta({**meta, "id": media_id, "type": media_type})
                        addon_name = str(manifest.get("name") or _name)
                        aliases = _extract_meta_aliases(meta, media_type, media_id, addon_name)
                        if aliases:
                            _remember_resolved_ids(media_type, media_id, aliases)
                        if media_type != "series" or (isinstance(meta.get("videos"), list) and meta.get("videos")):
                            resolved_metadata = True
                            break
                except RuntimeError:
                    continue
            if resolved_metadata:
                break

    if not isinstance(meta, dict):
        raise RuntimeError("no cached details; search for the title again")
    seasons: dict[int, int] = {}
    for video in meta.get("videos", []):
        if not isinstance(video, dict):
            continue
        season = video.get("season")
        episode = video.get("episode")
        try:
            season, episode = int(season), int(episode)
        except (TypeError, ValueError):
            continue
        if season >= 0 and episode > 0:
            seasons[season] = max(seasons.get(season, 0), episode)
    item = _meta_to_item(meta)
    return {
        "subjectId": value,
        "title": item["title"],
        "subjectType": item["stype"],
        "releaseDate": item["year"],
        "cover": {"url": item["cover"]},
        "description": str(meta.get("description") or ""),
        "genre": item["genre"],
        "duration": item["duration"],
        "imdbRatingValue": str(meta.get("imdbRating") or ""),
        "seasons": {"seasons": [{"se": key, "maxEp": seasons[key]} for key in sorted(seasons)]},
        "stremioId": media_id,
        "stremioType": media_type,
    }


def _resolution(text: str) -> int:
    match = re.search(r"(?<!\d)(2160|1440|1080|720|576|480|360)p?\b", text, re.I)
    return int(match.group(1)) if match else 0


def _size_hint(stream: dict, label: str = "") -> int:
    hints = stream.get("behaviorHints") if isinstance(stream.get("behaviorHints"), dict) else {}
    try:
        size = int(hints.get("videoSize") or 0)
    except (TypeError, ValueError):
        size = 0
    if size:
        return size
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*(Gi?B|Mi?B)\b", label, re.I)
    if not match:
        return 0
    multiplier = 1024**3 if match.group(2).lower().startswith("g") else 1024**2
    return int(float(match.group(1)) * multiplier)


def _seeders_hint(stream: dict, label: str = "") -> int:
    """Extract seeder/peer count from stream metadata or description."""
    for key in ("seeders", "seeds", "seedCount"):
        val = stream.get(key)
        try:
            if val is not None and int(val) >= 0:
                return int(val)
        except (TypeError, ValueError):
            pass
    hints = stream.get("behaviorHints") if isinstance(stream.get("behaviorHints"), dict) else {}
    for key in ("seeders", "seeds", "seedCount"):
        val = hints.get(key)
        try:
            if val is not None and int(val) >= 0:
                return int(val)
        except (TypeError, ValueError):
            pass
    # Stremio standard emoji icon
    match = re.search(r"👤\s*([0-9]+)", label)
    if match:
        return int(match.group(1))
    # Descriptive words
    match = re.search(r"\b([0-9]+)\s*(?:seeders?|seeds?)\b", label, re.I)
    if match:
        return int(match.group(1))
    match = re.search(r"\b(?:seeders?|seeds?|peers?):\s*([0-9]+)", label, re.I)
    if match:
        return int(match.group(1))
    return 0


def _friendly_provider(value: object) -> str:
    """Return a neutral provider name that is safe to show in the UI."""
    text = str(value or "").strip()
    text = re.sub(r"torrentsdb", "FastDB", text, flags=re.I)
    text = re.sub(r"torrentio", "IO Streams", text, flags=re.I)
    text = re.sub(r"\btorrents?\b", "Community Streams", text, flags=re.I)
    text = re.sub(r"\binfo[ -]?hash\b", "Stream ID", text, flags=re.I)
    text = re.sub(r"\b[0-9a-f]{40}\b", "", text, flags=re.I)
    text = re.sub(r"\s{2,}", " ", text).strip(" -•|")
    return text or "Community Source"


def _public_stream_text(value: object) -> str:
    """Scrub provider-controlled stream text before it can become a label."""
    text = _friendly_provider(value)
    text = re.sub(r"\b([0-9]+)\s*(?:seeders?|seeds?)\b", r"\1 sources", text, flags=re.I)
    text = re.sub(r"\b(?:seeders?|seeds?):\s*([0-9]+)", r"sources: \1", text, flags=re.I)
    return text


_RELEASE_BOUNDARY_WORDS = {
    "season", "seasons", "series", "complete", "collection", "pack",
    "proper", "repack", "internal", "extended", "uncut", "uncensored",
    "bluray", "bdrip", "brrip", "webrip", "webdl", "web", "hdtv",
    "dvdrip", "remux", "hdrip", "uhd", "amzn", "nf", "dsnp", "atvp",
    "xvid", "x264", "x265", "h264", "h265", "hevc", "avc", "av1",
    "ita", "eng", "rus", "multi", "dual", "dubbed", "subbed",
}


def _identity_tokens(value: object) -> list[str]:
    return re.findall(r"[a-z0-9]+", str(value or "").casefold())


def _series_release_conflicts(stream: dict, meta: dict) -> bool:
    """Detect a confidently different series hidden in a provider result.

    Some torrent indexes search by the word "Dexter" even when asked for the
    exact IMDb id and return New Blood, Original Sin and Resurrection beside
    the 2006 show.  The title prefix before Sxx/quality/release metadata is the
    useful boundary: extra words there identify a different show.  Missing or
    opaque labels are retained because they provide no safe basis to reject.
    """
    if not isinstance(stream, dict) or not isinstance(meta, dict):
        return False
    if not re.fullmatch(r"[0-9a-fA-F]{40}", str(stream.get("infoHash") or "")):
        return False
    title_tokens = _identity_tokens(meta.get("name") or meta.get("title"))
    if not title_tokens:
        return False
    year_match = re.search(
        r"\b((?:18|19|20)\d{2})\b",
        str(meta.get("year") or meta.get("releaseInfo") or meta.get("released") or ""),
    )
    expected_year = year_match.group(1) if year_match else ""
    text = str(stream.get("description") or stream.get("title") or "")
    conflicts = 0
    for line in text.splitlines() or [text]:
        tokens = _identity_tokens(line)
        width = len(title_tokens)
        for index in range(0, len(tokens) - width + 1):
            if tokens[index:index + width] != title_tokens:
                continue
            tail = tokens[index + width:]
            if not tail:
                return False
            first = tail[0]
            if re.fullmatch(r"(?:18|19|20)\d{2}", first):
                if expected_year and first != expected_year:
                    conflicts += 1
                    continue
                return False
            if (
                first in _RELEASE_BOUNDARY_WORDS
                or first.isdigit()
                or re.fullmatch(r"s\d{1,2}(?:e\d{1,3})?", first)
                or re.fullmatch(r"e\d{1,3}", first)
                or re.fullmatch(r"\d{1,2}x\d{1,3}", first)
                or re.fullmatch(r"(?:2160|1440|1080|720|576|480|360)p", first)
            ):
                return False
            # Words between the canonical title and Sxx/release metadata are
            # part of a longer title, not a quality tag: e.g. Dexter New Blood.
            conflicts += 1
    return conflicts > 0


def filter_streams_for_media(value: str, items: list[dict]) -> list[dict]:
    """Remove provider results that name a different franchise title."""
    media_type, media_id = _split_id(value)
    if media_type != "series" or not isinstance(items, list):
        return items if isinstance(items, list) else []
    meta = _recall_meta(media_type, media_id)
    if not isinstance(meta, dict):
        return items
    return [item for item in items if not _series_release_conflicts(item, meta)]


def _media_hint(label: str) -> str:
    video = ""
    for pattern, name in (
        (r"\b(?:x265|h[ .]?265|hevc)\b", "HEVC"),
        (r"\bav1\b", "AV1"),
        (r"\b(?:x264|h[ .]?264|avc)\b", "H.264"),
        (r"\bvp9\b", "VP9"),
        (r"\bxvid\b", "Xvid"),
    ):
        if re.search(pattern, label, re.I):
            video = name
            break
    audio = ""
    for pattern, name in (
        (r"\b(?:ddp|dd\+|eac3|e-ac-3)\b", "DD+"),
        (r"\btruehd\b", "TrueHD"),
        (r"\bdts(?:-hd)?\b", "DTS"),
        (r"\baac\b", "AAC"),
        (r"\bac3\b", "AC3"),
    ):
        if re.search(pattern, label, re.I):
            audio = name
            break
    return " / ".join(part for part in (audio, video) if part)


def _peer_sources(stream: dict, info_hash: str) -> list[str]:
    """Merge addon hints with simultaneous low-latency discovery fallbacks."""
    supplied = [str(x) for x in stream.get("sources", []) if isinstance(x, str) and len(x) < 2048]
    merged = [f"dht:{info_hash}", *supplied, *FALLBACK_PEER_SOURCES]
    out: list[str] = []
    seen: set[str] = set()
    for source in merged:
        if source not in seen:
            seen.add(source)
            out.append(source)
    return out


# 256 KiB is comfortably more than an MKV Cues block for a single episode,
# and small enough that fetching it does not delay the head.
TAIL_WARM_BYTES = 262144


def warm_stream(url: str) -> dict:
    """Prime a loopback stream with a highest-priority head range request."""
    parsed = urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("only local streams can be warmed")

    base_headers = {
        "User-Agent": "OmaCine/2.0",
        "EngineFS-Prio": "255",
        "Connection": "close",
    }
    content_length = 0
    try:
        with urlopen(Request(url, headers=base_headers, method="HEAD"), timeout=1.25) as response:
            content_length = int(response.headers.get("Content-Length") or 0)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError):
        pass

    range_headers = {**base_headers, "Range": "bytes=0-1048576"}
    received = 0
    try:
        with urlopen(Request(url, headers=range_headers, method="GET"), timeout=1.75) as response:
            while received <= 1048576:
                chunk = response.read(min(131072, 1048577 - received))
                if not chunk:
                    break
                received += len(chunk)
    except (HTTPError, URLError, TimeoutError, OSError):
        pass
    # The tail matters as much as the head. An MKV keeps its Cues - the
    # keyframe index mpv must read before it can show a single frame - at the
    # end of the file, and a sequential downloader never asks for it. A source
    # can be 86% cached, serve its head in milliseconds, and still show nothing
    # because the last pieces have not arrived yet.
    #
    # tail_expected is 0 when there is nothing to ask for - HEAD gave no length,
    # or the file is small enough that head and tail would overlap. That is not
    # a missing index, so callers are told the tail was never attempted rather
    # than being told it failed.
    tail_expected = TAIL_WARM_BYTES if content_length > TAIL_WARM_BYTES * 2 else 0
    tail_received = 0
    if tail_expected:
        tail_headers = {**base_headers,
                        "Range": f"bytes={content_length - TAIL_WARM_BYTES}-{content_length - 1}"}
        try:
            with urlopen(Request(url, headers=tail_headers, method="GET"), timeout=1.5) as response:
                while tail_received < TAIL_WARM_BYTES:
                    chunk = response.read(min(65536, TAIL_WARM_BYTES - tail_received))
                    if not chunk:
                        break
                    tail_received += len(chunk)
        except (HTTPError, URLError, TimeoutError, OSError):
            pass
    return {
        "ready": received > 0,
        "bytes": received,
        "headBytes": content_length,
        "tailBytes": tail_received,
        "tailExpectedBytes": tail_expected,
        "tailAttempted": bool(tail_expected),
        # The whole requested range, not merely a first chunk: a partial read
        # can stop short of the actual end of file, which is where the index
        # lives. False means "has not arrived yet", never "will not arrive".
        "tailReady": bool(tail_expected) and tail_received >= tail_expected,
        "priorityWindowBytes": max(1048577, int(content_length * 0.05)) if content_length else 1048577,
    }


def release_stream(url: str) -> dict:
    """Tear down an engine a prefetch started that the user did not play.

    Best effort by design: an engine that has already gone, or a server that
    refuses the call, must never surface as an error. The caller is cleaning
    up after itself, not asking the server for something it needs.
    """
    parsed = urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("only local streams can be released")
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 2 or not re.fullmatch(r"[0-9a-fA-F]{40}", parts[0]):
        raise ValueError("invalid local stream URL")
    try:
        int(parts[1])
    except ValueError as exc:
        raise ValueError("invalid local stream file") from exc
    info_hash = parts[0].lower()
    base = f"{parsed.scheme}://{parsed.netloc}"
    # /:infoHash/remove is EngineFS's own engine teardown. Note that
    # /:id/destroy belongs to the HLS converter router, not to engines: it
    # answers 200 for an id it does not know and leaves the swarm running.
    for path in (f"/{info_hash}/remove",):
        try:
            request = Request(base + path, headers={"User-Agent": "OmaCine/2.0"}, method="GET")
            with urlopen(request, timeout=2.0) as response:
                if 200 <= getattr(response, "status", 0) < 300:
                    return {"released": True}
        except (HTTPError, URLError, TimeoutError, OSError, ValueError):
            continue
    return {"released": False}


def stream_status(url: str) -> dict:
    """Return safe, user-facing telemetry for a loopback stream engine."""
    parsed = urlparse(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
        raise ValueError("only local stream status is available")
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 2 or not re.fullmatch(r"[0-9a-fA-F]{40}", parts[0]):
        raise ValueError("invalid local stream URL")
    try:
        file_idx = int(parts[1])
    except ValueError as exc:
        raise ValueError("invalid local stream file") from exc

    stats_url = f"{parsed.scheme}://{parsed.netloc}/{parts[0].lower()}/{file_idx}/stats.json"
    try:
        request = Request(
            stats_url,
            headers={"User-Agent": "OmaCine/2.0", "Cache-Control": "no-cache"},
            method="GET",
        )
        with urlopen(request, timeout=0.7) as response:
            payload = json.loads(response.read(1024 * 1024).decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, OSError, ValueError, UnicodeError):
        return {"available": False}
    if not isinstance(payload, dict):
        return {"available": False}

    def _number(key: str, *, integer: bool = True):
        try:
            value = float(payload.get(key) or 0)
            return max(0, int(value)) if integer else max(0.0, min(1.0, value))
        except (TypeError, ValueError, OverflowError):
            return 0 if integer else 0.0

    return {
        "available": True,
        "sources": _number("peers"),
        "active": _number("unchoked"),
        "attempts": _number("connectionTries"),
        "receiveRate": _number("downloadSpeed"),
        "downloaded": _number("downloaded"),
        "cachedProgress": _number("streamProgress", integer=False),
    }


def _stream_item(
    stream: dict,
    addon_name: str,
    server: str,
    extra_subtitles: list[dict] | None = None,
    addon_key: str = "",
) -> dict | None:
    label = " ".join(str(stream.get(key) or "") for key in ("name", "title", "description")).strip()
    url = _safe_url(stream.get("url"))
    info_hash = str(stream.get("infoHash") or "").lower()
    file_idx = stream.get("fileIdx", -1)
    if url:
        kind = "direct"
        resource = url
    elif re.fullmatch(r"[0-9a-f]{40}", info_hash):
        kind = "p2p"
        try:
            file_idx = int(file_idx)
        except (TypeError, ValueError):
            file_idx = -1
        sources = _peer_sources(stream, info_hash)
        query = urlencode([("tr", source) for source in sources])
        resource = f"{server}/{info_hash}/{file_idx}" + ("?" + query if query else "")
    else:
        return None
    subtitles = []
    seen_subs = set()
    for sub in stream.get("subtitles", []):
        if isinstance(sub, dict):
            sub_url = _safe_url(sub.get("url"))
            if sub_url and sub_url not in seen_subs:
                seen_subs.add(sub_url)
                subtitles.append({
                    "name": str(sub.get("lang") or sub.get("name") or "Subtitle"),
                    "url": sub_url,
                    "lang": str(sub.get("lang") or ""),
                })
    if extra_subtitles:
        for sub in extra_subtitles:
            if isinstance(sub, dict):
                sub_url = _safe_url(sub.get("url"))
                if sub_url and sub_url not in seen_subs:
                    seen_subs.add(sub_url)
                    subtitles.append({
                        "name": str(sub.get("name") or sub.get("lang") or "Subtitle"),
                        "url": sub_url,
                        "lang": str(sub.get("lang") or ""),
                    })
    headers = []
    hints = stream.get("behaviorHints") if isinstance(stream.get("behaviorHints"), dict) else {}
    stable_addon_key = addon_key or hashlib.sha256(
        _friendly_provider(addon_name).lower().encode("utf-8")
    ).hexdigest()[:20]
    raw_binge_group = hints.get("bingeGroup")
    continuity_group = ""
    if isinstance(raw_binge_group, str) and raw_binge_group.strip():
        continuity_group = hashlib.sha256(
            f"{stable_addon_key}|{raw_binge_group.strip()}".encode("utf-8")
        ).hexdigest()[:24]
    proxy_headers = hints.get("proxyHeaders") if isinstance(hints.get("proxyHeaders"), dict) else {}
    request_headers = proxy_headers.get("request") if isinstance(proxy_headers.get("request"), dict) else {}
    for key, value in request_headers.items():
        if (
            re.fullmatch(r"[A-Za-z0-9-]{1,64}", str(key))
            and isinstance(value, str)
            and "\n" not in value
            and "\r" not in value
        ):
            headers.append([str(key), value[:2048]])
    return {
        "resourceLink": resource,
        "resourceId": info_hash or hashlib.sha1(resource.encode("utf-8")).hexdigest(),
        "streamKind": kind,
        "infoHash": info_hash,
        "fileIdx": file_idx,
        "sourceLabel": _friendly_provider(addon_name),
        "name": _public_stream_text(stream.get("name") or ""),
        "description": _public_stream_text(stream.get("title") or stream.get("description") or ""),
        "resolution": _resolution(label),
        "size": _size_hint(stream, label),
        "seeders": _seeders_hint(stream, label),
        "peerCount": _seeders_hint(stream, label),
        "mediaLabel": _media_hint(label),
        "streamBadge": "Cached Stream" if kind == "p2p" else "Fast Mirror",
        "subtitles": subtitles,
        "headers": headers,
        "addonKey": stable_addon_key,
        "continuityGroup": continuity_group,
    }


def _continuity_number(stream: dict, key: str) -> int:
    try:
        return max(0, int(stream.get(key) or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def select_continuation(current: dict, candidates: list[dict]) -> dict | None:
    """Choose a conservative next-episode stream from the same source family."""
    if not isinstance(current, dict) or not isinstance(candidates, list):
        return None
    current_kind = str(current.get("streamKind") or "")
    current_addon = str(current.get("addonKey") or "")
    current_group = str(current.get("continuityGroup") or "")
    current_source = str(current.get("sourceLabel") or "").strip().casefold()
    current_resolution = _continuity_number(current, "resolution")
    current_media = str(current.get("mediaLabel") or "").strip().casefold()
    ranked = []
    for index, candidate in enumerate(candidates):
        if not isinstance(candidate, dict) or str(candidate.get("streamKind") or "") != current_kind:
            continue
        candidate_addon = str(candidate.get("addonKey") or "")
        candidate_group = str(candidate.get("continuityGroup") or "")
        same_addon = bool(current_addon and candidate_addon == current_addon)
        if not current_addon:
            same_addon = bool(
                current_source
                and str(candidate.get("sourceLabel") or "").strip().casefold() == current_source
            )
        exact_group = bool(current_group and candidate_group == current_group and same_addon)
        if not exact_group and not same_addon:
            continue
        candidate_resolution = _continuity_number(candidate, "resolution")
        candidate_media = str(candidate.get("mediaLabel") or "").strip().casefold()
        same_resolution = bool(current_resolution and candidate_resolution == current_resolution)
        same_media = bool(current_media and candidate_media == current_media)
        if exact_group:
            tier, match = 0, "exact"
        elif same_resolution and same_media:
            tier, match = 1, "format"
        elif same_resolution:
            tier, match = 2, "quality"
        else:
            tier, match = 3, "provider"
        peers = max(
            _continuity_number(candidate, "peerCount"),
            _continuity_number(candidate, "seeders"),
        )
        ranked.append((tier, -peers, index, match, candidate))
    if not ranked:
        return None
    _tier, _peers, _index, match, selected = min(ranked, key=lambda value: value[:3])
    result = dict(selected)
    result["continuityMatch"] = match
    return result


def _enabled_addons(cfg: dict) -> list[tuple[str, str]]:
    out = []
    for entry in cfg.get("addons", []):
        if not isinstance(entry, dict) or entry.get("enabled") is False:
            continue
        url = _safe_url(entry.get("manifestUrl"), manifest=True)
        if url:
            out.append((_friendly_provider(entry.get("name") or urlparse(url).hostname or "Addon"), url))
    return out


def _validated_mappings(value: object) -> list[dict[str, str]]:
    if not isinstance(value, list) or len(value) > 10000:
        raise ValueError("Resolver mappings must be a list with at most 10,000 entries")
    out = []
    seen = set()
    for entry in value:
        if not isinstance(entry, dict):
            raise ValueError("Each resolver mapping must be an object")
        media_type = str(entry.get("type") or "")
        source_id = str(entry.get("from") or "")
        target_id = str(entry.get("to") or "")
        if media_type not in ("movie", "series"):
            raise ValueError("Resolver mapping type must be movie or series")
        if not source_id or not target_id or len(source_id) > 512 or len(target_id) > 512:
            raise ValueError("Resolver mapping IDs must contain 1–512 characters")
        if any(char in source_id + target_id for char in ("/", "?", "#", "*", "\n", "\r")):
            raise ValueError("Resolver mapping IDs contain unsupported characters")
        key = (media_type, source_id, target_id)
        if key not in seen:
            seen.add(key)
            out.append({"type": media_type, "from": source_id, "to": target_id})
    if not out:
        raise ValueError("Resolver manifest has no mappings")
    return out


def validate_resolver_manifest(url: str) -> tuple[str, dict]:
    url = _safe_resolver_url(url.strip())
    if not url:
        raise ValueError("Use an HTTPS resolver URL ending in /resolver.json (localhost HTTP is also allowed)")
    resolver = _get_json(url, ttl=0, timeout=10.0, stale_ok=False)
    if resolver.get("schemaVersion") != 1:
        raise ValueError("Resolver manifest schemaVersion must be 1")
    if not isinstance(resolver.get("id"), str) or not resolver["id"].strip():
        raise ValueError("Resolver manifest is missing its id")
    if not isinstance(resolver.get("name"), str) or not resolver["name"].strip():
        raise ValueError("Resolver manifest is missing its name")
    resolver["mappings"] = _validated_mappings(resolver.get("mappings"))
    return url, resolver


def _enabled_resolvers(cfg: dict) -> list[tuple[str, str]]:
    out = []
    for entry in cfg.get("resolverManifests", []):
        if not isinstance(entry, dict) or entry.get("enabled") is False:
            continue
        url = _safe_resolver_url(entry.get("resolverUrl"))
        if url:
            out.append((str(entry.get("name") or urlparse(url).hostname or "Resolver"), url))
    return out


def _resolved_ids(media_type: str, media_id: str, cfg: dict) -> list[tuple[str, str]]:
    """Return the original ID plus aliases from static resolvers and dynamic metadata.

    Resolver manifests are static and deterministic JSON. Dynamic resolution
    inspects cached or queried metadata from enabled addons, recording provenance.
    """
    out = [(media_id, "")]
    seen = {media_id}

    # 1. Built-in public domain demo resolver
    if cfg.get("builtinFreeResolver", True):
        if media_type == "movie" and media_id == SINTEL_CATALOG_ID and SINTEL_ID not in seen:
            seen.add(SINTEL_ID)
            out.append((SINTEL_ID, "Public Domain Demo"))

    # 2. Configured static resolver manifests
    for configured_name, resolver_url in _enabled_resolvers(cfg):
        try:
            resolver = _get_json(resolver_url, ttl=3600, timeout=4.0)
            name = str(resolver.get("name") or configured_name)
            validated = _validated_mappings(resolver.get("mappings"))
        except (RuntimeError, ValueError):
            continue
        for entry in validated:
            if entry["type"] == media_type and entry["from"] == media_id and entry["to"] not in seen:
                seen.add(entry["to"])
                out.append((entry["to"], name))

    # 3. Local resolved ID cache
    cached_entries = _recall_resolved_ids(media_type, media_id)
    for target_id, source in cached_entries:
        if target_id not in seen:
            seen.add(target_id)
            out.append((target_id, source))

    # 4. Dynamic metadata resolution from cached meta or enabled meta addons
    meta = _recall_meta(media_type, media_id)
    addon_provenance = ""
    if meta is None:
        manifests = []
        metadata_manifest = _safe_url(cfg.get("metadataManifest"), manifest=True)
        if metadata_manifest:
            manifests.append(("Metadata", metadata_manifest))
        manifests.extend(_enabled_addons(cfg))
        for _name, manifest_url in manifests:
            try:
                manifest = _get_json(manifest_url, ttl=3600, timeout=3.0)
            except RuntimeError:
                continue
            if not _addon_supports_resource(manifest, "meta", media_type, media_id):
                continue
            try:
                payload = _get_json(_resource_url(manifest_url, "meta", media_type, media_id), ttl=86400)
                candidate = payload.get("meta")
                if isinstance(candidate, dict):
                    meta = candidate
                    _remember_meta(meta)
                    addon_provenance = str(manifest.get("name") or _name)
                    break
            except RuntimeError:
                continue

    if isinstance(meta, dict):
        if not addon_provenance:
            for _name, manifest_url in _enabled_addons(cfg):
                try:
                    manifest = _get_json(manifest_url, ttl=3600, timeout=1.0)
                    if _addon_supports_resource(manifest, "meta", media_type, media_id):
                        addon_provenance = str(manifest.get("name") or _name)
                        break
                except Exception:
                    pass
        if not addon_provenance:
            addon_provenance = "Metadata Addon"

        aliases = _extract_meta_aliases(meta, media_type, media_id, addon_provenance)
        new_aliases = []
        for alias_id, source in aliases:
            if alias_id not in seen:
                seen.add(alias_id)
                out.append((alias_id, source))
                new_aliases.append((alias_id, source))
        if new_aliases:
            all_resolved = [(target, src) for target, src in out if target != media_id]
            _remember_resolved_ids(media_type, media_id, all_resolved)

    return out


def _save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".new")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_PATH)


def validate_manifest(url: str) -> tuple[str, dict]:
    url = _safe_url(url.strip(), manifest=True)
    if not url:
        raise ValueError("Use an HTTPS manifest URL ending in /manifest.json (localhost HTTP is also allowed)")
    manifest = _get_json(url, ttl=0, timeout=10.0, stale_ok=False)
    if not isinstance(manifest.get("id"), str) or not manifest["id"].strip():
        raise ValueError("Manifest is missing its addon id")
    if not isinstance(manifest.get("name"), str) or not manifest["name"].strip():
        raise ValueError("Manifest is missing its addon name")
    resources = _manifest_resources(manifest)
    if not resources:
        raise ValueError("Manifest has no supported catalog, meta, stream, or subtitles resource")
    return url, manifest


def add_manifest(url: str) -> dict:
    url, manifest = validate_manifest(url)
    cfg = load_config()
    addons = cfg.get("addons") if isinstance(cfg.get("addons"), list) else []
    for entry in addons:
        if isinstance(entry, dict) and entry.get("manifestUrl") == url:
            entry["name"] = manifest["name"].strip()
            entry["enabled"] = True
            _save_config(cfg)
            return {"name": entry["name"], "manifestUrl": url, "enabled": True, "updated": True}
    addons.append({"name": manifest["name"].strip(), "manifestUrl": url, "enabled": True})
    cfg["addons"] = addons
    _save_config(cfg)
    return {"name": manifest["name"].strip(), "manifestUrl": url, "enabled": True, "updated": False}


def remove_manifest(url: str) -> dict:
    cfg = load_config()
    addons = cfg.get("addons") if isinstance(cfg.get("addons"), list) else []
    kept = [entry for entry in addons if not (isinstance(entry, dict) and entry.get("manifestUrl") == url)]
    if len(kept) == len(addons):
        raise ValueError("Addon is no longer in the configuration")
    cfg["addons"] = kept
    _save_config(cfg)
    return {"removed": True, "manifestUrl": url}


def toggle_manifest(url: str, enabled: bool) -> dict:
    cfg = load_config()
    addons = cfg.get("addons") if isinstance(cfg.get("addons"), list) else []
    for entry in addons:
        if isinstance(entry, dict) and entry.get("manifestUrl") == url:
            entry["enabled"] = bool(enabled)
            _save_config(cfg)
            return {"name": str(entry.get("name") or "Addon"), "manifestUrl": url, "enabled": bool(enabled)}
    raise ValueError("Addon is no longer in the configuration")


def add_resolver(url: str) -> dict:
    url, resolver = validate_resolver_manifest(url)
    cfg = load_config()
    entries = cfg.get("resolverManifests") if isinstance(cfg.get("resolverManifests"), list) else []
    for entry in entries:
        if isinstance(entry, dict) and entry.get("resolverUrl") == url:
            entry["name"] = resolver["name"].strip()
            entry["enabled"] = True
            _save_config(cfg)
            return {
                "name": entry["name"],
                "resolverUrl": url,
                "enabled": True,
                "mappingCount": len(resolver["mappings"]),
                "updated": True,
            }
    entries.append({"name": resolver["name"].strip(), "resolverUrl": url, "enabled": True})
    cfg["resolverManifests"] = entries
    _save_config(cfg)
    return {
        "name": resolver["name"].strip(),
        "resolverUrl": url,
        "enabled": True,
        "mappingCount": len(resolver["mappings"]),
        "updated": False,
    }


def remove_resolver(url: str) -> dict:
    cfg = load_config()
    entries = cfg.get("resolverManifests") if isinstance(cfg.get("resolverManifests"), list) else []
    kept = [entry for entry in entries if not (isinstance(entry, dict) and entry.get("resolverUrl") == url)]
    if len(kept) == len(entries):
        raise ValueError("Resolver is no longer in the configuration")
    cfg["resolverManifests"] = kept
    _save_config(cfg)
    return {"removed": True, "resolverUrl": url}


def toggle_resolver(url: str, enabled: bool) -> dict:
    cfg = load_config()
    entries = cfg.get("resolverManifests") if isinstance(cfg.get("resolverManifests"), list) else []
    for entry in entries:
        if isinstance(entry, dict) and entry.get("resolverUrl") == url:
            entry["enabled"] = bool(enabled)
            _save_config(cfg)
            return {"name": str(entry.get("name") or "Resolver"), "resolverUrl": url, "enabled": bool(enabled)}
    raise ValueError("Resolver is no longer in the configuration")


def subtitles(value: str, season: int = 0, episode: int = 0) -> list[dict]:
    media_type, media_id = _split_id(value)
    cfg = load_config()
    resolved_ids = _resolved_ids(media_type, media_id, cfg)

    # Check if cached metadata has specific episode ID hints
    cached_meta = _recall_meta(media_type, media_id)
    video_id_hints: dict[str, str] = {}
    if isinstance(cached_meta, dict) and media_type == "series" and season > 0 and episode > 0:
        for video in cached_meta.get("videos", []):
            if isinstance(video, dict):
                try:
                    v_se = int(video.get("season", 0))
                    v_ep = int(video.get("episode", 0))
                except (TypeError, ValueError):
                    continue
                if v_se == season and v_ep == episode:
                    vid = str(video.get("id") or "").strip()
                    if vid:
                        video_id_hints[vid.split(":", 1)[0]] = vid

    request_ids: list[str] = []
    seen_req = set()
    for resolved_id, _resolver_name in resolved_ids:
        if resolved_id in video_id_hints:
            hint_req_id = video_id_hints[resolved_id]
            if hint_req_id not in seen_req:
                seen_req.add(hint_req_id)
                request_ids.append(hint_req_id)

        request_id = resolved_id
        if media_type == "series" and season > 0 and episode > 0 and not re.search(r":\d+:\d+$", resolved_id):
            request_id = f"{resolved_id}:{season}:{episode}"
        if request_id not in seen_req:
            seen_req.add(request_id)
            request_ids.append(request_id)

    enabled_addons = _enabled_addons(cfg)
    subtitle_targets = []
    if enabled_addons:
        with ThreadPoolExecutor(max_workers=min(12, len(enabled_addons))) as pool:
            futures = {
                pool.submit(_get_json, manifest_url, ttl=3600, timeout=2.5): (configured_name, manifest_url)
                for configured_name, manifest_url in enabled_addons
            }
            for future in as_completed(futures):
                configured_name, manifest_url = futures[future]
                try:
                    manifest = future.result()
                    addon_name = _friendly_provider(manifest.get("name") or configured_name)
                except RuntimeError:
                    continue
                for request_id in request_ids:
                    if _addon_supports_resource(manifest, "subtitles", media_type, request_id):
                        url = _resource_url(manifest_url, "subtitles", media_type, request_id)
                        subtitle_targets.append((url, addon_name))

    out: list[dict] = []
    seen_urls: set[str] = set()
    if subtitle_targets:
        with ThreadPoolExecutor(max_workers=min(8, len(subtitle_targets))) as pool:
            futures = {pool.submit(_get_json, url): addon_name for url, addon_name in subtitle_targets}
            for fut in as_completed(futures):
                addon_name = futures[fut]
                try:
                    payload = fut.result()
                except RuntimeError:
                    continue
                for sub in payload.get("subtitles", []):
                    if not isinstance(sub, dict):
                        continue
                    url = _safe_url(sub.get("url"))
                    if not url or url in seen_urls:
                        continue
                    seen_urls.add(url)
                    lang = str(sub.get("lang") or sub.get("lang_code") or sub.get("language") or "English")
                    title = str(sub.get("title") or sub.get("name") or "")
                    name = f"{lang} ({title})" if title and title != lang else lang
                    out.append({
                        "id": str(sub.get("id") or sub.get("sub_id") or ""),
                        "name": name,
                        "lang": lang,
                        "url": url,
                        "source": _friendly_provider(addon_name),
                    })
    return out


def streams(value: str, season: int = 0, episode: int = 0) -> list[dict]:
    media_type, media_id = _split_id(value)
    cfg = load_config()
    server = _safe_url(cfg.get("streamingServer")) or DEFAULT_SERVER
    resolved_ids = _resolved_ids(media_type, media_id, cfg)

    # Check if cached metadata has specific episode ID hints
    cached_meta = _recall_meta(media_type, media_id)
    video_id_hints: dict[str, str] = {}
    if isinstance(cached_meta, dict) and media_type == "series" and season > 0 and episode > 0:
        for video in cached_meta.get("videos", []):
            if isinstance(video, dict):
                try:
                    v_se = int(video.get("season", 0))
                    v_ep = int(video.get("episode", 0))
                except (TypeError, ValueError):
                    continue
                if v_se == season and v_ep == episode:
                    vid = str(video.get("id") or "").strip()
                    if vid:
                        video_id_hints[vid.split(":", 1)[0]] = vid

    request_ids: list[tuple[str, str]] = []
    seen_req = set()
    for resolved_id, resolver_name in resolved_ids:
        if resolved_id in video_id_hints:
            hint_req_id = video_id_hints[resolved_id]
            if hint_req_id not in seen_req:
                seen_req.add(hint_req_id)
                request_ids.append((hint_req_id, resolver_name))

        request_id = resolved_id
        if media_type == "series" and season > 0 and episode > 0 and not re.search(r":\d+:\d+$", resolved_id):
            request_id = f"{resolved_id}:{season}:{episode}"
        if request_id not in seen_req:
            seen_req.add(request_id)
            request_ids.append((request_id, resolver_name))

    out = []
    with ThreadPoolExecutor(max_workers=10) as pool:
        stream_targets = []
        for configured_name, manifest_url in _enabled_addons(cfg):
            try:
                manifest = _get_json(manifest_url, ttl=3600, timeout=2.5)
                addon_name = str(manifest.get("name") or configured_name)
            except RuntimeError:
                continue
            addon_key = hashlib.sha256(
                f"{manifest.get('id') or ''}|{manifest_url}".encode("utf-8")
            ).hexdigest()[:20]

            for request_id, resolver_name in request_ids:
                if _addon_supports_resource(manifest, "stream", media_type, request_id):
                    url = _resource_url(manifest_url, "stream", media_type, request_id)
                    source_name = addon_name + (f" via {resolver_name}" if resolver_name else "")
                    stream_targets.append((url, source_name, resolver_name, request_id, addon_key))

        stream_futures = {
            pool.submit(_get_json, url): (s_name, res_name, req_id, addon_key)
            for url, s_name, res_name, req_id, addon_key in stream_targets
        }

        if any(resolved_id == SINTEL_ID for resolved_id, _name in resolved_ids) and cfg.get("builtinFreeMedia", True):
            stream = {
                "name": "OmaCine Free Media",
                "title": "Sintel • Creative Commons • resolved catalog → stream ID",
                "infoHash": SINTEL_HASH,
                "fileIdx": -1,
                "sources": SINTEL_TRACKERS,
            }
            item = _stream_item(
                stream,
                "Free Media via Public Domain Demo",
                server,
                addon_key="builtin-free-media",
            )
            if item:
                item["resolverProvenance"] = "Public Domain Demo"
                item["resolvedId"] = SINTEL_ID
                out.append(item)

        for fut in as_completed(stream_futures):
            source_name, resolver_name, request_id, addon_key = stream_futures[fut]
            try:
                payload = fut.result()
            except RuntimeError:
                continue
            for stream in payload.get("streams", []):
                if not isinstance(stream, dict):
                    continue
                item = _stream_item(
                    stream,
                    source_name,
                    server,
                    addon_key=addon_key,
                )
                if item:
                    item["resolverProvenance"] = resolver_name
                    item["resolvedId"] = request_id
                    out.append(item)

    unique = []
    seen = set()
    for item in out:
        key = item.get("resourceLink") or item.get("link") or str(item.get("id") or "")
        if key in seen:
            continue
        seen.add(key)
        unique.append(item)
    return unique


def addon_status() -> dict:
    cfg = load_config()
    addons = []
    for entry in cfg.get("addons", []):
        if not isinstance(entry, dict):
            continue
        url = _safe_url(entry.get("manifestUrl"), manifest=True)
        if not url:
            continue
        name = _friendly_provider(entry.get("name") or urlparse(url).hostname or "Addon")
        enabled = entry.get("enabled") is not False
        if not enabled:
            addons.append({
                "name": name,
                "manifestUrl": url,
                "enabled": False,
                "available": False,
                "host": urlparse(url).hostname or "",
            })
            continue
        try:
            manifest = _get_json(url, ttl=3600, timeout=2.0)
            addons.append({
                "name": _friendly_provider(manifest.get("name") or name),
                "manifestUrl": url,
                "enabled": True,
                "available": True,
                "host": urlparse(url).hostname or "",
                "resources": _manifest_resources(manifest),
            })
        except RuntimeError as exc:
            addons.append({
                "name": name,
                "manifestUrl": url,
                "enabled": True,
                "available": False,
                "host": urlparse(url).hostname or "",
                "error": str(exc),
            })
    resolvers = []
    if cfg.get("builtinFreeResolver", True):
        resolvers.append({
            "name": "Public Domain Demo",
            "resolverUrl": "builtin:public-domain-demo",
            "enabled": True,
            "available": True,
            "builtin": True,
            "mappingCount": 1,
        })
    for entry in cfg.get("resolverManifests", []):
        if not isinstance(entry, dict):
            continue
        url = _safe_resolver_url(entry.get("resolverUrl"))
        if not url:
            continue
        name = str(entry.get("name") or urlparse(url).hostname or "Resolver")
        enabled = entry.get("enabled") is not False
        base = {
            "name": name,
            "resolverUrl": url,
            "enabled": enabled,
            "builtin": False,
            "host": urlparse(url).hostname or "",
        }
        if not enabled:
            resolvers.append({**base, "available": False, "mappingCount": 0})
            continue
        try:
            resolver = _get_json(url, ttl=3600, timeout=2.0)
            mappings = _validated_mappings(resolver.get("mappings"))
            resolvers.append({
                **base,
                "name": str(resolver.get("name") or name),
                "available": True,
                "mappingCount": len(mappings),
            })
        except (RuntimeError, ValueError) as exc:
            resolvers.append({**base, "available": False, "mappingCount": 0, "error": str(exc)})
    return {
        "addons": addons,
        "resolvers": resolvers,
        "configPath": str(CONFIG_PATH),
        "streamingServer": cfg.get("streamingServer"),
    }
