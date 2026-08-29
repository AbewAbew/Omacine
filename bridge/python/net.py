"""Shared HTTP transport with connection reuse.

Every request used to open a fresh TCP + TLS connection. Measured on this
machine that setup costs 272-754 ms per host, which dominated multi-endpoint
fetches like the TMDB home feed or a fan-out across catalog add-ons.

A pooled session keeps sockets hot between calls. That only pays off in a
process that outlives a single command, so this matters in daemon mode; the
one-shot path still works, it just cannot benefit.

`requests` is preferred when installed (it is already required by the 4KHDHub
provider). Without it we fall back to urllib, which sends `Connection: close`
and therefore reconnects every time — correct, just slower.
"""
import threading
from urllib.request import Request, urlopen

_LOCK = threading.Lock()
_SESSION = None
_SESSION_TRIED = False

DEFAULT_POOL_SIZE = 16


def _session():
    """Lazily build one pooled session for the life of the process."""
    global _SESSION, _SESSION_TRIED
    if _SESSION is not None or _SESSION_TRIED:
        return _SESSION
    with _LOCK:
        if _SESSION is not None or _SESSION_TRIED:
            return _SESSION
        _SESSION_TRIED = True
        try:
            import requests
            from requests.adapters import HTTPAdapter
        except ImportError:
            return None
        session = requests.Session()
        adapter = HTTPAdapter(
            pool_connections=DEFAULT_POOL_SIZE,
            pool_maxsize=DEFAULT_POOL_SIZE,
            max_retries=0,
        )
        session.mount("https://", adapter)
        session.mount("http://", adapter)
        _SESSION = session
        return _SESSION


def get_bytes(url: str, headers: dict, timeout: float, limit: int) -> bytes:
    """Fetch a URL, reusing a pooled connection when possible.

    Raises RuntimeError on a non-200 status or a body larger than `limit`.
    Transport errors propagate unchanged so existing handlers still match on
    URLError/OSError/HTTPError.
    """
    session = _session()
    if session is not None:
        response = session.get(url, headers=headers, timeout=timeout, stream=True)
        try:
            if response.status_code != 200:
                raise RuntimeError(f"HTTP {response.status_code}")
            raw = response.raw.read(limit + 1, decode_content=True)
        finally:
            response.close()
        if len(raw) > limit:
            raise RuntimeError("response body is too large")
        return raw

    request = Request(url, headers=headers)
    with urlopen(request, timeout=timeout) as response:
        if int(getattr(response, "status", 200)) != 200:
            raise RuntimeError(f"HTTP {response.status}")
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise RuntimeError("response body is too large")
    return raw


def fetch_image(url: str, timeout: float = 8.0, limit: int = 16 * 1024 * 1024) -> bytes | None:
    """Download artwork, reusing the pooled connection.

    Poster fetching used to live on the MovieBox client; it belongs with the
    shared transport now that catalog add-ons are the only provider. Returns
    None on any failure so callers can simply skip that image.
    """
    try:
        return get_bytes(url, {"User-Agent": "OmaCine/2.0 ArtworkClient"}, timeout, limit)
    except Exception:
        return None
