#!/bin/bash
set -euo pipefail
TEST_NAME="test-setup"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"

# Run setup.sh inside an isolated temp copy so we don't touch the real repo.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$REPO/setup.sh" "$work/"
mkdir -p "$work/config"
cp "$REPO/config/"*.example.json "$work/config/"

( cd "$work" && ./setup.sh >/dev/null )

for name in server-settings map-gen-settings map-settings; do
  assert_file "$work/config/${name}.json" "seeded ${name}.json"
done
for d in saves mods scenarios script-output; do
  [[ -d "$work/$d" ]] || fail "missing dir $d"
done

# Idempotency: edit a file, re-run, confirm it is NOT overwritten.
echo '{"marker":true}' > "$work/config/server-settings.json"
( cd "$work" && ./setup.sh >/dev/null )
assert_contains "$(cat "$work/config/server-settings.json")" "marker" "setup is idempotent"

pass
