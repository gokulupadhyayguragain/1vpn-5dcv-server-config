#!/usr/bin/env bash
set -euo pipefail

# CURRENT ADMIN CIDR BLOCK
# REFRESHES .ENV WITH THIS MACHINE'S CURRENT PUBLIC IP SO SSH AUTOMATION SURVIVES WIFI/NETWORK CHANGES.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ENV file not found: $ENV_FILE" >&2
  exit 1
fi

if [[ "${AUTO_UPDATE_ADMIN_CIDR:-true}" == "false" ]]; then
  exit 0
fi

detected_public_ip="$(curl -fsSL https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"

if [[ ! "$detected_public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "WARNING: Could not auto-detect current public IP. Keeping ALLOWED_ADMIN_CIDR from $ENV_FILE." >&2
  exit 0
fi

new_cidr="${detected_public_ip}/32"
current_cidr="$(grep -E '^ALLOWED_ADMIN_CIDR=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- || true)"

if [[ "$current_cidr" == "$new_cidr" ]]; then
  exit 0
fi

if grep -qE '^ALLOWED_ADMIN_CIDR=' "$ENV_FILE"; then
  sed -i "s|^ALLOWED_ADMIN_CIDR=.*|ALLOWED_ADMIN_CIDR=$new_cidr|" "$ENV_FILE"
else
  printf '\nALLOWED_ADMIN_CIDR=%s\n' "$new_cidr" >>"$ENV_FILE"
fi

echo "Updated ALLOWED_ADMIN_CIDR to $new_cidr for current network."
