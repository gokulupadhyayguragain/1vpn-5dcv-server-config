#!/usr/bin/env bash
set -euo pipefail

# CHECK ORCHESTRATION BLOCK
# RUNS LOCAL SMOKE TESTS FIRST AND REMOTE VALIDATION WHEN TERRAFORM OUTPUTS EXIST.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/load_local_tooling.sh"
"$ROOT_DIR/scripts/readiness_report.sh"
echo
"$ROOT_DIR/scripts/smoke_check.sh"

# REMOTE VALIDATION BLOCK
# REUSES THE GENERATED INVENTORY TO VERIFY THE LIVE HOSTS WHEN THE STACK EXISTS.
if command -v terraform >/dev/null 2>&1 \
  && command -v ansible-playbook >/dev/null 2>&1 \
  && [[ -f "$ROOT_DIR/.env" ]] \
  && "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null 2>&1 \
  && (cd "$ROOT_DIR/terraform" && terraform output -json 2>/dev/null | jq -e 'has("vpn_public_ip") and has("s3_bucket_name") and has("dcv_private_ips")' >/dev/null 2>&1); then
  source "$ROOT_DIR/scripts/validate_env.sh" --scope=ansible "$ROOT_DIR/.env"
  "$ROOT_DIR/scripts/generate_inventory.sh"
  export S3_BUCKET_NAME="$(cd "$ROOT_DIR/terraform" && terraform output -raw s3_bucket_name)"
  export ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg"
  ansible-playbook -i "$ROOT_DIR/ansible/inventories/hosts.ini" "$ROOT_DIR/ansible/playbooks/validate.yml"
else
  echo "INFO: Terraform outputs not available, skipped remote validation"
fi
