#!/bin/bash
#
# WireGuard Double-Hop Setup Script
#
# This script sets up WireGuard as a transparent proxy for Shadowbox.
# It modifies the Docker Compose setup to route all Shadowbox traffic
# through a WireGuard tunnel.
#
# Usage:
#   sudo ./setup.sh [--wireguard-config PATH]
#   e.g ./setup.sh --wireguard-config /opt/outline/vpn.conf
#
# Requirements:
#   - Docker and Docker Compose installed
#   - WireGuard config file from your upstream VPN provider
#   - Port 8090 available (or set SB_API_PORT env var)
#   - Ports 8090/TCP and 51820/UDP accessible

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/opt/outline/shadowbox/persisted-state}"
WIREGUARD_CONFIG_FILE=""
SB_API_PORT="${SB_API_PORT:-8090}"
SECRET_KEY=""
PUBLIC_IP=""

function display_usage() {
  cat <<EOF
Usage: $0 [--wireguard-config PATH] [--api-port PORT] [--hostname HOSTNAME]

  --wireguard-config   Path to WireGuard config file (required)
  --api-port           Port for Shadowbox API (default: 8090)
  --hostname           Public hostname/IP for the server (auto-detected if not set)
EOF
}

function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

function log_error() {
  echo -e "\033[0;31m[ERROR] $*\033[0m" >&2
}

function check_requirements() {
  if ! command_exists docker; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
  fi

  if ! command_exists docker-compose && ! docker compose version &>/dev/null; then
    log_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
  fi
}

function command_exists() {
  command -v "$@" &> /dev/null
}

function safe_base64() {
  base64 -w 0 - | tr '/+' '_-' | tr -d '='
}

function generate_secret_key() {
  head -c 16 /dev/urandom | safe_base64
}

function get_public_ip() {
  local -r urls=(
    'https://icanhazip.com/'
    'https://ipinfo.io/ip'
    'https://domains.google.com/checkip'
  )
  for url in "${urls[@]}"; do
    if PUBLIC_IP=$(curl --ipv4 -s --max-time 5 "$url" 2>/dev/null); then
      return 0
    fi
  done
  return 1
}

function validate_wireguard_config() {
  local config_file="$1"

  if [[ ! -f "${config_file}" ]]; then
    log_error "WireGuard config file not found: ${config_file}"
    return 1
  fi

  if ! grep -q '^\[Interface\]' "${config_file}"; then
    log_error "WireGuard config missing [Interface] section"
    return 1
  fi

  if ! grep -q '^\[Peer\]' "${config_file}"; then
    log_error "WireGuard config missing [Peer] section"
    return 1
  fi

  if ! grep -q 'PrivateKey' "${config_file}"; then
    log_error "WireGuard config missing PrivateKey"
    return 1
  fi

  if ! grep -q 'Endpoint' "${config_file}"; then
    log_error "WireGuard config missing Endpoint"
    return 1
  fi

  log "WireGuard config validated successfully"
  return 0
}

function generate_certificate() {
  local -r cert_file="${STATE_DIR}/shadowbox-selfsigned.crt"
  local -r key_file="${STATE_DIR}/shadowbox-selfsigned.key"

  if [[ -f "${cert_file}" && -f "${key_file}" ]]; then
    log "Using existing certificate"
    return 0
  fi

  log "Generating self-signed certificate..."

  # Generate certificate
  openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
    -subj "/CN=${PUBLIC_IP}" \
    -keyout "${key_file}" \
    -out "${cert_file}" 2>/dev/null

  if [[ $? -ne 0 ]]; then
    log_error "Failed to generate certificate"
    return 1
  fi

  log "Certificate generated successfully"
  return 0
}

function get_cert_fingerprint() {
  local -r cert_file="${STATE_DIR}/shadowbox-selfsigned.crt"
  openssl x509 -in "${cert_file}" -noout -sha256 -fingerprint 2>/dev/null | \
    tr -d ':' | sed 's/.*=//g'
}

function create_docker_compose() {
  local state_dir="$1"
  local wireguard_config="$2"

  cat > "${state_dir}/docker-compose.yml" <<EOF
services:
  wireguard-proxy:
    image: ghcr.io/linuxserver/wireguard:latest
    container_name: wireguard-proxy
    restart: always
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv4.conf.all.rp_filter=2
      - net.ipv4.conf.all.src_valid_mark=1
    ports:
      - "${SB_API_PORT}:8090"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - "${wireguard_config}:/config/wg_confs/wg0.conf"
    networks:
      - outline-vpn
    dns:
      - 8.8.8.8
      - 8.8.4.4
    healthcheck:
      test: ["CMD", "wg", "show"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: local

  shadowbox:
    image: quay.io/outline/shadowbox:stable
    container_name: shadowbox
    restart: always
    network_mode: service:wireguard-proxy
    depends_on:
      wireguard-proxy:
        condition: service_healthy
    environment:
      - SB_STATE_DIR=/opt/outline/shadowbox/persisted-state
      - SB_API_PORT=8090
      - SB_API_PREFIX=${SECRET_KEY}
      - SB_CERTIFICATE_FILE=/opt/outline/shadowbox/persisted-state/shadowbox-selfsigned.crt
      - SB_PRIVATE_KEY_FILE=/opt/outline/shadowbox/persisted-state/shadowbox-selfsigned.key
      - SB_DEFAULT_SERVER_NAME=${PUBLIC_IP}
    volumes:
      - "${state_dir}:/opt/outline/shadowbox/persisted-state"
    logging:
      driver: local

networks:
  outline-vpn:
    driver: bridge
EOF

  log "Created docker-compose.yml"
}

function create_shadowbox_config() {
  local state_dir="$1"
  local config_file="${state_dir}/shadowbox_server_config.json"

  if [[ -f "${config_file}" ]]; then
    log "Shadowbox server config already exists, updating..."
    if command_exists python3; then
      python3 -c "
import json, sys
with open('${config_file}', 'r') as f:
    config = json.load(f)
config['portForNewAccessKeys'] = 443
config['hostname'] = '${PUBLIC_IP}'
with open('${config_file}', 'w') as f:
    json.dump(config, f, indent=2)
"
    fi
  else
    cat > "${config_file}" <<EOF
{
  "hostname": "${PUBLIC_IP}",
  "rollouts": [
    {
      "id": "single-port",
      "enabled": true
    }
  ],
  "portForNewAccessKeys": 443
}
EOF
  fi

  log "Shadowbox server config ready (hostname=${PUBLIC_IP}, access keys on port 443)"
}

function prepare_wireguard_config() {
  local config_file="$1"

  # Check if PostUp rules already exist
  if grep -q 'PostUp' "${config_file}"; then
    log "WireGuard config already has PostUp rules"
    return 0
  fi

  log "Adding NAT/forwarding/CONNMARK iptables rules to WireGuard config..."

  # These rules:
  #   1. Allow forwarding through the WireGuard tunnel
  #   2. MASQUERADE outgoing traffic through wg0
  #   3. CONNMARK only ports 8090 (API) and 443 (clients) — not all traffic
  #   4. DEF_IF is detected at runtime — no hardcoded eth0
  local postup='PostUp = DEF_IF=$(ip route show default | awk '"'"'{print $5}'"'"' | head -1); iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o %i -j MASQUERADE; iptables -t mangle -A PREROUTING -i $DEF_IF -p tcp --dport 8090 -j CONNMARK --set-mark 0x1; iptables -t mangle -A PREROUTING -i $DEF_IF -p tcp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -A PREROUTING -i $DEF_IF -p udp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -A OUTPUT -m connmark --mark 0x1 -j CONNMARK --restore-mark; ip rule add fwmark 0x1 table main priority 100'
  local postdown='PostDown = DEF_IF=$(ip route show default | awk '"'"'{print $5}'"'"' | head -1); iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o %i -j MASQUERADE; iptables -t mangle -D PREROUTING -i $DEF_IF -p tcp --dport 8090 -j CONNMARK --set-mark 0x1; iptables -t mangle -D PREROUTING -i $DEF_IF -p tcp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -D PREROUTING -i $DEF_IF -p udp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -D OUTPUT -m connmark --mark 0x1 -j CONNMARK --restore-mark; ip rule del fwmark 0x1 table main priority 100'

  # Append after the last line before [Peer]
  sed -i "/^\\[Peer\\]/i ${postup}\\n${postdown}" "${config_file}"

  log "Added iptables rules to WireGuard config"
}

function stop_existing_containers() {
  log "Stopping existing containers..."

  if docker ps -a --format '{{.Names}}' | grep -q '^shadowbox$'; then
    docker stop shadowbox 2>/dev/null || true
    docker rm shadowbox 2>/dev/null || true
    log "Removed existing shadowbox container"
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^wireguard-proxy$'; then
    docker stop wireguard-proxy 2>/dev/null || true
    docker rm wireguard-proxy 2>/dev/null || true
    log "Removed existing wireguard-proxy container"
  fi
}

function wait_for_shadowbox() {
  local api_url="https://localhost:${SB_API_PORT}/${SECRET_KEY}"

  log "Waiting for Shadowbox API to be ready..."
  local retries=60
  while [[ $retries -gt 0 ]]; do
    if curl -sk --max-time 2 "${api_url}/access-keys" &>/dev/null; then
      log "Shadowbox API is ready!"
      return 0
    fi
    sleep 1
    ((retries--))
  done

  log_error "Shadowbox API failed to start"
  return 1
}

function start_services() {
  local state_dir="$1"

  cd "${state_dir}"

  if docker compose version &>/dev/null; then
    docker compose up -d
  else
    docker-compose up -d
  fi

  log "Waiting for WireGuard tunnel to establish..."
  local retries=30
  while [[ $retries -gt 0 ]]; do
    if docker exec wireguard-proxy wg show 2>/dev/null | grep -q "peer:"; then
      log "WireGuard tunnel is active!"
      break
    fi
    sleep 1
    ((retries--))
  done

  if [[ $retries -eq 0 ]]; then
    log_error "WireGuard tunnel failed to establish"
    docker logs wireguard-proxy
    exit 1
  fi

  wait_for_shadowbox
}

function get_api_info() {
  local api_url="https://localhost:${SB_API_PORT}/${SECRET_KEY}/server"

  # Get server info including hostnameForAccessKeys
  local hostname_for_keys=$(curl -sk --max-time 5 "${api_url}" 2>/dev/null | \
    grep -o '"hostnameForAccessKeys":"[^"]*"' | cut -d'"' -f4)

  if [[ -z "${hostname_for_keys}" ]]; then
    hostname_for_keys="${PUBLIC_IP}"
  fi

  echo "${hostname_for_keys}"
}

function main() {
  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wireguard-config)
        WIREGUARD_CONFIG_FILE="$2"
        shift 2
        ;;
      --api-port)
        SB_API_PORT="$2"
        shift 2
        ;;
      --hostname)
        PUBLIC_IP="$2"
        shift 2
        ;;
      -h|--help)
        display_usage
        exit 0
        ;;
      *)
        log_error "Unknown flag: $1"
        display_usage
        exit 1
        ;;
    esac
  done

  if [[ -z "${WIREGUARD_CONFIG_FILE}" ]]; then
    log_error "WireGuard config file is required. Use --wireguard-config PATH"
    display_usage
    exit 1
  fi

  log "Starting WireGuard double-hop setup..."
  log "State directory: ${STATE_DIR}"
  log "API Port: ${SB_API_PORT}"

  check_requirements

  if ! validate_wireguard_config "${WIREGUARD_CONFIG_FILE}"; then
    exit 1
  fi

  # Get public IP if not set
  if [[ -z "${PUBLIC_IP}" ]]; then
    log "Detecting public IP..."
    if get_public_ip; then
      log "Public IP: ${PUBLIC_IP}"
    else
      log_error "Failed to detect public IP. Please provide --hostname"
      exit 1
    fi
  fi

  # Generate secret key
  SECRET_KEY=$(generate_secret_key)
  log "Generated API secret key"

  # Create state directory
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"

  # Generate TLS certificate
  generate_certificate
  CERT_SHA256=$(get_cert_fingerprint)

  # Prepare WireGuard config (add iptables rules if needed)
  prepare_wireguard_config "${WIREGUARD_CONFIG_FILE}"

  # Stop existing containers
  stop_existing_containers

  # Create docker-compose.yml
  create_docker_compose "${STATE_DIR}" "${WIREGUARD_CONFIG_FILE}"

  # Create shadowbox server config (sets access keys to port 443)
  create_shadowbox_config "${STATE_DIR}"

  # Start services
  start_services "${STATE_DIR}"

  # Create initial access key so outline-ss-server starts listening on port 443
  log "Creating initial access key..."
  local api_url="https://localhost:${SB_API_PORT}/${SECRET_KEY}"
  local key_response
  key_response=$(curl -sk -X POST "${api_url}/access-keys" 2>/dev/null)
  if echo "${key_response}" | grep -q '"id"'; then
    log "Initial access key created successfully"
  else
    log_error "Failed to create initial access key: ${key_response}"
  fi

  # Get hostname for access keys
  HOSTNAME_FOR_KEYS=$(get_api_info)

  # Build the API URL
  API_URL="https://${HOSTNAME_FOR_KEYS}:${SB_API_PORT}/${SECRET_KEY}"

  echo ""
  echo "=========================================="
  echo "Double-hop VPN setup complete!"
  echo ""
  echo "WireGuard tunnel: ACTIVE"
  echo "Shadowbox API: ${API_URL}"
  echo ""
  echo "To connect with Outline Manager:"
  echo "  Copy this into Step 2 of the Manager:"
  echo ""
  printf '  \033[1;32m{"apiUrl":"%s","certSha256":"%s"}\033[0m\n' "${API_URL}" "${CERT_SHA256}"
  echo ""
  echo "=========================================="
  echo ""
  echo "Debug commands:"
  echo "  docker logs wireguard-proxy"
  echo "  docker logs shadowbox"
  echo "  docker exec wireguard-proxy wg show"
  echo ""
}

main "$@"