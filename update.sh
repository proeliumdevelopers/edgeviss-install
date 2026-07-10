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

# Detect host architecture and pin the Docker platform so arm64 boards that
# self-report as linux/arm/v8 still pull the correct linux/arm64 manifest.
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PLATFORM="linux/amd64" ;;
  aarch64|arm64) PLATFORM="linux/arm64" ;;
  *)       PLATFORM="linux/amd64" ;;
esac
export DOCKER_DEFAULT_PLATFORM="$PLATFORM"

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${GATEWAY_PORT:-8080}"
CONTAINER="edgeviss-gateway"

# Build compose file args — include platform-compose.yml if present so the
# gateway container joins the platform network and --remove-orphans doesn't
# kill the EdgeX/platform service containers.
COMPOSE_FILES="-f docker-compose.yml"
if [ -f "$INSTALL_DIR/platform-compose.yml" ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f platform-compose.yml"
fi

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
  docker pull --platform "$PLATFORM" "$REGISTRY/$IMAGE:$TARGET" || die "Pull failed — aborting. Gateway unchanged."
  ok "Image pulled"
else
  ok "[dry-run] Would pull $REGISTRY/$IMAGE:$TARGET"
fi

# ── Step 4: Update image tag in compose ───────────────────────────────────────
step "Updating version in docker-compose.yml"
if [ "$DRY_RUN" = "0" ]; then
  sed -i "s|image: .*/${IMAGE}:.*|image: ${REGISTRY}/${IMAGE}:${TARGET}|g" \
    "$INSTALL_DIR/docker-compose.yml" \
    || die "Failed to update docker-compose.yml"
  # Ensure platform: is set immediately after the image: line so docker compose
  # pull works on boards that report linux/arm/v8 instead of linux/arm64.
  if ! grep -q "platform: ${PLATFORM}" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null; then
    sed -i "/image: .*\/${IMAGE}:/a\\    platform: ${PLATFORM}" \
      "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
  fi
  ok "Version updated to $TARGET"
else
  ok "[dry-run] Would update docker-compose.yml to $TARGET"
fi

# ── Step 5: Restart ────────────────────────────────────────────────────────────
step "Restarting gateway"
if [ "$DRY_RUN" = "0" ]; then
  cd "$INSTALL_DIR"
  docker compose $COMPOSE_FILES up -d --remove-orphans gateway || die "docker compose up failed"
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
    docker compose $COMPOSE_FILES up -d --remove-orphans gateway 2>/dev/null || true
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
