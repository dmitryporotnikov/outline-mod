#!/bin/bash
#
# Cleanup script for Outline VPN Double-Hop setup
# Stops and removes all containers, networks, and optionally wipes state
#
# Usage:
#   sudo ./cleanup.sh              # Stop containers and remove them
#   sudo ./cleanup.sh --full       # Also wipe state directory
#

set -euo pipefail

STATE_DIR="${STATE_DIR:-/opt/outline/shadowbox/persisted-state}"
FULL_CLEANUP=false

if [[ "${1:-}" == "--full" ]]; then
  FULL_CLEANUP=true
fi

echo "=== Outline VPN Double-Hop Cleanup ==="
echo ""

# Stop and remove containers
echo "[*] Stopping containers..."
for container in shadowbox wireguard-proxy; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    docker stop "$container" 2>/dev/null || true
    docker rm -f "$container" 2>/dev/null || true
    echo "    Removed: $container"
  else
    echo "    Not found: $container (skipping)"
  fi
done

# Remove docker network
echo "[*] Removing networks..."
if docker network ls --format '{{.Name}}' | grep -q 'outline-vpn'; then
  docker network rm outline-vpn 2>/dev/null || true
  echo "    Removed: outline-vpn"
else
  echo "    Not found: outline-vpn (skipping)"
fi

# Try docker compose down from state dir if compose file exists
if [[ -f "${STATE_DIR}/docker-compose.yml" ]]; then
  echo "[*] Running docker compose down from state directory..."
  cd "${STATE_DIR}"
  docker compose down 2>/dev/null || docker-compose down 2>/dev/null || true
fi

if [[ "$FULL_CLEANUP" == true ]]; then
  echo ""
  echo "[*] Full cleanup: removing state directory ${STATE_DIR}..."
  rm -rf "${STATE_DIR}"
  echo "    Removed: ${STATE_DIR}"
else
  # Just remove the generated docker-compose so it gets regenerated
  if [[ -f "${STATE_DIR}/docker-compose.yml" ]]; then
    rm -f "${STATE_DIR}/docker-compose.yml"
    echo "[*] Removed generated docker-compose.yml from state dir"
  fi
fi

echo ""
echo "=== Cleanup complete ==="
echo ""
if [[ "$FULL_CLEANUP" == true ]]; then
  echo "All state has been wiped. Run setup.sh to start fresh."
else
  echo "Containers removed. State preserved in ${STATE_DIR}"
  echo "Run setup.sh to redeploy, or use --full to also wipe state."
fi
