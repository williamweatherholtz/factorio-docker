#!/bin/bash
set -euo pipefail
TEST_NAME="test-compose"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"

# --- with .env present: full config resolves ---
[[ -f "$REPO/.env" ]] || cp "$REPO/.env.example" "$REPO/.env"
cfg="$(cd "$REPO" && docker compose config 2>/dev/null)" || fail "docker compose config failed"
assert_contains "$cfg" "ghcr.io/williamweatherholtz/factorio:2.0.77" "image pinned to explicit version"
assert_contains "$cfg" "/factorio/config" "config bind mount present"
assert_contains "$cfg" "/factorio/saves" "saves bind mount present"
assert_contains "$cfg" "/factorio/mods" "mods bind mount present"
assert_contains "$cfg" "stop_grace_period" "stop_grace_period set"
assert_contains "$cfg" "rcon /players" "RCON healthcheck configured"
assert_contains "$cfg" "max-size" "log rotation configured"

# The build-from-source compose must be gone (single stack only).
[[ ! -f "$REPO/docker/docker-compose.yml" ]] || fail "docker/docker-compose.yml should be removed (single compose)"

# --- without .env: must still resolve (env_file required:false) ---
env_backup=""
if [[ -f "$REPO/.env" ]]; then env_backup="$(mktemp)"; mv "$REPO/.env" "$env_backup"; fi
restore() { [[ -n "$env_backup" ]] && mv "$env_backup" "$REPO/.env" || true; }
trap restore EXIT
( cd "$REPO" && docker compose config >/dev/null 2>&1 ) || fail "compose must resolve without .env (required:false)"

pass
