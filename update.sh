#!/bin/sh
# EdgeViss Gateway Updater
# Usage:
#   ./update.sh v0.4.0              — update to specific version (required in production)
#   ./update.sh v0.4.0 --dry-run   — preview steps without applying anything
#   ./update.sh latest              — update to latest (dev/lab only — never use in production)
#
# What this script does:
#   1. Validates the target version
#   2. Backs up the SQLite database before touching anything
#   3. Tags the current image as a rollback target
#   4. Pulls the new image
#   5. Restarts the container
#   6. Waits for the health endpoint to respond
#   7. Auto-rollbacks and exits non-zero if health check fails

set -e

REGISTRY="${EDGEVISS_REGISTRY:-ghcr.io/proeliumdevelopers}"
IMAGE="${EDGEVISS_IMAGE:-edgeviss}"
TARGET="${1:-}"
DRY_RUN=0
[ "$2" = "--dry-run" ] && DRY_RUN=1

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
# install.sh persists GATEWAY_PORT in .env; the updater's own process env (an
# nsenter shell with no compose env) never carries it, so read it the same way
# GATEWAY_ENV is read below. An explicit process env value still wins.
if [ -z "${GATEWAY_PORT:-}" ]; then
  GATEWAY_PORT=$(sed -n 's/^GATEWAY_PORT=//p' "$INSTALL_DIR/.env" 2>/dev/null | tail -1 | tr -d '\r' | tr -d "\"' ")
fi
PORT="${GATEWAY_PORT:-8080}"
CONTAINER="edgeviss-gateway"
# Production updates are deliberately stricter than lab updates. Read the
# persisted installer posture rather than trusting the caller's shell.
DEPLOY_ENV=$(sed -n 's/^GATEWAY_ENV=//p' "$INSTALL_DIR/.env" 2>/dev/null | tail -1)
[ -n "$DEPLOY_ENV" ] || DEPLOY_ENV="development"
IS_PRODUCTION=0
[ "$DEPLOY_ENV" = "production" ] && IS_PRODUCTION=1

# Same platform-detection fix as install.sh: `docker compose` resolves each
# service's platform from the host's own Docker-reported default, which on
# a 32-bit userland OS (common Raspberry Pi OS config even on 64-bit-capable
# hardware/kernel) resolves to linux/arm/v8 instead of linux/arm64 - most
# platform-* images only publish amd64/arm64, so every pull fails with
# "no matching manifest for linux/arm/v8" without this override.
case "$(uname -m)" in
  x86_64)          export DOCKER_DEFAULT_PLATFORM="linux/amd64" ;;
  aarch64|arm64)   export DOCKER_DEFAULT_PLATFORM="linux/arm64" ;;
esac

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()      { printf "${GREEN}  ✓${NC} %s\n" "$1"; }
warn()    { printf "${YELLOW}  !${NC} %s\n" "$1"; }
err()     { printf "${RED}  ✗${NC} %s\n" "$1" >&2; }
step()    { printf "\n${GREEN}▶${NC} %s\n" "$1"; }
die()     { err "$1"; exit 1; }

# ── Argument validation ────────────────────────────────────────────────────────
if [ -z "$TARGET" ]; then
  die "Version required. Usage: ./update.sh v0.4.0"
fi

if [ "$TARGET" = "latest" ]; then
  if [ "$IS_PRODUCTION" = "1" ]; then
    die "Refusing ':latest' on a production gateway. Pin an immutable release tag (for example v0.4.0)."
  fi
  warn "WARNING: ':latest' is allowed only for dev/lab gateways."
  warn "         Pin to a specific version for reproducible production deployments."
fi

# ── Docker reachability in THESE namespaces ──────────────────────────────────
# This script is normally exec'd inside the host's own namespaces (nsenter to
# PID 1, so the host's docker CLI, paths and network apply). On hosts where
# PID 1 is not a normal init -- WSL2 (/init), Docker Desktop VMs -- the
# namespaces entered here have no docker socket: every later docker call
# then fails one by one ("Pull failed", backup skipped as "lab mode") and
# the real cause is invisible. Probe once, up front, and fail fast with the
# exact remedy instead. Exit 67 = docker unreachable in host namespaces
# (the Local UI and Manager both explain it; nothing was changed).
if ! docker info >/dev/null 2>&1; then
  err "Docker is not reachable from the host namespaces this updater runs in."
  err "Typical on WSL2 / Docker Desktop hosts, where PID 1 is not the system init that owns the Docker socket."
  err "Nothing was changed. Run this same updater from the host shell instead:"
  err "  sudo bash $INSTALL_DIR/update.sh $TARGET"
  exit 67
fi

# The running container is the truth: an update that stopped halfway has
# already rewritten docker-compose.yml, and re-running it must not then say
# "already on" while the old version keeps running.
CUR_REF=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null | tr -d ' ')
CURRENT=$(printf '%s' "$CUR_REF" | sed 's/.*://' | tr -d ' ')
[ -n "$CURRENT" ] || CURRENT=$(grep "image:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | head -1 | sed 's/.*://g' | tr -d ' ' || echo "unknown")

echo ""
echo "  EdgeViss Gateway Updater"
echo "  Current : ${CURRENT}"
echo "  Target  : ${TARGET}"
echo "  Gateway : ${DEPLOY_ENV}"
[ "$DRY_RUN" = "1" ] && echo "  Mode    : DRY RUN — no changes will be applied"
echo ""

if [ "$CURRENT" = "$TARGET" ] && [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
  warn "Already on $TARGET — nothing to do"
  exit 0
fi

# ── Disk space: a release's images need room ───────────────────────────────────
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
FREE_MB=$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
if [ "$DRY_RUN" = "0" ] && [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 1500 ]; then
  warn "Only ${FREE_MB} MB free on the Docker disk — removing unused untagged images first"
  docker image prune -f >/dev/null 2>&1 || true
  FREE_MB=$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 1000 ]; then
    die "Only ${FREE_MB} MB free on the Docker disk; at least 1000 MB is needed. Use System → Maintenance → Free disk space, then retry."
  fi
fi

# ── Pre-flight: verify gateway is reachable ────────────────────────────────────
step "Pre-flight health check"
if curl -fsS --max-time 5 "http://localhost:${PORT}/api/health" >/dev/null 2>&1; then
  ok "Gateway is healthy before update"
else
  warn "Gateway is not responding on port ${PORT} — may be stopped or starting"
  warn "Continuing anyway (could be first run or already down)"
fi

# ── Step 1: Consistent SQLite backup ─────────────────────────────────────────
# gateway-ui.db runs in WAL mode. Copying only the live .db file can produce a
# logically incomplete pre-update backup because committed pages may still be in
# gateway-ui.db-wal. Stop only the gateway API long enough for SQLite to close
# cleanly, copy the quiesced DB, then restart the old container before pulling
# or changing any image. Platform/Device Service containers stay running.
step "Creating consistent pre-update database backup"
BACKUP_DIR="$INSTALL_DIR/backups"
BACKUP_FILE="$BACKUP_DIR/pre-update-$(date +%Y%m%d-%H%M%S)-from-${CURRENT}.db"
BACKUP_OK=0
WAS_RUNNING=0

if [ "${EDGEVISS_UPDATE_REEXEC:-0}" = "1" ] && [ -n "${EDGEVISS_BACKUP_FILE:-}" ]; then
  # Re-exec after the self-refresh in step 3b: the first run already took the
  # quiesced backup. Do not stop the gateway and back up a second time; carry
  # the first run's result forward so rollback still restores it.
  BACKUP_FILE="$EDGEVISS_BACKUP_FILE"
  BACKUP_OK="${EDGEVISS_BACKUP_OK:-0}"
  ok "Pre-update database backup already taken by the first run (BACKUP_OK=$BACKUP_OK) — skipping"
elif [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$BACKUP_DIR"
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ] && WAS_RUNNING=1
    if [ "$WAS_RUNNING" = "1" ]; then
      docker stop -t 20 "$CONTAINER" >/dev/null 2>&1 \
        || die "Could not stop $CONTAINER cleanly for the pre-update SQLite backup. Update aborted."
    fi
    if docker cp "${CONTAINER}:/data/gateway-ui.db" "$BACKUP_FILE" 2>/dev/null && [ -s "$BACKUP_FILE" ]; then
      BACKUP_OK=1
      ok "Consistent database backup saved to $BACKUP_FILE"
    fi
    if [ "$WAS_RUNNING" = "1" ]; then
      docker start "$CONTAINER" >/dev/null 2>&1 \
        || die "Backup completed, but the existing gateway could not be restarted. Investigate before updating."
    fi
  fi

  if [ "$BACKUP_OK" != "1" ]; then
    rm -f "$BACKUP_FILE" 2>/dev/null || true
    if [ "$IS_PRODUCTION" = "1" ]; then
      die "A consistent pre-update database backup could not be created. Production update aborted; current gateway left unchanged."
    fi
    warn "Could not create a consistent pre-update database backup (lab mode only — continuing without rollback DB)."
  fi

  # Keep only the newest 10 successful DB backups.
  ls -t "$BACKUP_DIR"/*.db 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
  [ "$BACKUP_OK" = "1" ] && ok "Backup retention: keeping newest 10 database backups in $BACKUP_DIR"
else
  ok "[dry-run] Would stop the gateway API, copy a quiesced WAL-safe database backup, then restart the current gateway"
fi

# ── Step 2: Tag current image as rollback target ───────────────────────────────
step "Saving rollback target"
if [ "$DRY_RUN" = "0" ]; then
  if [ -n "$CUR_REF" ] && docker image inspect "$CUR_REF" >/dev/null 2>&1; then
    # Tag the ACTUAL running image (whatever repository it came from --
    # registry releases and locally-built demo images alike), not just the
    # registry path: on a locally-built gateway the registry ref does not
    # exist and the old code silently created no rollback target at all.
    docker tag "$CUR_REF" "${REGISTRY}/${IMAGE}:rollback" 2>/dev/null \
      && ok "Tagged ${CUR_REF} as :rollback" \
      || warn "Could not tag rollback image"
  elif docker image inspect "${REGISTRY}/${IMAGE}:${CURRENT}" >/dev/null 2>&1; then
    docker tag "${REGISTRY}/${IMAGE}:${CURRENT}" "${REGISTRY}/${IMAGE}:rollback" 2>/dev/null \
      && ok "Tagged ${CURRENT} as :rollback" \
      || warn "Could not tag rollback image (image may have been pruned)"
  else
    warn "Current image ${CUR_REF:-$CURRENT} not found locally — no rollback tag created"
  fi
else
  ok "[dry-run] Would tag ${CUR_REF:-$CURRENT} as :rollback"
fi

# ── Step 3: Pull new image ─────────────────────────────────────────────────────
step "Pulling $REGISTRY/$IMAGE:$TARGET"
if [ "$DRY_RUN" = "0" ]; then
  docker pull "$REGISTRY/$IMAGE:$TARGET" || die "Pull failed — aborting. Gateway unchanged."
  ok "Image pulled"
else
  ok "[dry-run] Would pull $REGISTRY/$IMAGE:$TARGET"
fi

# ── Step 3b: Self-refresh this updater from the pulled image ───────────────────
# An installed update.sh can predate deploy changes that need new update steps
# (e.g. new compose mounts). The image bundles the matching update.sh at
# /update.sh; refresh ours from it and re-exec so the newest logic always runs.
# EDGEVISS_UPDATE_REEXEC guards against an infinite re-exec loop.
if [ "$DRY_RUN" = "0" ] && [ "${EDGEVISS_UPDATE_REEXEC:-0}" != "1" ]; then
  SELF="$INSTALL_DIR/update.sh"
  TMP_SELF="$SELF.new"
  if docker run --rm --entrypoint cat "$REGISTRY/$IMAGE:$TARGET" /update.sh > "$TMP_SELF" 2>/dev/null \
      && [ -s "$TMP_SELF" ]; then
    if ! cmp -s "$TMP_SELF" "$SELF"; then
      step "Refreshing updater from image"
      chmod +x "$TMP_SELF" 2>/dev/null || true
      mv "$TMP_SELF" "$SELF"
      ok "update.sh refreshed — re-running with newest logic"
      EDGEVISS_UPDATE_REEXEC=1 EDGEVISS_BACKUP_FILE="$BACKUP_FILE" EDGEVISS_BACKUP_OK="$BACKUP_OK" exec "$SELF" "$@"
    else
      rm -f "$TMP_SELF"
    fi
  else
    rm -f "$TMP_SELF"
  fi
fi

# ── Step 4: Update image tag in compose ───────────────────────────────────────
step "Updating version in docker-compose.yml"
if [ "$DRY_RUN" = "0" ]; then
  # Every compose edit below is checked before the restart; this copy is
  # what the gateway comes back up on if the edited file does not validate.
  cp "$INSTALL_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml.pre-update"
  # Rewrite the gateway service's own image line, identified by its
  # container_name -- whatever repository it currently points at. Demo/lab
  # gateways run locally-built images (e.g. edgeviss-gateway:0.2.97-local.1),
  # not the registry path: a repo-pattern sed silently matches nothing there
  # and the "update" then restarts the SAME image while reporting success.
  # Two passes over the file (first finds the owning service block, then
  # rewrites its image line) because image: may sit above container_name.
  NEW_REF="${REGISTRY}/${IMAGE}:${TARGET}"
  CF="$INSTALL_DIR/docker-compose.yml"
  if awk -v container="$CONTAINER" -v ref="$NEW_REF" '
    FNR == NR {
      if ($0 ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/) svc = $1
      if ($0 ~ ("^[[:space:]]*container_name:[[:space:]]*" container "[[:space:]]*$")) target = svc
      next
    }
    $0 ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur = $1 }
    cur == target && /^[[:space:]]*image:[[:space:]]*/ { sub(/image:[[:space:]]*.*/, "image: " ref); changed = 1 }
    { print }
    END { exit !(target != "" && changed) }
  ' "$CF" "$CF" > "$CF.tmp"; then
    mv "$CF.tmp" "$CF"
    ok "Gateway image set to $NEW_REF"
  else
    rm -f "$CF.tmp"
    die "docker-compose.yml has no gateway image line to update (no service with container_name ${CONTAINER}). Edit the gateway service's image by hand to ${NEW_REF}, then re-run."
  fi
else
  ok "[dry-run] Would update docker-compose.yml to $TARGET"
fi

# ── Step 4a: Ensure host /dev is mounted for the Serial Port scanner ──────────
# update.sh never re-fetches docker-compose.yml (it only bumps the image tag),
# so features that need a compose change must be patched into the existing file
# here. The device form's "Scan Ports" button needs the gateway container to see
# the host's serial nodes; bind-mount host /dev read-only if it isn't already.
step "Ensuring serial port access (host /dev mount)"
if [ "$DRY_RUN" = "0" ]; then
  if grep -q '/host/dev' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "Host /dev already mounted — serial scan enabled"
  elif grep -q 'gateway-data:/data' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    # Re-use the exact indentation of the existing data volume line for the
    # injected mount so the YAML stays valid.
    sed -i 's|^\(\s*\)- gateway-data:/data|\1- gateway-data:/data\n\1- /dev:/host/dev:ro|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Added read-only host /dev mount for serial port scanning" \
      || warn "Could not patch docker-compose.yml — serial scan may return no ports"
  else
    warn "Could not locate gateway data volume in docker-compose.yml — skipping /dev mount"
    warn "Serial Port scanning will return no results until '- /dev:/host/dev:ro' is added manually"
  fi
else
  ok "[dry-run] Would ensure '- /dev:/host/dev:ro' is present in docker-compose.yml"
fi

# ── Step 4a2: Retrofit self-update + host-management support ──────────────────
# Installs from before self-update (docs/self-update-architecture.md), fleet
# version control, Reboot Host, and the autostart toggle existed won't have
# the .env vars or compose mounts those need. Add them here the same way
# Step 4a retrofits /dev, so upgrading an old install (not just a fresh one)
# gets working System -> Update / Reboot Host / autostart.
step "Ensuring self-update and host-management support"
if [ "$DRY_RUN" = "0" ]; then
  if ! grep -q '^EDGEVISS_HOST_INSTALL_DIR=' "$INSTALL_DIR/.env" 2>/dev/null; then
    printf '\nEDGEVISS_HOST_INSTALL_DIR=%s\n' "$INSTALL_DIR" >> "$INSTALL_DIR/.env"
    ok "Added EDGEVISS_HOST_INSTALL_DIR to .env"
  fi
  if ! grep -q '^CONNECTOR_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null; then
    RETRO_CONNECTOR_TOKEN=$(openssl rand -hex 24 2>/dev/null \
      || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null || echo "")
    printf 'CONNECTOR_TOKEN=%s\n' "$RETRO_CONNECTOR_TOKEN" >> "$INSTALL_DIR/.env"
    ok "Added CONNECTOR_TOKEN to .env"
  fi
  if ! grep -q '^CONNECTOR_LOCAL_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null; then
    RETRO_CONNECTOR_LOCAL_TOKEN=$(openssl rand -hex 24 2>/dev/null \
      || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null || echo "")
    printf 'CONNECTOR_LOCAL_TOKEN=%s\n' "$RETRO_CONNECTOR_LOCAL_TOKEN" >> "$INSTALL_DIR/.env"
    ok "Added CONNECTOR_LOCAL_TOKEN to .env (gateway-ui-api is now the sole Cloud-facing command consumer -- the connector service in docker-compose.yml reads the same value)"
  fi

  # gateway-ui-api no longer needs docker.sock at all -- self-update and
  # Reboot Host both now forward to the edgeviss-connector sidecar's own
  # Docker-privileged local API instead (the "connector" compose service,
  # CONNECTOR_LOCAL_URL/CONNECTOR_LOCAL_TOKEN below). This gateway remains
  # unprivileged with respect to Docker either way -- fresh installs never
  # get the socket mounted; a gateway that got it from an OLDER run of this
  # script has it actively removed here.
  # Scoped to the gateway service only: the connector service legitimately
  # mounts docker.sock, and a file-wide delete left it with an empty
  # volumes: list that failed compose validation and stopped the gateway.
  GW_SOCK_AWK='/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc=$1 } svc=="gateway:" && /^[[:space:]]*- \/var\/run\/docker\.sock:\/var\/run\/docker\.sock[[:space:]]*$/'
  if awk "$GW_SOCK_AWK { found=1 } END { exit !found }" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    if awk "$GW_SOCK_AWK { next } { print }" "$INSTALL_DIR/docker-compose.yml" > "$INSTALL_DIR/docker-compose.yml.tmp"       && mv "$INSTALL_DIR/docker-compose.yml.tmp" "$INSTALL_DIR/docker-compose.yml"; then
      ok "Removed docker.sock mount from gateway-ui-api -- self-update and Reboot Host now go through the Connector sidecar"
      warn "This gateway may still have a now-unused install-dir bind mount and/or group_add left over from an older update -- safe to remove by hand from docker-compose.yml (see deploy/install.sh for the current, clean shape), not required for correctness"
    else
      warn "Could not automatically remove the old docker.sock mount from docker-compose.yml -- gateway-ui-api will keep unused Docker access until this line is removed by hand: '- /var/run/docker.sock:/var/run/docker.sock'"
    fi
  else
    ok "gateway-ui-api has no docker.sock mount"
  fi

  if grep -q '^\s*- /etc/systemd/system:/host-systemd\s*$' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "host-systemd mounts already present (needed by the autostart toggle)"
  elif grep -q '^\(\s*\)- /dev:/host/dev:ro' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)- /dev:/host/dev:ro|\1- /dev:/host/dev:ro\n\1- /etc/systemd/system:/host-systemd\n\1- /usr/lib/systemd/system:/host-systemd-lib:ro|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Added systemd mounts for the autostart toggle" \
      || warn "Could not patch docker-compose.yml — the autostart toggle will 503 until the host-systemd mounts are added manually"
  else
    warn "Could not locate /dev mount anchor in docker-compose.yml — skipping autostart's host-systemd mounts"
    warn "The autostart toggle will 503 until the systemd mounts are added manually (see deploy/install.sh)"
  fi

  if grep -q 'EDGEVISS_CONNECTOR_TOKEN:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "EDGEVISS_CONNECTOR_TOKEN already wired into docker-compose.yml"
  elif grep -q '^\(\s*\)FEATURE_WRITE_COMMANDS:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)FEATURE_WRITE_COMMANDS:.*$|&\n\1EDGEVISS_HOST_INSTALL_DIR: ${EDGEVISS_HOST_INSTALL_DIR:-}\n\1EDGEVISS_CONNECTOR_TOKEN: ${CONNECTOR_TOKEN:-}|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Wired EDGEVISS_HOST_INSTALL_DIR/EDGEVISS_CONNECTOR_TOKEN into the gateway's environment" \
      || warn "Could not wire new env vars into docker-compose.yml — self-update will report EDGEVISS_HOST_INSTALL_DIR missing"
  else
    warn "Could not locate an anchor line to wire EDGEVISS_HOST_INSTALL_DIR/EDGEVISS_CONNECTOR_TOKEN into docker-compose.yml"
  fi

  if grep -q 'CONNECTOR_LOCAL_TOKEN:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "CONNECTOR_LOCAL_TOKEN already wired into docker-compose.yml"
  elif grep -q '^\(\s*\)EDGEVISS_CONNECTOR_TOKEN:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)EDGEVISS_CONNECTOR_TOKEN:.*$|&\n\1CONNECTOR_LOCAL_URL: ${CONNECTOR_LOCAL_URL:-http://edgeviss-connector:8090}\n\1CONNECTOR_LOCAL_TOKEN: ${CONNECTOR_LOCAL_TOKEN:-}|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Wired CONNECTOR_LOCAL_URL/CONNECTOR_LOCAL_TOKEN into the gateway's environment (gateway-ui-api is now the sole Cloud-facing command consumer)" \
      || warn "Could not wire CONNECTOR_LOCAL_URL/CONNECTOR_LOCAL_TOKEN into docker-compose.yml — deployment dispatch to the optional Connector will fail closed until this is added manually"
  else
    warn "Could not locate an anchor line to wire CONNECTOR_LOCAL_URL/CONNECTOR_LOCAL_TOKEN into docker-compose.yml"
  fi

  # group_add existed only to let the non-root gateway user access
  # docker.sock -- now unnecessary (see the docker.sock removal above), and
  # no longer added by a fresh install either. Left in place if present
  # (harmless without the socket mount) rather than risking an automated
  # multi-line removal against a production file; flagged for manual
  # cleanup, same as the install-dir bind mount above.
  if grep -q '^\(\s*\)group_add:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    warn "This gateway has a now-unnecessary 'group_add: [\${DOCKER_GID:-0}]' left over from an older update -- harmless without the docker.sock mount, safe to remove by hand"
  fi

  # Installs from before the timezone mount existed run on UTC wall-clock
  # time inside the container, so Scheduled Reboot's HH:MM (documented and
  # entered as host-local time) silently fires at the wrong hour instead of
  # never at all -- reads to an operator as "the scheduled reboot didn't
  # happen at the time I set." See install.sh's matching mount.
  if grep -q '/etc/localtime:/etc/localtime:ro' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "Host timezone already mounted"
  elif grep -q '^\(\s*\)- /dev:/host/dev:ro' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)- /dev:/host/dev:ro|\1- /dev:/host/dev:ro\n\1- /etc/localtime:/etc/localtime:ro|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Added /etc/localtime mount — Scheduled Reboot now fires at the correct host-local hour" \
      || warn "Could not patch docker-compose.yml — Scheduled Reboot will keep firing on UTC time until this is added manually"
  else
    warn "Could not locate /dev mount anchor in docker-compose.yml — skipping timezone mount"
    warn "Scheduled Reboot will keep firing on UTC time until /etc/localtime is mounted manually (see deploy/install.sh)"
  fi

  # Installs from before ALARM_INGEST_URL was added to install.sh have no
  # value for it in .env, so the gateway binary falls back to its compiled-in
  # default "http://gateway-ui-api:8080" -- which does not resolve on the
  # real docker-compose network, where this container is named
  # "edgeviss-gateway" (see docker-compose.yml's container_name below).
  # Confirmed live on 3 of 4 fleet gateways audited (2026-08-31): every
  # eKuiper alarm rule's REST sink was failing 100% of the time
  # (records_out_total: 0, exceptions_total = every record, error "lookup
  # gateway-ui-api ... no such host") -- meaning NO alarm setpoint, digital
  # or analog, had ever actually reached EdgeViss's evaluator on those
  # gateways, silently, since the day they were commissioned. A real digital
  # HIGHTEMPAL trip on a fielded gateway confirmed this: EdgeX recorded the true/false
  # transition correctly, but zero alarm_event was ever created because the
  # eKuiper sink couldn't reach the backend at all.
  if grep -q '^ALARM_INGEST_URL=' "$INSTALL_DIR/.env" 2>/dev/null; then
    ok "ALARM_INGEST_URL already present"
  else
    echo "ALARM_INGEST_URL=http://edgeviss-gateway:${PORT:-8080}" >> "$INSTALL_DIR/.env" \
      && ok "Added ALARM_INGEST_URL — alarm evaluation can now actually reach this gateway (was silently 0% delivered before)" \
      || warn "Could not add ALARM_INGEST_URL to .env — alarm evaluation will keep silently failing until this is added manually"
    warn "Existing eKuiper alarm rules baked in the old (broken) URL at creation time -- restart the gateway container, then re-run 'Ensure eKuiper Stream' (Alarms module) or recreate affected rules so they pick up the fix"
  fi

  # Batch 5C made /api/alarms/ingest, /api/alarms/evaluate, and
  # /api/sparkplug/ingest fail closed (503) in production when
  # ALARM_INGEST_TOKEN is unset -- a real, deliberate security fix, but one
  # that can silently break alarm ingest on an existing production gateway
  # the moment it upgrades to this version, with no actionable warning if
  # left unhandled (Pre-Batch-6 Gate A). Two distinct .env shapes both count
  # as "genuinely absent" here and both are handled: the key missing
  # entirely (older installs, before ALARM_INGEST_TOKEN existed in
  # install.sh at all) AND the key present with an empty value (every
  # install between Batch 5C's route change and this retrofit landing --
  # deploy/.env.example and pre-5C install.sh both ship the bare
  # "ALARM_INGEST_TOKEN=" line). `grep -q '^ALARM_INGEST_TOKEN='` alone
  # would match the second shape and skip it, silently leaving the token
  # empty -- this checks the actual VALUE, not just whether the key exists.
  #
  # Auto-generating here (not just warning) follows the exact precedent
  # already set for CONNECTOR_TOKEN/CONNECTOR_LOCAL_TOKEN above: a
  # genuinely-empty security token is filled in with fresh cryptographic
  # randomness, same as those. This is filling in an unset value, not
  # rotating an existing secret -- if ALARM_INGEST_TOKEN already has ANY
  # non-empty value, it is never touched.
  EXISTING_ALARM_TOKEN=$(grep '^ALARM_INGEST_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null | tail -1 | cut -d'=' -f2-)
  if [ -n "$EXISTING_ALARM_TOKEN" ]; then
    ok "ALARM_INGEST_TOKEN already configured -- left unchanged"
  else
    RETRO_ALARM_INGEST_TOKEN=$(openssl rand -hex 24 2>/dev/null \
      || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null || echo "")
    if grep -q '^ALARM_INGEST_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null; then
      sed -i "s|^ALARM_INGEST_TOKEN=.*|ALARM_INGEST_TOKEN=${RETRO_ALARM_INGEST_TOKEN}|" "$INSTALL_DIR/.env"
    else
      printf 'ALARM_INGEST_TOKEN=%s\n' "$RETRO_ALARM_INGEST_TOKEN" >> "$INSTALL_DIR/.env"
    fi
    ok "Generated ALARM_INGEST_TOKEN (was unset) -- required for /api/alarms/ingest, /api/alarms/evaluate, and /api/sparkplug/ingest to accept requests once GATEWAY_ENV=production"
    if grep -q '^GATEWAY_ENV=production' "$INSTALL_DIR/.env" 2>/dev/null; then
      warn "GATEWAY_ENV=production: alarm/Sparkplug ingest would have started returning 503 on every request after this upgrade without this token. A token has been generated automatically, but every EXISTING eKuiper alarm/export rule was built without the X-Alarm-Token header -- restart the gateway container, then re-run 'Ensure eKuiper Stream' (Alarms module) and recreate/re-save affected export rules so they pick up the header, the same remediation as the ALARM_INGEST_URL fix above."
    else
      warn "ALARM_INGEST_TOKEN was unset and has been generated -- if this gateway later switches to GATEWAY_ENV=production, existing eKuiper alarm/export rules will need to be recreated/re-saved to include the X-Alarm-Token header (same remediation as the ALARM_INGEST_URL fix above)."
    fi
  fi
else
  ok "[dry-run] Would ensure self-update/host-management .env vars, mounts, group_add, timezone mount, ALARM_INGEST_URL, and ALARM_INGEST_TOKEN are present"
fi

# ── Step 4a3: Connector service + host facts mounts ───────────────────────────
# Installs made before the connector became a compose service (and before
# gateway health read host facts) lack both. Add them in place, then move the
# connector to the target version only when that image is actually pullable,
# so a connector registry problem can never fail or roll back the gateway.
step "Ensuring connector service and host facts mounts"
CONNECTOR_IMAGE="${REGISTRY}/${IMAGE}-connector"
if [ "$DRY_RUN" = "0" ]; then
  COMPOSE_YML="$INSTALL_DIR/docker-compose.yml"
  if grep -q '/host/proc' "$COMPOSE_YML" 2>/dev/null; then
    ok "Host facts mounts already present"
  elif grep -q '^\s*- /dev:/host/dev:ro' "$COMPOSE_YML" 2>/dev/null; then
    sed -i 's|^\(\s*\)- /dev:/host/dev:ro|\1- /dev:/host/dev:ro\n\1- /etc/hostname:/host/etc/hostname:ro\n\1- /proc:/host/proc:ro\n\1- /sys:/host/sys:ro|' "$COMPOSE_YML" \
      && ok "Added read-only host hostname, /proc and /sys mounts (gateway health reports the host)" \
      || warn "Could not add host facts mounts — gateway health will report container values"
  else
    warn "No /dev mount anchor in docker-compose.yml — skipping host facts mounts"
  fi

  if grep -q '^  connector:' "$COMPOSE_YML" 2>/dev/null; then
    ok "Connector service already in docker-compose.yml"
  else
    CONNECTOR_NET=""
    grep -q 'edgeviss-platform-network' "$COMPOSE_YML" 2>/dev/null && CONNECTOR_NET="    networks:
      - edgeviss-platform-network"
    CONNECTOR_BLOCK="  connector:
    image: ${CONNECTOR_IMAGE}:${CURRENT}
    container_name: edgeviss-connector
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: \"10m\"
        max-file: \"3\"
    environment:
      CONNECTOR_LISTEN_ADDR: \":8090\"
      CONNECTOR_LOCAL_TOKEN: \${CONNECTOR_LOCAL_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/systemd/system:/host-systemd
      - /usr/lib/systemd/system:/host-systemd-lib:ro
${CONNECTOR_NET}
"
    # Insert before the top-level volumes: key (end of services:).
    if CB="$CONNECTOR_BLOCK" awk '/^volumes:/ && !done { printf "%s\n", ENVIRON["CB"]; done=1 } { print }' "$COMPOSE_YML" > "$COMPOSE_YML.tmp" \
      && grep -q '^  connector:' "$COMPOSE_YML.tmp"; then
      mv "$COMPOSE_YML.tmp" "$COMPOSE_YML"
      ok "Added connector service to docker-compose.yml"
    else
      rm -f "$COMPOSE_YML.tmp"
      warn "Could not add the connector service — in-UI updates and reboots stay unavailable (see deploy/install.sh)"
    fi
  fi

  # Start on boot moved into the connector (root); older connector services
  # lack the systemd mounts it needs.
  CONN_SYSD_AWK='/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc=$1 } svc=="connector:" && /\/host-systemd:?/ { found=1 } END { exit !found }'
  if grep -q '^  connector:' "$COMPOSE_YML" && ! awk "$CONN_SYSD_AWK" "$COMPOSE_YML"; then
    if awk '/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { svc=$1 } { print } svc=="connector:" && /^[[:space:]]*- \/var\/run\/docker\.sock:\/var\/run\/docker\.sock[[:space:]]*$/ { match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH); print ind "- /etc/systemd/system:/host-systemd"; print ind "- /usr/lib/systemd/system:/host-systemd-lib:ro" }' "$COMPOSE_YML" > "$COMPOSE_YML.tmp"       && awk "$CONN_SYSD_AWK" "$COMPOSE_YML.tmp"; then
      mv "$COMPOSE_YML.tmp" "$COMPOSE_YML"
      ok "Gave the connector the systemd mounts Start on boot needs"
    else
      rm -f "$COMPOSE_YML.tmp"
      warn "Could not add systemd mounts to the connector — Start on boot stays unavailable"
    fi
  fi

  if docker pull "${CONNECTOR_IMAGE}:${TARGET}" >/dev/null 2>&1 || docker image inspect "${CONNECTOR_IMAGE}:${TARGET}" >/dev/null 2>&1; then
    sed -i "s|image: ${CONNECTOR_IMAGE}:.*|image: ${CONNECTOR_IMAGE}:${TARGET}|" "$COMPOSE_YML"
    ok "Connector set to $TARGET"
  else
    warn "Connector image ${CONNECTOR_IMAGE}:${TARGET} is not pullable — keeping the connector on its current image"
  fi
else
  ok "[dry-run] Would ensure the connector service and host facts mounts"
fi

# compose_up starts every service; a connector whose image is not available
# locally is left out so it cannot fail the gateway update.
compose_up() {
  set -- up -d --remove-orphans
  [ -f "$INSTALL_DIR/platform-compose.yml" ] && CF="-f platform-compose.yml -f docker-compose.yml" || CF=""
  CONN_REF=$(sed -n "s|^\s*image: \(${CONNECTOR_IMAGE}:.*\)$|\1|p" "$INSTALL_DIR/docker-compose.yml" | head -1)
  if [ -n "$CONN_REF" ] && ! docker image inspect "$CONN_REF" >/dev/null 2>&1 && ! docker pull "$CONN_REF" >/dev/null 2>&1; then
    warn "Connector image $CONN_REF unavailable — starting everything else"
    # shellcheck disable=SC2086
    docker compose $CF "$@" $(docker compose $CF config --services | grep -vx connector)
  else
    # shellcheck disable=SC2086
    docker compose $CF "$@"
  fi
}

# ── Step 4b: Sync platform-compose.yml (protocol drivers + platform services) ─
# The gateway image bundles the matching platform-compose.yml at build time.
# Extract it so the platform stack always stays in sync with the gateway version.
PLATFORM_COMPOSE="$INSTALL_DIR/platform-compose.yml"
# Remember the internal message broker's container so Step 5 can tell whether
# this update recreated it (see the stream-engine reconnect there).
BROKER_ID_BEFORE=$(docker inspect -f '{{.Id}}' platform-broker 2>/dev/null || echo "")
if [ -f "$PLATFORM_COMPOSE" ]; then
  step "Syncing platform-compose.yml from new gateway image"
  if [ "$DRY_RUN" = "0" ]; then
    # Extract the platform-compose.yml that was baked into this release image
    if docker run --rm --entrypoint cat "$REGISTRY/$IMAGE:$TARGET" \
        /platform-compose.yml > "$PLATFORM_COMPOSE.new" 2>/dev/null \
        && [ -s "$PLATFORM_COMPOSE.new" ]; then
      mv "$PLATFORM_COMPOSE.new" "$PLATFORM_COMPOSE"
      ok "platform-compose.yml updated from the $TARGET image"
      # Pull only. Both compose files form one project, so starting this file
      # alone with --remove-orphans deleted the gateway and connector
      # containers mid-update; the single reconcile of both files happens at
      # the restart step (compose_up).
      docker compose -f "$PLATFORM_COMPOSE" pull --ignore-pull-failures 2>/dev/null || true
      ok "Platform service images pulled"
    else
      rm -f "$PLATFORM_COMPOSE.new"
      warn "Could not extract platform-compose.yml from image — platform stack unchanged"
      warn "If new protocol drivers were added, run: curl -fsSL https://raw.githubusercontent.com/proeliumdevelopers/edgeviss/main/deploy/platform-compose.yml -o $PLATFORM_COMPOSE && docker compose -f $PLATFORM_COMPOSE up -d"
    fi
  else
    ok "[dry-run] Would extract platform-compose.yml from $TARGET image and reconcile platform services"
  fi
fi

# ── Step 4c: Heal an orphaned platform network ─────────────────────────────────
# Real failure mode hit in production: if edgeviss-platform-network ever ends up
# existing without Compose's own com.docker.compose.network label (e.g. it was
# left behind by a prior `docker compose down` that didn't clean up the network,
# or was created outside Compose entirely), every subsequent `docker compose up`
# refuses to proceed at all -- and does so QUIETLY, printing only a WARN line,
# not a failure `die` would catch. The result: the entire platform stack (every
# EdgeX/protocol-driver container) silently never gets (re)created, while the
# gateway container itself still starts and looks "up" -- so this can go
# unnoticed until Data Center/Dashboard show all zeros. Detect and fix this
# before every `up`, not just once at install time, since it can recur any time
# the platform stack is torn down outside a full `docker compose down` on both
# files together.
PLATFORM_NETWORK="edgeviss-platform-network"
if [ "$DRY_RUN" = "0" ] && docker network inspect "$PLATFORM_NETWORK" >/dev/null 2>&1; then
  NET_LABEL=$(docker network inspect "$PLATFORM_NETWORK" \
    --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null || echo "")
  if [ "$NET_LABEL" != "platform-network" ]; then
    step "Healing orphaned platform network"
    # The most common real case is $CONTAINER (edgeviss-gateway) itself still
    # attached -- it typically keeps running while the platform stack around it
    # gets torn down. That's still safe to heal: disconnect our own container,
    # remove the network, and let the `docker compose up` below recreate it
    # correctly and reattach everything (including re-attaching $CONTAINER,
    # since it's one of the services in docker-compose.yml). Only bail out and
    # surface a warning if some OTHER, unrecognized container is attached --
    # that's not ours to touch automatically.
    ATTACHED_NAMES=$(docker network inspect "$PLATFORM_NETWORK" \
      --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
    UNKNOWN_ATTACHED=""
    for name in $ATTACHED_NAMES; do
      [ "$name" = "$CONTAINER" ] && continue
      UNKNOWN_ATTACHED="$UNKNOWN_ATTACHED $name"
    done
    if [ -z "$UNKNOWN_ATTACHED" ]; then
      if [ -n "$ATTACHED_NAMES" ]; then
        docker network disconnect "$PLATFORM_NETWORK" "$CONTAINER" --force >/dev/null 2>&1 \
          && ok "Disconnected $CONTAINER from the orphaned network" \
          || warn "Could not disconnect $CONTAINER — network removal below may fail"
      fi
      docker network rm "$PLATFORM_NETWORK" >/dev/null 2>&1 \
        && ok "Removed orphaned $PLATFORM_NETWORK — Compose will recreate it correctly" \
        || warn "Could not remove $PLATFORM_NETWORK — platform stack may fail to start below"
    else
      warn "$PLATFORM_NETWORK exists with the wrong Compose label AND has unrecognized container(s) attached:$UNKNOWN_ATTACHED"
      warn "Not removing it automatically. Platform services will likely fail to start below."
      warn "Investigate manually: docker network inspect $PLATFORM_NETWORK"
    fi
  fi
fi

# ── Step 4c2: Remote Access capability flag ────────────────────────────────────
# FEATURE_REMOTE_ACCESS defaults to false in the binary and older compose files
# never set it, so Manager Remote Access sessions were refused silently
# (reported "failed") on installs made by install.sh. The .env reaches the
# gateway through env_file; the System toggle and Manager credentials still
# gate every tunnel.
step "Ensuring Remote Access capability"
if [ "$DRY_RUN" = "0" ]; then
  if grep -q '^FEATURE_REMOTE_ACCESS=' "$INSTALL_DIR/.env" 2>/dev/null || grep -q 'FEATURE_REMOTE_ACCESS:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "Remote Access capability already configured"
  else
    printf '\n# Cloud Remote Access capability (System toggle + Manager credentials still gate it)\nFEATURE_REMOTE_ACCESS=true\n' >> "$INSTALL_DIR/.env"
    ok "Enabled the Remote Access capability in .env"
  fi
else
  ok "[dry-run] Would ensure FEATURE_REMOTE_ACCESS is set"
fi

# ── Step 4c3: Docker starts at boot ────────────────────────────────────────────
step "Ensuring Docker starts at boot"
if [ "$DRY_RUN" = "0" ]; then
# Docker must start at boot: every EdgeVISS container has
# restart: unless-stopped, but with docker.service disabled (socket
# activation only) nothing starts dockerd after a reboot, so the gateway
# stays down until someone runs a docker command (found on a fielded
# gateway after its nightly scheduled reboot).
  if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl is-enabled docker 2>/dev/null)" != "enabled" ]; then
    if systemctl enable docker >/dev/null 2>&1; then
    ok "Enabled Docker at boot so EdgeVISS comes back after every reboot"
  else
    warn "Could not enable Docker at boot — after a reboot EdgeVISS stays down until: sudo systemctl start docker (fix: sudo systemctl enable docker)"
  fi
fi
else
  ok "[dry-run] Would ensure docker.service is enabled at boot"
fi

# A legacy Node-RED left running beside EdgeVISS polls the same RS-485 bus:
# two Modbus RTU masters corrupt each other's frames ("unexpected EOF",
# missing readings). It is never stopped automatically -- it may still be
# someone's live flow -- but it is reported every time.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nodered 2>/dev/null; then
  warn "Node-RED is running on this gateway. If it still polls the same devices as EdgeVISS, they collide: on a serial (RS-485) bus frames get corrupted, and Modbus TCP devices that accept only one connection (common for battery and UPS controllers) refuse EdgeVISS entirely, so readings stop. Stop it once EdgeVISS has taken over: sudo systemctl disable --now nodered"
fi

# ── Step 4d: Ensure Docker log rotation (prevent /var filling the root disk) ───
# Found live on a fielded Pi gateway: with no log-driver
# config anywhere, dockerd defaults to json-file with NO size cap, so a noisy
# container's stdout/stderr grows without bound forever. On that gateway two
# container logs alone had grown to 1.8GB and 770MB, filling the 15GB root
# partition to 100% -- app failures, updates failing, services crashing, the
# whole cascade. This is a host-level dockerd default, not something any
# compose `logging:` block can retrofit after the fact for containers already
# running under the old default, so it's fixed once at the daemon level and
# applied to every container on the host, current and future, not just ours.
step "Ensuring Docker log rotation is configured"
if [ "$DRY_RUN" = "0" ]; then
  DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f "$DAEMON_JSON" ] && grep -q '"max-size"' "$DAEMON_JSON" 2>/dev/null; then
    ok "Docker log rotation already configured ($DAEMON_JSON)"
  else
    NEEDS_DOCKER_RESTART=0
    if [ ! -f "$DAEMON_JSON" ] || [ ! -s "$DAEMON_JSON" ]; then
      sudo sh -c "cat > '$DAEMON_JSON'" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
      ok "Created $DAEMON_JSON with 10m x 3 file log rotation (30MB cap per container)"
      NEEDS_DOCKER_RESTART=1
    elif command -v python3 >/dev/null 2>&1; then
      # Existing daemon.json with other keys (registry mirrors, etc.) --
      # merge log-driver/log-opts in rather than clobbering it.
      if sudo python3 -c "
import json, sys
path = '$DAEMON_JSON'
with open(path) as f:
    cfg = json.load(f)
cfg['log-driver'] = 'json-file'
cfg.setdefault('log-opts', {})
cfg['log-opts']['max-size'] = '10m'
cfg['log-opts']['max-file'] = '3'
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null; then
        ok "Merged log rotation into existing $DAEMON_JSON"
        NEEDS_DOCKER_RESTART=1
      else
        warn "$DAEMON_JSON exists with custom content and could not be safely merged (invalid JSON?) — add log-opts manually, see deploy/install.sh"
      fi
    else
      warn "$DAEMON_JSON exists with custom content and python3 is unavailable to merge safely — add log-opts manually, see deploy/install.sh"
    fi

    if [ "$NEEDS_DOCKER_RESTART" = "1" ]; then
      # Never restart dockerd here: this script runs inside the updater
      # container, and restarting the daemon kills that container (exit 137)
      # mid-update with no rollback. install.sh (run by an operator on the
      # host) applies the restart; for an updated gateway the new cap simply
      # takes effect the next time Docker or the host restarts.
      warn "Docker log rotation was written to $DAEMON_JSON but dockerd was NOT restarted (it would kill this updater). It applies at the next Docker or host restart."
    fi
  fi

  # systemd journal size cap -- independent disk-fill risk from Docker logs
  # above (host-level systemd/kernel logging, not just container stdout).
  # See install.sh's matching first-install step for why this is separate
  # from the Docker log-driver cap, not redundant with it.
  if [ -f /etc/systemd/journald.conf.d/edgeviss-log-limit.conf ]; then
    ok "systemd journal size cap already configured"
  elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd ]; then
    sudo mkdir -p /etc/systemd/journald.conf.d
    sudo sh -c "cat > /etc/systemd/journald.conf.d/edgeviss-log-limit.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=20M
EOF
    sudo systemctl restart systemd-journald 2>/dev/null && ok "Configured systemd journal size cap (200MB total)" \
      || warn "Wrote journald.conf.d/edgeviss-log-limit.conf but could not restart systemd-journald — restart it manually or reboot"
  fi
fi

# ── Step 4e: Clock sync check ───────────────────────────────────────────────────
# See install.sh's matching first-install step for the full reasoning:
# alarm_events.timestamp comes straight from this host's wall clock, so a
# gateway whose NTP sync silently failed produces alarms with the wrong
# date. Found live on a fielded gateway. This only checks/enables NTP; it
# cannot correct an already-wrong clock or a dead RTC battery.
step "Checking system clock sync (NTP)"
if [ "$DRY_RUN" = "0" ]; then
  if command -v timedatectl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
      ok "System clock is NTP-synchronized"
    else
      sudo timedatectl set-ntp true 2>/dev/null || true
      sleep 2
      if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        ok "Enabled NTP sync — system clock is now synchronized"
      else
        warn "System clock is NOT NTP-synchronized — alarm timestamps on this gateway will be wrong until this syncs. Check 'timedatectl status' and this gateway's internet access."
      fi
    fi
  else
    warn "timedatectl not available — could not check NTP sync status"
  fi
fi

# Installs from before AUTO_BACKUP_DIR was pinned to /data/backups (see
# deploy/Dockerfile) had auto-backups silently written under /app/backups --
# the OLD container's ephemeral layer, not the persistent /data volume. This
# is the one chance to rescue them: once the container below is recreated
# from the new image, that ephemeral layer is gone for good. Best-effort only
# -- a fresh install, or a gateway that never enabled Auto Backup, has
# nothing at /app/backups and both commands below just no-op.
step "Rescuing any auto-backups from the old container's ephemeral storage"
if [ "$DRY_RUN" = "0" ]; then
  RESCUE_TMP=$(mktemp -d)
  if docker cp "${CONTAINER}:/app/backups" "$RESCUE_TMP/backups" 2>/dev/null \
    && [ -n "$(ls -A "$RESCUE_TMP/backups" 2>/dev/null)" ]; then
    if docker cp "$RESCUE_TMP/backups/." "${CONTAINER}:/data/backups/" 2>/dev/null; then
      ok "Rescued pre-existing auto-backups into the persistent /data/backups volume"
    else
      warn "Found old auto-backups at /app/backups but could not copy them into /data/backups -- they will be lost on restart"
    fi
  else
    ok "No pre-existing auto-backups found under the old ephemeral path — nothing to rescue"
  fi
  rm -rf "$RESCUE_TMP"
else
  ok "[dry-run] Would rescue any auto-backups from /app/backups into /data/backups before restart"
fi

# ── Step 4f: Platform database in its named volume ─────────────────────────────
# postgres 18 keeps its data in /var/lib/postgresql/18/docker, not in
# /var/lib/postgresql/data where earlier platform-compose files mounted the
# named volume: every device, profile and reading lived in an anonymous
# volume that a `docker compose down` or a new container would silently drop.
# platform-compose now mounts the named volume at /var/lib/postgresql; before
# the restart moves onto it, the existing data directory is renamed into the
# named volume (same disk, so instant and needing no free space).
step "Checking the platform database volume"
if [ "$DRY_RUN" = "0" ] && [ -f "$PLATFORM_COMPOSE" ] \
   && grep -qE 'platform-db-data:/var/lib/postgresql([^/]|$)' "$PLATFORM_COMPOSE" \
   && docker inspect platform-database >/dev/null 2>&1; then
  PG_ANON=$(docker inspect -f '{{range .Mounts}}{{if and (eq .Type "volume") (eq .Destination "/var/lib/postgresql")}}{{.Name}}{{end}}{{end}}' platform-database)
  PG_NAMED=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' platform-database)
  if [ -n "$PG_ANON" ] && [ -n "$PG_NAMED" ] && [ "$PG_ANON" != "$PG_NAMED" ]; then
    ANON_DIR=$(docker volume inspect -f '{{.Mountpoint}}' "$PG_ANON")
    NAMED_DIR=$(docker volume inspect -f '{{.Mountpoint}}' "$PG_NAMED")
    if [ -e "$NAMED_DIR/18" ]; then
      warn "The named database volume already holds a database — leaving both volumes as they are"
    elif [ -f "$ANON_DIR/18/docker/PG_VERSION" ]; then
      docker stop -t 60 platform-database >/dev/null \
        || die "Could not stop the platform database to move it — gateway unchanged"
      if mv "$ANON_DIR/18" "$NAMED_DIR/18"; then
        ok "Platform database moved into the named volume $PG_NAMED"
      else
        docker start platform-database >/dev/null 2>&1 || true
        die "Could not move the platform database into $PG_NAMED — gateway unchanged"
      fi
    fi
  else
    ok "Platform database already in its named volume"
  fi
fi

# ── Step 5: Restart ────────────────────────────────────────────────────────────
step "Restarting gateway"
if [ "$DRY_RUN" = "0" ]; then
  cd "$INSTALL_DIR"
  # Always include platform-compose.yml when it exists so both stacks share the
  # same Docker Compose project name. Without this, the gateway and the platform
  # resolve to different project prefixes and volumes can mismatch.
  if [ -f "$INSTALL_DIR/platform-compose.yml" ]; then VCF="-f platform-compose.yml -f docker-compose.yml"; else VCF=""; fi
  # shellcheck disable=SC2086
  if ! docker compose $VCF config -q; then
    err "Edited docker-compose.yml does not validate — restoring the pre-update file and restarting the current version"
    cp "$INSTALL_DIR/docker-compose.yml.pre-update" "$INSTALL_DIR/docker-compose.yml"
    compose_up || true
    die "Update aborted before restart; gateway kept on $CURRENT"
  fi
  if ! compose_up; then
    err "docker compose up failed — restoring the pre-update compose file and restarting the current version"
    cp "$INSTALL_DIR/docker-compose.yml.pre-update" "$INSTALL_DIR/docker-compose.yml"
    compose_up || true
    die "Update aborted: docker compose up failed; gateway kept on $CURRENT"
  fi
  ok "Container started"
  # The stream engine's shared platform source does not reconnect when the
  # internal message broker container is recreated under it: every export
  # and alarm rule keeps showing "running" while receiving nothing (found
  # live on a fielded gateway -- northbound publishing stopped silently after an update
  # recreated platform-broker). Restart it whenever the broker changed.
  BROKER_ID_AFTER=$(docker inspect -f '{{.Id}}' platform-broker 2>/dev/null || echo "")
  if [ -n "$BROKER_ID_BEFORE" ] && [ "$BROKER_ID_BEFORE" != "$BROKER_ID_AFTER" ] ; then
    BROKER_STARTED=$(docker inspect -f '{{.State.StartedAt}}' platform-broker 2>/dev/null || echo "")
    RECONNECTED=""
    for c in $(docker network inspect edgeviss-platform-network --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
      [ "$c" = "platform-broker" ] && continue
      c_started=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null || echo "")
      # started before the new broker => still holding the dead connection
      if [ -n "$c_started" ] && [ "$c_started" != "$BROKER_STARTED" ] && \
         [ "$(printf '%s\n%s\n' "$c_started" "$BROKER_STARTED" | sort | head -1)" = "$c_started" ]; then
        docker restart "$c" >/dev/null 2>&1 && RECONNECTED="$RECONNECTED $c"
      fi
    done
    [ -n "$RECONNECTED" ] && ok "Message broker was recreated — restarted services still on the old connection:$RECONNECTED"
  fi
else
  ok "[dry-run] Would restart container"
  echo ""
  echo "  Dry run complete. Run without --dry-run to apply."
  exit 0
fi

# ── Step 6: Health check with auto-rollback ────────────────────────────────────
# Two failure modes, handled differently:
#   * Crash-loop (the new container keeps exiting): definite failure — fail
#     fast once it has been seen dead 3 checks in a row instead of waiting out
#     the whole window against a container that will never answer.
#   * Running but not healthy yet (slow host, first-boot migrations): be
#     patient — up to 120s, double the old 60s window that rolled back healthy
#     but slow gateways.
# Either way the failed container's own logs are captured BEFORE the rollback
# replaces it: after a rollback `docker logs edgeviss-gateway` only shows the
# OLD version, so without this the reason for the failure is unrecoverable.
step "Waiting for gateway to be healthy (up to 120s)"
TRIES=0
HEALTHY=0
LAST_CODE="no-response"
DEAD_STREAK=0
SAW_RUNNING=0
LAST_EXIT=""
while [ "$TRIES" -lt 60 ]; do
  HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:${PORT}/api/health" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    HEALTHY=1
    break
  fi
  LAST_CODE="$HTTP_CODE"
  # Container state: running | restarting | exited:<code> | missing
  CSTATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
  if [ "$CSTATE" = "running" ] || [ "$CSTATE" = "restarting" ]; then
    SAW_RUNNING=1
    DEAD_STREAK=0
  else
    LAST_EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo "?")
    DEAD_STREAK=$((DEAD_STREAK+1))
    if [ "$DEAD_STREAK" -ge 3 ]; then
      err "New container is ${CSTATE} (exit ${LAST_EXIT}) — it will never become healthy; failing fast"
      break
    fi
  fi
  TRIES=$((TRIES+1))
  sleep 2
done

if [ "$HEALTHY" = "1" ]; then
  ok "Health check passed after $((TRIES * 2))s"
else
  if [ "$SAW_RUNNING" = "1" ]; then
    err "Health check failed after up to 120s (last HTTP ${LAST_CODE}) — rolling back to ${CURRENT}"
  else
    err "New container never stayed running (state ${CSTATE:-missing}, exit ${LAST_EXIT:-?}) — rolling back to ${CURRENT}"
  fi
  echo ""

  # Capture WHY before the rollback destroys the evidence. The updater's own
  # stdout reaches System → Update and Manager through the connector's status
  # logs; the file survives on the host for later inspection.
  UPDATE_LOG_DIR="$INSTALL_DIR/logs"
  UPDATE_LOG_FILE="$UPDATE_LOG_DIR/update-$(echo "$TARGET" | tr -c 'A-Za-z0-9._-' '_')-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$UPDATE_LOG_DIR" 2>/dev/null || true
  {
    echo "EdgeViss update failure: ${CURRENT} -> ${TARGET} ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo "Container state at failure: ${CSTATE:-missing} (exit ${LAST_EXIT:-?}); last /api/health HTTP: ${LAST_CODE}"
    echo "--- docker inspect (State) ---"
    docker inspect -f '{{json .State}}' "$CONTAINER" 2>&1 || echo "(inspect unavailable)"
    echo "--- ${CONTAINER} logs, newest 150 lines (the FAILED version) ---"
    docker logs --tail 150 "$CONTAINER" 2>&1 || echo "(logs unavailable)"
  } > "$UPDATE_LOG_FILE" 2>/dev/null || true
  if [ -s "$UPDATE_LOG_FILE" ]; then
    err "Failure diagnostics saved to $UPDATE_LOG_FILE"
    echo "--- failed version logs (newest 40 lines) ---"
    docker logs --tail 40 "$CONTAINER" 2>/dev/null || tail -40 "$UPDATE_LOG_FILE" 2>/dev/null || true
    echo "--- end of failed version logs ---"
  fi

  # Auto-rollback: restore the pre-update DB (if captured), restore the
  # previous immutable image tag, then bring the exact same compose pair back.
  if docker image inspect "${REGISTRY}/${IMAGE}:rollback" >/dev/null 2>&1; then
    docker stop -t 20 "$CONTAINER" >/dev/null 2>&1 || true

    DB_RESTORED=0
    if [ "$BACKUP_OK" = "1" ] && [ -s "$BACKUP_FILE" ]; then
      # Use the known-old image as a short-lived helper so the restored DB is
      # written as the normal non-root gateway user. Remove WAL/SHM first so
      # pages written by the failed new version cannot be replayed onto the
      # restored pre-update database.
      if docker run --rm --volumes-from "$CONTAINER" \
          -v "$BACKUP_DIR:/backup:ro" \
          --entrypoint sh "${REGISTRY}/${IMAGE}:rollback" \
          -c "rm -f /data/gateway-ui.db /data/gateway-ui.db-wal /data/gateway-ui.db-shm && cp '/backup/$(basename "$BACKUP_FILE")' /data/gateway-ui.db" >/dev/null 2>&1; then
        DB_RESTORED=1
        err "Restored pre-update database before rollback"
      else
        err "WARNING: could not restore pre-update database automatically; old binary may see schema changes made by the failed release"
      fi
    fi

    sed -i "s|image: ${REGISTRY}/${IMAGE}:.*|image: ${REGISTRY}/${IMAGE}:${CURRENT}|g" \
      "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
    cd "$INSTALL_DIR"
    compose_up 2>/dev/null || true
    err "Rolled back to $CURRENT"
    # Exit code 3 = health check failed and the previous version was restored.
    # The gateway reads the updater container's exit status to report
    # "rolled_back" to Manager (any other non-zero exit is a plain failure).
    ROLLED_BACK=1
    [ "$BACKUP_OK" = "1" ] && err "Pre-update backup: $BACKUP_FILE"
    [ "$BACKUP_OK" = "1" ] && [ "$DB_RESTORED" != "1" ] && err "Database restore requires manual verification before returning this gateway to service"
    err "Failure diagnostics (failed-version logs included): ${UPDATE_LOG_FILE:-$INSTALL_DIR/logs/}"
  else
    err "No rollback image available — manual intervention required"
    err "Edit docker-compose.yml back to the previous immutable tag and restore $BACKUP_FILE if the failed release changed the database."
  fi

  [ "${ROLLED_BACK:-0}" = "1" ] && exit 3
  exit 1
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "  Update complete."
echo ""
echo "  Version : $TARGET"
if [ "$BACKUP_OK" = "1" ]; then
  echo "  Backup  : $BACKUP_FILE"
else
  echo "  Backup  : NOT CREATED (lab mode only)"
fi
echo "  Rollback: re-run this updater with the prior immutable version tag if manual rollback is needed"
echo ""
echo "  If anything looks wrong:"
echo "    docker logs $CONTAINER"
echo "    ./update.sh $CURRENT"
echo ""
