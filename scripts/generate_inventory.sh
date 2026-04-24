#!/usr/bin/env bash
set -euo pipefail

# INVENTORY SOURCE BLOCK
# PULLS REQUIRED HOST DATA FROM TERRAFORM OUTPUTS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=inventory "$ROOT_DIR/.env"
"$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null

cd "$ROOT_DIR/terraform"
if ! terraform output -json 2>/dev/null | jq -e 'has("vpn_public_ip") and has("dcv_private_ips")' >/dev/null 2>&1; then
  echo "ERROR: Terraform outputs are unavailable. Run create first."
  exit 1
fi

vpn_public_ip="$(terraform output -raw vpn_public_ip)"
mapfile -t dcv_private_ips < <(terraform output -json dcv_private_ips | jq -r '.[]')
inventory_ssh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
proxy_command="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -i $SSH_PRIVATE_KEY_PATH ubuntu@$vpn_public_ip -W %h:%p"

# INVENTORY RENDER BLOCK
# CREATES BASTION-AWARE INVENTORY FOR PRIVATE DCV HOST ACCESS.
inventory_file="$ROOT_DIR/ansible/inventories/hosts.ini"
mkdir -p "$(dirname "$inventory_file")"

{
  echo "[vpn]"
  echo "vpn-server ansible_host=$vpn_public_ip ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_PRIVATE_KEY_PATH ansible_ssh_common_args='$inventory_ssh_args'"
  echo
  echo "[dcv]"
  for index in "${!dcv_private_ips[@]}"; do
    host_num="$((index + 1))"
    echo "dcv-$host_num ansible_host=${dcv_private_ips[$index]} ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_PRIVATE_KEY_PATH ansible_ssh_common_args='$inventory_ssh_args -o ProxyCommand=\"$proxy_command\"'"
  done
} >"$inventory_file"

echo "Generated inventory at $inventory_file"
