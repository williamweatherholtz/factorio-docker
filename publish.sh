#!/bin/bash
# Build and push the Factorio image to GHCR for every version/tag in
# buildinfo.json. Multi-arch by default.
#   ./publish.sh              build+push linux/amd64,linux/arm64
#   ./publish.sh --amd64-only build+push linux/amd64 only
#   ./publish.sh --print      print the buildx commands without running them
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="ghcr.io/williamweatherholtz/factorio"
PLATFORMS="linux/amd64,linux/arm64"
PRINT=0

for arg in "$@"; do
  case "$arg" in
    --amd64-only) PLATFORMS="linux/amd64" ;;
    --print)      PRINT=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# tr -d '\r' guards against a native Windows jq emitting CRLF; no-op on Linux.
for version in $(jq -r 'keys[]' buildinfo.json | tr -d '\r'); do
  sha="$(jq -r --arg v "$version" '.[$v].sha256' buildinfo.json | tr -d '\r')"
  tag_args=()
  while IFS= read -r tag; do
    tag="${tag%$'\r'}"
    tag_args+=( -t "${IMAGE}:${tag}" )
  done < <(jq -r --arg v "$version" '.[$v].tags[]' buildinfo.json)

  cmd=( docker buildx build docker
        --platform "$PLATFORMS"
        --build-arg "VERSION=${version}"
        --build-arg "SHA256=${sha}"
        "${tag_args[@]}"
        --push )

  if [[ "$PRINT" -eq 1 ]]; then
    printf '%s ' "${cmd[@]}"; printf '\n'
  else
    echo "building ${IMAGE} ${version} (${PLATFORMS})"
    "${cmd[@]}"
  fi
done
