#!/usr/bin/env bash
set -euo pipefail

# VPN SSH READINESS BLOCK
# WAITS FOR THE PUBLIC VPN HOST TO FINISH CLOUD BOOT AND ACCEPT SSH BEFORE ANSIBLE GATHERS FACTS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=inventory "$ROOT_DIR/.env"
"$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null

vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
deadline="$(( $(date +%s) + ${VPN_SSH_WAIT_TIMEOUT_SECONDS:-600} ))"
attempt=0

echo "Waiting for VPN SSH on ${vpn_public_ip}:22..."

while (( "$(date +%s)" < deadline )); do
  attempt="$((attempt + 1))"

  if ssh \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -i "$SSH_PRIVATE_KEY_PATH" \
    "ubuntu@${vpn_public_ip}" \
    "true" >/dev/null 2>&1; then
    echo "VPN SSH is ready after ${attempt} attempt(s)."
    exit 0
  fi

  sleep 10
done

echo "ERROR: VPN SSH did not become ready on ${vpn_public_ip}:22 within ${VPN_SSH_WAIT_TIMEOUT_SECONDS:-600} seconds." >&2
echo "Try checking the EC2 instance status checks, security group port 22, and Ubuntu cloud-init logs." >&2
exit 1
