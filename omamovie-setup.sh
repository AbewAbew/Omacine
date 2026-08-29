#!/usr/bin/env bash
# OmaCine setup — no compile, pure Python bridge
# Scope: writes only to $RUNTIME ($XDG_CACHE_HOME/omamovie) and $VERSION_FILE.
# Never writes inside the plugin dir (avoids omarchy inotify reload blink).
# Installs bridge to $RUNTIME, verifies it. Prerequisites manual per README.
export PYTHONDONTWRITEBYTECODE=1
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${XDG_CACHE_HOME:-$HOME/.cache}/omamovie"
BRIDGE_SRC_DIR="$DIR/bridge/python"
BRIDGE_DST_DIR="$RUNTIME/bridge/python"
BRIDGE_DST="$RUNTIME/omamovie-bridge"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omamovie"
SERVICE_SETTINGS_DIR="$CONFIG_DIR/stremio-service"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USER_UNIT="$USER_UNIT_DIR/omamovie-stremio-server.service"
VERSION="$(jq -er '.version' "$DIR/manifest.json" 2>/dev/null || echo "1.0.0")"
VERSION_FILE="$RUNTIME/version"
REVISION_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/omamovie/plugin-revision"
PYTHON_BIN="${OMAMOVIE_PYTHON:-python3}"

say()  { printf '\033[1;36m[OmaCine]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[OmaCine]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[OmaCine]\033[0m %s\n' "$*"; exit 1; }

command -v mpv >/dev/null 2>&1 || command -v vlc >/dev/null 2>&1 ||
  warn "no media player found - mpv is required for playback (see README)"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "python3 not found (tried $PYTHON_BIN) - see README"
PY_VER="$("$PYTHON_BIN" --version 2>&1 | head -n1 || echo "python unknown")"
say "using $PY_VER at $(command -v "$PYTHON_BIN")"

mkdir -p "$RUNTIME" "$RUNTIME/mpv-cache"

record_plugin_revision() {
  local revision
  revision="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || printf '%s' "$VERSION")"
  mkdir -p "$(dirname "$REVISION_FILE")"
  if [[ ! -f "$REVISION_FILE" || $(<"$REVISION_FILE") != "$revision" ]]; then
    printf '%s\n' "$revision" >"$REVISION_FILE.new"
    mv -f "$REVISION_FILE.new" "$REVISION_FILE"
  fi
}

LOCK_FILE="$RUNTIME/setup.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -w 180 9 || { warn "another install is already running"; exit 0; }

# Source hash stamp — bridge code fixes propagate even when version unchanged
SRC_STAMP="$RUNTIME/.src_stamp"
src_hash() {
  (cd "$DIR" && {
    find bridge config systemd mpv -type f -exec sha256sum {} +
    find components -type f -exec sha256sum {} +
    sha256sum Panel.qml BarWidget.qml manifest.json omamovie-setup.sh
  } | sha256sum | cut -d' ' -f1)
}
CUR_HASH="$(src_hash 2>/dev/null || echo missing)"

# If already installed, version matches AND source unchanged, exit early (no ping check — avoids reinstall loop on offline fresh install)
if [[ -x "$BRIDGE_DST" && -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" == "$VERSION" \
      && -f "$SRC_STAMP" && "$(<"$SRC_STAMP")" == "$CUR_HASH" ]]; then
  say "bridge $VERSION already installed"
  record_plugin_revision
  exit 0
fi

if [[ "${OMAMOVIE_BUILD_FROM_SOURCE:-0}" == "1" || "${OMAMOVIE_ALLOW_PREBUILT:-0}" == "1" ]]; then
  say "OMAMOVIE_BUILD_FROM_SOURCE/ALLOW_PREBUILT deprecated with python backend - ignoring"
fi

[[ -d "$BRIDGE_SRC_DIR" ]] || fail "python bridge not found at $BRIDGE_SRC_DIR"

# User-owned addon configuration is created once and never overwritten by an
# update. The service has a separate settings file so Stremio Enhanced and
# OmaCine instances cannot truncate each other's settings during simultaneous startup.
mkdir -p "$CONFIG_DIR" "$SERVICE_SETTINGS_DIR" "$USER_UNIT_DIR"
if [[ ! -f "$CONFIG_DIR/addons.json" ]]; then
  cp -f "$DIR/config/addons.json" "$CONFIG_DIR/addons.json"
  say "created $CONFIG_DIR/addons.json"
fi
chmod 600 "$CONFIG_DIR/addons.json"
# Restarting the cache service drops every torrent's peers and its in-progress
# pieces. Remember what the service actually reads, so a plain bridge reinstall
# does not throw away a warm cache.
# Compare values, not bytes: the streaming server rewrites this file with its
# own indentation on shutdown while jq uses another, so a byte comparison always
# looks changed and would restart on every single run.
service_state() {
  { jq -S -c . "$SERVICE_SETTINGS_DIR/server-settings.json" 2>/dev/null || echo missing
    cat "$USER_UNIT" 2>/dev/null; } | sha256sum
}
SERVICE_STATE_BEFORE="$(service_state)"

if [[ ! -f "$SERVICE_SETTINGS_DIR/server-settings.json" ]]; then
  jq --arg cache_root "$HOME/.stremio-server" \
    '.appPath = $cache_root | .cacheRoot = $cache_root' \
    "$DIR/config/server-settings.json" >"$SERVICE_SETTINGS_DIR/server-settings.json.new"
  mv -f "$SERVICE_SETTINGS_DIR/server-settings.json.new" "$SERVICE_SETTINGS_DIR/server-settings.json"
else
  # Migrate only untouched legacy defaults; preserve explicit user tuning.
  if jq '
    if .cacheSize == 2147483648 then .cacheSize = 10737418240 else . end |
    if .btMaxConnections == 55 then .btMaxConnections = 80 else . end |
    if .btHandshakeTimeout == 20000 then .btHandshakeTimeout = 8000 else . end |
    if .btRequestTimeout == 4000 then .btRequestTimeout = 2500 else . end |
    if .btDownloadSpeedSoftLimit == 2621440 then .btDownloadSpeedSoftLimit = 20971520 else . end |
    if .btDownloadSpeedHardLimit == 3670016 then .btDownloadSpeedHardLimit = 52428800 else . end |
    if .btMinPeersForStable == 5 then .btMinPeersForStable = 3 else . end
  ' "$SERVICE_SETTINGS_DIR/server-settings.json" >"$SERVICE_SETTINGS_DIR/server-settings.json.new"; then
    mv -f "$SERVICE_SETTINGS_DIR/server-settings.json.new" "$SERVICE_SETTINGS_DIR/server-settings.json"
  else
    warn "could not migrate streaming performance settings; preserving the existing file"
  fi
fi

chmod +x "$DIR/bridge/stremio-server-wrapper.sh"
if [[ -f "$HOME/.config/stremio-enhanced/streamingserver/server.js" ]]; then
  cp -f "$DIR/systemd/omamovie-stremio-server.service" "$USER_UNIT.new"
  mv -f "$USER_UNIT.new" "$USER_UNIT"
  systemctl --user daemon-reload || warn "could not reload user services"
  systemctl --user enable --now omamovie-stremio-server.service || warn "could not start streaming cache service"
  if [[ "$(service_state)" != "$SERVICE_STATE_BEFORE" ]]; then
    say "streaming settings changed - restarting cache service"
    systemctl --user restart omamovie-stremio-server.service || warn "could not reload streaming performance settings"
  fi
else
  warn "Stremio Enhanced service bundle not found; direct addon URLs still work"
fi

if ! "$PYTHON_BIN" -c "import requests" 2>/dev/null; then
  warn "python 'requests' not found - MovieBox will use urllib, but 4KHDHub will be unavailable"
fi

# Copy bridge python dir to cache (so Panel bridge at $RUNTIME works without plugin-dir writes)
say "installing bridge $VERSION → $BRIDGE_DST"
mkdir -p "$BRIDGE_DST_DIR"
# copy all python files; use cp -r to preserve structure, then ensure __main__ is executable via shim
cp -f "$BRIDGE_SRC_DIR"/*.py "$BRIDGE_DST_DIR"/ 2>/dev/null || cp -r "$BRIDGE_SRC_DIR"/* "$BRIDGE_DST_DIR"/
# Drop modules the plugin no longer ships. Copying alone would leave a removed
# provider importable, so an update could keep serving code that is gone.
for installed in "$BRIDGE_DST_DIR"/*.py; do
  [[ -e "$installed" ]] || continue
  if [[ ! -f "$BRIDGE_SRC_DIR/$(basename "$installed")" ]]; then
    rm -f "$installed"
    say "removed stale module $(basename "$installed")"
  fi
done
rm -rf "$BRIDGE_DST_DIR/__pycache__"
# also copy requirements if present (not used at runtime, kept for reference)
[[ -f "$BRIDGE_SRC_DIR/requirements.txt" ]] && cp -f "$BRIDGE_SRC_DIR/requirements.txt" "$BRIDGE_DST_DIR"/ 2>/dev/null || true

# Create shim at $RUNTIME/omamovie-bridge
cat >"$BRIDGE_DST.new" <<EOF2
#!/usr/bin/env bash
# Auto-generated by omamovie-setup.sh - do not edit
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
RUNTIME="\${XDG_CACHE_HOME:-\$HOME/.cache}/omamovie"
PLUGIN_DIR="$DIR"
if [[ -f "\$RUNTIME/bridge/python/__main__.py" ]]; then
  exec $PYTHON_BIN "\$RUNTIME/bridge/python/__main__.py" "\$@"
else
  exec $PYTHON_BIN -B "\$PLUGIN_DIR/bridge/python/__main__.py" "\$@"
fi
EOF2
chmod +x "$BRIDGE_DST.new"
mv -f "$BRIDGE_DST.new" "$BRIDGE_DST"

# Verify bridge (non-fatal on fresh install without network — still write version to avoid restart loop)
say "verifying bridge ..."
if ! "$BRIDGE_DST" '{"cmd":"ping"}' 2>/dev/null | grep -q '"ok": *true'; then
  warn "bridge ping failed — check python deps and bridge script; continuing anyway"
  "$BRIDGE_DST" '{"cmd":"ping"}' || true
else
  say "bridge ping OK"
fi

# Quick functional test (search) — best-effort, no fail
say "testing search ..."
if "$BRIDGE_DST" '{"cmd":"search","q":"one piece"}' 2>/dev/null | grep -q '"ok": *true'; then
  say "search OK"
else
  warn "search test failed — network may be blocked (expected on offline fresh install)"
fi

mkdir -p "$(dirname "$VERSION_FILE")"
printf '%s\n' "$VERSION" > "$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"
printf '%s\n' "$CUR_HASH" > "$SRC_STAMP.new"
mv -f "$SRC_STAMP.new" "$SRC_STAMP"

say "installed $BRIDGE_DST ($VERSION) — ready"
record_plugin_revision
# Fresh install finished: ask the host to restart the Omarchy shell exactly ONCE.
# BarWidget parses this marker and runs omarchy-restart-shell; the
# "already installed" early-exit above never prints it, so no restart loop.
echo "OMAMOVIE_RESTART_SHELL=1"
exit 0
