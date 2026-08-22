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
PORT="${GATEWAY_PORT:-8080}"
CONTAINER="edgeviss-gateway"

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
  warn "WARNING: ':latest' should never be used in production."
  warn "         Pin to a specific version (e.g. v0.4.0) for reproducible deployments."
  warn "         Continuing — assume this is a dev/lab environment."
fi

CURRENT=$(grep "image:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null | head -1 | sed 's/.*://g' | tr -d ' ' || echo "unknown")

echo ""
echo "  EdgeViss Gateway Updater"
echo "  Current : ${CURRENT}"
echo "  Target  : ${TARGET}"
[ "$DRY_RUN" = "1" ] && echo "  Mode    : DRY RUN — no changes will be applied"
echo ""

if [ "$CURRENT" = "$TARGET" ]; then
  warn "Already on $TARGET — nothing to do"
  exit 0
fi

# ── Pre-flight: verify gateway is reachable ────────────────────────────────────
step "Pre-flight health check"
if curl -fsS --max-time 5 "http://localhost:${PORT}/api/health" >/dev/null 2>&1; then
  ok "Gateway is healthy before update"
else
  warn "Gateway is not responding on port ${PORT} — may be stopped or starting"
  warn "Continuing anyway (could be first run or already down)"
fi

# ── Step 1: Backup SQLite database ────────────────────────────────────────────
step "Backing up database"
BACKUP_DIR="$INSTALL_DIR/backups"
BACKUP_FILE="$BACKUP_DIR/pre-update-$(date +%Y%m%d-%H%M%S)-from-${CURRENT}.db"

if [ "$DRY_RUN" = "0" ]; then
  mkdir -p "$BACKUP_DIR"
  # Copy SQLite file directly from the running container's data volume
  if docker cp "${CONTAINER}:/data/gateway-ui.db" "$BACKUP_FILE" 2>/dev/null; then
    ok "Database backed up to $BACKUP_FILE"
  else
    # Container may not be running — try to copy from the volume directly
    warn "Could not copy from running container, trying volume mount"
    VOLUME_NAME=$(docker inspect "$CONTAINER" 2>/dev/null \
      | grep -o '"gateway-data"' | head -1 || true)
    if [ -n "$VOLUME_NAME" ]; then
      docker run --rm \
        -v "$(cd "$INSTALL_DIR" && docker compose -f docker-compose.yml config --volumes 2>/dev/null | head -1 || echo gateway-data):/data" \
        alpine cp /data/gateway-ui.db "/backup/$(basename "$BACKUP_FILE")" 2>/dev/null \
        && ok "Database backed up via volume" \
        || warn "Backup failed — proceeding without backup (container may be down)"
    else
      warn "Container not running — skipping backup, proceeding with update"
    fi
  fi
  # Keep only last 10 backups
  ls -t "$BACKUP_DIR"/*.db 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
  ok "Backup retention: keeping last 10 backups in $BACKUP_DIR"
else
  ok "[dry-run] Would back up database to $BACKUP_FILE"
fi

# ── Step 2: Tag current image as rollback target ───────────────────────────────
step "Saving rollback target"
if [ "$DRY_RUN" = "0" ]; then
  if docker image inspect "${REGISTRY}/${IMAGE}:${CURRENT}" >/dev/null 2>&1; then
    docker tag "${REGISTRY}/${IMAGE}:${CURRENT}" "${REGISTRY}/${IMAGE}:rollback" 2>/dev/null \
      && ok "Tagged ${CURRENT} as :rollback" \
      || warn "Could not tag rollback image (image may have been pruned)"
  else
    warn "Current image ${CURRENT} not found locally — no rollback tag created"
  fi
else
  ok "[dry-run] Would tag ${CURRENT} as :rollback"
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
      EDGEVISS_UPDATE_REEXEC=1 exec "$SELF" "$@"
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
  sed -i "s|image: ${REGISTRY}/${IMAGE}:.*|image: ${REGISTRY}/${IMAGE}:${TARGET}|g" \
    "$INSTALL_DIR/docker-compose.yml" \
    || die "Failed to update docker-compose.yml"
  ok "Version updated to $TARGET"
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
  if ! grep -q '^DOCKER_GID=' "$INSTALL_DIR/.env" 2>/dev/null; then
    RETRO_DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null \
      || getent group docker 2>/dev/null | cut -d: -f3 || echo "0")
    printf 'DOCKER_GID=%s\n' "$RETRO_DOCKER_GID" >> "$INSTALL_DIR/.env"
    ok "Added DOCKER_GID to .env"
  fi
  if ! grep -q '^CONNECTOR_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null; then
    RETRO_CONNECTOR_TOKEN=$(openssl rand -hex 24 2>/dev/null \
      || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null || echo "")
    printf 'CONNECTOR_TOKEN=%s\n' "$RETRO_CONNECTOR_TOKEN" >> "$INSTALL_DIR/.env"
    ok "Added CONNECTOR_TOKEN to .env"
  fi

  if grep -q '/var/run/docker.sock:/var/run/docker.sock' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "Docker socket already mounted"
  elif grep -q '^\(\s*\)- /dev:/host/dev:ro' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)- /dev:/host/dev:ro|\1- /dev:/host/dev:ro\n\1- /var/run/docker.sock:/var/run/docker.sock\n\1- '"$INSTALL_DIR"':'"$INSTALL_DIR"'\n\1- /etc/systemd/system:/host-systemd\n\1- /usr/lib/systemd/system:/host-systemd-lib:ro|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Added docker.sock, install-dir, and systemd mounts for self-update / Reboot Host / autostart" \
      || warn "Could not patch docker-compose.yml — self-update, Reboot Host, and autostart will 503 until this is added manually"
  else
    warn "Could not locate /dev mount anchor in docker-compose.yml — skipping self-update/host-management mounts"
    warn "Self-update, Reboot Host, and autostart will 503 until docker.sock and the systemd mounts are added manually (see deploy/install.sh)"
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

  if grep -q '^\(\s*\)group_add:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    ok "group_add already present"
  elif grep -q '^\(\s*\)healthcheck:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i 's|^\(\s*\)healthcheck:|\1group_add:\n\1  - "${DOCKER_GID:-0}"\n\1healthcheck:|' \
      "$INSTALL_DIR/docker-compose.yml" \
      && ok "Added group_add so the non-root gateway user can actually use docker.sock" \
      || warn "Could not add group_add — docker.sock calls will get permission denied"
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
else
  ok "[dry-run] Would ensure self-update/host-management .env vars, mounts, group_add, and timezone mount are present"
fi

# ── Step 4b: Sync platform-compose.yml (protocol drivers + platform services) ─
# The gateway image bundles the matching platform-compose.yml at build time.
# Extract it so the platform stack always stays in sync with the gateway version.
PLATFORM_COMPOSE="$INSTALL_DIR/platform-compose.yml"
if [ -f "$PLATFORM_COMPOSE" ]; then
  step "Syncing platform-compose.yml from new gateway image"
  if [ "$DRY_RUN" = "0" ]; then
    # Extract the platform-compose.yml that was baked into this release image
    if docker run --rm --entrypoint cat "$REGISTRY/$IMAGE:$TARGET" \
        /platform-compose.yml > "$PLATFORM_COMPOSE.new" 2>/dev/null \
        && [ -s "$PLATFORM_COMPOSE.new" ]; then
      mv "$PLATFORM_COMPOSE.new" "$PLATFORM_COMPOSE"
      ok "platform-compose.yml updated from v$TARGET image"
      # Start any new platform services added in this release (no restart of existing)
      MIRROR_REGISTRY="${MIRROR_REGISTRY:-ghcr.io/proeliumdevelopers}"
      docker compose -f "$PLATFORM_COMPOSE" pull --ignore-pull-failures 2>/dev/null || true
      docker compose -f "$PLATFORM_COMPOSE" up -d --remove-orphans 2>/dev/null \
        && ok "Platform services reconciled" \
        || warn "Platform service reconcile had warnings — check: docker compose -f platform-compose.yml ps"
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

# ── Step 4d: Ensure Docker log rotation (prevent /var filling the root disk) ───
# Found live on a fielded Pi gateway (GW-019, 2026-08-21): with no log-driver
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
      if sudo systemctl restart docker 2>/dev/null; then
        ok "Restarted dockerd to apply log rotation (existing container logs are NOT retroactively truncated by this alone)"
        # Existing json-file logs already on disk keep growing under the
        # OLD unbounded behavior until Docker itself rotates them on next
        # write past the new cap -- for a host that's already near-full
        # (like GW-019 was), truncate now so the fix has effect immediately
        # rather than waiting for organic rotation.
        sudo find /var/lib/docker/containers/ -name '*-json.log' -size +10M -exec truncate -s 0 {} \; 2>/dev/null \
          && ok "Truncated existing oversized container logs (>10MB) to apply the new cap immediately" \
          || true
      else
        warn "Could not restart dockerd — log rotation is configured in $DAEMON_JSON but won't take effect until the host is rebooted or docker is restarted manually"
      fi
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
      sudo timedatectl set-ntp true 2>/dev/null
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

# ── Step 5: Restart ────────────────────────────────────────────────────────────
step "Restarting gateway"
if [ "$DRY_RUN" = "0" ]; then
  cd "$INSTALL_DIR"
  # Always include platform-compose.yml when it exists so both stacks share the
  # same Docker Compose project name. Without this, the gateway and the platform
  # resolve to different project prefixes and volumes can mismatch.
  if [ -f "$INSTALL_DIR/platform-compose.yml" ]; then
    docker compose -f platform-compose.yml -f docker-compose.yml up -d --remove-orphans || die "docker compose up failed"
  else
    docker compose up -d --remove-orphans || die "docker compose up failed"
  fi
  ok "Container started"
else
  ok "[dry-run] Would restart container"
  echo ""
  echo "  Dry run complete. Run without --dry-run to apply."
  exit 0
fi

# ── Step 6: Health check with auto-rollback ────────────────────────────────────
step "Waiting for gateway to be healthy (up to 60s)"
TRIES=0
HEALTHY=0
while [ "$TRIES" -lt 30 ]; do
  if curl -fsS --max-time 3 "http://localhost:${PORT}/api/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  TRIES=$((TRIES+1))
  sleep 2
done

if [ "$HEALTHY" = "1" ]; then
  ok "Health check passed after $((TRIES * 2))s"
else
  err "Health check failed after 60s — rolling back to ${CURRENT}"
  echo ""

  # Auto-rollback: restore previous compose tag and restart
  if docker image inspect "${REGISTRY}/${IMAGE}:rollback" >/dev/null 2>&1; then
    sed -i "s|image: ${REGISTRY}/${IMAGE}:.*|image: ${REGISTRY}/${IMAGE}:rollback|g" \
      "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
    docker compose up -d --remove-orphans 2>/dev/null || true
    err "Rolled back to $CURRENT"
    err "Investigate with: docker logs $CONTAINER"
    err "Backup saved at:  $BACKUP_FILE"
  else
    err "No rollback image available — manual intervention required"
    err "Run: docker compose down && edit docker-compose.yml manually"
  fi

  exit 1
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "  Update complete."
echo ""
echo "  Version : $TARGET"
echo "  Backup  : $BACKUP_FILE"
echo "  Rollback: ./update.sh rollback  (uses the :rollback tag saved above)"
echo ""
echo "  If anything looks wrong:"
echo "    docker logs $CONTAINER"
echo "    ./update.sh $CURRENT"
echo ""
