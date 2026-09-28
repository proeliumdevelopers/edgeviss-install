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
INSTALL_MODE="${EDGEVISS_INSTALL_MODE:-lab}"
# KIOSK=1 (--kiosk): gateway with a screen -- open Local full-screen on the
# local display at every login. KIOSK=0 (--headless, default): no screen,
# open http://<gateway-ip>:<port> from any PC. Same install either way.
KIOSK="${EDGEVISS_KIOSK:-0}"
# Fresh installs are TCP-hardened unless RTU access is explicitly requested.
# Existing .env files are never rewritten by this installer, so an already-
# fielded RTU gateway keeps its current privilege/device-access posture.
MODBUS_RTU_MODE="${EDGEVISS_ENABLE_MODBUS_RTU:-0}"
for arg in "$@"; do
  [ "$arg" = "--reconfigure" ] && RECONFIGURE=1
  [ "$arg" = "--production" ] && INSTALL_MODE="production"
  [ "$arg" = "--lab" ] && INSTALL_MODE="lab"
  [ "$arg" = "--kiosk" ] && KIOSK=1
  [ "$arg" = "--headless" ] && KIOSK=0
  [ "$arg" = "--modbus-rtu" ] && MODBUS_RTU_MODE="1"
  [ "$arg" = "--modbus-tcp-only" ] && MODBUS_RTU_MODE="0"
done
[ "${EDGEVISS_RECONFIGURE:-0}" = "1" ] && RECONFIGURE=1
case "$INSTALL_MODE" in
  production|lab) : ;;
  *) printf "ERROR: EDGEVISS_INSTALL_MODE must be 'production' or 'lab'\n" >&2; exit 1 ;;
esac
case "$MODBUS_RTU_MODE" in
  0|1) : ;;
  *) printf "ERROR: EDGEVISS_ENABLE_MODBUS_RTU must be 0 or 1\n" >&2; exit 1 ;;
esac
if [ "$INSTALL_MODE" = "production" ] && [ "${EDGEVISS_EXTERNAL_HTTPS:-0}" != "1" ]; then
  printf "\nERROR: production install requires HTTPS in front of EdgeViss.\n" >&2
  printf "Set EDGEVISS_EXTERNAL_HTTPS=1 only after configuring the reverse proxy/TLS endpoint,\n" >&2
  printf "then re-run with --production (or EDGEVISS_INSTALL_MODE=production).\n\n" >&2
  exit 1
fi

REGISTRY="${EDGEVISS_REGISTRY:-ghcr.io/proeliumdevelopers}"
IMAGE="${EDGEVISS_IMAGE:-edgeviss}"
VERSION="${EDGEVISS_VERSION:-latest}"
INSTALL_DIR="${EDGEVISS_DIR:-/opt/edgeviss}"
# Must run as root: it writes /opt/edgeviss, /etc/docker and systemd files.
if [ "$(id -u)" != "0" ]; then
  printf "\nERROR: run the installer as root, e.g.\n  curl -fsSL https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/install.sh | sudo bash\n\n" >&2
  exit 1
fi
# "latest" (the default) means the newest released vX.Y.Z image, resolved
# from the registry's public tag list and then pinned, so the gateway records
# an exact version and later updates/rollbacks are reproducible. Only if the
# registry cannot be read does it fall back to the floating :latest tag.
if [ "$VERSION" = "latest" ]; then
  _GHCR_TOKEN=$(curl -fsSL -m 15 "https://ghcr.io/token?scope=repository:${EDGEVISS_REGISTRY_REPO:-proeliumdevelopers/edgeviss}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  # Newest first; a release counts only once its connector image is
  # published too (the two images are pushed one after the other).
  _CONN_REPO="${EDGEVISS_REGISTRY_REPO:-proeliumdevelopers/edgeviss}-connector"
  _CONN_TOKEN=$(curl -fsSL -m 15 "https://ghcr.io/token?scope=repository:${_CONN_REPO}:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  _LATEST=""
  for _TAG in $(curl -fsSL -m 15 -H "Authorization: Bearer ${_GHCR_TOKEN}" \
      "https://ghcr.io/v2/${EDGEVISS_REGISTRY_REPO:-proeliumdevelopers/edgeviss}/tags/list?n=1000" 2>/dev/null \
    | tr ',' '\n' | tr -d '"[]{} ' | sed 's/^tags://' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | head -5); do
    if curl -fsS -m 15 -o /dev/null -H "Authorization: Bearer ${_CONN_TOKEN}" \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
        "https://ghcr.io/v2/${_CONN_REPO}/manifests/${_TAG}" 2>/dev/null; then
      _LATEST="$_TAG"
      break
    fi
  done
  if [ -n "$_LATEST" ]; then
    VERSION="$_LATEST"
    printf "Newest released version: %s\n" "$VERSION"
  else
    printf "WARNING: could not read the release list; installing the floating ':latest' tag\n" >&2
  fi
fi
# Production must be reproducible. An unpinned floating tag makes rollback and
# site acceptance impossible to tie to exact bytes.
if [ "$INSTALL_MODE" = "production" ] && [ "$VERSION" = "latest" ]; then
  printf "\nERROR: production install requires a pinned EDGEVISS_VERSION (for example v1.2.3); ':latest' is not accepted.\n\n" >&2
  exit 1
fi
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
  # os-release defines its own VERSION (e.g. "13 (trixie)"); sourcing it
  # directly would clobber the EdgeVISS image tag held in $VERSION.
  _EV_VERSION="$VERSION"
  . /etc/os-release
  VERSION="$_EV_VERSION"
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
    # EDGEVISS_INSTALL_DOCKER=1 answers yes without asking (used by the
    # Manager's Windows/WSL path, which has no usable terminal for a prompt).
    [ "${EDGEVISS_INSTALL_DOCKER:-0}" = "1" ] && REPLY="y"
    if [ -z "$REPLY" ] && [ -t 1 ] && [ -r /dev/tty ]; then
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

# The daemon must be running, not just installed. WSL and fresh installs may
# not have started it yet.
if ! docker info >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || err "Docker is installed but its service is not running. Start it (sudo systemctl start docker, or on WSL: sudo service docker start) and re-run."
  ok "Docker service started"
fi

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

# A legacy Node-RED left running beside EdgeVISS polls the same RS-485 bus:
# two Modbus RTU masters corrupt each other's frames ("unexpected EOF",
# missing readings). It is never stopped automatically -- it may still be
# someone's live flow -- but it is reported every time.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nodered 2>/dev/null; then
  warn "Node-RED is running on this gateway. If it still polls the same devices as EdgeVISS, they collide: on a serial (RS-485) bus frames get corrupted, and Modbus TCP devices that accept only one connection (common for battery and UPS controllers) refuse EdgeVISS entirely, so readings stop. Stop it once EdgeVISS has taken over: sudo systemctl disable --now nodered"
fi

DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
ok "Docker version: $DOCKER_VERSION"

# Docker Compose v2 ("docker compose") is required. The legacy Python
# docker-compose 1.x crashes against current Docker ("KeyError:
# 'ContainerConfig'" when recreating a container) and cannot read the labels
# v2 writes, so it is never used. When the plugin is missing (e.g. apt's
# docker.io, or Docker Desktop's WSL integration running as root), the
# official plugin binary is installed.
COMPOSE_V2_VERSION="${EDGEVISS_COMPOSE_VERSION:-v2.29.7}"
if ! docker compose version >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64|amd64)  COMPOSE_ARCH="x86_64" ;;
    aarch64|arm64) COMPOSE_ARCH="aarch64" ;;
    armv7l)        COMPOSE_ARCH="armv7" ;;
    *)             COMPOSE_ARCH="" ;;
  esac
  [ -n "$COMPOSE_ARCH" ] || err "Docker Compose v2 is required and cannot be installed automatically on $(uname -m). Install the Docker Compose plugin and re-run."
  step "Installing Docker Compose $COMPOSE_V2_VERSION"
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_V2_VERSION}/docker-compose-linux-${COMPOSE_ARCH}"     -o /usr/local/lib/docker/cli-plugins/docker-compose     && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose     || err "Could not download Docker Compose v2. Install the Docker Compose plugin and re-run."
  docker compose version >/dev/null 2>&1 || err "Docker Compose v2 was installed but 'docker compose' still does not work. Install the Docker Compose plugin and re-run."
fi
COMPOSE="docker compose"
ok "Docker Compose found ($(docker compose version --short 2>/dev/null || echo v2))"

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
    mkdir -p /etc/docker
    sh -c "cat > /etc/docker/daemon.json" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    systemctl restart docker 2>/dev/null && ok "Configured Docker log rotation (10m x 3 files per container)" \
      || warn "Wrote /etc/docker/daemon.json but could not restart docker — log rotation won't apply until the host restarts docker"
  elif command -v python3 >/dev/null 2>&1 && python3 - <<'PY'
import json
p = "/etc/docker/daemon.json"
with open(p) as f:
    cfg = json.load(f)
cfg.setdefault("log-driver", "json-file")
opts = cfg.setdefault("log-opts", {})
opts.setdefault("max-size", "10m")
opts.setdefault("max-file", "3")
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
PY
  then
    systemctl restart docker 2>/dev/null && ok "Merged Docker log rotation into the existing /etc/docker/daemon.json" \
      || warn "Merged log rotation into /etc/docker/daemon.json but could not restart docker — it applies after the next docker restart"
  else
    warn "/etc/docker/daemon.json has custom content that could not be merged automatically — every EdgeVISS container still caps its own logs (10m x 3) through docker-compose"
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
  mkdir -p /etc/systemd/journald.conf.d
  sh -c "cat > /etc/systemd/journald.conf.d/edgeviss-log-limit.conf" <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=20M
EOF
  systemctl restart systemd-journald 2>/dev/null && ok "Configured systemd journal size cap (200MB total)" \
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
    timedatectl set-ntp true 2>/dev/null || true
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

# ── Existing installation: upgrade in place ────────────────────────────────────
# Re-running the installer on a gateway that already has EdgeVISS keeps its
# .env (secrets, settings) and its data volume; the compose file is rewritten
# for this version. The database is copied first so the upgrade can be undone.
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  PREV_VERSION=$(sed -n "s|^\s*image: ${REGISTRY}/${IMAGE}:\(.*\)$|\1|p" "$INSTALL_DIR/docker-compose.yml" | head -1)
  step "Existing installation found (${PREV_VERSION:-unknown version}) — upgrading in place to $VERSION"
  DATA_VOL=$(docker volume ls -q | grep -E '(^|_)gateway-data$' | head -1)
  if [ -n "$DATA_VOL" ]; then
    mkdir -p "$INSTALL_DIR/backups"
    BK="pre-install-$(date +%Y%m%d-%H%M%S)-from-${PREV_VERSION:-unknown}"
    if docker run --rm --user root --entrypoint sh -v "$DATA_VOL":/data:ro -v "$INSTALL_DIR/backups":/backup \
        "$REGISTRY/$IMAGE:$VERSION" -c "for f in /data/gateway-ui.db /data/gateway-ui.db-wal /data/gateway-ui.db-shm; do [ -f \"\$f\" ] && cp \"\$f\" \"/backup/$BK.\${f##*.}\"; done; [ -f /backup/$BK.db ]" >/dev/null 2>&1; then
      ok "Database backed up to $INSTALL_DIR/backups/$BK.db"
    else
      warn "Could not back up the database before upgrading — continuing (settings and data stay in volume $DATA_VOL)"
    fi
  fi
else
  step "New installation"
fi

# ── Create install directory ───────────────────────────────────────────────────
step "Creating installation at  $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Copy update script
cp "$(dirname "$0")/update.sh" "$INSTALL_DIR/update.sh" 2>/dev/null || \
  curl -fsSL "https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/update.sh" \
    -o "$INSTALL_DIR/update.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/update.sh" 2>/dev/null || true

# Copy the read-only production posture preflight alongside update.sh so the
# handover command printed at the end of this installer always refers to a
# real installed file, not the source checkout the installer may have been
# piped from.
cp "$(dirname "$0")/production-preflight.sh" "$INSTALL_DIR/production-preflight.sh" 2>/dev/null || \
  curl -fsSL "https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/production-preflight.sh" \
    -o "$INSTALL_DIR/production-preflight.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/production-preflight.sh" 2>/dev/null || true

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
NEW_ENV=0
if [ ! -f "$INSTALL_DIR/.env" ]; then
  NEW_ENV=1
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

  # Machine-to-machine secret for POST /api/system/connector-update
  # (handleConnectorSelfUpdate, backend/internal/api/system_edgex.go).
  # gateway-ui-api's own Manager poll now reconciles self-update in-process
  # by default (reconcileSelfUpdate, deployment_dispatch.go) -- this
  # loopback route/token stays available as a harmless, unused-by-default
  # machine-to-machine hook, not the primary self-update path.
  CONNECTOR_TOKEN=$(openssl rand -hex 24 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "")

  # Shared secret gateway-ui-api presents as X-Connector-Auth when
  # forwarding deployment commands to the optional Connector agent
  # (the "connector" service in docker-compose.yml) over its narrow local HTTP contract (see
  # deployment_dispatch.go, connector/internal/localapi). Only relevant if
  # the Connector is ever installed; harmless if not -- an empty/mismatched
  # token just means deployment dispatch fails closed rather than silently
  # calling the Connector unauthenticated.
  CONNECTOR_LOCAL_TOKEN=$(openssl rand -hex 24 2>/dev/null \
    || cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 2>/dev/null \
    || echo "")

  # Machine-to-machine token for /api/alarms/ingest, /api/alarms/evaluate,
  # and /api/sparkplug/ingest (Foundation Hardening Batch 5C). Auto-
  # generated on every FRESH install so a gateway that later switches
  # GATEWAY_ENV to production already has this configured rather than
  # discovering, only once alarms silently stop ingesting, that production
  # now requires it (see backend/internal/api/machine_ingest_auth.go).
  # Never generated for an EXISTING install (see the `if [ ! -f .env ]`
  # guard around this whole block) -- an already-fielded gateway's token
  # (or deliberate choice to leave it empty) is never silently rotated by
  # re-running this script.
  ALARM_INGEST_TOKEN=$(openssl rand -hex 24 2>/dev/null \
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

  if [ "$INSTALL_MODE" = "production" ]; then
    GENERATED_GATEWAY_ENV="production"
    GENERATED_SESSION_SECURE="true"
    # Production assumes the TLS reverse proxy is on this gateway by default,
    # so the clear-text app listener is loopback-only. Sites whose reverse
    # proxy is on another trusted host may explicitly set EDGEVISS_BIND_ADDRESS
    # to the gateway's dedicated management IP before install.
    GENERATED_BIND_ADDRESS="${EDGEVISS_BIND_ADDRESS:-127.0.0.1}"
  else
    GENERATED_GATEWAY_ENV="development"
    GENERATED_SESSION_SECURE="false"
    GENERATED_BIND_ADDRESS="${EDGEVISS_BIND_ADDRESS:-0.0.0.0}"
  fi
  if [ "$MODBUS_RTU_MODE" = "1" ]; then
    GENERATED_MODBUS_PRIVILEGED="true"
  else
    GENERATED_MODBUS_PRIVILEGED="false"
  fi

  cat > "$INSTALL_DIR/.env" << ENV
# ── EdgeViss Gateway Configuration ───────────────────────────────────────────
# Edit this file to connect to your platform services.
# After editing, restart with: cd $INSTALL_DIR && docker compose $COMPOSE_FILES restart

GATEWAY_PORT=$PORT
# Host interface for the clear-text application listener. Fresh production
# installs default to loopback so users reach EdgeViss through the configured
# HTTPS reverse proxy, not by bypassing TLS on the raw application port.
GATEWAY_BIND_ADDRESS=$GENERATED_BIND_ADDRESS
# Installation posture. --production (or EDGEVISS_INSTALL_MODE=production)
# is accepted only when EDGEVISS_EXTERNAL_HTTPS=1 is explicitly supplied.
# Lab mode is intentionally NOT a production deployment posture.
GATEWAY_ENV=$GENERATED_GATEWAY_ENV

# Security (auto-generated — do not share this value)
SESSION_SECRET=$SECRET
SESSION_SECURE=$GENERATED_SESSION_SECURE

# Recovery token (auto-generated) — the ONLY way to reset a login if every
# engineer/admin password is lost. Printed once at the end of this install
# script; store it offline (printed copy, password manager) and NOT only in
# this file, since losing this file too means no recovery path at all.
# Use it via the Login page's "Forgot password?" link, or directly:
#   POST /api/auth/recovery {"token": "...", "newPassword": "..."}
GATEWAY_RECOVERY_TOKEN=$RECOVERY_TOKEN

# ── Platform Service Endpoints ────────────────────────────────────────────────
$PLATFORM_URLS

# The bundled EdgeX 4.0.2 appliance uses the /api/v3 REST prefix. Product
# version and REST API prefix are intentionally separate concepts. Do not
# change this unless a future EdgeX release/prefix pair is explicitly certified.
PLATFORM_API_VERSION=v3

# Scheduled full migration backups are written inside the persistent /data
# volume. This path must stay on persistent storage so container replacement
# cannot erase the backup history.
AUTO_BACKUP_DIR=/data/backups

# Registry the bundled platform images are pulled from (only used when
# platform-compose.yml is in play)
MIRROR_REGISTRY=$MIRROR_REGISTRY

# Fresh installs are TCP-hardened by default. `--modbus-rtu` (or
# EDGEVISS_ENABLE_MODBUS_RTU=1) makes this true explicitly for a gateway that
# needs host serial-device access. Existing .env files are never rewritten.
MODBUS_PRIVILEGED=$GENERATED_MODBUS_PRIVILEGED

# ── In-UI self-update (System → Update) ───────────────────────────────────────
# EDGEVISS_HOST_INSTALL_DIR must be the HOST path to this directory (not a
# path inside any container) -- gateway-ui-api sends it to the Connector
# sidecar, which bind-mounts it 1:1 into its own short-lived updater
# container so update.sh's file edits land on the real host filesystem.
# gateway-ui-api itself has no Docker access and never mounts this path
# directly. If you move this install directory, update this value.
EDGEVISS_HOST_INSTALL_DIR=$INSTALL_DIR
CONNECTOR_TOKEN=$CONNECTOR_TOKEN
CONNECTOR_LOCAL_TOKEN=$CONNECTOR_LOCAL_TOKEN

# Self URL the stream engine (eKuiper) uses to POST alarm evaluations back to
# this gateway -- must match the docker-compose service's container_name
# below (edgeviss-gateway), NOT the backend's built-in default of
# "gateway-ui-api" (that default only matches deploy/docker-compose.yml's dev
# stack, a different service name than what this installer generates). Left
# unset, every alarm setpoint silently never fires -- confirmed live: the
# eKuiper rule shows "running" with zero indication in the UI that its REST
# sink to /api/alarms/evaluate is failing on every single message.
ALARM_INGEST_URL=http://edgeviss-gateway:$PORT

# Auto-generated (Batch 5C) — required in production, optional (network-
# level trust) in development/test. See machine_ingest_auth.go. If you
# already have a fielded gateway from before this change and are running
# --reconfigure rather than a fresh install, this value is left exactly as
# it was in your existing .env (this block only runs when .env doesn't
# exist yet) — set ALARM_INGEST_TOKEN yourself before switching that
# gateway to GATEWAY_ENV=production, or alarm ingest will start returning
# 503 until you do.
ALARM_INGEST_TOKEN=$ALARM_INGEST_TOKEN

# Optional: comma-separated data export service URLs
# DATA_EXPORT_URLS=http://export-service:59730

# Optional: API token for secured deployments
# PLATFORM_AUTH_TOKEN=

# ── Optional modules (off by default) ────────────────────────────────────────
# The default UI is workflow-oriented: Dashboard, Data, Publish, Operate,
# System, Advanced and Audit. These four optional modules expose lower-level
# platform internals; keep them off unless an expert workflow needs them.
# Uncomment any you actually need, then restart:
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
  # An .env from an older version lacks keys the current compose file needs;
  # add only the missing ones (existing values are never changed).
  ENV_ADDED=""
  env_add() {
    grep -q "^$1=" "$INSTALL_DIR/.env" 2>/dev/null && return 0
    printf '%s=%s\n' "$1" "$2" >> "$INSTALL_DIR/.env"
    ENV_ADDED="$ENV_ADDED $1"
  }
  env_add CONNECTOR_LOCAL_TOKEN "$(openssl rand -hex 24 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 48)"
  if [ "$BUNDLE_PLATFORM" = "1" ]; then
    env_add PLATFORM_REGISTRY_URL "http://platform-registry:59890"
  fi
  env_add GATEWAY_BIND_ADDRESS "0.0.0.0"
  env_add FEATURE_REMOTE_ACCESS "true"
  chmod 600 "$INSTALL_DIR/.env"
  [ -n "$ENV_ADDED" ] && ok "Added settings this version needs to the existing .env:$ENV_ADDED"
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
# Every container caps its own logs, independent of the host's
# /etc/docker/daemon.json, so logs can never fill the gateway's disk.
x-logging: &capped-logs
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  gateway:
    image: ${REGISTRY}/${IMAGE}:${VERSION}
    container_name: edgeviss-gateway
    restart: unless-stopped
    logging: *capped-logs
    ports:
      - "\${GATEWAY_BIND_ADDRESS:-0.0.0.0}:\${GATEWAY_PORT:-$PORT}:\${GATEWAY_PORT:-$PORT}"
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
      # Cloud Remote Access capability. On by default: a tunnel still needs
      # the System -> Remote Access toggle plus Manager-delivered credentials.
      FEATURE_REMOTE_ACCESS: \${FEATURE_REMOTE_ACCESS:-true}
      PLATFORM_METADATA_URL: \${PLATFORM_METADATA_URL}
      PLATFORM_DATA_URL: \${PLATFORM_DATA_URL}
      PLATFORM_COMMAND_URL: \${PLATFORM_COMMAND_URL}
      PLATFORM_SCHEDULER_URL: \${PLATFORM_SCHEDULER_URL}
      PLATFORM_NOTIFICATIONS_URL: \${PLATFORM_NOTIFICATIONS_URL}
      PLATFORM_RULES_URL: \${PLATFORM_RULES_URL}
      PLATFORM_REGISTRY_URL: \${PLATFORM_REGISTRY_URL}
      PLATFORM_APP_SERVICES_URLS: \${DATA_EXPORT_URLS:-}
      PLATFORM_AUTH_TOKEN: \${PLATFORM_AUTH_TOKEN:-}
      # In-UI self-update (System -> Update) forwards this to the Connector
      # sidecar, which spawns its own sibling updater container -- this
      # gateway has no Docker access of its own. Missing
      # EDGEVISS_HOST_INSTALL_DIR disables the feature with a clear message
      # rather than failing oddly.
      EDGEVISS_HOST_INSTALL_DIR: \${EDGEVISS_HOST_INSTALL_DIR:-}
      # Harmless, unused-by-default machine-to-machine self-update loopback
      # (see handleConnectorSelfUpdate) -- gateway-ui-api's own Manager poll
      # reconciles self-update in-process by default now. Empty = that route
      # always 403s.
      EDGEVISS_CONNECTOR_TOKEN: \${CONNECTOR_TOKEN:-}
      # Narrow authenticated local contract to the optional Connector agent
      # (deployment dispatch + GET_RUNTIME_STATUS) -- gateway-ui-api is the
      # sole Cloud-facing command consumer and never touches Docker itself.
      # Empty = deployment dispatch fails closed rather than calling the
      # Connector with no auth header. Safe if the Connector is never
      # installed.
      CONNECTOR_LOCAL_URL: \${CONNECTOR_LOCAL_URL:-http://edgeviss-connector:8090}
      CONNECTOR_LOCAL_TOKEN: \${CONNECTOR_LOCAL_TOKEN:-}
    volumes:
      - gateway-data:/data
      # Host /dev mounted read-only so the device form's Serial Port scanner
      # can list connected serial/USB adapters (ttyUSB*, ttyACM*, ttyAMA*,
      # ttyS*, video*). Read-only: the backend only enumerates node names.
      - /dev:/host/dev:ro
      # NOTE: this container has NO docker.sock mount and no group_add --
      # self-update and Reboot Host both forward to the edgeviss-connector
      # sidecar's own Docker-privileged local API instead (see
      # the "connector" service below, CONNECTOR_LOCAL_URL/CONNECTOR_LOCAL_TOKEN
      # above). This gateway is unprivileged with respect to Docker.
      # (Start on boot is also done by the connector below: writing the
      # host's /etc/systemd/system needs root, which this container is not.)
      # Container has no timezone info of its own -- without this, Go's
      # time.Now() reads UTC, so System -> Scheduled Reboot's HH:MM (entered
      # and documented as host-local time, see system_scheduled_reboot.go)
      # silently fires at the wrong wall-clock hour instead of never at all,
      # which reads to an operator as "the scheduled reboot didn't happen at
      # the time I set." Read-only bind of the host's real zoneinfo file is
      # the standard fix for this in any minimal/scratch container image.
      - /etc/localtime:/etc/localtime:ro
      # Gateway health (Dashboard + Publish -> Gateway health) reports the
      # HOST's hostname, IP/MAC and network state, not the container's own:
      # read-only views of the host's hostname, /proc and /sys.
      - /etc/hostname:/host/etc/hostname:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:\${GATEWAY_PORT:-$PORT}/api/health >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
    $NETWORK_BLOCK

  # Privileged local worker for in-UI updates and host reboots (manual and
  # scheduled). No Cloud identity and no published port: only the gateway
  # reaches it, on this compose network, with CONNECTOR_LOCAL_TOKEN.
  connector:
    image: ${REGISTRY}/edgeviss-connector:${VERSION}
    container_name: edgeviss-connector
    restart: unless-stopped
    logging: *capped-logs
    environment:
      CONNECTOR_LISTEN_ADDR: ":8090"
      CONNECTOR_LOCAL_TOKEN: \${CONNECTOR_LOCAL_TOKEN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # Start on boot (System page): enable/disable docker.service the way
      # "systemctl enable docker" does. The unit dir is read-only.
      - /etc/systemd/system:/host-systemd
      - /usr/lib/systemd/system:/host-systemd-lib:ro
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
        # Usually left by an older installer or the legacy docker-compose 1.x.
        # When only EdgeVISS containers use it, remove them (their data lives
        # in named volumes and survives) and the network, so compose recreates
        # both correctly. Anything else attached is left alone.
        NET_USERS=$(docker network inspect "$PLATFORM_NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
        FOREIGN=""
        for c in $NET_USERS; do
          case "$c" in platform-*|edgeviss-*|*_edgeviss-gateway|device-bacnet-custom) ;; *) FOREIGN="$FOREIGN $c" ;; esac
        done
        if [ -z "$FOREIGN" ]; then
          # shellcheck disable=SC2086
          docker rm -f $NET_USERS >/dev/null 2>&1 || true
          docker network rm "$PLATFORM_NETWORK" >/dev/null 2>&1             && ok "Recreating $PLATFORM_NETWORK (it had the wrong labels from an older install; data volumes kept)"             || warn "Could not remove $PLATFORM_NETWORK — platform services may fail to start"
        else
          warn "$PLATFORM_NETWORK has the wrong Compose label and non-EdgeVISS containers attached ($FOREIGN) — not touching it automatically"
        fi
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
  BROKER_ID_BEFORE=$(docker inspect -f '{{.Id}}' platform-broker 2>/dev/null || echo "")
  MIRROR_REGISTRY="$MIRROR_REGISTRY" DOCKER_DEFAULT_PLATFORM="$PLATFORM" $COMPOSE -f platform-compose.yml up -d
  ok "Platform services started"
  # On an upgrade, a recreated message broker leaves the stream engine's
  # shared source disconnected (exports/alarms "running" but receiving
  # nothing); restart it so northbound publishing resumes.
  BROKER_ID_AFTER=$(docker inspect -f '{{.Id}}' platform-broker 2>/dev/null || echo "")
  if [ -n "$BROKER_ID_BEFORE" ] && [ "$BROKER_ID_BEFORE" != "$BROKER_ID_AFTER" ]; then
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
  step "Waiting for platform services to register (up to 60s)"
  sleep 20
fi

# ── Manager enrollment (optional) ──────────────────────────────────────────────
# A Manager-generated install command passes MANAGER_URL, DEVICE_ID and a
# one-time ACTIVATION_TOKEN. They go into .env for the gateway's first start
# (BootstrapManagerActivation), and the token is removed again once the
# gateway reports the result below.
ACT_URL="${MANAGER_URL:-${EDGEVISS_MANAGER_URL:-}}"
ACT_ID="${DEVICE_ID:-${EDGEVISS_DEVICE_ID:-}}"
ACT_TOKEN="${ACTIVATION_TOKEN:-${EDGEVISS_ACTIVATION_TOKEN:-}}"
ENROLL=0
if [ -n "$ACT_URL" ] && [ -n "$ACT_ID" ] && [ -n "$ACT_TOKEN" ]; then
  ENROLL=1
  sed -i '/^EDGEVISS_MANAGER_URL=/d;/^EDGEVISS_DEVICE_ID=/d;/^EDGEVISS_ACTIVATION_TOKEN=/d' "$INSTALL_DIR/.env"
  printf 'EDGEVISS_MANAGER_URL=%s\nEDGEVISS_DEVICE_ID=%s\nEDGEVISS_ACTIVATION_TOKEN=%s\n' "$ACT_URL" "$ACT_ID" "$ACT_TOKEN" >> "$INSTALL_DIR/.env"
  chmod 600 "$INSTALL_DIR/.env"
elif [ -n "$ACT_URL$ACT_ID$ACT_TOKEN" ]; then
  warn "Manager enrollment needs MANAGER_URL, DEVICE_ID and ACTIVATION_TOKEN together — skipping enrollment (activate later in System → Manager Connectivity)"
fi

step "Starting gateway"
cd "$INSTALL_DIR"
# A crashed recreate (legacy docker-compose 1.x) leaves the old gateway
# renamed to <id>_edgeviss-gateway, which blocks the new one.
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^[0-9a-f]+_edgeviss-(gateway|connector)$'); do
  docker rm -f "$c" >/dev/null 2>&1 && ok "Removed leftover container $c from an interrupted earlier install"
done
# Same platform override as the platform-compose.yml invocation above -
# this compose call also resolves platform via host autodetection
# independently of the earlier `docker pull --platform "$PLATFORM"`.
DOCKER_DEFAULT_PLATFORM="$PLATFORM" $COMPOSE $COMPOSE_FILES up -d gateway
ok "Gateway started"

# The connector (in-UI updates, host reboots) is started separately so a
# registry problem with its image never blocks the gateway itself.
if DOCKER_DEFAULT_PLATFORM="$PLATFORM" $COMPOSE $COMPOSE_FILES up -d connector; then
  ok "Connector started"
else
  warn "Connector image could not be pulled (${REGISTRY}/edgeviss-connector:${VERSION}) — data collection is unaffected, but in-UI updates and scheduled reboots stay unavailable until: cd $INSTALL_DIR && docker compose $COMPOSE_FILES up -d connector"
fi

# ── Wait for health ────────────────────────────────────────────────────────────
step "Waiting for gateway to be ready (up to 30s)"
TRIES=0
until curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  [ "$TRIES" -gt 15 ] && warn "Health check timed out — gateway may still be starting" && break
  sleep 2
done
[ "$TRIES" -le 15 ] && ok "Gateway is healthy"

if [ "$ENROLL" = "1" ]; then
  step "Enrolling with EdgeVISS Cloud Manager ($ACT_URL)"
  ENROLL_RESULT=""
  for _ in $(seq 1 60); do
    ENROLL_RESULT=$(docker logs edgeviss-gateway 2>&1 | grep -o 'manager activation: [a-z, ]*' | tail -1)
    [ -n "$ENROLL_RESULT" ] && break
    sleep 5
  done
  # The one-time token is spent either way; never leave it on disk.
  sed -i '/^EDGEVISS_ACTIVATION_TOKEN=/d' "$INSTALL_DIR/.env"
  case "$ENROLL_RESULT" in
    *completed*) ok "Enrolled — this gateway now reports to $ACT_URL" ;;
    *already*)   ok "Already enrolled with a Manager — kept the existing enrollment" ;;
    *failed*)    warn "Enrollment failed: $(docker logs edgeviss-gateway 2>&1 | grep 'manager activation: failed' | tail -1 | sed 's/.*"err":"\([^"]*\)".*/\1/')"
                 warn "Generate a new install command in the Manager (tokens are single-use), or activate in System → Manager Connectivity" ;;
    *)           warn "No enrollment result within 5 minutes — check System → Manager Connectivity" ;;
  esac
fi

# ── Optional: local display (kiosk) ───────────────────────────────────────────
if [ "$KIOSK" = "1" ]; then
  step "Setting up the local display (kiosk)"
  KIOSK_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  if [ -z "$KIOSK_USER" ] || [ "$KIOSK_USER" = "root" ]; then
    warn "Kiosk skipped: run the installer with sudo from the desktop user's account so the screen opens for that user."
  elif [ "$(systemctl get-default 2>/dev/null)" != "graphical.target" ]; then
    warn "Kiosk skipped: this system does not boot to a desktop. Install a desktop OS image (e.g. Raspberry Pi OS with desktop) or use the gateway headless."
  else
    BROWSER="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
    if [ -z "$BROWSER" ] && command -v apt-get >/dev/null 2>&1; then
      apt-get install -y chromium >/dev/null 2>&1 || apt-get install -y chromium-browser >/dev/null 2>&1 || true
      BROWSER="$(command -v chromium || command -v chromium-browser || true)"
    fi
    if [ -z "$BROWSER" ]; then
      warn "Kiosk skipped: could not install Chromium. Install it and re-run with --kiosk."
    else
      KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
      mkdir -p "$KIOSK_HOME/.config/autostart"
      cat > "$KIOSK_HOME/.config/autostart/edgeviss-kiosk.desktop" <<KIOSKEOF
[Desktop Entry]
Type=Application
Name=EdgeVISS Local
Comment=Opens EdgeVISS Local full-screen on this gateway's display
Exec=sh -c 'until curl -fs http://localhost:${PORT}/api/health >/dev/null; do sleep 3; done; exec ${BROWSER} --kiosk --noerrdialogs --disable-infobars --no-first-run --password-store=basic --check-for-update-interval=31536000 http://localhost:${PORT}/'
X-GNOME-Autostart-enabled=true
KIOSKEOF
      chown -R "$KIOSK_USER": "$KIOSK_HOME/.config/autostart"
      ok "Kiosk enabled for user $KIOSK_USER: EdgeVISS Local opens full-screen at every login (remove $KIOSK_HOME/.config/autostart/edgeviss-kiosk.desktop to disable)"
    fi
  fi
fi

# ── Done ───────────────────────────────────────────────────────────────────────
GATEWAY_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$GATEWAY_IP" ] || GATEWAY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
[ -n "$GATEWAY_IP" ] || GATEWAY_IP="localhost"

echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   EdgeViss is running!                               ║"
echo "  ║                                                      ║"
if [ "$INSTALL_MODE" = "production" ]; then
  echo "  ║   Open:  your configured HTTPS endpoint             "
else
  echo "  ║   Open:  http://${GATEWAY_IP}:${PORT}               "
fi
echo "  ║                                                      ║"
echo "  ║   First time? The browser will guide you to         ║"
echo "  ║   create your admin account.                        ║"
echo "  ║                                                      ║"
echo "  ║   Config:  $INSTALL_DIR/.env                        "
echo "  ║   Update:  $INSTALL_DIR/update.sh                   "
echo "  ║   Stop:    cd $INSTALL_DIR && docker compose $COMPOSE_FILES down  "
echo "  ╚══════════════════════════════════════════════════════╝"
if [ "$NEW_ENV" = "1" ]; then
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
else
  ok "Existing .env preserved; recovery token was not rotated or printed"
fi


# Production posture reminder added by Local Production Readiness Closure.
if [ "$INSTALL_MODE" = "lab" ]; then
  warn "Installed in LAB mode (GATEWAY_ENV=development, non-secure session cookie). Do not use this posture for a production site. Configure HTTPS and re-run with --production, then run deploy/production-preflight.sh."
else
  ok "Production mode selected. Run $INSTALL_DIR/production-preflight.sh before site handover."
fi
