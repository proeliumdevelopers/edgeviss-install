#!/bin/sh
# EdgeViss Gateway Installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/install.sh | bash
#   or with a specific version:
#   curl -fsSL .../install.sh | EDGEVISS_VERSION=v0.2.0 bash

set -e

REGISTRY="${EDGEVISS_REGISTRY:-ghcr.io/proeliumdevelopers}"
IMAGE="${EDGEVISS_IMAGE:-edgeviss}"
VERSION="${EDGEVISS_VERSION:-latest}"
INSTALL_DIR="${EDGEVISS_DIR:-/opt/edgeviss}"
PORT="${GATEWAY_UI_PORT:-8080}"

# ── Architecture detection ─────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PLATFORM="linux/amd64" ;;
  aarch64) PLATFORM="linux/arm64" ;;
  arm64)   PLATFORM="linux/arm64" ;;
  armv7l)  printf "\n  ERROR: 32-bit ARM not supported.\n  Install 64-bit Raspberry Pi OS and retry.\n\n"; exit 1 ;;
  *)       PLATFORM="linux/amd64" ;;  # fallback
esac

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

# ── Write .env if it doesn't exist ────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/.env" ]; then
  # Generate a strong random session secret
  SECRET=$(openssl rand -base64 48 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "CHANGE_THIS_TO_A_RANDOM_48_CHAR_STRING")

  cat > "$INSTALL_DIR/.env" << ENV
# ── EdgeViss Gateway Configuration ───────────────────────────────────────────
# Edit this file to connect to your installed platform services.
# After editing, restart with: cd $INSTALL_DIR && docker compose restart

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
# Update these to the hostnames/IPs where your platform services are running.
# If EdgeViss is on the same Docker network as your services, use service names.
# If connecting to external hosts, use IP addresses or hostnames.

PLATFORM_METADATA_URL=http://platform-metadata:59881
PLATFORM_DATA_URL=http://platform-data:59880
PLATFORM_COMMAND_URL=http://platform-command:59882
PLATFORM_SCHEDULER_URL=http://platform-scheduler:59863
PLATFORM_NOTIFICATIONS_URL=http://platform-notifications:59860
PLATFORM_RULES_URL=http://platform-rules:59720

# Optional: comma-separated data export service URLs
# DATA_EXPORT_URLS=http://export-service:59730

# Optional: API token for secured deployments
# PLATFORM_AUTH_TOKEN=
ENV
  ok ".env created with auto-generated secret"
  warn "IMPORTANT: Edit $INSTALL_DIR/.env to set your platform service endpoint addresses"
else
  ok ".env already exists — keeping existing configuration"
fi

# ── Write docker-compose.yml ───────────────────────────────────────────────────
cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSE
services:
  gateway:
    image: ${REGISTRY}/${IMAGE}:${VERSION}
    container_name: edgeviss-gateway
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
    volumes:
      - gateway-data:/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\${GATEWAY_PORT:-$PORT}/api/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3

volumes:
  gateway-data:
COMPOSE
ok "docker-compose.yml written"

# ── Start ──────────────────────────────────────────────────────────────────────
step "Starting gateway"
cd "$INSTALL_DIR"
$COMPOSE up -d
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
echo "  ║   Stop:    cd $INSTALL_DIR && docker compose down    ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""
