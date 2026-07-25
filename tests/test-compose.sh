#!/bin/bash
set -euo pipefail
TEST_NAME="test-compose"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"

# .env must exist for `docker compose config` to resolve env_file.
[[ -f "$REPO/.env" ]] || cp "$REPO/.env.example" "$REPO/.env"

cfg="$(cd "$REPO" && docker compose config 2>/dev/null)" || fail "docker compose config failed"
assert_contains "$cfg" "ghcr.io/williamweatherholtz/factorio" "uses GHCR image"
assert_contains "$cfg" "/factorio/config" "config bind mount present"
assert_contains "$cfg" "/factorio/saves" "saves bind mount present"
assert_contains "$cfg" "/factorio/mods" "mods bind mount present"

pass
