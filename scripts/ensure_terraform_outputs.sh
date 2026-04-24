#!/usr/bin/env bash
set -euo pipefail

# OUTPUT RECOVERY ENTRY BLOCK
# RESTORES LOCAL TERRAFORM OUTPUTS FROM THE LAST KNOWN GOOD BACKUP WHEN THE ACTIVE LOCAL STATE FILE IS EMPTY.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
if [[ -f "$ROOT_DIR/.env" ]]; then
  source "$SCRIPT_DIR/load_env.sh" "$ROOT_DIR/.env"
fi

cd "$ROOT_DIR/terraform"

if terraform output -json 2>/dev/null | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
  exit 0
fi

# LOCAL STATE RECOVERY BLOCK
# USES terraform.tfstate.backup ONLY FOR LOCAL STATE MODE SO OUTPUT-DRIVEN SSH AND ANSIBLE FLOWS CAN KEEP WORKING AFTER AN INTERRUPTED RUN.
if [[ -f "$ROOT_DIR/terraform/backend_override.tf" ]]; then
  echo "ERROR: Terraform outputs are unavailable from the configured backend." >&2
  exit 1
fi

if [[ ! -f "$ROOT_DIR/terraform/terraform.tfstate.backup" ]]; then
  echo "ERROR: Terraform outputs are unavailable and no backup state file exists." >&2
  exit 1
fi

if ! jq -e '(.resources | length) > 0 and (.outputs | length) > 0' "$ROOT_DIR/terraform/terraform.tfstate.backup" >/dev/null 2>&1; then
  echo "ERROR: Terraform outputs are unavailable and the backup state file does not contain usable outputs." >&2
  exit 1
fi

# BACKUP VALIDATION BLOCK
# CONFIRMS THE BACKUP INSTANCE IDS STILL EXIST IN AWS BEFORE REUSING THEM SO STALE OUTPUTS DO NOT BREAK SSH OR INVENTORY AFTER RESOURCES WERE DESTROYED.
mapfile -t backup_instance_ids < <(jq -r '.resources[] | select(.type == "aws_instance") | .instances[].attributes.id // empty' "$ROOT_DIR/terraform/terraform.tfstate.backup")
if [[ "${#backup_instance_ids[@]}" -gt 0 ]] && command -v aws >/dev/null 2>&1 && [[ -n "${AWS_REGION:-}" ]]; then
  if ! backup_instance_query="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "${backup_instance_ids[@]}" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"; then
    echo "ERROR: Terraform outputs are unavailable and the backup state no longer matches live AWS instances. Re-run ./scripts/terraform_apply.sh." >&2
    exit 1
  fi

  mapfile -t live_backup_instance_ids < <(printf '%s\n' "$backup_instance_query" | tr '\t' '\n' | sed '/^$/d')
  if [[ "${#live_backup_instance_ids[@]}" -ne "${#backup_instance_ids[@]}" ]]; then
    echo "ERROR: Terraform outputs are unavailable and the backup state no longer matches live AWS instances. Re-run ./scripts/terraform_apply.sh." >&2
    exit 1
  fi
fi

cp "$ROOT_DIR/terraform/terraform.tfstate.backup" "$ROOT_DIR/terraform/terraform.tfstate"

if ! terraform output -json 2>/dev/null | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
  echo "ERROR: Terraform state recovery did not restore usable outputs." >&2
  exit 1
fi

echo "Recovered Terraform outputs from terraform.tfstate.backup." >&2
