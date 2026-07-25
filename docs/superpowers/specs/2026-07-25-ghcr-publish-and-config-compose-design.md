# Design: GHCR-published image + config-first compose stack

**Date:** 2026-07-25
**Status:** Approved (design), pending implementation plan
**Author:** William Weatherholtz (with Claude Code)

## Problem

Two related goals for this fork of `factoriotools/factorio-docker`:

1. **Publish** the Factorio server image to the user's own GitHub Container
   Registry namespace (`ghcr.io/williamweatherholtz/factorio`).
2. Ship a **"proper" compose stack** that makes the Factorio `server*.json`
   configuration easy to **introspect** (see the real settings without
   spelunking a first-boot-populated volume) and **modify** (edit files
   directly, plus override a set of hot keys via environment variables), while
   keeping server data (saves, mods, scenarios) host-visible for backup.

### Background: how config works today

- `docker-entrypoint.sh` seeds `/factorio/config/{server-settings,map-gen-settings,map-settings}.json`
  from the image's `*.example.json` **only if they don't already exist**
  (`docker-entrypoint.sh:24-35`).
- Actual game-server parameters (name, description, `max_players`, visibility,
  `game_password`, `autosave_interval`, admins, `allow_commands`, etc.) live in
  `server-settings.json`. They are **not** exposed as environment variables.
- Only orchestration flags are ENV-driven: `PORT`, `RCON_PORT`, `SAVE_NAME`,
  `LOAD_LATEST_SAVE`, `GENERATE_NEW_SAVE`, `PRESET`, `BIND`,
  `CONSOLE_LOG_LOCATION`, `DLC_SPACE_AGE`, `PUID`/`PGID`,
  `UPDATE_MODS_ON_START`/`UPDATE_IGNORE`, `USERNAME`/`TOKEN`.
- The current top-level `docker-compose.yml` mounts one opaque `./data:/factorio`
  volume, so config only appears after first boot.

## Goals

- Reproducible publish of the image to `ghcr.io/williamweatherholtz/factorio`.
- Config files (`server-settings.json`, `map-gen-settings.json`,
  `map-settings.json`) present and editable in the repo **before** first boot.
- Files are the source of truth; a defined set of "hot" keys can be overridden
  by env vars at boot **without mutating the committed files** (no drift).
- Server data (saves, mods, scenarios, script-output) bind-mounted for backup.
- Clear preflight diagnostics when config files are missing or mis-mounted (the
  classic "single-file bind mount became a directory" failure).

## Non-goals

- Full read-only container root filesystem (offered only as optional hardening
  note; the stock entrypoint mutates `config.ini` via `sed` and does ARM box64
  setup, which complicates a `read_only: true` root).
- Exposing every `server-settings.json` key as an env var. Only the hot set
  below; everything else stays file-only.
- Changing upstream's `build.py`/`buildinfo.json` version-management flow.

## Design

### 1. Image publishing → `ghcr.io/williamweatherholtz/factorio`

Build `docker/Dockerfile` with buildx and push to GHCR.

- Version comes from `buildinfo.json` (currently `2.0.77`) and its associated
  SHA256; the Dockerfile takes `VERSION` and `SHA256` build args.
- Tags pushed: the exact version (`2.0.77`), the minor/major shortcuts
  (`2.0`, `2`), `stable`, and `latest`.
- Auth: `gh auth token | docker login ghcr.io -u williamweatherholtz --password-stdin`.
- Captured as a repeatable `publish.sh` at repo root (not a one-off shell
  command). The `deployer` skill may be used for content-hash versioning and
  recording the deploy; `publish.sh` remains the canonical entry point.

`publish.sh` responsibilities:
- Read `VERSION`/`SHA256` from `buildinfo.json` (default to the stable entry).
- `docker buildx build` for `linux/amd64,linux/arm64` (multi-arch by default,
  matching upstream's supported platforms) with those build args, tagging all
  the tags above. A `--amd64-only` flag skips ARM for faster local iteration.
- `--push` to GHCR.
- Print the resulting image ref(s).

### 2. Compose stack (top-level `docker-compose.yml`)

Rewrite to:

- `image: ghcr.io/williamweatherholtz/factorio:stable` (pinned, pullable).
- Explicit per-subdir bind mounts (host-visible, backup-friendly, and they
  avoid the single-file-mount → directory trap):

  ```yaml
  volumes:
    - ./config:/factorio/config              # server-settings, map-*, rconpw, lists, server-id
    - ./saves:/factorio/saves                # backup target
    - ./mods:/factorio/mods                  # add/remove mods from host
    - ./scenarios:/factorio/scenarios
    - ./script-output:/factorio/script-output
  ```

- `env_file: .env` for the overlay + orchestration vars. Commit a
  `.env.example`; git-ignore `.env`.
- Keep existing port mappings and `restart: unless-stopped`.
- Retain the commented watchtower service block from the current file.

### 3. Config seeding — `setup.sh` (or `make setup`)

Because we bind-mount real directories, the config JSONs must exist on the host
before `docker compose up`. `setup.sh`:

- Creates `./config`, `./saves`, `./mods`, `./scenarios`, `./script-output`.
- Seeds `./config/{server-settings,map-gen-settings,map-settings}.json` from
  committed reference copies (`config/*.example.json` checked into the repo) if
  the live files don't already exist. **Decision:** commit the reference example
  JSONs into the repo so `setup.sh` needs no image pull and the defaults are
  reviewable in version control. The reference copies are refreshed from the
  image whenever the Factorio version bumps (a note in the publish flow).
- Copies `.env.example` → `.env` if `.env` is absent.
- Is idempotent: never overwrites an existing file.

### 4. Env overlay — renders to temp, never mutates committed files

New script `docker/files/docker-apply-overrides.sh`, invoked from
`docker-entrypoint.sh` immediately after the config seeding block (after
`docker-entrypoint.sh:35`) and before the `FLAGS` array is built.

Behavior:

- Reads the base `$CONFIG/server-settings.json` (the committed, effectively
  read-only source).
- For each mapped env var **that is set**, applies a `jq` patch. Unset env vars
  leave the file value untouched. Precedence: file value → overridden by env var
  when present.
- If **any** override is set, writes the effective config to a writable temp
  path (`/tmp/server-settings.rendered.json`) and exports a variable (e.g.
  `RENDERED_SERVER_SETTINGS`) that the entrypoint uses for `--server-settings`.
  If **no** override is set, the entrypoint uses `$CONFIG/server-settings.json`
  directly.
- Uses `jq` (already installed in the image).

Entrypoint change: `--server-settings` in the `FLAGS` array
(`docker-entrypoint.sh:97`) points at `${RENDERED_SERVER_SETTINGS:-$CONFIG/server-settings.json}`.

Overlay key mapping:

| Env var | JSON path | Type |
|---|---|---|
| `SERVER_NAME` | `.name` | string |
| `SERVER_DESCRIPTION` | `.description` | string |
| `MAX_PLAYERS` | `.max_players` | number |
| `SERVER_VISIBILITY_PUBLIC` | `.visibility.public` | bool |
| `SERVER_VISIBILITY_LAN` | `.visibility.lan` | bool |
| `REQUIRE_USER_VERIFICATION` | `.require_user_verification` | bool |
| `AUTO_PAUSE` | `.auto_pause` | bool |
| `AFK_AUTOKICK_INTERVAL` | `.afk_autokick_interval` | number |
| `ALLOW_COMMANDS` | `.allow_commands` | string (`true`/`false`/`admins-only`) |
| `AUTOSAVE_INTERVAL` | `.autosave_interval` | number |

Type handling: numbers and bools must be injected as JSON scalars, not strings
(`jq --argjson` for numbers/bools, `--arg` for strings). `ALLOW_COMMANDS` stays a
string because Factorio expects the literal `"admins-only"` among its values.

`game_password` (`.game_password`) is intentionally **not** in the overlay set
(not requested); trivial to add later as `GAME_PASSWORD`.

### 5. Preflight checks / debug output

Add a preflight block at entrypoint start (before the seeding block). For each
expected config file (`server-settings.json`, `map-gen-settings.json`,
`map-settings.json`):

- **Path is a directory** → **error and exit** with an actionable message, e.g.
  `ERROR: /factorio/config/server-settings.json is a DIRECTORY. The host file ./config/server-settings.json is missing — run ./setup.sh before 'docker compose up'.`
  (This is the symptom of a single-file bind mount whose host source didn't
  exist.)
- **File missing** → **warn**, then fall back to seeding from the example
  (preserves the current fresh-clone-boots behavior).
- **File present** → **info** line naming the config in use.

Verbose info lines are gated behind `DEBUG=true`; errors and warnings always
print. Implemented with a small helper so the same check covers all three files.

### 6. Read-only stance (recommendation, documented)

- **Container root filesystem read-only:** off by default; note it as optional
  hardening. Blocked by `sed -i` on `config.ini` and ARM box64 setup.
- **`map-gen-settings.json` / `map-settings.json`:** read-only in effect;
  Factorio reads them only at map creation and never writes them.
- **`server-settings.json`:** kept pristine via the render-to-temp mechanism in
  §4, so it's effectively read-only even though the `config` dir must remain
  writable for `rconpw`, `server-id.json`, and the ban/white/admin lists.

### 7. Documentation

- Update `README.md` (and compose comments) to explain: the GHCR image, the two
  config tiers (files vs. env overlay), the overlay key table, `setup.sh`, and
  the publish flow.
- Document the read-only stance from §6.

## Components & responsibilities

| Unit | Purpose | Depends on |
|---|---|---|
| `publish.sh` | Build + push image to GHCR, tagged from `buildinfo.json` | Docker buildx, `gh` auth, `buildinfo.json` |
| `docker-compose.yml` | Run the GHCR image with explicit bind mounts + `.env` | GHCR image, `./config` + data dirs, `.env` |
| `.env.example` | Documented template of overlay + orchestration vars | — |
| `setup.sh` | Seed config files + data dirs before first `up` | example JSONs (committed refs or image) |
| `docker/files/docker-apply-overrides.sh` | Render effective server-settings from base + env overlay | `jq`, base `server-settings.json`, env vars |
| `docker-entrypoint.sh` (edited) | Preflight checks; call overrides script; point `--server-settings` at rendered file | above script |
| `README.md` (edited) | Explain config tiers, overlay table, publish + setup | — |

## Data flow

```
setup.sh ──seeds──▶ ./config/*.json (host, committed/editable)
                          │ bind mount
                          ▼
docker compose up ──▶ /factorio/config/*.json
                          │
docker-entrypoint.sh:
  preflight (dir? missing? present?) ──▶ error/warn/info
  seed-if-missing
  docker-apply-overrides.sh:
     base server-settings.json + set env vars ──jq──▶ /tmp/server-settings.rendered.json
                          │
  FLAGS: --server-settings ${RENDERED_SERVER_SETTINGS:-.../server-settings.json}
                          ▼
                    factorio binary
```

## Error handling

- Missing config file → warn + seed from example (non-fatal).
- Config path is a directory → fatal error with remediation message.
- `jq` failure while rendering overrides → fatal (bad env value should not
  silently produce a broken config).
- No overrides set → skip render entirely; use committed file directly.

## Testing

- **`setup.sh`:** run in a clean checkout → all dirs + config JSONs created;
  re-run → idempotent, no overwrites.
- **Overlay:** with each hot env var set, assert the rendered temp file has the
  expected JSON scalar (correct type for numbers/bools) and the committed source
  file is byte-for-byte unchanged.
- **Overlay off:** no env vars set → entrypoint uses the committed file, no temp
  render produced.
- **Preflight:** simulate a directory at `server-settings.json` path → fatal
  error; simulate missing file → warn + seed; present → info under `DEBUG=true`.
- **Publish:** dry-run/build succeeds and tags are correct (push validated
  manually against GHCR).

## Divergence from upstream

`docker-entrypoint.sh` gains a preflight block, a call to
`docker-apply-overrides.sh`, and a one-token change to the `--server-settings`
flag. This is an intentional divergence from `factoriotools/factorio-docker`,
acceptable because we ship our own GHCR image.

## Open questions

None outstanding. (`publish.sh` builds `linux/amd64,linux/arm64` by default with
an opt-in `--amd64-only` flag.)
