#!/bin/sh
# EdgeViss Connector Installer — optional EdgeVISS Cloud Manager enrollment.
# Run this on a gateway that already has EdgeViss Local installed
# (deploy/install.sh) if you want fleet monitoring/deployments from Manager.
# EdgeViss Local keeps working standalone with or without this.
#
# Usage — copy the exact command shown after "Issue Activation Token" on
# the Manager's Devices page. It already has MANAGER_URL/DEVICE_ID/
# ACTIVATION_TOKEN filled in for you:
#
#   curl -fsSL https://raw.githubusercontent.com/proeliumdevelopers/edgeviss-install/main/connector-install.sh | \
#     MANAGER_URL=https://manager.example.com DEVICE_ID=... ACTIVATION_TOKEN=... bash

set -e

REGISTRY="${EDGEVISS_REGISTRY:-ghcr.io/proeliumdevelopers/edgeviss-connector}"
VERSION="${EDGEVISS_CONNECTOR_VERSION:-latest}"
LOCAL_URL="${EDGEVISS_LOCAL_URL:-http://edgeviss-gateway:8080}"
POLL_INTERVAL="${CONNECTOR_POLL_INTERVAL_SECONDS:-30}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()  { printf "${GREEN}  ✓${NC} %s\n" "$1"; }
err() { printf "${RED}  ✗${NC} %s\n" "$1" >&2; exit 1; }
step() { printf "\n${GREEN}▶${NC} %s\n" "$1"; }

[ -z "$MANAGER_URL" ] && err "MANAGER_URL is required (copy the full command from Manager's Devices page)"
[ -z "$DEVICE_ID" ] && err "DEVICE_ID is required"
[ -z "$ACTIVATION_TOKEN" ] && err "ACTIVATION_TOKEN is required"

command -v docker >/dev/null 2>&1 || err "Docker is required. Install it first."

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PLATFORM="linux/amd64" ;;
  aarch64|arm64) PLATFORM="linux/arm64" ;;
  *)       PLATFORM="linux/amd64" ;;
esac

step "Pulling connector image ($REGISTRY:$VERSION for $PLATFORM)"
docker pull --platform "$PLATFORM" "$REGISTRY:$VERSION"
ok "Image ready"

step "Starting connector"
docker rm -f edgeviss-connector >/dev/null 2>&1 || true
docker run -d \
  --name edgeviss-connector \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v edgeviss-connector-data:/data \
  -e CONNECTOR_LISTEN_ADDR=:8090 \
  -e CONNECTOR_STORE_PATH=/data/state.json \
  -e EDGEVISS_LOCAL_URL="$LOCAL_URL" \
  -e POLL_INTERVAL_SECONDS="$POLL_INTERVAL" \
  "$REGISTRY:$VERSION"
ok "Connector running"

step "Activating against EdgeVISS Cloud Manager"
TRIES=0
until curl -fsS http://localhost:8090/status >/dev/null 2>&1; do
  TRIES=$((TRIES+1))
  [ "$TRIES" -gt 10 ] && err "Connector did not come up — check: docker logs edgeviss-connector"
  sleep 1
done

RESP=$(curl -fsS -X POST http://localhost:8090/activate \
  -H "Content-Type: application/json" \
  -d "{\"managerUrl\":\"$MANAGER_URL\",\"deviceId\":\"$DEVICE_ID\",\"activationToken\":\"$ACTIVATION_TOKEN\"}") \
  || err "Activation request failed — check the token hasn't already been used"

case "$RESP" in
  *'"activated":true'*) ok "Activated" ;;
  *) err "Activation failed: $RESP" ;;
esac

echo ""
echo "  EdgeViss Connector is enrolled with EdgeVISS Cloud Manager."
echo "  Check status: curl http://localhost:8090/status"
echo "  Or in EdgeViss Local: System → Manager Connectivity"
echo ""
