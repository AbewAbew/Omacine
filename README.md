# OmaCine for Omarchy

> **Based on [omamovie](https://github.com/yesheytenzin/omamovie) by [yesheytenzin](https://github.com/yesheytenzin)**, MIT licensed. This repository starts from a
> clean history; the original project holds the bulk of the early authorship and its
> copyright notice is retained in [`LICENSE`](LICENSE).
>
> **Also credits:** [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) by [mesamirh](https://github.com/mesamirh) — provider work that shaped the Python backend (`bridge/python/`).

OmaCine is a cinematic, theme-native Quickshell media hub for discovery, personal library tracking, technical stream comparison, episode continuity and `mpv` playback.

- **No Rust, no binary downloads** — pure Python
- **Cinematic discovery** — TMDB spotlight, trending rails, popular movies and television, new releases and rich episode metadata
- **Informed playback** — compare quality, active sources, file size, codec and provider before opening a stream
- **Instant** — dedicated stream process, episode pre-resolution, `≥2` chars for suggestions, `Esc` to close/clear
- **High-quality fallback** — 4KHDHub exposes available 2160p/1080p releases, audio labels and multiple mirrors
- **Catalog protocol** — compatible manifest, catalog, metadata and stream responses with direct and community-hosted media sources
- **Open ID resolvers** — add HTTPS resolver manifests to bridge catalog and stream ID namespaces without executable plugins
- **Persistent cache** — the bundled Stremio Enhanced service keeps up to 10 GB under `~/.stremio-server/stremio-cache`; mpv reads up to 512 MiB ahead while paused
- **Verified** — `py_compile` + crypto unit tests on `push/PR` only (no release artifacts)

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable
```

Creates shim `$XDG_CACHE_HOME/omamovie/omamovie-bridge` → `bridge/python/__main__.py` and verifies `{"cmd":"ping"}`. Click **** in the bar to browse.

## Update / Remove

```bash
omarchy plugin update tenzin.omamovie
omarchy plugin remove tenzin.omamovie
```

## Backend

Pure Python — no Rust, no compilation, no binary downloads. The panel and backend share a small CLI JSON contract.

| File | Role |
|---|---|
| `bridge/python/crypto.py` | HMAC-MD5 signing (`x-client-token`, `x-tr-signature`), sorted query, `x-client-info` |
| `bridge/python/client.py` | 7-host failover, `requests` or `urllib` fallback, token via `x-user` |
| `bridge/python/fourkhdhub.py` | 4KHDHub search/details/releases plus HubCloud/HubDrive mirror resolution |
| `bridge/python/cache.py` | `~/.cache/moviebox-tui/` — 24h search/details, 2h streams, 1h homepage |
| `bridge/python/stremio.py` | Safe Stremio Addon Protocol client, metadata cache, torrent URL construction |
| `bridge/python/__main__.py` | Provider-aware JSON bridge, including addon streams, 4KHDHub `resolve`, and MovieBox filtering/sorting |

Rust bridge (`moviebox-tui` crates) fully replaced; removed from repo.

## Panel

- `Esc` closes from any view; clears search field when focused
- Episodes auto-populate on `openDetails`; `E1` selected, dedicated `streamsProc` for instant load
- Suggestions gated at `≥2` chars (350ms debounce)
- Streams placeholder: `Loading streams for S1E1 …` / `No streams — tap again to retry` (retry `MouseArea`)
- Original audio is preferred automatically; available dubs remain explicitly selectable
- Use the **MovieBox** / **4KHD** / **Addons** buttons beside Search to choose a provider
- 4KHDHub playback tries its mirrors in order and forwards the required Referer/User-Agent to `mpv`

## Authorized addons and local cache

The default Sources configuration contains a public-domain catalog, a local-files source, and the Creative Commons film Sintel. OmaCine does not import another app's source list. Add only manifests for media you are authorized to access in:

```text
~/.config/omamovie/addons.json
```

You can manage this without editing JSON: open OmaCine, select **Sources**, paste the manifest URL into **Add manifest**, then press Enter or click the button. The source manager shows availability and resource types and lets you enable, disable, or remove each manifest.

Each entry uses this shape:

```json
{
  "name": "My authorized addon",
  "manifestUrl": "https://example.org/manifest.json",
  "enabled": true
}
```

## Open resolver manifests

Some catalog and stream addons describe the same authorized media with different IDs. A resolver manifest provides explicit, auditable aliases between those namespaces. In the **Addons** view, paste an HTTPS URL ending in `/resolver.json` into **Add resolver**. Resolver entries can be enabled, disabled, and removed beside addons.

OmaCine includes a working public-domain demonstration: searching for **Sintel** returns the catalog ID `omamovie:catalog:sintel`; the built-in resolver maps it to the Creative Commons stream ID `omamovie:free:sintel`. The resolver itself never supplies or selects a stream—it only returns another ID which enabled sources may understand.

A resolver is plain JSON and runs no code:

```json
{
  "schemaVersion": 1,
  "id": "org.example.my-authorized-library",
  "name": "My authorized library IDs",
  "mappings": [
    {
      "type": "movie",
      "from": "catalog:my-free-film",
      "to": "archive:my-free-film"
    },
    {
      "type": "series",
      "from": "catalog:my-free-series",
      "to": "archive:my-free-series"
    }
  ]
}
```

For a series, OmaCine resolves the base series ID and then appends `:season:episode` for the stream request. URLs must use HTTPS, except localhost HTTP for development. IDs are literal—wildcards and executable transforms are deliberately unsupported. The complete public-domain template is at `examples/public-domain-resolver/resolver.json`; host that directory on HTTPS when testing the Add resolver flow.

The setup enables the existing `omamovie-stremio-server.service` compatibility unit. Internal paths retain the old identifier so upgrades preserve library, settings and cached media. Check it with:

```bash
systemctl --user status omamovie-stremio-server.service
```

Downloaded media pieces survive pause, player exit, and reboot until the 10 GB cache needs space. mpv's separate pause/read-ahead files live under `~/.cache/omamovie/mpv-cache` and are temporary.

The 4KHDHub provider needs Python `requests` (`python -c 'import requests'`). MovieBox retains its standard-library fallback.

## License

MIT
