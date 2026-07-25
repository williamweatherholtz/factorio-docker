#!/bin/bash
set -euo pipefail
TEST_NAME="test-preflight"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"
SCRIPT="$REPO/docker/files/docker-preflight.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cfg="$work/config"; mkdir -p "$cfg"

# Case A: all present -> exit 0; INFO only under DEBUG.
for f in server-settings map-gen-settings map-settings; do echo '{}' > "$cfg/$f.json"; done
set +e
out="$(DEBUG=true bash "$SCRIPT" "$cfg" 2>&1)"; rc=$?
set -e
assert_eq "0" "$rc" "all present exits 0"
assert_contains "$out" "INFO" "DEBUG prints INFO"
out="$(bash "$SCRIPT" "$cfg" 2>&1)"
assert_eq "" "$out" "no INFO without DEBUG"

# Case B: one missing -> WARN, still exit 0.
rm "$cfg/map-settings.json"
set +e
out="$(bash "$SCRIPT" "$cfg" 2>&1)"; rc=$?
set -e
assert_eq "0" "$rc" "missing file is non-fatal"
assert_contains "$out" "WARN" "missing file warns"

# Case C: a path is a directory -> ERROR + exit 1.
rm -f "$cfg/server-settings.json"; mkdir -p "$cfg/server-settings.json"
if out="$(bash "$SCRIPT" "$cfg" 2>&1)"; then fail "directory path must exit non-zero"; fi
assert_contains "$out" "ERROR" "directory path errors"
assert_contains "$out" "DIRECTORY" "error message names the symptom"

# Case D: a missing config dir is fine (entrypoint creates it) -> exit 0.
set +e
out="$(bash "$SCRIPT" "$work/does-not-exist" 2>&1)"; rc=$?
set -e
assert_eq "0" "$rc" "missing config dir is non-fatal"

# Case E: config dir is actually a FILE -> ERROR + exit 1.
filecfg="$work/config-as-file"; : > "$filecfg"
if out="$(bash "$SCRIPT" "$filecfg" 2>&1)"; then fail "config-dir-as-file must exit non-zero"; fi
assert_contains "$out" "not a directory" "file-as-config-dir errors"

pass
