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

# --reconfigure re-probes an already-installed gateway's configured EdgeX
# endpoint and wires up ADR-001 secure-mode auth if it finds one. See the
# RECONFIGURE block near the end of this file.
RECONFIGURE=0
for arg in "$@"; do
  [ "$arg" = "--reconfigure" ] && RECONFIGURE=1
done
[ "${EDGEVISS_RECONFIGURE:-0}" = "1" ] && RECONFIGURE=1

REGISTRY="${EDGEVISS_REGISTRY:-ghcr.io/proeliumdevelopers}"
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

# ── Platform gate ──────────────────────────────────────────────────────────────
# This has to run before anything else -- previously the first real check was
# "is Docker installed," which meant running this on the wrong machine (a
# technician's own Windows laptop, most commonly -- EdgeViss Local only ever
# runs ON the gateway itself, never on the laptop provisioning it) failed
# confusingly partway through with a Docker/systemd error that gave no hint
# what actually went wrong. Fail here instead, immediately, with the actual
# fix.
step "Checking this is a supported gateway OS"

KERNEL=$(uname -s)
if [ "$KERNEL" != "Linux" ]; then
  printf "\n" >&2
  err "EdgeViss Local only runs on Linux -- this machine reports '$KERNEL'. \
If you're provisioning a gateway FROM a Windows or Linux laptop, use the EdgeViss \
Provisioner app instead (it SSHes into the real gateway and runs this script there \
for you) -- see the Devices page in EdgeViss Cloud Manager, or \
https://github.com/proeliumdevelopers/edgeviss/tree/main/provisioner."
fi

# Debian/Ubuntu-family only -- not because EdgeViss itself needs anything
# distro-specific, but because the automatic Docker install below (a real
# commercial gap this closes: the old behavior was just linking to Docker's
# docs and giving up) uses apt and Docker's own Debian/Ubuntu convenience
# script. A non-Debian Linux with Docker already installed manually will
# still pass the check right below this one and continue normally -- this
# is a warning, not a hard stop, since EdgeViss itself has no Debian
# dependency, only this installer's auto-install path does.
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *)
      warn "This looks like '${PRETTY_NAME:-an unrecognized distro}', not Debian/Ubuntu. \
EdgeViss itself doesn't require Debian -- but if Docker isn't already installed, this \
script's automatic install (below) only knows how to do that on Debian/Ubuntu. \
Install Docker yourself first if this fails."
      ;;
  esac
else
  warn "Could not read /etc/os-release to confirm this is Debian/Ubuntu -- continuing anyway."
fi
ok "Running on $KERNEL${PRETTY_NAME:+ ($PRETTY_NAME)}"

# ── Prerequisites check ────────────────────────────────────────────────────────
step "Checking prerequisites"

if ! command -v docker >/dev/null 2>&1; then
  warn "Docker not found."
  IS_DEBIAN_FAMILY=0
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) IS_DEBIAN_FAMILY=1 ;;
  esac
  if [ "$IS_DEBIAN_FAMILY" = "1" ]; then
    # Piped installs (curl ... | sh) have stdin already consumed by the
    # script stream itself -- `read` here would read from that stream, not
    # the person running the command. Reading from /dev/tty instead is the
    # standard fix (same trick Docker's, Rustup's, and most other
    # curl-pipe-shell installers use) so this can still ask a real question
    # even when invoked exactly the way this script's own usage comment
    # at the top recommends.
    REPLY=""
    if [ -t 1 ] && [ -r /dev/tty ]; then
      printf "  Install Docker now via Docker's official convenience script \
(curl -fsSL https://get.docker.com | sh)? [y/N] "
      read -r REPLY < /dev/tty || REPLY=""
    fi
    case "$REPLY" in
      y|Y|yes|YES)
        step "Installing Docker"
        curl -fsSL https://get.docker.com | sh
        ok "Docker installed"
        ;;
      *)
        err "Docker is required. Install it from https://docs.docker.com/engine/install/ \
(or re-run this script and answer 'y' to install it automatically), then re-run."
        ;;
    esac
  else
    err "Docker is required, and this script only knows how to auto-install it on \
Debian/Ubuntu. Install it from https://docs.docker.com/engine/install/ and re-run."
  fi
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

# ── Disk space check ───────────────────────────────────────────────────────────
# Cheap to check up front, and directly prevents a disk-full incident at the
# single worst possible time: mid-install, on a customer's brand-new
# hardware, before there's even a running gateway to diagnose the problem
# from. 2GB is a floor, not a comfortable margin -- the platform images
# alone run over 1GB combined.
MIN_FREE_KB=2097152  # 2GB
AVAIL_KB=$(df -Pk "$(dirname "$INSTALL_DIR")" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$MIN_FREE_KB" ]; then
  AVAIL_MB=$((AVAIL_KB / 1024))
  warn "Only ${AVAIL_MB}MB free on this disk -- EdgeViss and its bundled platform images \
need at least 2GB. Installation may fail partway through, or leave no headroom for \
logs/updates afterward. Free up space before continuing if possible."
else
  ok "Disk space OK"
fi

# ── Docker log rotation ────────────────────────────────────────────────────────
# Set once, up front, before any container ever runs on this host. Without
# this, dockerd's json-file default has no size cap — a noisy container's
# logs grow unbounded forever. Found live on a fielded Pi gateway:
# two container logs alone grew to 1.8GB and 770MB and filled the entire
# 15GB root partition, cascading into app failures and failed updates. See
# update.sh's matching retrofit step (Step 4d) for gateways installed before
# this existed.
if [ -f /etc/docker/daemon.json ] && grep -q '"max-size"' /etc/docker/daemon.json 2>/dev/null; then
  ok "Docker log rotation already configured"
else
  if [ ! -f /etc/docker/daemon.json ] || [ ! -s /etc/docker/daemon.json ]; then
    sudo sh -c "cat > /etc/docker/daemon.json" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    sudo systemctl restart docker 2>/dev/null && ok "Configured Docker log rotation (10m x 3 files per container)" \
      || warn "Wrote /etc/docker/daemon.json but could not restart docker — log rotation won't apply until the host restarts docker"
  else
    warn "/etc/docker/daemon.json exists with custom content — add log-opts (max-size/max-file) to it manually, see deploy/update.sh's retrofit step for the merge logic"
  fi
fi

# ── systemd journal size cap ───────────────────────────────────────────────────
# Independent disk-fill risk from the Docker log cap above -- persistent
# journald logging (the Raspberry Pi OS default) has no size cap out of the
# box either, and captures every container's stdout/stderr a second time via
# the journald log driver's own path PLUS all host-level systemd/kernel
# logging. Capped separately so a verbose kernel/systemd log stream alone
# can't refill the disk even with Docker's own logs now bounded.
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
else
  warn "systemd not detected — skipping journal size cap (not applicable on this OS)"
fi

# ── Clock sync check ────────────────────────────────────────────────────────────
# alarm_events.timestamp comes straight from this host's own wall clock
# (time.Now().UTC() in the Go backend) -- there is no per-device timestamp
# anywhere in the alarm pipeline. Found live: a fielded gateway with a
# drifted/unsynced clock produced alarms stamped with the wrong date,
# reading to the customer as "the product is broken" when the actual alarm
# firing was correct and only the recorded date was wrong. A gateway with
# no reliable internet at boot (common on a field Pi) can silently fail to
# sync via NTP and nothing surfaces that until a customer notices a bad
# timestamp. This only checks/enables NTP -- it does not (and cannot from
# software alone) fix a dead RTC battery or correct an already-wrong clock;
# see docs/device-bacnet-custom.md-style field notes for that class of fix.
if command -v timedatectl >/dev/null 2>&1; then
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    ok "System clock is NTP-synchronized"
  else
    sudo timedatectl set-ntp true 2>/dev/null
    sleep 2
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
      ok "Enabled NTP sync — system clock is now synchronized"
    else
      warn "System clock is NOT NTP-synchronized (no network at boot, or NTP blocked) — alarm timestamps on this gateway will be wrong until this syncs. Check 'timedatectl status' once this gateway has internet access."
    fi
  fi
else
  warn "timedatectl not available — could not check NTP sync status"
fi

# ── Reconfigure: EdgeX secure-mode auth detection (ADR-001) ───────────────────
# Only meaningful for EDGEVISS_BUNDLE_PLATFORM=0 (connecting to an existing,
# independently-run EdgeX). The bundled platform stack this installer manages
# itself always runs EdgeX non-secure and has no use for this path. Detection
# is deferred to --reconfigure (rather than attempted during the first-run
# install above) because on first run PLATFORM_METADATA_URL is still the
# placeholder <your-platform-host> -- there is no real endpoint to probe yet.
if [ "$RECONFIGURE" = "1" ]; then
  step "Reconfiguring EdgeX authentication mode"
  [ -f "$INSTALL_DIR/.env" ] || err "$INSTALL_DIR/.env not found — run the installer once before using --reconfigure"

  PLATFORM_URL=$(grep -E '^PLATFORM_METADATA_URL=' "$INSTALL_DIR/.env" | tail -1 | cut -d= -f2-)
  if [ -z "$PLATFORM_URL" ] || printf '%s' "$PLATFORM_URL" | grep -q '<your-platform-host>'; then
    err "PLATFORM_METADATA_URL in $INSTALL_DIR/.env is still the placeholder — set it to your real EdgeX host, then re-run --reconfigure"
  fi
  EDGEX_HOST=$(printf '%s' "$PLATFORM_URL" | sed -E 's#^https?://##; s#[:/].*##')
  ok "Probing EdgeX at $EDGEX_HOST"

  # EdgeX secure mode fronts every service with nginx TLS on :8443. Non-secure
  # mode exposes core-metadata directly on :59881 with nothing in front.
  EDGEX_MODE="unknown"
  if curl -fsSk -o /dev/null --max-time 5 "https://${EDGEX_HOST}:8443/api/v3/ping" 2>/dev/null; then
    EDGEX_MODE="secure"
  elif curl -fsS -o /dev/null --max-time 5 "http://${EDGEX_HOST}:59881/api/v3/ping" 2>/dev/null; then
    EDGEX_MODE="non-secure"
  fi

  case "$EDGEX_MODE" in
    secure)
      ok "Secure-mode EdgeX detected (nginx :8443 responding)"
      TOKEN_FILE="/tmp/edgex/secrets/edgeviss/secrets-token.json"
      if [ -f "$TOKEN_FILE" ]; then
        ok "Service token found at $TOKEN_FILE — EdgeViss shares this host with EdgeX's security stack"
        cp "$(dirname "$0")/add-edgeviss-secrets.yml" "$INSTALL_DIR/add-edgeviss-secrets.yml" 2>/dev/null || \
          curl -fsSL "https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/add-edgeviss-secrets.yml" \
            -o "$INSTALL_DIR/add-edgeviss-secrets.yml" || err "Could not fetch add-edgeviss-secrets.yml"
        if grep -q '^EDGEX_AUTH_MODE=' "$INSTALL_DIR/.env"; then
          sed -i 's/^EDGEX_AUTH_MODE=.*/EDGEX_AUTH_MODE=service/' "$INSTALL_DIR/.env"
        else
          printf '\nEDGEX_AUTH_MODE=service\n' >> "$INSTALL_DIR/.env"
        fi
        ok "EDGEX_AUTH_MODE=service written to .env"
        step "Restarting gateway with secure-mode auth"
        cd "$INSTALL_DIR"
        $COMPOSE -f docker-compose.yml -f add-edgeviss-secrets.yml up -d gateway
        ok "Gateway restarted — service-mode JWT auth active"
      else
        warn "Secure-mode EdgeX detected, but no service token at $TOKEN_FILE"
        warn "Service-mode auth requires EdgeViss and EdgeX's security-secretstore-setup"
        warn "to run on the SAME docker host (it reads a bind-mounted file, not a shared volume)."
        warn "On the EdgeX host's own compose file, add:"
        warn "    security-secretstore-setup:"
        warn "      environment:"
        warn "        ADD_SECRETSTORE_TOKENS: edgeviss"
        warn "then restart security-secretstore-setup and re-run: $0 --reconfigure"
        warn "If EdgeViss runs on a different host than EdgeX, service mode is not available —"
        warn "use 'external' mode instead: set EDGEX_AUTH_TOKEN in .env (see"
        warn "docs/adr-001-edgex-authentication.md for the full explanation)."
      fi
      ;;
    non-secure)
      ok "Non-secure EdgeX detected — no auth token needed (EDGEX_AUTH_MODE auto-detects to 'none')"
      ;;
    *)
      warn "Could not reach EdgeX at $EDGEX_HOST on :8443 or :59881 — check PLATFORM_METADATA_URL and network connectivity"
      ;;
  esac
  exit 0
fi

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
  warn "After editing .env with your real platform host, run: $0 --reconfigure"
  warn "to auto-detect and wire up secure-mode auth if that EdgeX runs secure."
fi

# ── Write .env if it doesn't exist ────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/.env" ]; then
  # Generate a strong random session secret
  SECRET=$(openssl rand -base64 48 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "CHANGE_THIS_TO_A_RANDOM_48_CHAR_STRING")

  # Recovery token: the ONLY way back in if every engineer/admin account's
  # password is lost (see backend/internal/api/auth_password.go's
  # handleRecovery -- POST /api/auth/recovery). Previously this was left
  # unset by install.sh entirely, meaning recovery was silently DISABLED on
  # every gateway installed via this script despite the backend mechanism
  # being fully built -- confirmed live: GATEWAY_RECOVERY_TOKEN had no
  # generation step anywhere in this file. Auto-generating one here, same
  # pattern as SESSION_SECRET above, and printing it once at the end of
  # this script is what actually activates the feature by default.
  RECOVERY_TOKEN=$(openssl rand -hex 24 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "CHANGE_THIS_TO_A_RANDOM_TOKEN")

  # GID of the host's docker.sock — needed so the gateway container (runs as
  # a non-root user) can actually use the socket once mounted, for in-UI
  # self-update (spawns a sibling updater container; see handleSelfUpdate).
  # Without this, the mount succeeds but every docker API call inside the
  # container gets a silent permission-denied.
  DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null \
    || getent group docker 2>/dev/null | cut -d: -f3 \
    || echo "0")

  # Shared secret the optional Connector agent (deploy/connector-install.sh)
  # uses to trigger self-update on this gateway's behalf when Cloud Manager's
  # Devices page sets a target version -- see handleConnectorSelfUpdate in
  # backend/internal/api/system_edgex.go. Only relevant if the Connector is
  # ever installed; harmless if not.
  CONNECTOR_TOKEN=$(openssl rand -hex 24 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "")

  if [ "$BUNDLE_PLATFORM" = "1" ]; then
    PLATFORM_URLS="PLATFORM_METADATA_URL=http://platform-metadata:59881
PLATFORM_DATA_URL=http://platform-data:59880
PLATFORM_COMMAND_URL=http://platform-command:59882
PLATFORM_SCHEDULER_URL=http://platform-scheduler:59863
PLATFORM_NOTIFICATIONS_URL=http://platform-notifications:59860
PLATFORM_RULES_URL=http://platform-rules:59720
PLATFORM_REGISTRY_URL=http://platform-registry:59890"
  else
    PLATFORM_URLS="PLATFORM_METADATA_URL=http://<your-platform-host>:59881
PLATFORM_DATA_URL=http://<your-platform-host>:59880
PLATFORM_COMMAND_URL=http://<your-platform-host>:59882
PLATFORM_SCHEDULER_URL=http://<your-platform-host>:59863
PLATFORM_NOTIFICATIONS_URL=http://<your-platform-host>:59860
PLATFORM_RULES_URL=http://<your-platform-host>:59720
PLATFORM_REGISTRY_URL=http://<your-platform-host>:59890"
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

# Recovery token (auto-generated) — the ONLY way to reset a login if every
# engineer/admin password is lost. Printed once at the end of this install
# script; store it offline (printed copy, password manager) and NOT only in
# this file, since losing this file too means no recovery path at all.
# Use it via the Login page's "Forgot password?" link, or directly:
#   POST /api/auth/recovery {"token": "...", "newPassword": "..."}
GATEWAY_RECOVERY_TOKEN=$RECOVERY_TOKEN

# ── Platform Service Endpoints ────────────────────────────────────────────────
$PLATFORM_URLS

# Registry the bundled platform images are pulled from (only used when
# platform-compose.yml is in play)
MIRROR_REGISTRY=$MIRROR_REGISTRY

# ── In-UI self-update (System → Update) ───────────────────────────────────────
# Both auto-detected above. EDGEVISS_HOST_INSTALL_DIR must be the HOST path to
# this directory (not a path inside any container) — it's bind-mounted 1:1 into
# the short-lived updater container so update.sh's file edits land on the real
# host filesystem. If you move this install directory, update this value.
EDGEVISS_HOST_INSTALL_DIR=$INSTALL_DIR
DOCKER_GID=$DOCKER_GID
CONNECTOR_TOKEN=$CONNECTOR_TOKEN

# Self URL the stream engine (eKuiper) uses to POST alarm evaluations back to
# this gateway -- must match the docker-compose service's container_name
# below (edgeviss-gateway), NOT the backend's built-in default of
# "gateway-ui-api" (that default only matches deploy/docker-compose.yml's dev
# stack, a different service name than what this installer generates). Left
# unset, every alarm setpoint silently never fires -- confirmed live: the
# eKuiper rule shows "running" with zero indication in the UI that its REST
# sink to /api/alarms/evaluate is failing on every single message.
ALARM_INGEST_URL=http://edgeviss-gateway:$PORT

# Optional: comma-separated data export service URLs
# DATA_EXPORT_URLS=http://export-service:59730

# Optional: API token for secured deployments
# PLATFORM_AUTH_TOKEN=

# ── Optional modules (off by default) ────────────────────────────────────────
# The default menu is the core commissioning path: Dashboard, Asset Management,
# Device Control, Data Center, Alarms, System, Audit. These four are advanced/
# admin tools, off by default so a first-time OT engineer isn't shown raw
# platform internals. Uncomment any you actually need, then restart:
#   cd $INSTALL_DIR && docker compose $COMPOSE_FILES restart
# FEATURE_APP_SERVICES=true    # read-only health/config viewer for the northbound pipeline
# FEATURE_RULES=true           # raw stream-engine rule editor (advanced/admin escape hatch)
# FEATURE_SCHEDULER=true       # generic job scheduler, separate from device polling schedules
# FEATURE_NOTIFICATIONS=true   # IT-alerting subscriptions, separate from the Alarms module
ENV
  ok ".env created with auto-generated secret"
  if [ "$BUNDLE_PLATFORM" != "1" ]; then
    warn "IMPORTANT: Edit $INSTALL_DIR/.env to set your platform service endpoint addresses"
  fi
else
  ok ".env already exists — keeping existing configuration"
fi

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
      # Off by default -- advanced/admin tools, not the core OT commissioning
      # path. See the "Optional modules" block in .env to opt in.
      FEATURE_APP_SERVICES: \${FEATURE_APP_SERVICES:-false}
      FEATURE_RULES: \${FEATURE_RULES:-false}
      FEATURE_SCHEDULER: \${FEATURE_SCHEDULER:-false}
      FEATURE_NOTIFICATIONS: \${FEATURE_NOTIFICATIONS:-false}
      PLATFORM_METADATA_URL: \${PLATFORM_METADATA_URL}
      PLATFORM_DATA_URL: \${PLATFORM_DATA_URL}
      PLATFORM_COMMAND_URL: \${PLATFORM_COMMAND_URL}
      PLATFORM_SCHEDULER_URL: \${PLATFORM_SCHEDULER_URL}
      PLATFORM_NOTIFICATIONS_URL: \${PLATFORM_NOTIFICATIONS_URL}
      PLATFORM_RULES_URL: \${PLATFORM_RULES_URL}
      PLATFORM_REGISTRY_URL: \${PLATFORM_REGISTRY_URL}
      PLATFORM_APP_SERVICES_URLS: \${DATA_EXPORT_URLS:-}
      PLATFORM_AUTH_TOKEN: \${PLATFORM_AUTH_TOKEN:-}
      # In-UI self-update (System -> Update) needs both of these to spawn
      # its sibling updater container. Missing EDGEVISS_HOST_INSTALL_DIR
      # disables the feature with a clear message rather than failing oddly.
      EDGEVISS_HOST_INSTALL_DIR: \${EDGEVISS_HOST_INSTALL_DIR:-}
      # Lets the optional Connector agent trigger the same self-update path
      # on this gateway's behalf (see handleConnectorSelfUpdate). Empty =
      # that route always 403s -- safe if the Connector is never installed.
      EDGEVISS_CONNECTOR_TOKEN: \${CONNECTOR_TOKEN:-}
    group_add:
      - "\${DOCKER_GID:-0}"
    volumes:
      - gateway-data:/data
      # Host /dev mounted read-only so the device form's Serial Port scanner
      # can list connected serial/USB adapters (ttyUSB*, ttyACM*, ttyAMA*,
      # ttyS*, video*). Read-only: the backend only enumerates node names.
      - /dev:/host/dev:ro
      # Docker socket + the install dir bind-mounted 1:1 (same host path on
      # both sides) so the sibling updater container this backend spawns for
      # self-update can both control Docker and edit docker-compose.yml/.env
      # at their real host paths. See handleSelfUpdate in
      # backend/internal/api/system_edgex.go for why 1:1 path mounting
      # matters here (Docker-outside-of-Docker: any -v flag issued by a
      # command inside this container is resolved by the HOST daemon).
      - /var/run/docker.sock:/var/run/docker.sock
      - \${EDGEVISS_HOST_INSTALL_DIR:-$INSTALL_DIR}:\${EDGEVISS_HOST_INSTALL_DIR:-$INSTALL_DIR}
      # System -> Reboot Host and the autostart toggle (handleRebootHost /
      # handleGetAutostart / handleSetAutostart) need these two host paths.
      # /etc/systemd/system read-write to create/remove the same enablement
      # symlink "systemctl enable/disable docker" would; the /usr/lib copy
      # read-only just to confirm docker.service's real unit file exists
      # before symlinking to it. Neither needs --privileged; reboot itself
      # (a separate short-lived helper container, not this one) is the only
      # action that does.
      - /etc/systemd/system:/host-systemd
      - /usr/lib/systemd/system:/host-systemd-lib:ro
      # Container has no timezone info of its own -- without this, Go's
      # time.Now() reads UTC, so System -> Scheduled Reboot's HH:MM (entered
      # and documented as host-local time, see system_scheduled_reboot.go)
      # silently fires at the wrong wall-clock hour instead of never at all,
      # which reads to an operator as "the scheduled reboot didn't happen at
      # the time I set." Read-only bind of the host's real zoneinfo file is
      # the standard fix for this in any minimal/scratch container image.
      - /etc/localtime:/etc/localtime:ro
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
  # Guard against a leftover edgeviss-platform-network from a previous failed
  # or partial install/uninstall -- if it exists without Compose's own
  # com.docker.compose.network label, `compose up` refuses to (re)create the
  # platform stack and does so quietly (a WARN, not a failure `set -e` catches).
  # See update.sh's matching check for the full failure-mode writeup.
  PLATFORM_NETWORK="edgeviss-platform-network"
  if docker network inspect "$PLATFORM_NETWORK" >/dev/null 2>&1; then
    NET_LABEL=$(docker network inspect "$PLATFORM_NETWORK" \
      --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null || echo "")
    if [ "$NET_LABEL" != "platform-network" ]; then
      ATTACHED=$(docker network inspect "$PLATFORM_NETWORK" --format '{{len .Containers}}' 2>/dev/null || echo "1")
      if [ "$ATTACHED" = "0" ]; then
        docker network rm "$PLATFORM_NETWORK" >/dev/null 2>&1 \
          && ok "Removed orphaned $PLATFORM_NETWORK from a previous install attempt" \
          || warn "Could not remove orphaned $PLATFORM_NETWORK — platform services may fail to start"
      else
        warn "$PLATFORM_NETWORK exists with the wrong Compose label and has containers attached — not touching it automatically"
      fi
    fi
  fi

  step "Starting platform services (this takes longer on first run — pulling several images)"
  cd "$INSTALL_DIR"
  # DOCKER_DEFAULT_PLATFORM is required here, not optional: `docker compose`
  # resolves each service's platform independently of the `docker pull
  # --platform "$PLATFORM"` done above for the main gateway image (that
  # pull only affects the gateway image's own cache entry). Without this,
  # compose falls back to the host's own Docker-reported default platform,
  # which on a 32-bit userland OS running on 64-bit-capable ARM hardware
  # (a real, common Raspberry Pi OS configuration - 64-bit kernel, 32-bit
  # "Raspbian" userland) resolves to linux/arm/v8 (32-bit) instead of
  # linux/arm64 - and most platform-* images only publish amd64/arm64, so
  # every pull fails with "no matching manifest for linux/arm/v8" even
  # though the arm64 image and a 64-bit-capable kernel are both right
  # there. Confirmed live: identical symptom reproduced on real hardware,
  # fixed by forcing the platform explicitly instead of trusting Docker's
  # host-arch autodetection.
  MIRROR_REGISTRY="$MIRROR_REGISTRY" DOCKER_DEFAULT_PLATFORM="$PLATFORM" $COMPOSE -f platform-compose.yml up -d
  ok "Platform services started"
  step "Waiting for platform services to register (up to 60s)"
  sleep 20
fi

step "Starting gateway"
cd "$INSTALL_DIR"
# Same platform override as the platform-compose.yml invocation above -
# this compose call also resolves platform via host autodetection
# independently of the earlier `docker pull --platform "$PLATFORM"`.
DOCKER_DEFAULT_PLATFORM="$PLATFORM" $COMPOSE $COMPOSE_FILES up -d gateway
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
echo "  ⚠  SAVE THIS PASSWORD RECOVERY TOKEN NOW — shown only this once:"
echo ""
echo "      $RECOVERY_TOKEN"
echo ""
echo "  If every login is ever lost, use this token on the Login page's"
echo "  \"Forgot password?\" link to reset the admin account. It's also"
echo "  saved in $INSTALL_DIR/.env, but store a copy offline too (printed"
echo "  copy, password manager) — losing that file as well means no"
echo "  recovery path exists."
echo ""
