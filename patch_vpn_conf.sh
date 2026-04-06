#!/bin/bash
#
# Patches a WireGuard config file to include the PostUp/PostDown iptables
# rules required for the Outline double-hop setup.
#
# Usage:
#   ./patch_vpn_conf.sh <path-to-vpn.conf>
#
# What it does:
#   - Adds FORWARD/MASQUERADE rules so traffic from Shadowbox can exit via wg0
#   - Adds CONNMARK rules so responses to incoming connections (API + client)
#     route back through Docker's network interface instead of the WireGuard tunnel
#   - Auto-detects the Docker network interface at runtime (no hardcoded eth0)
#   - Skips patching if PostUp rules already exist

set -euo pipefail

POSTUP='PostUp = DEF_IF=$(ip route show default | awk '"'"'{print $5}'"'"' | head -1); iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o %i -j MASQUERADE; iptables -t mangle -A PREROUTING -i $DEF_IF -p tcp --dport 8090 -j CONNMARK --set-mark 0x1; iptables -t mangle -A PREROUTING -i $DEF_IF -p tcp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -A PREROUTING -i $DEF_IF -p udp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -A OUTPUT -m connmark --mark 0x1 -j CONNMARK --restore-mark; ip rule add fwmark 0x1 table main priority 100'
POSTDOWN='PostDown = DEF_IF=$(ip route show default | awk '"'"'{print $5}'"'"' | head -1); iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o %i -j MASQUERADE; iptables -t mangle -D PREROUTING -i $DEF_IF -p tcp --dport 8090 -j CONNMARK --set-mark 0x1; iptables -t mangle -D PREROUTING -i $DEF_IF -p tcp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -D PREROUTING -i $DEF_IF -p udp --dport 443 -j CONNMARK --set-mark 0x1; iptables -t mangle -D OUTPUT -m connmark --mark 0x1 -j CONNMARK --restore-mark; ip rule del fwmark 0x1 table main priority 100'

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-vpn.conf>"
  exit 1
fi

CONFIG_FILE="$1"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: file not found: $CONFIG_FILE"
  exit 1
fi

if ! grep -q '^\[Interface\]' "$CONFIG_FILE"; then
  echo "Error: not a valid WireGuard config (missing [Interface] section)"
  exit 1
fi

if grep -q 'PostUp' "$CONFIG_FILE"; then
  echo "Config already has PostUp rules, skipping."
  exit 0
fi

# Find the last line of the [Interface] section (line before [Peer])
PEER_LINE=$(grep -n '^\[Peer\]' "$CONFIG_FILE" | head -1 | cut -d: -f1)

if [[ -z "$PEER_LINE" ]]; then
  # No [Peer] section, append to end of file
  echo "$POSTUP" >> "$CONFIG_FILE"
  echo "$POSTDOWN" >> "$CONFIG_FILE"
else
  # Insert before [Peer]
  sed -i "${PEER_LINE}i\\${POSTUP}\n${POSTDOWN}\n" "$CONFIG_FILE"
fi

echo "Patched $CONFIG_FILE with PostUp/PostDown rules."
