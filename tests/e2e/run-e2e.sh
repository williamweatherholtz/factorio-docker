#!/bin/bash
# End-to-end tests: boot the REAL server image (with a shim in place of the
# factorio binary) once per ENV endpoint and assert the entrypoint's observable
# effect — the effective server-settings.json, the launch flags, the runtime
# UID/GID, and the DLC mod-list. Requires Docker + jq on the host.
set -euo pipefail
# NOTE: do not export MSYS_NO_PATHCONV globally — the native Windows jq/docker
# build-context args need normal path conversion. Disable it only on `docker run`
# (below), where the -e values are container-internal paths (/factorio, /tmp).

TEST_NAME="e2e"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/lib.sh"

BASE="factorio-e2e-base:ci"
E2E="factorio-e2e:ci"
VERSION="2.0.77"
SHA="$(jq -r --arg v "$VERSION" '.[$v].sha256' "$REPO/buildinfo.json" | tr -d '\r')"

# --- build images -----------------------------------------------------------
if ! docker image inspect "$BASE" >/dev/null 2>&1; then
  echo "building base image $BASE (one-time)..."
  docker buildx build "$REPO/docker" \
    --platform linux/amd64 \
    --build-arg "VERSION=$VERSION" --build-arg "SHA256=$SHA" \
    -t "$BASE" --load >/dev/null
fi
echo "building e2e shim image $E2E..."
docker buildx build "$REPO/tests/e2e" \
  -f "$REPO/tests/e2e/Dockerfile.e2e" \
  --platform linux/amd64 \
  --build-arg "BASE=$BASE" \
  -t "$E2E" --load >/dev/null

# --- helpers ----------------------------------------------------------------
run() { MSYS_NO_PATHCONV=1 docker run --rm "$@" "$E2E" 2>&1; }   # extra args = -e KEY=VAL ...
settings_json() { printf '%s\n' "$1" | sed -n '/EFFECTIVE_SERVER_SETTINGS_BEGIN/,/EFFECTIVE_SERVER_SETTINGS_END/p' | sed '1d;$d'; }
mod_list_json() { printf '%s\n' "$1" | sed -n '/MOD_LIST_BEGIN/,/MOD_LIST_END/p' | sed '1d;$d'; }
field() { printf '%s\n' "$1" | sed -n "s/^$2: //p" | tr -d '\r'; }
jqr() { jq -r "$@" | tr -d '\r'; }

# =====================================================================
# server-settings overlay endpoints
# =====================================================================

# No override -> the base file is used, not a rendered temp.
out="$(run)"
assert_eq "/factorio/config/server-settings.json" "$(field "$out" 'EFFECTIVE_SERVER_SETTINGS_PATH')" "no-override uses base file"

# SERVER_NAME
out="$(run -e SERVER_NAME='E2E Name')"
rp="$(field "$out" 'EFFECTIVE_SERVER_SETTINGS_PATH')"
[[ "$rp" != "/factorio/config/server-settings.json" && -n "$rp" ]] || fail "override must use a rendered temp path, not the base file (got '$rp')"
assert_eq "E2E Name" "$(settings_json "$out" | jqr .name)" "SERVER_NAME endpoint"

# SERVER_DESCRIPTION
out="$(run -e SERVER_DESCRIPTION='E2E desc')"
assert_eq "E2E desc" "$(settings_json "$out" | jqr .description)" "SERVER_DESCRIPTION endpoint"

# MAX_PLAYERS (number)
out="$(run -e MAX_PLAYERS=99)"
assert_eq "99" "$(settings_json "$out" | jqr .max_players)" "MAX_PLAYERS value"
assert_eq "number" "$(settings_json "$out" | jqr '.max_players|type')" "MAX_PLAYERS is number"

# SERVER_VISIBILITY_PUBLIC (bool)
out="$(run -e SERVER_VISIBILITY_PUBLIC=false)"
assert_eq "false" "$(settings_json "$out" | jqr .visibility.public)" "SERVER_VISIBILITY_PUBLIC value"
assert_eq "boolean" "$(settings_json "$out" | jqr '.visibility.public|type')" "SERVER_VISIBILITY_PUBLIC is bool"

# SERVER_VISIBILITY_LAN (bool)
out="$(run -e SERVER_VISIBILITY_LAN=false)"
assert_eq "false" "$(settings_json "$out" | jqr .visibility.lan)" "SERVER_VISIBILITY_LAN value"
assert_eq "boolean" "$(settings_json "$out" | jqr '.visibility.lan|type')" "SERVER_VISIBILITY_LAN is bool"

# REQUIRE_USER_VERIFICATION (bool)
out="$(run -e REQUIRE_USER_VERIFICATION=false)"
assert_eq "false" "$(settings_json "$out" | jqr .require_user_verification)" "REQUIRE_USER_VERIFICATION value"
assert_eq "boolean" "$(settings_json "$out" | jqr '.require_user_verification|type')" "REQUIRE_USER_VERIFICATION is bool"

# AUTO_PAUSE (bool)
out="$(run -e AUTO_PAUSE=false)"
assert_eq "false" "$(settings_json "$out" | jqr .auto_pause)" "AUTO_PAUSE value"
assert_eq "boolean" "$(settings_json "$out" | jqr '.auto_pause|type')" "AUTO_PAUSE is bool"

# AFK_AUTOKICK_INTERVAL (number)
out="$(run -e AFK_AUTOKICK_INTERVAL=300)"
assert_eq "300" "$(settings_json "$out" | jqr .afk_autokick_interval)" "AFK_AUTOKICK_INTERVAL value"
assert_eq "number" "$(settings_json "$out" | jqr '.afk_autokick_interval|type')" "AFK_AUTOKICK_INTERVAL is number"

# ALLOW_COMMANDS (string)
out="$(run -e ALLOW_COMMANDS=true)"
assert_eq "true" "$(settings_json "$out" | jqr .allow_commands)" "ALLOW_COMMANDS value"
assert_eq "string" "$(settings_json "$out" | jqr '.allow_commands|type')" "ALLOW_COMMANDS is string"

# AUTOSAVE_INTERVAL (number)
out="$(run -e AUTOSAVE_INTERVAL=15)"
assert_eq "15" "$(settings_json "$out" | jqr .autosave_interval)" "AUTOSAVE_INTERVAL value"
assert_eq "number" "$(settings_json "$out" | jqr '.autosave_interval|type')" "AUTOSAVE_INTERVAL is number"

# Combined: multiple overrides applied together; an unset key keeps its default.
out="$(run -e SERVER_NAME='Combo' -e MAX_PLAYERS=8 -e AUTO_PAUSE=false)"
js="$(settings_json "$out")"
assert_eq "Combo" "$(printf '%s' "$js" | jqr .name)" "combo: name"
assert_eq "8" "$(printf '%s' "$js" | jqr .max_players)" "combo: max_players"
assert_eq "false" "$(printf '%s' "$js" | jqr .auto_pause)" "combo: auto_pause"
assert_eq "true" "$(printf '%s' "$js" | jqr .visibility.public)" "combo: unset key keeps default"

# =====================================================================
# orchestration endpoints (assert launch flags)
# =====================================================================

# PORT
out="$(run -e PORT=34500)"
assert_contains "$(field "$out" 'FACTORIO_SHIM_ARGS')" "--port 34500" "PORT endpoint"

# RCON_PORT
out="$(run -e RCON_PORT=27100)"
assert_contains "$(field "$out" 'FACTORIO_SHIM_ARGS')" "--rcon-port 27100" "RCON_PORT endpoint"

# BIND
out="$(run -e BIND=0.0.0.0)"
assert_contains "$(field "$out" 'FACTORIO_SHIM_ARGS')" "--bind 0.0.0.0" "BIND endpoint"

# CONSOLE_LOG_LOCATION
out="$(run -e CONSOLE_LOG_LOCATION=/factorio/console.log)"
assert_contains "$(field "$out" 'FACTORIO_SHIM_ARGS')" "--console-log /factorio/console.log" "CONSOLE_LOG_LOCATION endpoint"

# LOAD_LATEST_SAVE default (true) -> load latest
out="$(run)"
assert_contains "$(field "$out" 'FACTORIO_SHIM_ARGS')" "--start-server-load-latest" "LOAD_LATEST_SAVE default loads latest"

# GENERATE_NEW_SAVE=true + SAVE_NAME + LOAD_LATEST_SAVE=false -> start named save.
# (SAVE_NAME is only honored when GENERATE_NEW_SAVE is explicitly true; otherwise
# the entrypoint's no-saves auto-path forces SAVE_NAME=_autosave1.)
out="$(run -e GENERATE_NEW_SAVE=true -e SAVE_NAME=mygame -e LOAD_LATEST_SAVE=false)"
args="$(field "$out" 'FACTORIO_SHIM_ARGS')"
assert_contains "$args" "--start-server mygame" "SAVE_NAME + GENERATE_NEW_SAVE + LOAD_LATEST_SAVE endpoints"
[[ "$args" != *"--start-server-load-latest"* ]] || fail "LOAD_LATEST_SAVE=false must not load latest"

# PUID / PGID -> the server process runs as that uid/gid
out="$(run -e PUID=1234 -e PGID=5678)"
assert_eq "1234" "$(field "$out" 'SHIM_RUNTIME_UID')" "PUID endpoint"
assert_eq "5678" "$(field "$out" 'SHIM_RUNTIME_GID')" "PGID endpoint"

# =====================================================================
# DLC endpoint (assert mod-list.json)
# =====================================================================

# DLC_SPACE_AGE=true -> space-age flipped enabled (mod pre-seeded disabled)
out="$(run -e MODS=/opt/e2e-mods -e DLC_SPACE_AGE=true)"
ml="$(mod_list_json "$out")"
assert_eq "true" "$(printf '%s' "$ml" | jqr '.mods[] | select(.name=="space-age") | .enabled')" "DLC true enables space-age"

# DLC_SPACE_AGE=false -> space-age disabled
out="$(run -e MODS=/opt/e2e-mods -e DLC_SPACE_AGE=false)"
ml="$(mod_list_json "$out")"
assert_eq "false" "$(printf '%s' "$ml" | jqr '.mods[] | select(.name=="space-age") | .enabled')" "DLC false disables space-age"

pass
