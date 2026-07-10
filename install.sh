#!/bin/sh
# EdgeViss Gateway Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/install.sh | bash
#   or with a specific version:
#   curl -fsSL .../install.sh | EDGEVISS_VERSION=v0.2.0 bash
#
# By default this installs EdgeViss AND its backing platform services
# together — one command, fully self-contained, nothing else to set up.
# If you already have an existing platform deployment to connect to
# instead, set EDGEVISS_BUNDLE_PLATFORM=0 and configure the endpoint URLs
# in .env after install.

set -e

REGISTRY="${EDGEVISS_REGISTRY:-dataviss}"
IMAGE="${EDGEVISS_IMAGE:-edgeviss}"
VERSION="${EDGEVISS_VERSION:-latest}"
INSTALL_DIR="${EDGEVISS_DIR:-/opt/edgeviss}"
PORT="${GATEWAY_UI_PORT:-8080}"
BUNDLE_PLATFORM="${EDGEVISS_BUNDLE_PLATFORM:-1}"
# Registry the bundled platform images are pulled from — defaults to our own
# mirror (see deploy/mirror-platform-images.sh), never the upstream project's.
MIRROR_REGISTRY="${EDGEVISS_MIRROR_REGISTRY:-ghcr.io/proeliumdevelopers}"

# ── Architecture detection ─────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PLATFORM="linux/amd64" ;;
  aarch64) PLATFORM="linux/arm64" ;;
  arm64)   PLATFORM="linux/arm64" ;;
  armv7l|armv6l|armhf)
    printf "\n  ERROR: 32-bit ARM (%s) is not supported.\n\n" "$ARCH" >&2
    printf "  This is not an EdgeViss limitation — the platform services this\n" >&2
    printf "  installer bundles have never published a 32-bit ARM build, at any\n" >&2
    printf "  version. There is no 32-bit build to fall back to.\n\n" >&2
    printf "  Fix: reflash this gateway with 64-bit Raspberry Pi OS (or any other\n" >&2
    printf "  64-bit OS for your board) and re-run this installer.\n" >&2
    printf "  https://www.raspberrypi.com/software/  → choose the 64-bit image.\n\n" >&2
    exit 1
    ;;
  *)       PLATFORM="linux/amd64" ;;  # fallback
esac

# Some arm64 boards (Raspberry Pi with certain Docker builds) self-report as
# linux/arm/v8 instead of linux/arm64 when docker compose pulls without an
# explicit --platform flag. DOCKER_DEFAULT_PLATFORM pins the correct value for
# all subsequent docker compose calls in this script.
export DOCKER_DEFAULT_PLATFORM="$PLATFORM"

# ── Colour output ─────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { printf "${GREEN}  ✓${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}  !${NC} %s\n" "$1"; }
err()  { printf "${RED}  ✗${NC} %s\n" "$1" >&2; exit 1; }
step() { printf "\n${GREEN}▶${NC} %s\n" "$1"; }

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   EdgeViss Gateway Installer         ║"
echo "  ║   Version: ${VERSION}                "
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Prerequisites check ────────────────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v docker >/dev/null 2>&1; then
  err "Docker is required. Install it from https://docs.docker.com/engine/install/ and re-run."
fi
ok "Docker found"

DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
ok "Docker version: $DOCKER_VERSION"

# Check docker compose (plugin or standalone)
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  err "Docker Compose is required. Install the Docker Compose plugin and re-run."
fi
ok "Docker Compose found"

# ── Pull image ─────────────────────────────────────────────────────────────────
step "Pulling gateway image  ($REGISTRY/$IMAGE:$VERSION for $PLATFORM)"
docker pull --platform "$PLATFORM" "$REGISTRY/$IMAGE:$VERSION"
ok "Image ready"

# ── Create install directory ───────────────────────────────────────────────────
step "Creating installation at  $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy update script
cp "$(dirname "$0")/update.sh" "$INSTALL_DIR/update.sh" 2>/dev/null || \
  curl -fsSL "https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/update.sh" \
    -o "$INSTALL_DIR/update.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/update.sh" 2>/dev/null || true

# ── Bundled platform stack (default) ──────────────────────────────────────────
COMPOSE_FILES="-f docker-compose.yml"
if [ "$BUNDLE_PLATFORM" = "1" ]; then
  step "Fetching bundled platform services"
  cp "$(dirname "$0")/platform-compose.yml" "$INSTALL_DIR/platform-compose.yml" 2>/dev/null || \
    curl -fsSL "https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/platform-compose.yml" \
      -o "$INSTALL_DIR/platform-compose.yml" || err "Could not fetch platform-compose.yml"
  COMPOSE_FILES="-f docker-compose.yml -f platform-compose.yml"
  ok "Bundled platform stack ready"
else
  warn "EDGEVISS_BUNDLE_PLATFORM=0 — connecting to an existing platform deployment instead"
fi

# ── Write .env if it doesn't exist ────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/.env" ]; then
  # Generate a strong random session secret
  SECRET=$(openssl rand -base64 48 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "CHANGE_THIS_TO_A_RANDOM_48_CHAR_STRING")

  if [ "$BUNDLE_PLATFORM" = "1" ]; then
    PLATFORM_URLS="PLATFORM_METADATA_URL=http://platform-metadata:59881
PLATFORM_DATA_URL=http://platform-data:59880
PLATFORM_COMMAND_URL=http://platform-command:59882
PLATFORM_SCHEDULER_URL=http://platform-scheduler:59863
PLATFORM_NOTIFICATIONS_URL=http://platform-notifications:59860
PLATFORM_RULES_URL=http://platform-rules:59720"
  else
    PLATFORM_URLS="PLATFORM_METADATA_URL=http://<your-platform-host>:59881
PLATFORM_DATA_URL=http://<your-platform-host>:59880
PLATFORM_COMMAND_URL=http://<your-platform-host>:59882
PLATFORM_SCHEDULER_URL=http://<your-platform-host>:59863
PLATFORM_NOTIFICATIONS_URL=http://<your-platform-host>:59860
PLATFORM_RULES_URL=http://<your-platform-host>:59720"
  fi

  cat > "$INSTALL_DIR/.env" << ENV
# ── EdgeViss Gateway Configuration ───────────────────────────────────────────
# Edit this file to connect to your platform services.
# After editing, restart with: cd $INSTALL_DIR && docker compose $COMPOSE_FILES restart

GATEWAY_PORT=$PORT
# Starts in "development" mode so it runs immediately on a fresh gateway with
# no TLS in front of it yet. Once you put a reverse proxy (Nginx/Caddy) with
# real HTTPS in front of this gateway, switch to:
#   GATEWAY_ENV=production
#   SESSION_SECURE=true
# (the backend refuses to start in production mode without HTTPS-only
# cookies — that's intentional, not a bug to work around).
GATEWAY_ENV=development

# Security (auto-generated — do not share this value)
SESSION_SECRET=$SECRET
SESSION_SECURE=false   # Set to true when serving over HTTPS (required once GATEWAY_ENV=production)

# ── Platform Service Endpoints ────────────────────────────────────────────────
$PLATFORM_URLS

# Registry the bundled platform images are pulled from (only used when
# platform-compose.yml is in play)
MIRROR_REGISTRY=$MIRROR_REGISTRY

# Optional: comma-separated data export service URLs
# DATA_EXPORT_URLS=http://export-service:59730

# Optional: API token for secured deployments
# PLATFORM_AUTH_TOKEN=

# Update notifications — polls GitHub releases to show "Update available" in the System UI.
# Clear this value to disable on air-gapped sites.
UPDATE_CHECK_URL=https://api.github.com/repos/proeliumdevelopers/edgeviss/releases/latest
ENV
  ok ".env created with auto-generated secret"
  if [ "$BUNDLE_PLATFORM" != "1" ]; then
    warn "IMPORTANT: Edit $INSTALL_DIR/.env to set your platform service endpoint addresses"
  fi
else
  ok ".env already exists — keeping existing configuration"
fi

# ── Pin PLATFORM in .env for docker compose image pulls ───────────────────────
# Some arm64 boards (including Raspberry Pi with certain Docker builds) report
# linux/arm/v8 as their platform to Docker instead of linux/arm64.  The
# platform-compose.yml services use `platform: ${PLATFORM}` which overrides
# daemon auto-detection and requests the correct manifest directly.
if grep -q "^PLATFORM=" "$INSTALL_DIR/.env" 2>/dev/null; then
  sed -i "s|^PLATFORM=.*|PLATFORM=$PLATFORM|" "$INSTALL_DIR/.env"
else
  printf "\n# Host architecture — used by platform-compose.yml to pin manifest pulls.\nPLATFORM=%s\n" "$PLATFORM" >> "$INSTALL_DIR/.env"
fi
ok "Host platform pinned: $PLATFORM"

# ── Write docker-compose.yml ───────────────────────────────────────────────────
NETWORK_BLOCK=""
NETWORK_REF=""
if [ "$BUNDLE_PLATFORM" = "1" ]; then
  NETWORK_BLOCK="networks:
      - edgeviss-platform-network"
  NETWORK_REF="
networks:
  edgeviss-platform-network:
    external: true
    name: edgeviss-platform-network"
fi

cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSE
services:
  gateway:
    image: ${REGISTRY}/${IMAGE}:${VERSION}
    platform: ${PLATFORM}
    container_name: edgeviss-gateway
    pull_policy: always
    restart: unless-stopped
    ports:
      - "\${GATEWAY_PORT:-$PORT}:\${GATEWAY_PORT:-$PORT}"
    env_file:
      - .env
    environment:
      GATEWAY_UI_PORT: \${GATEWAY_PORT:-$PORT}
      GATEWAY_ENV: \${GATEWAY_ENV:-production}
      SESSION_SECRET: \${SESSION_SECRET}
      SESSION_SECURE: \${SESSION_SECURE:-false}
      WRITE_COMMANDS_ENABLED: \${WRITE_COMMANDS_ENABLED:-false}
      FEATURE_WRITE_COMMANDS: \${FEATURE_WRITE_COMMANDS:-false}
      FEATURE_APP_SERVICES: \${FEATURE_APP_SERVICES:-true}
      FEATURE_RULES: \${FEATURE_RULES:-true}
      FEATURE_SCHEDULER: \${FEATURE_SCHEDULER:-true}
      FEATURE_NOTIFICATIONS: \${FEATURE_NOTIFICATIONS:-true}
      PLATFORM_METADATA_URL: \${PLATFORM_METADATA_URL}
      PLATFORM_DATA_URL: \${PLATFORM_DATA_URL}
      PLATFORM_COMMAND_URL: \${PLATFORM_COMMAND_URL}
      PLATFORM_SCHEDULER_URL: \${PLATFORM_SCHEDULER_URL}
      PLATFORM_NOTIFICATIONS_URL: \${PLATFORM_NOTIFICATIONS_URL}
      PLATFORM_RULES_URL: \${PLATFORM_RULES_URL}
      PLATFORM_APP_SERVICES_URLS: \${DATA_EXPORT_URLS:-}
      PLATFORM_AUTH_TOKEN: \${PLATFORM_AUTH_TOKEN:-}
      UPDATE_CHECK_URL: \${UPDATE_CHECK_URL:-}
      EDGEVISS_SELF_IMAGE: ${REGISTRY}/${IMAGE}:${VERSION}
    volumes:
      - gateway-data:/data
      # Docker socket — allows the gateway to pull its own image update from the
      # System UI without requiring SSH access. Mounted read-only is not supported
      # for unix sockets; the daemon controls access via socket permissions (root/docker group).
      - /var/run/docker.sock:/var/run/docker.sock
    # Go 1.22+ uses the rseq (restartable-sequences) syscall on Linux/arm64
    # for goroutine scheduling. Docker's default seccomp profile blocks rseq
    # on some Raspberry Pi / embedded kernel configurations, causing the
    # process to exit immediately with SIGSYS (exit code 159).
    # seccomp:unconfined removes that restriction for this container only.
    security_opt:
      - seccomp:unconfined
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\${GATEWAY_PORT:-$PORT}/api/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
    $NETWORK_BLOCK

volumes:
  gateway-data:
$NETWORK_REF
COMPOSE
ok "docker-compose.yml written"

# ── Start ──────────────────────────────────────────────────────────────────────
if [ "$BUNDLE_PLATFORM" = "1" ]; then
  step "Starting platform services (this takes longer on first run — pulling several images)"
  cd "$INSTALL_DIR"
  MIRROR_REGISTRY="$MIRROR_REGISTRY" $COMPOSE -f platform-compose.yml up -d
  ok "Platform services started"
  step "Waiting for platform services to register (up to 60s)"
  sleep 20
fi

step "Starting gateway"
cd "$INSTALL_DIR"
$COMPOSE $COMPOSE_FILES up -d gateway
ok "Gateway started"

# ── Wait for health ────────────────────────────────────────────────────────────
step "Waiting for gateway to be ready (up to 30s)"
TRIES=0
until curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  [ "$TRIES" -gt 15 ] && warn "Health check timed out — gateway may still be starting" && break
  sleep 2
done
[ "$TRIES" -le 15 ] && ok "Gateway is healthy"

# ── Done ───────────────────────────────────────────────────────────────────────
GATEWAY_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   EdgeViss is running!                               ║"
echo "  ║                                                      ║"
echo "  ║   Open:  http://${GATEWAY_IP}:${PORT}               "
echo "  ║                                                      ║"
echo "  ║   First time? The browser will guide you to         ║"
echo "  ║   create your admin account.                        ║"
echo "  ║                                                      ║"
echo "  ║   Config:  $INSTALL_DIR/.env                        "
echo "  ║   Update:  $INSTALL_DIR/update.sh                   "
echo "  ║   Stop:    cd $INSTALL_DIR && docker compose $COMPOSE_FILES down  "
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
