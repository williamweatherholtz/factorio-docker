#!/bin/bash
# Test double that replaces the real factorio binary during e2e runs.
# - For the map-creation invocation (--create <path>) it just creates the file
#   so the entrypoint proceeds to assemble the server-start command.
# - For the server-start invocation it prints the runtime UID/GID it was launched
#   as, the full argument list, the effective server-settings file it was handed,
#   and the resulting mod-list.json. The e2e runner asserts against these.
set -u

# Handle the --create <save> pre-step: materialize the save and exit.
prev=""
for a in "$@"; do
  if [[ "$prev" == "--create" ]]; then
    : > "$a"
    exit 0
  fi
  prev="$a"
done

echo "SHIM_RUNTIME_UID: $(id -u)"
echo "SHIM_RUNTIME_GID: $(id -g)"
echo "FACTORIO_SHIM_ARGS: $*"

prev=""
for a in "$@"; do
  if [[ "$prev" == "--server-settings" ]]; then
    echo "EFFECTIVE_SERVER_SETTINGS_PATH: $a"
    echo "EFFECTIVE_SERVER_SETTINGS_BEGIN"
    cat "$a"
    echo ""
    echo "EFFECTIVE_SERVER_SETTINGS_END"
  fi
  prev="$a"
done

MOD_LIST="${MODS:-/factorio/mods}/mod-list.json"
if [[ -f "$MOD_LIST" ]]; then
  echo "MOD_LIST_BEGIN"
  cat "$MOD_LIST"
  echo ""
  echo "MOD_LIST_END"
fi

exit 0
