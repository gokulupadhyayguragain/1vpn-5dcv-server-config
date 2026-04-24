#!/usr/bin/env bash
set -euo pipefail

# PREP BLOCK
# LOADS ENVIRONMENT AND REGENERATES INVENTORY FROM TERRAFORM STATE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/validate_env.sh" --scope=ansible "$ROOT_DIR/.env"
"$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null
"$SCRIPT_DIR/generate_inventory.sh"
"$SCRIPT_DIR/wait_for_vpn_ssh.sh"

export S3_BUCKET_NAME="$(cd "$ROOT_DIR/terraform" && terraform output -raw s3_bucket_name)"
export ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="/tmp/.ansible-local"
export ANSIBLE_REMOTE_TEMP="/var/tmp/.ansible/tmp"
export ANSIBLE_SSH_CONTROL_PATH_DIR="/tmp/.ansible/cp"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
mkdir -p "$ANSIBLE_SSH_CONTROL_PATH_DIR"

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  echo "ERROR: ansible-galaxy is not installed"
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible-playbook is not installed"
  exit 1
fi

# EXECUTION BLOCK
# RUNS CONFIGURATION PLAYBOOKS THEN RUNS VALIDATION CHECKS.
cd "$ROOT_DIR"
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventories/hosts.ini ansible/playbooks/site.yml
ansible-playbook -i ansible/inventories/hosts.ini ansible/playbooks/validate.yml
