#!/usr/bin/env bash
set -euo pipefail

# DESTROY ORCHESTRATION BLOCK
# REMOVES THE FULL STACK USING THE SAME CENTRAL .ENV CONFIGURATION WHILE OPTIONALLY PRESERVING OR RELEASING THE VPN ELASTIC IP.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/load_local_tooling.sh"
source "$ROOT_DIR/scripts/dcv_user_helpers.sh"

ENV_FILE="$ROOT_DIR/.env"
destroy_vpn_eip_choice="destroy"
post_destroy_release_eip=false
preserve_managed_eip_requested=false
preserve_managed_eip_prepared=false
current_vpn_endpoint_mode=""
current_vpn_eip_allocation_id=""
current_vpn_public_ip=""
current_s3_bucket_name=""
env_backup_path=""
tfstate_backup_path=""

replace_env_value() {
  local key="$1"
  local value="$2"

  replace_env_value_in_file "$ENV_FILE" "$key" "$value"
}

create_destroy_rollback_backups() {
  # DESTROY ROLLBACK BACKUP BLOCK
  # CREATES TEMPORARY COPIES OF .ENV AND TERRAFORM STATE SO EIP PRESERVE PREPARATION CAN ROLL BACK CLEANLY BEFORE DESTROY STARTS.
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Cannot preserve VPN EIP because ${ENV_FILE} is missing."
    exit 1
  fi

  env_backup_path="$(mktemp)"
  cp "$ENV_FILE" "$env_backup_path"

  tfstate_backup_path="$(mktemp)"
  (
    cd "$ROOT_DIR/terraform"
    terraform state pull >"$tfstate_backup_path"
  )
}

restore_destroy_rollback_backups() {
  # DESTROY ROLLBACK RESTORE BLOCK
  # RESTORES .ENV AND TERRAFORM STATE ONLY WHEN THE PRESERVE PREPARATION STEP FAILS BEFORE TERRAFORM DESTROY STARTS.
  if [[ -n "$env_backup_path" && -f "$env_backup_path" ]]; then
    cp "$env_backup_path" "$ENV_FILE"
  fi

  if [[ -n "$tfstate_backup_path" && -f "$tfstate_backup_path" ]]; then
    (
      cd "$ROOT_DIR/terraform"
      terraform state push -force "$tfstate_backup_path" >/dev/null
    )
  fi
}

cleanup_destroy_rollback_backups() {
  # DESTROY ROLLBACK CLEANUP BLOCK
  # REMOVES TEMPORARY BACKUP FILES ONCE DESTROY COMPLETES OR THE ROLLBACK FINISHES.
  if [[ -n "$env_backup_path" && -f "$env_backup_path" ]]; then
    rm -f "$env_backup_path"
  fi
  if [[ -n "$tfstate_backup_path" && -f "$tfstate_backup_path" ]]; then
    rm -f "$tfstate_backup_path"
  fi
}

load_current_vpn_endpoint_state() {
  if [[ ! -f "$ENV_FILE" ]] || ! command -v terraform >/dev/null 2>&1; then
    return 1
  fi

  source "$ROOT_DIR/scripts/load_env.sh" "$ENV_FILE"
  if ! "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null 2>&1; then
    return 1
  fi

  current_vpn_endpoint_mode="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_endpoint_mode 2>/dev/null || true)"
  current_vpn_eip_allocation_id="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_eip_allocation_id 2>/dev/null || true)"
  current_vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip 2>/dev/null || true)"
  [[ -n "$current_vpn_endpoint_mode" ]]
}

load_current_artifact_cleanup_state() {
  # ARTIFACT CONTEXT BLOCK
  # CAPTURES THE ACTIVE S3 BUCKET NAME AND USER LIST BEFORE DESTROY SO PER-USER ARTIFACT PREFIXES CAN BE REMOVED CLEANLY.
  if [[ ! -f "$ENV_FILE" ]]; then
    return 0
  fi

  source "$ROOT_DIR/scripts/load_env.sh" "$ENV_FILE"
  normalize_vpn_users_array "${VPN_USERS_CSV:-}"
  current_s3_bucket_name="${S3_BUCKET_NAME:-}"

  if command -v terraform >/dev/null 2>&1 && "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null 2>&1; then
    current_s3_bucket_name="$(cd "$ROOT_DIR/terraform" && terraform output -raw s3_bucket_name 2>/dev/null || printf '%s' "$current_s3_bucket_name")"
  fi
}

cleanup_s3_user_artifacts() {
  # S3 ARTIFACT CLEANUP BLOCK
  # REMOVES THE PER-USER S3 PREFIXES BEFORE TERRAFORM DESTROY SO ANSIBLE-UPLOADED VPN FILES DO NOT GET LEFT BEHIND.
  local vpn_user=""

  if [[ -z "$current_s3_bucket_name" ]]; then
    return 0
  fi

  if [[ "${#VPN_USERS_LIST[@]}" -eq 0 ]]; then
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "WARNING: aws CLI is not installed, so S3 user artifact cleanup was skipped for bucket ${current_s3_bucket_name}."
    return 0
  fi

  source "$ROOT_DIR/scripts/load_env.sh" "$ENV_FILE"

  for vpn_user in "${VPN_USERS_LIST[@]}"; do
    if ! aws s3 rm "s3://${current_s3_bucket_name}/${vpn_user}/" \
      --recursive \
      --region "$AWS_REGION" >/dev/null; then
      echo "WARNING: Failed to remove s3://${current_s3_bucket_name}/${vpn_user}/ before destroy."
    fi
  done

  echo "INFO: Removed per-user VPN/DCV artifacts from s3://${current_s3_bucket_name}/<user>/ before destroy."
}

cleanup_local_user_artifacts() {
  # LOCAL ARTIFACT CLEANUP BLOCK
  # REMOVES THE CONTROLLER-SIDE PER-USER ARTIFACT DIRECTORIES AFTER A SUCCESSFUL DESTROY SO LOCAL OUTPUTS MATCH AWS CLEANUP.
  local vpn_user=""
  local removed_any_local_artifacts=false

  if [[ "${#VPN_USERS_LIST[@]}" -eq 0 ]]; then
    return 0
  fi

  for vpn_user in "${VPN_USERS_LIST[@]}"; do
    if [[ -d "$ROOT_DIR/artifacts/${vpn_user}" ]]; then
      rm -rf "$ROOT_DIR/artifacts/${vpn_user}"
      removed_any_local_artifacts=true
    fi
  done

  if [[ "$removed_any_local_artifacts" == "true" ]]; then
    echo "INFO: Removed local per-user artifact directories from $ROOT_DIR/artifacts/."
  fi
}

prepare_managed_eip_for_preservation() {
  # EIP PRESERVATION BLOCK
  # MOVES THE TERRAFORM-CREATED EIP OUT OF STATE AND SAVES ITS ALLOCATION ID IN .ENV SO THE NEXT CREATE REUSES THE SAME STATIC PUBLIC IP.
  local resource_address=""

  if [[ -z "$current_vpn_eip_allocation_id" ]]; then
    echo "ERROR: Could not determine the current VPN EIP allocation ID, so preservation cannot continue."
    exit 1
  fi

  "$ROOT_DIR/scripts/terraform_init.sh"
  create_destroy_rollback_backups

  (
    cd "$ROOT_DIR/terraform"
    for resource_address in 'aws_eip_association.vpn_new[0]' 'aws_eip.vpn[0]'; do
      if terraform state show "$resource_address" >/dev/null 2>&1; then
        terraform state rm "$resource_address" >/dev/null
      fi
    done
  ) || {
    restore_destroy_rollback_backups
    cleanup_destroy_rollback_backups
    echo "ERROR: Failed while preparing VPN EIP preservation. Restored .env and Terraform state." >&2
    exit 1
  }

  replace_env_value "CREATE_VPN_EIP" "false"
  replace_env_value "VPN_EIP_ALLOCATION_ID" "$current_vpn_eip_allocation_id"
  preserve_managed_eip_requested=true
  preserve_managed_eip_prepared=true

  echo "INFO: Preserving VPN Elastic IP allocation ${current_vpn_eip_allocation_id} for reuse after destroy."
  echo "INFO: Updated .env to CREATE_VPN_EIP=false and VPN_EIP_ALLOCATION_ID=${current_vpn_eip_allocation_id}."
}

release_existing_eip_after_destroy() {
  # EIP RELEASE BLOCK
  # RELEASES A REUSED STATIC EIP ONLY WHEN YOU EXPLICITLY ASK FOR IT AFTER THE REST OF THE STACK IS GONE.
  if [[ -z "$current_vpn_eip_allocation_id" ]]; then
    return 0
  fi

  if ! command -v aws >/dev/null 2>&1; then
    echo "WARNING: aws CLI is not installed, so the preserved Elastic IP was not released."
    return 0
  fi

  source "$ROOT_DIR/scripts/load_env.sh" "$ENV_FILE"
  aws ec2 release-address \
    --region "$AWS_REGION" \
    --allocation-id "$current_vpn_eip_allocation_id"

  replace_env_value "CREATE_VPN_EIP" "true"
  replace_env_value "VPN_EIP_ALLOCATION_ID" ""
  echo "INFO: Released Elastic IP allocation ${current_vpn_eip_allocation_id} and reset .env to Terraform-managed EIP mode."
}

prompt_for_vpn_eip_behavior() {
  local confirmation=""

  if ! load_current_vpn_endpoint_state; then
    return 0
  fi

  case "$current_vpn_endpoint_mode" in
    terraform_managed_elastic_ip)
      echo "VPN STATIC PUBLIC IP: ${current_vpn_public_ip:-UNKNOWN} (${current_vpn_eip_allocation_id})"
      read -r -p "Do you want to destroy the Elastic IP (${current_vpn_public_ip:-UNKNOWN}) attached to the VPN server? [y/N]: " confirmation
      if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        destroy_vpn_eip_choice="destroy"
      else
        destroy_vpn_eip_choice="preserve"
        prepare_managed_eip_for_preservation
      fi
      ;;
    existing_elastic_ip)
      echo "VPN STATIC PUBLIC IP: ${current_vpn_public_ip:-UNKNOWN} (${current_vpn_eip_allocation_id})"
      read -r -p "Do you want to destroy the Elastic IP (${current_vpn_public_ip:-UNKNOWN}) attached to the VPN server after infra destroy? [y/N]: " confirmation
      if [[ "$confirmation" =~ ^[Yy]$ ]]; then
        post_destroy_release_eip=true
      fi
      ;;
    *)
      :
      ;;
  esac
}

load_current_artifact_cleanup_state
prompt_for_vpn_eip_behavior
cleanup_s3_user_artifacts

if ! "$ROOT_DIR/scripts/terraform_destroy.sh"; then
  if [[ "$preserve_managed_eip_requested" == "true" ]]; then
    cleanup_destroy_rollback_backups
    echo "ERROR: Destroy failed after preparing VPN EIP preservation." >&2
    echo "INFO: The VPN EIP remains preserved. .env is still set to CREATE_VPN_EIP=false and VPN_EIP_ALLOCATION_ID=${current_vpn_eip_allocation_id} so a retry will not release it." >&2
  fi
  exit 1
fi

cleanup_local_user_artifacts

if [[ "$post_destroy_release_eip" == "true" ]]; then
  release_existing_eip_after_destroy
fi

if [[ "$preserve_managed_eip_prepared" == "true" ]]; then
  cleanup_destroy_rollback_backups
fi
