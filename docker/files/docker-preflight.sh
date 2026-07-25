#!/bin/bash
# Validate the three server config JSON files before the entrypoint uses them.
# Fatal (exit 1) if any expected path is a directory (the classic symptom of a
# single-file bind mount whose host source was missing). Missing files only warn
# (the entrypoint seeds them from examples). Present files log INFO under DEBUG.
set -uo pipefail

CONFIG_DIR="${1:-${CONFIG:-/factorio/config}}"
DEBUG="${DEBUG:-false}"
status=0

for f in server-settings.json map-gen-settings.json map-settings.json; do
  path="$CONFIG_DIR/$f"
  if [[ -d "$path" ]]; then
    echo "ERROR: $path is a DIRECTORY. The host file is missing — run ./setup.sh before 'docker compose up'." >&2
    status=1
  elif [[ ! -f "$path" ]]; then
    echo "WARN: $path missing; will seed from the bundled example." >&2
  else
    [[ "$DEBUG" == "true" ]] && echo "INFO: using $path" >&2 || true
  fi
done

exit "$status"
