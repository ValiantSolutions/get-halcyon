#!/usr/bin/env bash
# Halcyon AI Security — public bootstrap installer.
# Downloads release-owned assets from the private Halcyon repository (customer
# token required) and drives the Docker or EC2 install/upgrade paths.
# Usage: ./halcyon.sh <install-docker|start|upgrade-docker|install-ec2|upgrade-ec2|version> [--tag vX.Y.Z[-rc.N]]
# © Valiant Solutions — provided solely for installing Halcyon
set -euo pipefail

# Stamped by the release publish job; "__UNRELEASED__" means a dev copy.
HALCYON_BOOTSTRAP_VERSION="v0.1.0-rc.9"
# Per-release sha256 of the EC2 installer assets, stamped by the same publish
# job; "__UNSET__" means a dev copy (checksum verification is skipped).
INSTALL_EC2_SHA256="10c297b7dceb52e302803fc96400a72d2f787d2d494d9d5bb50f4623f31db640"
UPDATE_EC2_SHA256="cf100b586b797066206ac204bf2f03ad6d141862a66904f3b4e1b7409044117c"

GITHUB_REPO="ValiantSolutions/Halcyon-AI-Security"
GHCR_USER="valiant-deploy"
HEALTH_URL="http://localhost/health"
HEALTH_TIMEOUT=90
HEALTH_INTERVAL=3
TAG=""
SUBCOMMAND=""
RELEASE_JSON_FILE=""
# In-progress .env temp; holds live secrets, so the trap must remove it.
ENV_TMP_FILE=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { printf '%b%s%b\n' "$YELLOW" "$*" "$NC"; }
good() { printf '%b%s%b\n' "$GREEN" "$*" "$NC"; }
err()  { printf '%b%s%b\n' "$RED" "$*" "$NC" >&2; }
die()  { err "ERROR: $*"; exit 1; }

cleanup() {
  if [ -n "$RELEASE_JSON_FILE" ]; then rm -f -- "$RELEASE_JSON_FILE"; fi
  # A Ctrl-C between mktemp and mv would otherwise leave all three live secrets
  # on disk, where a customer tarring the install dir for backup picks them up.
  if [ -n "${ENV_TMP_FILE:-}" ]; then rm -f -- "$ENV_TMP_FILE"; fi
  # If a failure exits us anywhere between ghcr_login and the normal logout,
  # still drop the credential docker login persisted in ~/.docker/config.json.
  if [ "${GHCR_LOGGED_IN:-0}" = "1" ]; then docker logout ghcr.io; fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Halcyon bootstrap ${HALCYON_BOOTSTRAP_VERSION}
Usage: ./halcyon.sh <subcommand> [--tag vX.Y.Z[-rc.N]]

Subcommands:
  install-docker --tag <tag>  Log in to ghcr.io, download docker-compose.yml,
                              docker/nginx.conf and the .env template from the
                              release, and prepare data/. Stops so you can edit
                              .env — it does NOT start Halcyon.
  start                       Validate .env, run 'docker compose up -d', and
                              wait for the /health endpoint.
  upgrade-docker --tag <tag>  Refresh the release-owned files (docker-compose.yml,
                              docker/nginx.conf), pull the new image, restart.
                              Never touches .env or data/.
  install-ec2 --tag <tag>     (root) Download and run the EC2 installer.
  upgrade-ec2 --tag <tag>     (root) Download and run the EC2 updater.
  version                     Print the bootstrap script version.

Environment:
  GITHUB_TOKEN  Customer deploy token (read:packages, contents:read). Prompted
                for interactively if not set.
  GHCR_TOKEN    Optional override token for the ghcr.io docker login.

Run each command from your Halcyon install directory. Tags are always pinned
explicitly (e.g. v1.2.3 or v1.2.3-rc.1); 'latest' is never used.
EOF
}

banner() {
  info "Halcyon bootstrap ${HALCYON_BOOTSTRAP_VERSION}"
  if [ -n "$TAG" ] && [ "$TAG" != "$HALCYON_BOOTSTRAP_VERSION" ]; then
    printf 'NOTICE: bootstrap script version (%s) differs from --tag (%s); continuing.\n' \
      "$HALCYON_BOOTSTRAP_VERSION" "$TAG"
  fi
}

_validate_tag() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || \
    die "Invalid tag format: $1 (expected v1.2.3 or v1.2.3-rc.1)"
}

require_token() {
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    # Never read the token from stdin: under 'curl | bash' stdin is script
    # text, not the user. Prompt from the terminal, or fail if there is none.
    if { : < /dev/tty; } 2>/dev/null; then
      read -rsp 'Deploy token: ' GITHUB_TOKEN < /dev/tty || { printf '\n' >&2; die "no token provided"; }
      printf '\n' >&2
      export GITHUB_TOKEN
    else
      die "GITHUB_TOKEN is not set and no TTY is available to prompt — set GITHUB_TOKEN in the environment"
    fi
  fi
  [ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN is required and is empty"
}

# Fetch the release JSON for $TAG once per run into a temp file (cleaned by trap).
_fetch_release_json() {
  [ -n "$RELEASE_JSON_FILE" ] && return 0
  RELEASE_JSON_FILE="$(mktemp)"
  curl -sf \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN") \
    -o "$RELEASE_JSON_FILE" \
    "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${TAG}" || {
    err "could not fetch release ${TAG} — check GITHUB_TOKEN and that the tag exists."
    err "Tags look like v1.2.3 or v1.2.3-rc.1. This script always pins an explicit"
    err "tag and never uses 'latest' (GitHub's 'latest' excludes prereleases)."
    exit 1
  }
}

list_release_assets() {
  awk '/"url": *"[^"]*\/releases\/assets\/[0-9]+"/ { in_asset = 1 }
       in_asset && /"name": *"/ { n = $2; gsub(/[",]/, "", n); print "  - " n; in_asset = 0 }' \
    "$RELEASE_JSON_FILE" >&2
}

# Download one named asset from the $TAG release. Lands next to the caller
# (audit trail) unless an explicit destination path is given as $2.
fetch_release_asset() {
  local name="$1" dest="${2:-$1}" asset_url
  _fetch_release_json
  # NOTE: parsing assumes the GitHub API's pretty-printed one-key-per-line JSON.
  # A release *titled* the same as a requested asset name would match the top-level
  # "name" field first, where url is still unset — so that case fails safe (not found).
  asset_url=$(awk -v name="$name" '
    /"url": *"[^"]*\/releases\/assets\/[0-9]+"/ { url = $2; gsub(/[",]/, "", url) }
    index($0, "\"name\": \"" name "\"") { print url; exit }' "$RELEASE_JSON_FILE")
  [ -n "$asset_url" ] || {
    err "asset ${name} not found on release ${TAG}. Available assets:"
    list_release_assets
    exit 1
  }
  # Assumes curl >= 7.58, which stops forwarding Authorization on the cross-host redirect to the asset CDN.
  curl -sfL -H "Accept: application/octet-stream" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN") \
    -o "$dest" "$asset_url" || die "download of ${name} failed"
}

ghcr_login() {
  info "Logging in to ghcr.io as ${GHCR_USER}..."
  printf '%s' "${GHCR_TOKEN:-$GITHUB_TOKEN}" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
  GHCR_LOGGED_IN=1
}

fetch_compose_and_nginx() {
  info "Fetching release-owned files from ${TAG} (docker-compose.yml, docker/nginx.conf)..."
  # Stage both downloads, then move into place only after both succeed — no
  # torn upgrade if the second fetch fails, no transient ./nginx.conf clobber.
  fetch_release_asset docker-compose.yml docker-compose.yml.tmp
  fetch_release_asset nginx.conf nginx.conf.tmp
  mkdir -p docker
  mv -f docker-compose.yml.tmp docker-compose.yml
  mv -f nginx.conf.tmp docker/nginx.conf
}

ensure_data_dir() {
  mkdir -p data
  local owner
  owner="$(stat -c %u data 2>/dev/null || stat -f %u data)"
  [ "$owner" = "1001" ] && return 0
  # The container runs as non-root uid 1001; data/ must be writable by it.
  if [ "$EUID" -eq 0 ]; then
    chown -R 1001:1001 data
  else
    info "Setting data/ owner to uid 1001 (the container user); sudo may prompt."
    sudo chown -R 1001:1001 data
  fi
}

_health_ok() { curl -sf -o /dev/null "$HEALTH_URL"; }

poll_health() {
  info "Waiting for ${HEALTH_URL} (up to ${HEALTH_TIMEOUT}s)..."
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if _health_ok; then
      good "Halcyon is up — ${HEALTH_URL} returned HTTP 200."
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
    waited=$((waited + HEALTH_INTERVAL))
  done
  # One final probe: the last sleep lands exactly at the deadline, so a service
  # that came up in the closing interval still passes the advertised window.
  if _health_ok; then
    good "Halcyon is up — ${HEALTH_URL} returned HTTP 200."
    return 0
  fi
  err "Health check did not pass within ${HEALTH_TIMEOUT}s."
  err "Inspect container state with: docker compose ps   (logs: docker compose logs)"
  exit 1
}

# Random secrets, matching the generators documented in the .env template so a
# customer regenerating one by hand produces the same shape. openssl is the
# fallback because the Docker path may run on a host without python3.
#   hex     -> python3 secrets.token_hex(32)     -> 64 chars of [0-9a-f]
#   urlsafe -> python3 secrets.token_urlsafe(32) -> 43 chars of [A-Za-z0-9_-]
# An explicit command -v branch, not 'python3 ... || openssl ...': under set -e
# a failing command substitution in an assignment exits before any fallback.
gen_secret() {
  local kind="$1" value="" shape='^[0-9a-f]{64}$' pyfn=token_hex
  [ "$kind" = hex ] || { shape='^[A-Za-z0-9_-]{43}$'; pyfn=token_urlsafe; }
  if command -v python3 >/dev/null 2>&1; then
    value="$(python3 -c "import secrets; print(secrets.${pyfn}(32))" || true)"
    # Shape-check here too, not just at the end: a python3 that exits 0 with a
    # truncated value must fall through to openssl rather than kill the install.
    [[ "$value" =~ $shape ]] || value=""
  fi
  if [ -z "$value" ] && command -v openssl >/dev/null 2>&1; then
    if [ "$kind" = hex ]; then value="$(openssl rand -hex 32 || true)"
    else value="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' || true)"; fi
  fi
  # Shape, not just non-empty: catches a truncated or half-written value from a
  # python3/openssl that is present but broken.
  [[ "$value" =~ $shape ]] || die "could not generate a ${kind} secret — install python3 or openssl, then re-run"
  printf '%s' "$value"
}

# Write .env from the template with the three crypto secrets filled in.
# Nothing lands at .env until it has passed validation: a half-written .env
# would be preserved forever by the -e/-L guard and brick every future run.
create_env_with_secrets() {
  local sk ek ps tmp key
  sk="$(gen_secret hex)"; ek="$(gen_secret hex)"; ps="$(gen_secret urlsafe)"
  # Test for ANY collision explicitly. The 'A && B || C' form is SC2015: it is
  # not if-then-else, and it would run die() whenever an earlier test failed for
  # an unexpected reason, not only on a real collision.
  if [ "$sk" = "$ek" ] || [ "$ek" = "$ps" ] || [ "$sk" = "$ps" ]; then
    die "generated secrets are not distinct - aborting"
  fi
  tmp="$(mktemp ./.env.tmp.XXXXXX)"
  ENV_TMP_FILE="$tmp"
  chmod 600 "$tmp"
  # Values reach awk via ENVIRON[], never argv or the program text, so no shell
  # or awk escape processing touches them — injection-safe for any generated
  # byte. ENV_TMP_FILE is set, so the EXIT trap removes the temp on every
  # failure path below (die included) and nothing reaches .env until it passes.
  HALC_SK="$sk" HALC_EK="$ek" HALC_PS="$ps" awk '
    /^SECRET_KEY=$/     { print "SECRET_KEY="     ENVIRON["HALC_SK"]; next }
    /^ENCRYPTION_KEY=$/ { print "ENCRYPTION_KEY=" ENVIRON["HALC_EK"]; next }
    /^PBKDF2_SALT=$/    { print "PBKDF2_SALT="    ENVIRON["HALC_PS"]; next }
    { print }' default.env.template > "$tmp" || die "could not write .env from default.env.template"
  # Verify the GENERATED SHAPE, not merely non-empty: the anchors match only a
  # bare '^KEY=$', so any other template line passes through verbatim and '.+'
  # would bless it — 'PBKDF2_SALT= ' yields an empty salt and
  # 'PBKDF2_SALT=halcyon-ai-security-v1' ships the source-published default,
  # reopening the hole this closes. Template bytes are load-bearing now.
  for key in "SECRET_KEY=[0-9a-f]{64}" "ENCRYPTION_KEY=[0-9a-f]{64}" "PBKDF2_SALT=[A-Za-z0-9_-]{43}"; do
    grep -Eq "^${key}$" "$tmp" || die "${key%%=*} did not receive a generated value — default.env.template must contain a bare '${key%%=*}=' line; nothing was written"
  done
  mv -f "$tmp" .env
  ENV_TMP_FILE=""
  info "Created .env with generated SECRET_KEY, ENCRYPTION_KEY and PBKDF2_SALT.
IMPORTANT: back up .env now — ENCRYPTION_KEY and PBKDF2_SALT cannot be recovered,
and changing them later orphans all encrypted data. See default.env.template."
}

cmd_install_docker() {
  require_token
  ghcr_login
  fetch_compose_and_nginx
  fetch_release_asset default.env.template
  # Front-load the image download so 'start' needs no credentials, then drop
  # the login — docker login persists the token base64'd in ~/.docker/config.json.
  docker compose pull
  docker logout ghcr.io; GHCR_LOGGED_IN=0
  # -e/-L guard: a directory or dangling-symlink .env must also be preserved.
  local generated=0
  if [ -e .env ] || [ -L .env ]; then
    info "Existing .env preserved (never overwritten); default.env.template was"
    info "downloaded alongside it for reference. Its secrets were NOT checked or"
    info "generated — an .env from an older installer may still have them unset."
  else
    # Secrets are generated exactly once, here. A re-run takes the branch above
    # and regenerates nothing — regenerating over a live deployment would orphan
    # every encrypted column.
    create_env_with_secrets
    generated=1
  fi
  ensure_data_dir
  good "Install assets are in place. Halcyon has NOT been started yet."
  printf '\nNext steps:\n'
  printf '  1. Edit .env and set values for:\n'
  printf '       BASE_URL, and Google OAuth (GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET).\n'
  # Only true on the branch that generated them: claiming it on the preserved
  # path would tell an upgrading SE their secrets are set when an .env from the
  # old installer still has all three bare.
  if [ "$generated" = 1 ]; then
    printf '     SECRET_KEY, ENCRYPTION_KEY and PBKDF2_SALT are already generated.\n'
  else
    printf '       plus SECRET_KEY, ENCRYPTION_KEY and PBKDF2_SALT if not already set.\n'
  fi
  printf '     LLM provider keys are configured in the app after first login.\n'
  printf '  2. Then run: ./halcyon.sh start\n'
  exit 0
}

cmd_start() {
  [ -f .env ] || die ".env not found — run './halcyon.sh install-docker --tag <tag>' first, then edit .env"
  local key missing=""
  # PBKDF2_SALT is required in production: unset, the app falls back to a salt
  # published in this repository's source and only logs a warning. Fail closed.
  for key in SECRET_KEY ENCRYPTION_KEY PBKDF2_SALT BASE_URL; do
    grep -Eq "^${key}=.+" .env || missing="${missing} ${key}"
  done
  if [ -n "$missing" ]; then
    err "these required .env keys are missing or empty:${missing}"
    # Existing-deployment case FIRST, stated as the preserving action: an install
    # that already booted encrypted its data under the crypto_utils.py fallback
    # salt, so a fresh value orphans all of it. A hurried operator copies the
    # first instruction — it must be the safe one.
    case "$missing" in *PBKDF2_SALT*)
      err "PBKDF2_SALT is now required:
  Already booted (holds encrypted data)? Set PBKDF2_SALT=halcyon-ai-security-v1
    — the default it has been using. Any other value orphans that data; move off
    the default later via the migrate_encryption.py rotation flow.
  Never booted? Generate one:
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))'" ;;
    esac
    exit 1
  fi
  # Credential-free by design: install-docker/upgrade-docker already pulled
  # the image and logged out of ghcr.io.
  docker compose up -d
  poll_health
}

cmd_upgrade_docker() {
  require_token
  ghcr_login
  fetch_compose_and_nginx
  info ".env and data/ are never touched by upgrade-docker."
  docker compose pull
  docker logout ghcr.io; GHCR_LOGGED_IN=0
  docker compose up -d
  poll_health
}

# Byte-level integrity for the EC2 scripts we exec as root. The publish job
# stamps per-release sha256 values next to HALCYON_BOOTSTRAP_VERSION.
verify_ec2_checksum() {
  local file="$1" expected="$2" actual
  if [ "$expected" = "__UNSET__" ]; then
    printf 'NOTICE: unstamped dev bootstrap — skipping checksum verification of %s.\n' "$(basename "$file")"
    return 0
  fi
  if [ "$TAG" != "$HALCYON_BOOTSTRAP_VERSION" ]; then
    printf 'NOTICE: integrity verification unavailable — this bootstrap is stamped %s but --tag is %s.\n' \
      "$HALCYON_BOOTSTRAP_VERSION" "$TAG"
    printf 'NOTICE: fetch the bootstrap published with %s to enable checksum verification.\n' "$TAG"
    return 0
  fi
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $(basename "$file") (expected ${expected}, got ${actual}) — the download does not match the published release and may have been tampered with; not executing"
}

# install-ec2 / upgrade-ec2: download the release's own installer and delegate.
cmd_ec2() {
  local script="$1" expected_sha="$2" stage
  [ "$EUID" -eq 0 ] || \
    die "${SUBCOMMAND} must run as root — re-run with: sudo -E ./halcyon.sh ${SUBCOMMAND} --tag ${TAG}"
  require_token
  info "Fetching ${script} from release ${TAG}..."
  # Stage in a private tempdir (mktemp -d creates it 0700): downloading into
  # the CWD and exec'ing as root is a TOCTOU window in a shared directory.
  stage="$(mktemp -d)"
  fetch_release_asset "$script" "${stage}/${script}"
  [ -s "${stage}/${script}" ] || die "downloaded ${script} is empty — not executing"
  verify_ec2_checksum "${stage}/${script}" "$expected_sha"
  bash -n "${stage}/${script}" || die "downloaded ${script} failed a syntax check (bash -n) — not executing"
  chmod +x "${stage}/${script}"
  info "Delegating to ${stage}/${script} --tag ${TAG}"
  # Clean only the release-JSON tempfile here. The staging dir intentionally
  # outlives the exec (EXIT traps do not survive exec) and persists for the
  # delegated installer's lifetime by design.
  cleanup
  exec "${stage}/${script}" --tag "$TAG"
}

# ── Argument parsing and dispatch ─────────────────────────────────────
[ $# -ge 1 ] || { usage >&2; exit 1; }
SUBCOMMAND="$1"
shift
case "$SUBCOMMAND" in
  -h|--help|help) usage; exit 0 ;;
  version) printf '%s\n' "$HALCYON_BOOTSTRAP_VERSION"; exit 0 ;;
  install-docker|start|upgrade-docker|install-ec2|upgrade-ec2) ;;
  *) err "Unknown subcommand: ${SUBCOMMAND}"; usage >&2; exit 1 ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)
      [ -n "${2:-}" ] || die "--tag requires a value (e.g. --tag v1.2.3)"
      TAG="$2"
      shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Validate the tag BEFORE any network use — it is interpolated into URLs.
if [ -n "$TAG" ]; then
  _validate_tag "$TAG"
fi
case "$SUBCOMMAND" in
  install-docker|upgrade-docker|install-ec2|upgrade-ec2)
    [ -n "$TAG" ] || die "--tag is required for ${SUBCOMMAND} (e.g. --tag v1.2.3)" ;;
  start)
    [ -z "$TAG" ] || die "start takes no --tag — use upgrade-docker to change versions" ;;
esac

banner
case "$SUBCOMMAND" in
  install-docker) cmd_install_docker ;;
  start)          cmd_start ;;
  upgrade-docker) cmd_upgrade_docker ;;
  install-ec2)    cmd_ec2 install-ec2.sh "$INSTALL_EC2_SHA256" ;;
  upgrade-ec2)    cmd_ec2 update-ec2.sh "$UPDATE_EC2_SHA256" ;;
esac
