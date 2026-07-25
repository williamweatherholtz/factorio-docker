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

# Warn about tags defined under more than one version: whichever version builds
# last wins for that tag (e.g. "2" currently resolves to the newest 2.x).
while IFS= read -r dup; do
  [[ -n "$dup" ]] && echo "WARN: tag '$dup' is defined under multiple versions; the last-built version wins for :$dup" >&2
done < <(jq -r '[.[].tags[]] | group_by(.) | map(select(length > 1)[0]) | .[]' buildinfo.json | tr -d '\r')

# Prechecks before mutating the registry (skipped for --print dry runs).
if [[ "$PRINT" -eq 0 ]]; then
  if [[ "$PLATFORMS" == *,* ]]; then
    driver="$(docker buildx inspect 2>/dev/null | sed -n 's/^Driver:[[:space:]]*//p' | tr -d '\r')"
    if [[ "$driver" != "docker-container" ]]; then
      echo "ERROR: multi-arch build needs a docker-container builder (current driver: '${driver:-none}')." >&2
      echo "       Run: docker buildx create --use   (or pass --amd64-only for a single-arch build)" >&2
      exit 1
    fi
  fi
  cfg_dir="${DOCKER_CONFIG:-$HOME/.docker}"
  if ! grep -q "ghcr.io" "$cfg_dir/config.json" 2>/dev/null; then
    echo "ERROR: no ghcr.io credentials found in $cfg_dir/config.json." >&2
    echo "       Run: gh auth token | docker login ghcr.io -u williamweatherholtz --password-stdin" >&2
    exit 1
  fi
fi

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
