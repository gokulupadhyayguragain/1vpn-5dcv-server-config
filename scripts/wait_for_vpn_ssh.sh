#!/usr/bin/env bash
set -euo pipefail

# VPN SSH READINESS BLOCK
# WAITS FOR THE PUBLIC VPN HOST TO FINISH CLOUD BOOT AND ACCEPT SSH BEFORE ANSIBLE GATHERS FACTS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=inventory "$ROOT_DIR/.env"

if "$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null 2>&1 \
  && vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip 2>/dev/null)"; then
  :
else
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: Terraform outputs are unavailable and aws CLI is not installed for VPN SSH discovery." >&2
    exit 1
  fi

  vpn_public_ip="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpn" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PublicIpAddress' \
    --output text)"
fi

if [[ -z "$vpn_public_ip" || "$vpn_public_ip" == "None" ]]; then
  echo "ERROR: Could not resolve a running VPN public IP for project ${PROJECT_NAME}." >&2
  exit 1
fi

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
