#!/bin/bash
set -euo pipefail
TEST_NAME="test-overrides"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"
SCRIPT="$REPO/docker/files/docker-apply-overrides.sh"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
base="$work/base.json"
cat > "$base" <<'JSON'
{"name":"file-name","description":"file-desc","max_players":5,
 "visibility":{"public":true,"lan":true},
 "require_user_verification":true,"auto_pause":true,
 "afk_autokick_interval":0,"allow_commands":"true","autosave_interval":30}
JSON

# Case A: no overrides -> prints base path unchanged, writes no temp file.
out="$work/rendered.json"
result="$(bash "$SCRIPT" "$base" "$out")"
assert_eq "$base" "$result" "no-override returns base path"
[[ ! -f "$out" ]] || fail "no-override must not write temp file"

# Case B: overrides applied -> prints out path; base untouched; types correct.
base_before="$(cat "$base")"
result="$(SERVER_NAME='live-name' MAX_PLAYERS=16 SERVER_VISIBILITY_PUBLIC=false \
          AUTOSAVE_INTERVAL=10 ALLOW_COMMANDS=admins-only \
          bash "$SCRIPT" "$base" "$out")"
assert_eq "$out" "$result" "override returns out path"
assert_eq "$base_before" "$(cat "$base")" "base file must be unchanged"
assert_eq "live-name" "$(jq -r '.name' "$out")" ".name overridden"
assert_eq "16" "$(jq -r '.max_players' "$out")" ".max_players value"
assert_eq "number" "$(jq -r '.max_players|type' "$out")" ".max_players is a number"
assert_eq "false" "$(jq -r '.visibility.public' "$out")" ".visibility.public value"
assert_eq "boolean" "$(jq -r '.visibility.public|type' "$out")" ".visibility.public is bool"
assert_eq "10" "$(jq -r '.autosave_interval' "$out")" ".autosave_interval value"
assert_eq "admins-only" "$(jq -r '.allow_commands' "$out")" ".allow_commands string"
assert_eq "string" "$(jq -r '.allow_commands|type' "$out")" ".allow_commands is string"
# Untouched key keeps file value.
assert_eq "file-desc" "$(jq -r '.description' "$out")" "unset key keeps file value"

# Case C: invalid numeric env -> validation fails -> non-zero exit, base untouched.
base_before="$(cat "$base")"
if MAX_PLAYERS=notanumber bash "$SCRIPT" "$base" "$out" >/dev/null 2>&1; then
  fail "invalid MAX_PLAYERS should exit non-zero"
fi
assert_eq "$base_before" "$(cat "$base")" "invalid input must not touch base"

# Case D: set-but-EMPTY vars are ignored (not fatal, not written).
result="$(SERVER_NAME='' MAX_PLAYERS='' AUTO_PAUSE='' bash "$SCRIPT" "$base" "$out")"
assert_eq "$base" "$result" "empty vars are ignored -> base path"
[[ ! -f "$out" ]] || fail "empty vars must not write a rendered file"

# Case E: wrong-typed bool -> non-zero exit (AUTO_PAUSE must be true/false, not 1).
if AUTO_PAUSE=1 bash "$SCRIPT" "$base" "$out" >/dev/null 2>&1; then
  fail "AUTO_PAUSE=1 should be rejected"
fi

# Case F: invalid allow_commands enum -> non-zero exit.
if ALLOW_COMMANDS=banana bash "$SCRIPT" "$base" "$out" >/dev/null 2>&1; then
  fail "ALLOW_COMMANDS=banana should be rejected"
fi

# Case G: valid allow_commands enum value is accepted.
result="$(ALLOW_COMMANDS=admins-only bash "$SCRIPT" "$base" "$out")"
assert_eq "admins-only" "$(jq -r '.allow_commands' "$out")" "valid enum accepted"

# Case H: no out-path arg -> renders to a mktemp file whose path is printed.
result="$(SERVER_NAME='Temp' bash "$SCRIPT" "$base")"
[[ -f "$result" ]] || fail "mktemp render path should exist"
assert_eq "Temp" "$(jq -r '.name' "$result")" "mktemp render has override"
rm -f "$result"

pass
