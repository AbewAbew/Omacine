#!/usr/bin/env bash
# OmaCine's own streaming cache. It shares nothing with Stremio Enhanced: its
# own copy of the server bundle, its own listening port, its own settings file
# and its own cache root. Either application can be installed, upgraded or
# removed without disturbing the other, and both can run at the same time.
set -euo pipefail

APP_PATH="$HOME/.local/share/omamovie/server"
SERVER_JS="$APP_PATH/streamingserver/server.js"
SETTINGS_DIR="$HOME/.config/omamovie/stremio-service"

[[ -f "$SERVER_JS" ]] || {
  echo "OmaCine: no streaming server at $SERVER_JS" >&2
  echo "OmaCine: run omamovie-setup.sh to install one." >&2
  exit 1
}

mkdir -p "$SETTINGS_DIR" "$APP_PATH"
# The bundle hard-codes :12470 for its HTTPS endpoint with no override, and
# that is the one port left that would still collide with Stremio Enhanced.
# OmaCine only ever talks to http://127.0.0.1, so that server is not started.
export APP_PATH SETTINGS_PATH="$SETTINGS_DIR" NO_HTTPS_SERVER=1
exec /usr/bin/node "$SERVER_JS"
