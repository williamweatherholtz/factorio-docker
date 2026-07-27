#!/bin/bash
# Seed host directories and config files before 'docker compose up'.
# Idempotent: never overwrites an existing file.
set -euo pipefail
cd "$(dirname "$0")"

for d in config saves mods scenarios script-output; do
  mkdir -p "$d"
done

for name in server-settings map-gen-settings map-settings; do
  src="config/${name}.example.json"
  dst="config/${name}.json"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: missing reference $src (run the extraction step in the plan)" >&2
    exit 1
  fi
  if [[ -f "$dst" ]]; then
    echo "skip: $dst already exists"
  else
    cp "$src" "$dst"
    echo "seed: $dst"
  fi
done

echo "setup complete."
