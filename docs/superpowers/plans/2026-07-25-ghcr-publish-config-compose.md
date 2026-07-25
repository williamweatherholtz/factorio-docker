# GHCR Publish + Config-First Compose Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the Factorio image to `ghcr.io/williamweatherholtz/factorio` and ship a compose stack where `server*.json` config is editable repo files, a set of hot keys is env-overridable at boot without mutating those files, server data is bind-mounted for backup, and boot emits clear diagnostics when config is missing or mis-mounted.

**Architecture:** Config files are the source of truth, seeded into `./config` by `setup.sh` before first `up`. At boot, `docker-preflight.sh` validates the three config JSONs (fatal if a path is a directory, warn+seed if missing, info if present). `docker-apply-overrides.sh` reads the committed `server-settings.json`, applies only the env vars that are set via `jq`, writes the effective result to `/tmp` (never touching the source), and prints the path the entrypoint should hand to `--server-settings`. `publish.sh` builds multi-arch and pushes every tag defined in `buildinfo.json`.

**Tech Stack:** Bash, `jq` (already in the image), Docker Buildx, docker-compose v2, GitHub Container Registry.

## Global Constraints

- Image ref: `ghcr.io/williamweatherholtz/factorio` (tags come from `buildinfo.json`).
- Multi-arch default: `linux/amd64,linux/arm64`; `publish.sh --amd64-only` opts out.
- New container scripts live in `docker/files/` so the existing `COPY files/*.sh /` (`docker/Dockerfile:91`) picks them up — no Dockerfile change needed. They are invoked from `/` (the entrypoint's `INSTALLED_DIRECTORY`).
- Overlay must NEVER mutate committed `config/*.json`; render to `/tmp` and select via stdout path.
- Overlay type rules: numbers/bools → `jq --argjson`; strings → `jq --arg`. `ALLOW_COMMANDS` stays a string (`true`/`false`/`admins-only`).
- Overlay keys (exact env → path): `SERVER_NAME`→`.name`(str), `SERVER_DESCRIPTION`→`.description`(str), `MAX_PLAYERS`→`.max_players`(num), `SERVER_VISIBILITY_PUBLIC`→`.visibility.public`(bool), `SERVER_VISIBILITY_LAN`→`.visibility.lan`(bool), `REQUIRE_USER_VERIFICATION`→`.require_user_verification`(bool), `AUTO_PAUSE`→`.auto_pause`(bool), `AFK_AUTOKICK_INTERVAL`→`.afk_autokick_interval`(num), `ALLOW_COMMANDS`→`.allow_commands`(str), `AUTOSAVE_INTERVAL`→`.autosave_interval`(num).
- "Set" means the env var is defined (even if empty): test with `${VAR+set}`.
- Tests are bash scripts run via git-bash with `jq` on PATH; each exits non-zero on failure. No new test framework.
- Commit after each task. Branch already exists: `feat/ghcr-publish-config-compose`.

---

## File Structure

| File | Responsibility |
|---|---|
| `tests/lib.sh` (create) | Shared bash assertion helpers for all tests |
| `config/server-settings.example.json` (create) | Committed reference default, extracted from upstream image |
| `config/map-gen-settings.example.json` (create) | Committed reference default |
| `config/map-settings.example.json` (create) | Committed reference default |
| `.env.example` (create) | Documented template of overlay + orchestration vars |
| `setup.sh` (create) | Seed data dirs + `config/*.json` + `.env` before first `up`; idempotent |
| `docker/files/docker-apply-overrides.sh` (create) | Render effective server-settings from base + env overlay; print path |
| `docker/files/docker-preflight.sh` (create) | Validate the three config JSONs; fatal on directory, warn on missing, info on present |
| `docker/files/docker-entrypoint.sh` (modify) | Call preflight; call overrides; point `--server-settings` at the printed path |
| `docker-compose.yml` (modify) | GHCR image, explicit bind mounts, `env_file` |
| `publish.sh` (create) | Multi-arch buildx build + push of every `buildinfo.json` tag |
| `README.md` (modify) | Document config tiers, overlay table, setup, publish |
| `tests/*.sh` (create) | One test script per logic task |

---

## Task 1: Test helper + reference example configs + `.env.example` + `setup.sh`

**Files:**
- Create: `tests/lib.sh`
- Create: `config/server-settings.example.json`, `config/map-gen-settings.example.json`, `config/map-settings.example.json`
- Create: `.env.example`
- Create: `setup.sh`
- Test: `tests/test-setup.sh`

**Interfaces:**
- Produces: `setup.sh` — run from repo root, no args. Creates dirs `config saves mods scenarios script-output`; copies `config/<name>.example.json` → `config/<name>.json` for each of `server-settings`, `map-gen-settings`, `map-settings` only if the target is absent; copies `.env.example` → `.env` if absent. Idempotent, never overwrites.
- Produces: `tests/lib.sh` — sourced by every test. Defines `assert_eq expected actual msg`, `assert_file file msg`, `assert_contains haystack needle msg`, `fail msg`, and a trap that prints `PASS: <basename>` on clean exit.

- [ ] **Step 1: Extract the three reference example JSONs from the public upstream image**

Run (writes real content into the committed reference files):

```bash
for f in server-settings map-gen-settings map-settings; do
  docker run --rm --entrypoint cat factoriotools/factorio:stable \
    "/opt/factorio/data/${f}.example.json" > "config/${f}.example.json"
done
head -5 config/server-settings.example.json
```

Expected: `config/server-settings.example.json` begins with `{` and contains `"name"`. If Docker/network is unavailable, obtain the same files from a local Factorio install's `data/` directory — they must be the genuine Factorio examples, not hand-written.

- [ ] **Step 2: Write the test helper `tests/lib.sh`**

```bash
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
```

- [ ] **Step 3: Write `.env.example`**

```bash
# Copy to .env (setup.sh does this for you) and edit.
# These values override the matching keys in config/server-settings.json AT BOOT
# ONLY when uncommented. The committed JSON file is never modified.

# --- server-settings.json hot overrides ---
#SERVER_NAME=My Factorio Server
#SERVER_DESCRIPTION=Hosted with docker
#MAX_PLAYERS=0
#SERVER_VISIBILITY_PUBLIC=false
#SERVER_VISIBILITY_LAN=true
#REQUIRE_USER_VERIFICATION=true
#AUTO_PAUSE=true
#AFK_AUTOKICK_INTERVAL=0
#ALLOW_COMMANDS=admins-only
#AUTOSAVE_INTERVAL=10

# --- orchestration (read by docker-entrypoint.sh) ---
#UPDATE_MODS_ON_START=true
#UPDATE_IGNORE=mod1,mod2
#USERNAME=FactorioUsername
#TOKEN=FactorioToken
#DLC_SPACE_AGE=true
#PUID=1000
#PGID=1000
#DEBUG=false
```

- [ ] **Step 4: Write `setup.sh`**

```bash
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

if [[ -f .env ]]; then
  echo "skip: .env already exists"
else
  cp .env.example .env
  echo "seed: .env"
fi

echo "setup complete."
```

- [ ] **Step 5: Write the failing test `tests/test-setup.sh`**

```bash
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
cp "$REPO/.env.example" "$work/"

( cd "$work" && ./setup.sh >/dev/null )

for name in server-settings map-gen-settings map-settings; do
  assert_file "$work/config/${name}.json" "seeded ${name}.json"
done
assert_file "$work/.env" "seeded .env"
for d in saves mods scenarios script-output; do
  [[ -d "$work/$d" ]] || fail "missing dir $d"
done

# Idempotency: edit a file, re-run, confirm it is NOT overwritten.
echo '{"marker":true}' > "$work/config/server-settings.json"
( cd "$work" && ./setup.sh >/dev/null )
assert_contains "$(cat "$work/config/server-settings.json")" "marker" "setup is idempotent"

pass
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bash tests/test-setup.sh`
Expected: FAIL initially if any file is missing (e.g. before Steps 1-4 complete). After Steps 1-4 it should PASS — run it now.

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash tests/test-setup.sh`
Expected: `PASS: test-setup`

- [ ] **Step 8: Commit**

```bash
git add tests/lib.sh tests/test-setup.sh config/*.example.json .env.example setup.sh
git commit -m "feat: add setup.sh, reference config examples, .env.example"
```

---

## Task 2: Env overlay script `docker-apply-overrides.sh`

**Files:**
- Create: `docker/files/docker-apply-overrides.sh`
- Test: `tests/test-overrides.sh`

**Interfaces:**
- Consumes: overlay env vars from Global Constraints; a base server-settings JSON path.
- Produces: `docker-apply-overrides.sh <base_path> [out_path]`. Reads `<base_path>`, applies each set overlay env var via `jq`, and:
  - if ≥1 override was applied: writes the merged JSON to `out_path` (default `/tmp/server-settings.rendered.json`), `chmod 0644`, and prints `out_path` to stdout.
  - if no override set: prints `<base_path>` to stdout and writes nothing.
  - All diagnostics go to stderr; stdout is exactly the chosen path. Exits non-zero if `jq` fails (e.g. a numeric/bool env var holds invalid JSON).

- [ ] **Step 1: Write the failing test `tests/test-overrides.sh`**

```bash
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

# Case C: invalid numeric env -> jq fails -> non-zero exit.
if MAX_PLAYERS=notanumber bash "$SCRIPT" "$base" "$out" >/dev/null 2>&1; then
  fail "invalid MAX_PLAYERS should exit non-zero"
fi

pass
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-overrides.sh`
Expected: FAIL with the script not found / no output (script doesn't exist yet).

- [ ] **Step 3: Write `docker/files/docker-apply-overrides.sh`**

```bash
#!/bin/bash
# Render effective server-settings.json from a base file plus env-var overrides.
# The base file is never modified. Prints to stdout the path that should be
# passed to factorio's --server-settings (the rendered temp file if any override
# was applied, otherwise the base path). Diagnostics go to stderr.
set -euo pipefail

BASE="${1:-${CONFIG:-/factorio/config}/server-settings.json}"
OUT="${2:-/tmp/server-settings.rendered.json}"
DEBUG="${DEBUG:-false}"

log() { [[ "$DEBUG" == "true" ]] && echo "docker-apply-overrides: $1" >&2 || true; }

changed=0
cp "$BASE" "$OUT"

# $1 = jq path, $2 = value, $3 = jq value-flag (--arg for strings, --argjson for num/bool)
patch() {
  local path="$1" value="$2" flag="$3" tmp
  tmp="$(jq "$flag" v "$value" "$path = \$v" "$OUT")"
  printf '%s\n' "$tmp" > "$OUT"
  changed=1
  log "set $path = $value"
}

[[ -n "${SERVER_NAME+set}" ]]                 && patch '.name'                       "$SERVER_NAME"                 --arg
[[ -n "${SERVER_DESCRIPTION+set}" ]]          && patch '.description'                "$SERVER_DESCRIPTION"          --arg
[[ -n "${MAX_PLAYERS+set}" ]]                 && patch '.max_players'                "$MAX_PLAYERS"                 --argjson
[[ -n "${SERVER_VISIBILITY_PUBLIC+set}" ]]    && patch '.visibility.public'          "$SERVER_VISIBILITY_PUBLIC"    --argjson
[[ -n "${SERVER_VISIBILITY_LAN+set}" ]]       && patch '.visibility.lan'             "$SERVER_VISIBILITY_LAN"       --argjson
[[ -n "${REQUIRE_USER_VERIFICATION+set}" ]]   && patch '.require_user_verification'  "$REQUIRE_USER_VERIFICATION"   --argjson
[[ -n "${AUTO_PAUSE+set}" ]]                  && patch '.auto_pause'                 "$AUTO_PAUSE"                  --argjson
[[ -n "${AFK_AUTOKICK_INTERVAL+set}" ]]       && patch '.afk_autokick_interval'      "$AFK_AUTOKICK_INTERVAL"       --argjson
[[ -n "${ALLOW_COMMANDS+set}" ]]              && patch '.allow_commands'             "$ALLOW_COMMANDS"              --arg
[[ -n "${AUTOSAVE_INTERVAL+set}" ]]           && patch '.autosave_interval'          "$AUTOSAVE_INTERVAL"           --argjson

if [[ "$changed" -eq 1 ]]; then
  chmod 0644 "$OUT"
  printf '%s\n' "$OUT"
else
  rm -f "$OUT"
  printf '%s\n' "$BASE"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-overrides.sh`
Expected: `PASS: test-overrides`

- [ ] **Step 5: Commit**

```bash
git add docker/files/docker-apply-overrides.sh tests/test-overrides.sh
git commit -m "feat: env overlay renders server-settings without mutating source"
```

---

## Task 3: Preflight checks `docker-preflight.sh`

**Files:**
- Create: `docker/files/docker-preflight.sh`
- Test: `tests/test-preflight.sh`

**Interfaces:**
- Produces: `docker-preflight.sh [config_dir]` (default `${CONFIG:-/factorio/config}`). For each of `server-settings.json`, `map-gen-settings.json`, `map-settings.json`: if the path is a directory → print `ERROR:` line to stderr and set failure; if missing → print `WARN:` line to stderr; if present → print `INFO:` line to stderr only when `DEBUG=true`. Exits `1` if any path was a directory, else `0`.

- [ ] **Step 1: Write the failing test `tests/test-preflight.sh`**

```bash
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
out="$(DEBUG=true bash "$SCRIPT" "$cfg" 2>&1)"; rc=$?
assert_eq "0" "$rc" "all present exits 0"
assert_contains "$out" "INFO" "DEBUG prints INFO"
out="$(bash "$SCRIPT" "$cfg" 2>&1)"
assert_eq "" "$out" "no INFO without DEBUG"

# Case B: one missing -> WARN, still exit 0.
rm "$cfg/map-settings.json"
out="$(bash "$SCRIPT" "$cfg" 2>&1)"; rc=$?
assert_eq "0" "$rc" "missing file is non-fatal"
assert_contains "$out" "WARN" "missing file warns"

# Case C: a path is a directory -> ERROR + exit 1.
rm -f "$cfg/server-settings.json"; mkdir -p "$cfg/server-settings.json"
if out="$(bash "$SCRIPT" "$cfg" 2>&1)"; then fail "directory path must exit non-zero"; fi
assert_contains "$out" "ERROR" "directory path errors"
assert_contains "$out" "DIRECTORY" "error message names the symptom"

pass
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-preflight.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Write `docker/files/docker-preflight.sh`**

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-preflight.sh`
Expected: `PASS: test-preflight`

- [ ] **Step 5: Commit**

```bash
git add docker/files/docker-preflight.sh tests/test-preflight.sh
git commit -m "feat: preflight config validation with actionable diagnostics"
```

---

## Task 4: Wire preflight + overlay into `docker-entrypoint.sh`

**Files:**
- Modify: `docker/files/docker-entrypoint.sh` (add preflight call after the `mkdir` block ~line 17; add overlay call after the config-seed block ~line 35; change `--server-settings` in the `FLAGS` array ~line 97)
- Test: `tests/test-entrypoint-flags.sh`

**Interfaces:**
- Consumes: `docker-preflight.sh`, `docker-apply-overrides.sh` (both at `${INSTALLED_DIRECTORY}`, which is `/` in the image).
- Produces: entrypoint that aborts on fatal preflight, sets `SERVER_SETTINGS_FILE` from the overlay script, and passes it to `--server-settings`.

- [ ] **Step 1: Add the preflight call**

In `docker/files/docker-entrypoint.sh`, immediately after the `mkdir -p "$SCRIPTOUTPUT"` line (currently line 17) and before the `rconpw` block, insert:

```bash

# Validate config files early; abort on a fatal mis-mount (e.g. a JSON path that
# became a directory because its host bind-mount source was missing).
"${INSTALLED_DIRECTORY}"/docker-preflight.sh "$CONFIG"
```

- [ ] **Step 2: Add the overlay call after the seed block**

Immediately after the `map-settings.json` seed block (currently ending line 35, `fi`), insert:

```bash

# Apply env-var overrides onto a rendered copy of server-settings.json without
# mutating the committed file. Prints the path to use for --server-settings.
SERVER_SETTINGS_FILE="$("${INSTALLED_DIRECTORY}"/docker-apply-overrides.sh "$CONFIG/server-settings.json")"
```

- [ ] **Step 3: Point `--server-settings` at the rendered path**

In the `FLAGS=(...)` array, change:

```bash
  --server-settings "$CONFIG/server-settings.json" \
```

to:

```bash
  --server-settings "$SERVER_SETTINGS_FILE" \
```

- [ ] **Step 4: Write the test `tests/test-entrypoint-flags.sh`**

This verifies the three edits are present and internally consistent (a full entrypoint run needs the Factorio binary, so we assert the wiring statically plus exercise the referenced scripts).

```bash
#!/bin/bash
set -euo pipefail
TEST_NAME="test-entrypoint-flags"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"
EP="$REPO/docker/files/docker-entrypoint.sh"

body="$(cat "$EP")"
assert_contains "$body" "docker-preflight.sh \"\$CONFIG\"" "preflight is invoked"
assert_contains "$body" 'SERVER_SETTINGS_FILE="$("${INSTALLED_DIRECTORY}"/docker-apply-overrides.sh' "overlay is invoked"
assert_contains "$body" '--server-settings "$SERVER_SETTINGS_FILE"' "flag uses rendered path"
# The old hard-coded flag must be gone.
[[ "$body" != *'--server-settings "$CONFIG/server-settings.json"'* ]] || fail "old --server-settings flag still present"
# Bash must parse the edited script.
bash -n "$EP" || fail "entrypoint has a syntax error"

pass
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-entrypoint-flags.sh`
Expected: `PASS: test-entrypoint-flags`

- [ ] **Step 6: Commit**

```bash
git add docker/files/docker-entrypoint.sh tests/test-entrypoint-flags.sh
git commit -m "feat: entrypoint runs preflight and env overlay for server-settings"
```

---

## Task 5: Rewrite `docker-compose.yml`

**Files:**
- Modify: `docker-compose.yml`
- Test: `tests/test-compose.sh`

**Interfaces:**
- Produces: a compose file using `image: ghcr.io/williamweatherholtz/factorio:stable`, `env_file: [.env]`, and the five explicit bind mounts. Retains the commented watchtower block.

- [ ] **Step 1: Write the new `docker-compose.yml`**

```yaml
services:
  factorio:
    container_name: factorio
    image: ghcr.io/williamweatherholtz/factorio:stable
    restart: unless-stopped
    ports:
      - "34197:34197/udp"
      - "27015:27015/tcp"
    env_file:
      - .env
    volumes:
      - ./config:/factorio/config              # server-settings, map-*, rconpw, lists, server-id
      - ./saves:/factorio/saves                # back these up
      - ./mods:/factorio/mods                  # add/remove mods from the host
      - ./scenarios:/factorio/scenarios
      - ./script-output:/factorio/script-output

    # Uncomment to enable autoupdate via watchtower
    #labels:
    #  - com.centurylinklabs.watchtower.enable=true
    #  - com.centurylinklabs.watchtower.scope=factorio
    #  - com.centurylinklabs.watchtower.lifecycle.pre-update="/players-online.sh"

  # Uncomment to use watchtower for updating the factorio container
  # Full documentation: https://github.com/containrrr/watchtower
  #watchtower:
  #  container_name: watchtower_factorio
  #  image: ghcr.io/nicholas-fedor/watchtower:latest
  #  restart: unless-stopped
  #  volumes:
  #   - /var/run/docker.sock:/var/run/docker.sock
  #  environment:
  #    - WATCHTOWER_TIMEOUT=30s
  #    - WATCHTOWER_LABEL_ENABLE=true
  #    - WATCHTOWER_POLL_INTERVAL=3600
  #    - WATCHTOWER_LIFECYCLE_HOOKS=true
  #    - WATCHTOWER_SCOPE=factorio
  #  labels:
  #    - com.centurylinklabs.watchtower.scope=factorio
```

- [ ] **Step 2: Write the test `tests/test-compose.sh`**

```bash
#!/bin/bash
set -euo pipefail
TEST_NAME="test-compose"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/tests/lib.sh"

# .env must exist for `docker compose config` to resolve env_file.
[[ -f "$REPO/.env" ]] || cp "$REPO/.env.example" "$REPO/.env"

cfg="$(cd "$REPO" && docker compose config 2>/dev/null)" || fail "docker compose config failed"
assert_contains "$cfg" "ghcr.io/williamweatherholtz/factorio" "uses GHCR image"
assert_contains "$cfg" "/factorio/config" "config bind mount present"
assert_contains "$cfg" "/factorio/saves" "saves bind mount present"
assert_contains "$cfg" "/factorio/mods" "mods bind mount present"

pass
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `bash tests/test-compose.sh`
Expected: `PASS: test-compose`. (Requires Docker CLI. If Docker is unavailable, fall back to asserting the file contents with grep for the same four strings.)

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml tests/test-compose.sh
git commit -m "feat: compose stack uses GHCR image with explicit bind mounts"
```

---

## Task 6: `publish.sh` — multi-arch build + push

**Files:**
- Create: `publish.sh`
- Test: `tests/test-publish.sh`

**Interfaces:**
- Produces: `publish.sh [--amd64-only] [--print]`. Reads every version key from `buildinfo.json`; for each, runs `docker buildx build` in `docker/` context with `VERSION`/`SHA256` build args, `-t ghcr.io/williamweatherholtz/factorio:<tag>` for every tag in that version's `tags` array, `--platform linux/amd64,linux/arm64` (or `linux/amd64` with `--amd64-only`), and `--push`. `--print` echoes each buildx command to stdout instead of running it.

- [ ] **Step 1: Write the failing test `tests/test-publish.sh`**

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-publish.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Write `publish.sh`**

```bash
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

for version in $(jq -r 'keys[]' buildinfo.json); do
  sha="$(jq -r --arg v "$version" '.[$v].sha256' buildinfo.json)"
  tag_args=()
  while IFS= read -r tag; do
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
```

Note: the buildx context is `docker` (the Dockerfile lives at `docker/Dockerfile`, which is the default `Dockerfile` name inside that directory).

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-publish.sh`
Expected: `PASS: test-publish`

- [ ] **Step 5: Real publish (manual, requires auth — not part of automated tests)**

```bash
gh auth token | docker login ghcr.io -u williamweatherholtz --password-stdin
docker buildx create --use --name factorio-builder 2>/dev/null || true
./publish.sh
```

Expected: images appear under `https://github.com/williamweatherholtz?tab=packages`. Verify: `docker pull ghcr.io/williamweatherholtz/factorio:stable`.

- [ ] **Step 6: Commit**

```bash
git add publish.sh tests/test-publish.sh
git commit -m "feat: publish.sh builds and pushes multi-arch images to GHCR"
```

---

## Task 7: Documentation + `.gitignore`

**Files:**
- Modify: `README.md`
- Create/Modify: `.gitignore` (ignore `.env`, and the runtime data dirs)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add ignore rules**

Append to `.gitignore` (create it if absent):

```
# local compose runtime data + secrets
.env
/config/*.json
!/config/*.example.json
/saves/
/mods/
/scenarios/
/script-output/
/data/
```

- [ ] **Step 2: Add a README section**

Insert a new section into `README.md` (after the existing quick-start/usage area) with this exact content:

````markdown
## Self-hosted image (GHCR) + config-first compose

This fork publishes to `ghcr.io/williamweatherholtz/factorio` and ships a
compose stack where server configuration lives in editable repo files.

### First-time setup

```bash
./setup.sh          # seeds ./config/*.json, ./saves, ./mods, ... and .env
docker compose up -d
```

### Two config tiers

1. **Files (source of truth).** Edit `config/server-settings.json`,
   `config/map-gen-settings.json`, `config/map-settings.json` directly, then
   `docker compose restart factorio`. These files are bind-mounted and are never
   modified by the container.
2. **Env overrides (hot keys).** Uncomment keys in `.env` to override the
   matching `server-settings.json` values **at boot only** — the JSON file on
   disk stays untouched (overrides render to a temp file inside the container).

| `.env` var | server-settings.json key | type |
|---|---|---|
| `SERVER_NAME` | `name` | string |
| `SERVER_DESCRIPTION` | `description` | string |
| `MAX_PLAYERS` | `max_players` | number |
| `SERVER_VISIBILITY_PUBLIC` | `visibility.public` | bool |
| `SERVER_VISIBILITY_LAN` | `visibility.lan` | bool |
| `REQUIRE_USER_VERIFICATION` | `require_user_verification` | bool |
| `AUTO_PAUSE` | `auto_pause` | bool |
| `AFK_AUTOKICK_INTERVAL` | `afk_autokick_interval` | number |
| `ALLOW_COMMANDS` | `allow_commands` | string (`true`/`false`/`admins-only`) |
| `AUTOSAVE_INTERVAL` | `autosave_interval` | number |

Set `DEBUG=true` in `.env` for verbose boot diagnostics. If a config path shows
up as a **directory** the server aborts with guidance to run `./setup.sh`.

### Backups

`./saves`, `./mods`, and `./config` are plain host directories — back them up by
copying, no volume archaeology required.

### Publishing the image

```bash
gh auth token | docker login ghcr.io -u williamweatherholtz --password-stdin
./publish.sh                # linux/amd64,linux/arm64
./publish.sh --amd64-only   # faster local iteration
```

`publish.sh` reads versions and tags from `buildinfo.json`.
````

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: document GHCR image, config tiers, overrides, and setup"
```

---

## Task 8: Full test sweep + branch verification

**Files:** none (verification only).

- [ ] **Step 1: Run every test**

```bash
for t in tests/test-*.sh; do bash "$t" || exit 1; done
```

Expected: a `PASS:` line for each test, exit 0.

- [ ] **Step 2: Lint the shell scripts (if shellcheck is available)**

```bash
shellcheck setup.sh publish.sh docker/files/docker-apply-overrides.sh docker/files/docker-preflight.sh || true
```

Expected: no errors (warnings acceptable). If shellcheck is unavailable, skip.

- [ ] **Step 3: Confirm the committed config files are only the examples**

```bash
git ls-files config/
```

Expected: only `config/*.example.json` are tracked; no live `config/*.json`, `.env`, or data dirs.

---

## Self-Review

**Spec coverage:**
- Publish to GHCR → Task 6 (`publish.sh`), README Task 7. ✓
- Compose with explicit bind mounts + env_file → Task 5. ✓
- Config seeded before boot (introspection) → Task 1 (`setup.sh` + committed examples). ✓
- Env overlay, files source-of-truth, no drift, render-to-temp → Task 2 + Task 4 wiring. ✓
- Overlay key table + types → Task 2 (Global Constraints + test asserts types). ✓
- Preflight: directory=fatal, missing=warn+seed, present=info under DEBUG → Task 3 + Task 4. ✓
- Server data bind-mounted for backup → Task 5. ✓
- Read-only stance documented → README Task 7 (root fs left rw; map files read-only in effect; server-settings pristine via temp render). ✓
- `.gitignore` for `.env`/data → Task 7. ✓

**Placeholder scan:** No TBD/TODO; every code step contains full content. ✓

**Type consistency:** `SERVER_SETTINGS_FILE` (entrypoint) is fed by `docker-apply-overrides.sh` stdout in both Task 2 (contract) and Task 4 (wiring). `patch` uses `--arg`/`--argjson` consistently with the Global Constraints table. `docker-preflight.sh` arg is `config_dir` in both definition and entrypoint call. ✓
