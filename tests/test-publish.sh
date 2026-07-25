#!/bin/bash
set -euo pipefail
TEST_NAME="test-publish"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"
SCRIPT="$REPO/publish.sh"

out="$(bash "$SCRIPT" --print)"
assert_contains "$out" "docker buildx build" "prints buildx command"
assert_contains "$out" "linux/amd64,linux/arm64" "multi-arch by default"
assert_contains "$out" "ghcr.io/williamweatherholtz/factorio:stable" "tags the stable image"
assert_contains "$out" "ghcr.io/williamweatherholtz/factorio:latest" "tags the latest image"
assert_contains "$out" "VERSION=2.0.77" "passes stable VERSION build-arg"
assert_contains "$out" "--push" "pushes"

out="$(bash "$SCRIPT" --print --amd64-only)"
assert_contains "$out" "--platform linux/amd64 " "amd64-only narrows platform"
[[ "$out" != *"linux/arm64"* ]] || fail "--amd64-only must not include arm64"

pass
