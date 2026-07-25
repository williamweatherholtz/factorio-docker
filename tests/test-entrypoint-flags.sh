#!/bin/bash
set -euo pipefail
TEST_NAME="test-entrypoint-flags"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"
EP="$REPO/docker/files/docker-entrypoint.sh"

body="$(cat "$EP")"
assert_contains "$body" "docker-preflight.sh \"\$CONFIG\"" "preflight is invoked"
assert_contains "$body" 'SERVER_SETTINGS_FILE="$("${INSTALLED_DIRECTORY}"/docker-apply-overrides.sh' "overlay is invoked"
assert_contains "$body" '--server-settings "$SERVER_SETTINGS_FILE"' "flag uses rendered path"
# The old hard-coded flag must be gone.
[[ "$body" != *'--server-settings "$CONFIG/server-settings.json"'* ]] || fail "old --server-settings flag still present"
# Bash must parse the edited script.
bash -n "$EP" || fail "entrypoint has a syntax error"

pass
