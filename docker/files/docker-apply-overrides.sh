#!/bin/bash
# Render effective server-settings.json from a base file plus env-var overrides.
# The base file is never modified. Prints to stdout the path that should be
# passed to factorio's --server-settings (a rendered temp file if any override
# was applied, otherwise the base path). Diagnostics go to stderr.
#
# An override is applied only when its env var is set AND non-empty, so blank
# placeholders are ignored rather than fatal. Bool/int/enum values are validated
# before they reach jq to avoid silently writing a wrong-typed config.
set -euo pipefail

BASE="${1:-${CONFIG:-/factorio/config}/server-settings.json}"
OUT="${2:-}"
[[ -n "$OUT" ]] || OUT="$(mktemp)"   # unpredictable path avoids /tmp symlink games
DEBUG="${DEBUG:-false}"

log() { [[ "$DEBUG" == "true" ]] && echo "docker-apply-overrides: $1" >&2 || true; }
die() { echo "docker-apply-overrides ERROR: $1" >&2; exit 2; }

changed=0
cp "$BASE" "$OUT"

# apply <kind> <ENV_VAR_NAME> <jq-path>
#   kind: str | int | bool | enum_cmd
# Skips when the env var is unset or empty. Validates the value per kind.
apply() {
  local kind="$1" name="$2" path="$3"
  [[ -n "${!name:+set}" ]] || return 0        # unset or empty -> leave file value
  local value="${!name}" flag="--arg" tmp
  case "$kind" in
    int)      [[ "$value" =~ ^[0-9]+$ ]]            || die "$name must be a non-negative integer (got '$value')"; flag="--argjson" ;;
    bool)     [[ "$value" =~ ^(true|false)$ ]]      || die "$name must be 'true' or 'false' (got '$value')";       flag="--argjson" ;;
    enum_cmd) [[ "$value" =~ ^(true|false|admins-only)$ ]] || die "$name must be 'true', 'false', or 'admins-only' (got '$value')" ;;
    str)      : ;;
    *)        die "unknown kind '$kind'" ;;
  esac
  tmp="$(jq "$flag" v "$value" "$path = \$v" "$OUT")"
  printf '%s\n' "$tmp" > "$OUT"
  changed=1
  log "set $path = $value"
}

apply str      SERVER_NAME                .name
apply str      SERVER_DESCRIPTION         .description
apply int      MAX_PLAYERS                .max_players
apply bool     SERVER_VISIBILITY_PUBLIC   .visibility.public
apply bool     SERVER_VISIBILITY_LAN      .visibility.lan
apply bool     REQUIRE_USER_VERIFICATION  .require_user_verification
apply bool     AUTO_PAUSE                 .auto_pause
apply int      AFK_AUTOKICK_INTERVAL      .afk_autokick_interval
apply enum_cmd ALLOW_COMMANDS             .allow_commands
apply int      AUTOSAVE_INTERVAL          .autosave_interval
# Account linking: username + token from factorio.com/profile. Writing them into
# the (rendered) server-settings lets the server register in the public browser.
# The committed base file is never touched, so the token isn't persisted to disk.
apply str      USERNAME                   .username
apply str      TOKEN                      .token

if [[ "$changed" -eq 1 ]]; then
  chmod 0644 "$OUT"
  printf '%s\n' "$OUT"
else
  rm -f "$OUT"
  printf '%s\n' "$BASE"
fi
