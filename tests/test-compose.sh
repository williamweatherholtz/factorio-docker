#!/bin/bash
set -euo pipefail
TEST_NAME="test-compose"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"

# No env_file — all config is inline in the environment: block, so `config`
# resolves with nothing extra on disk.
cfg="$(cd "$REPO" && docker compose config 2>/dev/null)" || fail "docker compose config failed"
assert_contains "$cfg" "ghcr.io/williamweatherholtz/factorio:2.0.77" "image pinned to explicit version"
assert_contains "$cfg" "/factorio/config" "config bind mount present"
assert_contains "$cfg" "/factorio/saves" "saves bind mount present"
assert_contains "$cfg" "/factorio/mods" "mods bind mount present"
assert_contains "$cfg" "stop_grace_period" "stop_grace_period set"
assert_contains "$cfg" "rcon /players" "RCON healthcheck configured"
assert_contains "$cfg" "max-size" "log rotation configured"
assert_contains "$cfg" "SERVER_VISIBILITY_PUBLIC" "LAN preset: public visibility set"
assert_contains "$cfg" "REQUIRE_USER_VERIFICATION" "LAN preset: user verification set"

# No env_file directive should remain.
[[ "$cfg" != *"env_file"* ]] || fail "compose should not use env_file (direct environment only)"

# The build-from-source compose must be gone (single stack only).
[[ ! -f "$REPO/docker/docker-compose.yml" ]] || fail "docker/docker-compose.yml should be removed (single compose)"

pass
