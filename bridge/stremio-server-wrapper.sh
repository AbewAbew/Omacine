#!/usr/bin/env bash
# Keep the compatible streaming cache available to OmaCine without racing a
# server that Stremio Enhanced may already have started.
set -euo pipefail

SERVER_JS="$HOME/.config/stremio-enhanced/streamingserver/server.js"
SETTINGS_DIR="$HOME/.config/omamovie/stremio-service"
APP_PATH="$HOME/.stremio-server"

[[ -f "$SERVER_JS" ]] || {
  echo "OmaCine: streaming server is not installed: $SERVER_JS" >&2
  exit 1
}

# If Stremio Enhanced owns the port, remain healthy and take over only after
# it exits. Its on-disk cache is shared, so playback remains resumable.
while /usr/bin/curl --silent --fail --max-time 2 \
  http://127.0.0.1:11470/local-addon/manifest.json >/dev/null 2>&1; do
  sleep 10
done

mkdir -p "$SETTINGS_DIR" "$APP_PATH"
export APP_PATH SETTINGS_PATH="$SETTINGS_DIR"
exec /usr/bin/node "$SERVER_JS"
