#!/bin/bash
# Shared assertion helpers for repo bash tests.
set -euo pipefail

fail() { echo "FAIL: ${TEST_NAME:-test}: $1" >&2; exit 1; }

assert_eq() { # expected actual msg
  [[ "$1" == "$2" ]] || fail "$3 (expected '$1', got '$2')"
}

assert_file() { # path msg
  [[ -f "$1" ]] || fail "$2 (missing file '$1')"
}

assert_contains() { # haystack needle msg
  [[ "$1" == *"$2"* ]] || fail "$3 (missing '$2')"
}

pass() { echo "PASS: ${TEST_NAME:-test}"; }
