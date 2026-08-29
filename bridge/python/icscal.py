"""Episode calendar from an iCalendar feed (pogdesign's Calendar For TV et al).

TMDB knows when episodes air, but not which shows *you* follow beyond the
OmaCine library. A subscribed ICS feed is a list the user curates elsewhere,
so it is treated as a first-class source rather than a substitute.

Two things about these feeds shape the parsing:

  * there is no TMDB or IMDb id anywhere - only a show name, a UID shaped like
    SHOWNAME_season_episode, and a summary. Ids have to be resolved by name,
    which is cached because it is the expensive part.
  * DTSTART values are floating times in the feed's own zone (GMT for
    pogdesign), so they must be converted before the *date* can be trusted:
    21:00 GMT is the next day in EAT.
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

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "omamovie"
CONFIG_PATH = CONFIG_DIR / "calendar.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "omamovie" / "calendar"
FEED_CACHE = CACHE_DIR / "feed.ics"
MAP_PATH = CACHE_DIR / "name-map.json"
FEED_TTL = 6 * 60 * 60          # the feed changes at most daily
MAX_FEED_BYTES = 8 * 1024 * 1024


def _config() -> dict:
    try:
        value = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def status() -> dict:
    url = str(_config().get("icsUrl") or "")
    return {"configured": bool(url), "host": re.sub(r"^https?://([^/]+).*$", r"\1", url) if url else ""}


def configure(url: object) -> dict:
    """Store the feed URL. It is a bearer token, so it never leaves this file."""
    text = str(url or "").strip()
    if not text:
        try:
            CONFIG_PATH.unlink()
        except OSError:
            pass
        return status()
    if not re.match(r"^https://[^\s]{10,600}$", text):
        raise ValueError("paste the https:// link to your calendar feed")
    # Fetch once before saving, so a bad link fails now rather than silently later.
    raw = net.get_bytes(text, {"Accept": "text/calendar"}, 20.0, MAX_FEED_BYTES)
    if b"BEGIN:VCALENDAR" not in raw[:2048]:
        raise ValueError("that link did not return an iCalendar feed")
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    handle = os.open(CONFIG_PATH.with_suffix(".new"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump({"icsUrl": text}, stream, separators=(",", ":"))
    os.replace(CONFIG_PATH.with_suffix(".new"), CONFIG_PATH)
    _store_feed(raw)
    return status()


def _store_feed(raw: bytes) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        FEED_CACHE.write_bytes(raw)
    except OSError:
        pass


def _feed_text(refresh: bool = False) -> str:
    url = str(_config().get("icsUrl") or "")
    if not url:
        return ""
    if not refresh:
        try:
            if time.time() - FEED_CACHE.stat().st_mtime < FEED_TTL:
                return FEED_CACHE.read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
    try:
        raw = net.get_bytes(url, {"Accept": "text/calendar"}, 20.0, MAX_FEED_BYTES)
    except (RuntimeError, OSError):
        try:
            return FEED_CACHE.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""
    _store_feed(raw)
    return raw.decode("utf-8", errors="replace")


def _unescape(value: str) -> str:
    return (value.replace("\\n", " ").replace("\\,", ",")
                 .replace("\;", ";").replace("&#039;", "'").strip())


def _local_date(stamp: str, tz_utc: bool) -> str:
    """ICS timestamp -> local calendar date."""
    text = stamp.strip()
    try:
        if text.endswith("Z"):
            when = datetime.strptime(text[:15], "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc)
        elif "T" in text:
            when = datetime.strptime(text[:15], "%Y%m%dT%H%M%S")
            when = when.replace(tzinfo=timezone.utc) if tz_utc else when.astimezone()
        else:
            return f"{text[0:4]}-{text[4:6]}-{text[6:8]}"
    except ValueError:
        return ""
    return when.astimezone().date().isoformat()


def events(refresh: bool = False) -> list[dict]:
    """Parse the feed into dated episode entries."""
    text = _feed_text(refresh)
    if not text:
        return []
    # RFC 5545 folds long lines with a leading space or tab.
    text = re.sub(r"\r?\n[ \t]", "", text)
    # pogdesign declares GMT; treat a floating time as UTC when it does.
    tz_utc = "X-WR-TIMEZONE:GMT" in text or "X-WR-TIMEZONE:UTC" in text

    out = []
    for block in text.split("BEGIN:VEVENT")[1:]:
        fields = {}
        for line in block.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key.split(";")[0].strip().upper()] = value.strip()
        start = fields.get("DTSTART", "")
        summary = _unescape(fields.get("SUMMARY", ""))
        if not start or not summary:
            continue
        date = _local_date(start, tz_utc)
        if not date:
            continue
        # "Show Name S01E02 - Episode Title"
        match = re.match(r"^(.*?)\s+[Ss](\d{1,3})[Ee](\d{1,4})\s*-?\s*(.*)$", summary)
        if match:
            show, season, episode, ep_title = (match.group(1).strip(), int(match.group(2)),
                                               int(match.group(3)), match.group(4).strip())
        else:
            show, season, episode, ep_title = summary, 0, 0, ""
        if ep_title.lower().startswith("season ") or ep_title.lower().startswith("series "):
            ep_title = ""      # "Season 1, Episode 1" carries nothing the code does not
        out.append({
            "date": date,
            "show": show[:200],
            "season": season,
            "episode": episode,
            "episodeTitle": ep_title[:200],
            "overview": _unescape(fields.get("DESCRIPTION", ""))[:600],
            "uid": fields.get("UID", "")[:120],
            "isPremiere": season == 1 and episode == 1,
            "isSeasonPremiere": season > 1 and episode == 1,
            # The feed carries no finale marker, so nothing is claimed.
            "isFinale": False,
            "source": "feed",
        })
    return out


def _name_map() -> dict:
    try:
        value = json.loads(MAP_PATH.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def save_name_map(mapping: dict) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = MAP_PATH.with_suffix(".new")
        tmp.write_text(json.dumps(mapping, separators=(",", ":")), encoding="utf-8")
        os.replace(tmp, MAP_PATH)
    except OSError:
        pass


def name_map() -> dict:
    return _name_map()
