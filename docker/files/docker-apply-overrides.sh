#!/bin/bash
# Render effective server-settings.json from a base file plus env-var overrides.
# The base file is never modified. Prints to stdout the path that should be
# passed to factorio's --server-settings (the rendered temp file if any override
# was applied, otherwise the base path). Diagnostics go to stderr.
set -euo pipefail

BASE="${1:-${CONFIG:-/factorio/config}/server-settings.json}"
OUT="${2:-/tmp/server-settings.rendered.json}"
DEBUG="${DEBUG:-false}"

log() { [[ "$DEBUG" == "true" ]] && echo "docker-apply-overrides: $1" >&2 || true; }

changed=0
cp "$BASE" "$OUT"

# $1 = jq path, $2 = value, $3 = jq value-flag (--arg for strings, --argjson for num/bool)
patch() {
  local path="$1" value="$2" flag="$3" tmp
  tmp="$(jq "$flag" v "$value" "$path = \$v" "$OUT")"
  printf '%s\n' "$tmp" > "$OUT"
  changed=1
  log "set $path = $value"
}

[[ -n "${SERVER_NAME+set}" ]]                 && patch '.name'                       "$SERVER_NAME"                 --arg
[[ -n "${SERVER_DESCRIPTION+set}" ]]          && patch '.description'                "$SERVER_DESCRIPTION"          --arg
[[ -n "${MAX_PLAYERS+set}" ]]                 && patch '.max_players'                "$MAX_PLAYERS"                 --argjson
[[ -n "${SERVER_VISIBILITY_PUBLIC+set}" ]]    && patch '.visibility.public'          "$SERVER_VISIBILITY_PUBLIC"    --argjson
[[ -n "${SERVER_VISIBILITY_LAN+set}" ]]       && patch '.visibility.lan'             "$SERVER_VISIBILITY_LAN"       --argjson
[[ -n "${REQUIRE_USER_VERIFICATION+set}" ]]   && patch '.require_user_verification'  "$REQUIRE_USER_VERIFICATION"   --argjson
[[ -n "${AUTO_PAUSE+set}" ]]                  && patch '.auto_pause'                 "$AUTO_PAUSE"                  --argjson
[[ -n "${AFK_AUTOKICK_INTERVAL+set}" ]]       && patch '.afk_autokick_interval'      "$AFK_AUTOKICK_INTERVAL"       --argjson
[[ -n "${ALLOW_COMMANDS+set}" ]]              && patch '.allow_commands'             "$ALLOW_COMMANDS"              --arg
[[ -n "${AUTOSAVE_INTERVAL+set}" ]]           && patch '.autosave_interval'          "$AUTOSAVE_INTERVAL"           --argjson

if [[ "$changed" -eq 1 ]]; then
  chmod 0644 "$OUT"
  printf '%s\n' "$OUT"
else
  rm -f "$OUT"
  printf '%s\n' "$BASE"
fi
