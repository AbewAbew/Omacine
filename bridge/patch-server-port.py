#!/usr/bin/env python3
"""Repoint a Stremio streaming-server bundle from :11470 onto OmaCine's :11480.

Stremio Enhanced ships this same webpack bundle and binds 11470. The listening
port is a hard-coded literal inside the bundle with no environment override, so
patching our own vendored copy is the only way for both applications to run at
once. Every literal below is an engine self-reference. The HTTPS endpoint on
:12470 is deliberately not patched - the wrapper disables that server outright
with NO_HTTPS_SERVER, because OmaCine only ever talks to http://127.0.0.1.

Exits non-zero without writing if the bundle does not have the expected shape,
so an upstream change leaves the previous working copy in place.
"""
import pathlib
import sys

SUBS = [
    ("port = 11470", "port = 11480", 2),
    ("port++ < 11474", "port++ < 11484", 1),
    ("127.0.0.1:11470/subtitles.srt", "127.0.0.1:11480/subtitles.srt", 1),
    ('engineUrl = "http://127.0.0.1:11470"', 'engineUrl = "http://127.0.0.1:11480"', 1),
    ("serverPort || 11470", "serverPort || 11480", 1),
    ("localhost):11470$", "localhost):11480$", 1),
]


def patch(path: str) -> int:
    target = pathlib.Path(path)
    body = target.read_text(encoding="utf-8", errors="surrogateescape")
    if "port = 11480" in body and "port = 11470" not in body:
        return 0
    for old, new, expected in SUBS:
        found = body.count(old)
        if found != expected:
            print(
                f"patch-server-port: expected {expected} of {old!r}, found {found}",
                file=sys.stderr,
            )
            return 1
        body = body.replace(old, new)
    target.write_text(body, encoding="utf-8", errors="surrogateescape")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: patch-server-port.py <server.js>", file=sys.stderr)
        sys.exit(2)
    sys.exit(patch(sys.argv[1]))
