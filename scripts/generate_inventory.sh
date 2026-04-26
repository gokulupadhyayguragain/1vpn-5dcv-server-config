#!/usr/bin/env bash
set -euo pipefail

# INVENTORY SOURCE BLOCK
# PULLS REQUIRED HOST DATA FROM TERRAFORM OUTPUTS, OR FROM LIVE AWS TAGS WHEN THIS CHECKOUT DOES NOT HAVE STATE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=inventory "$ROOT_DIR/.env"

cd "$ROOT_DIR/terraform"
if "$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null 2>&1 \
  && terraform output -json 2>/dev/null | jq -e 'has("vpn_public_ip") and has("dcv_private_ips")' >/dev/null 2>&1; then
  vpn_public_ip="$(terraform output -raw vpn_public_ip)"
  mapfile -t dcv_private_ips < <(terraform output -json dcv_private_ips | jq -r '.[]')
  inventory_source="terraform"
else
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: Terraform outputs are unavailable and aws CLI is not installed for live inventory discovery." >&2
    exit 1
  fi

  vpn_public_ip="$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpn" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PublicIpAddress' \
    --output text)"

  mapfile -t dcv_private_ips < <(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${PROJECT_NAME}-dcv-*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress]' \
    --output text | sort -V | awk '{print $2}')

  inventory_source="aws"
fi

if [[ -z "$vpn_public_ip" || "$vpn_public_ip" == "None" ]]; then
  echo "ERROR: Could not resolve a running VPN public IP for project ${PROJECT_NAME}." >&2
  exit 1
fi

if [[ "${#dcv_private_ips[@]}" -ne "${DCV_INSTANCE_COUNT:-0}" ]]; then
  echo "ERROR: Expected ${DCV_INSTANCE_COUNT:-0} running DCV instance(s), found ${#dcv_private_ips[@]} for project ${PROJECT_NAME}." >&2
  echo "Start or replace stopped DCV instances before running Ansible." >&2
  exit 1
fi

inventory_ssh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
inventory_proxy_command="ssh $inventory_ssh_args -i $SSH_PRIVATE_KEY_PATH -W %h:%p ubuntu@$vpn_public_ip"
inventory_jump_args="$inventory_ssh_args -o IdentityFile=$SSH_PRIVATE_KEY_PATH -o ProxyCommand='$inventory_proxy_command'"

# INVENTORY RENDER BLOCK
# CREATES BASTION-AWARE INVENTORY FOR PRIVATE DCV HOST ACCESS.
inventory_file="$ROOT_DIR/ansible/inventories/hosts.yml"
mkdir -p "$(dirname "$inventory_file")"

{
  echo "all:"
  echo "  children:"
  echo "    vpn:"
  echo "      hosts:"
  echo "        vpn-server:"
  echo "          ansible_host: $vpn_public_ip"
  echo "          ansible_user: ubuntu"
  echo "          ansible_ssh_private_key_file: $SSH_PRIVATE_KEY_PATH"
  echo "          ansible_ssh_common_args: >-"
  echo "            $inventory_ssh_args"
  echo "    dcv:"
  echo "      hosts:"
  for index in "${!dcv_private_ips[@]}"; do
    host_num="$((index + 1))"
    echo "        dcv-$host_num:"
    echo "          ansible_host: ${dcv_private_ips[$index]}"
    echo "          ansible_user: ubuntu"
    echo "          ansible_ssh_private_key_file: $SSH_PRIVATE_KEY_PATH"
    echo "          ansible_ssh_common_args: >-"
    echo "            $inventory_jump_args"
  done
} >"$inventory_file"

echo "Generated $inventory_source inventory at $inventory_file"
