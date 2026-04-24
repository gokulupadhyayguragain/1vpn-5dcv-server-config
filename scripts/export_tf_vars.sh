#!/usr/bin/env bash
set -euo pipefail

# TERRAFORM EXPORT ENTRY BLOCK
# LOADS AND VALIDATES THE CENTRAL CONFIG BEFORE MAPPING IT TO TF_VAR INPUTS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/validate_env.sh" --scope=terraform "${1:-$ROOT_DIR/.env}"

export TF_IN_AUTOMATION=1
export TF_VAR_project_name="$PROJECT_NAME"
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_availability_zone="$AWS_AVAILABILITY_ZONE"
export TF_VAR_vpc_cidr="$VPC_CIDR"
export TF_VAR_public_subnet_cidr="$PUBLIC_SUBNET_CIDR"
export TF_VAR_private_subnet_cidr="$PRIVATE_SUBNET_CIDR"
export TF_VAR_vpn_private_ip="${VPN_PRIVATE_IP:-}"
export TF_VAR_vpn_client_cidr="$VPN_CLIENT_CIDR"
export TF_VAR_dcv_self_service_port="${DCV_SELF_SERVICE_PORT:-8444}"
export TF_VAR_allowed_admin_cidr="$ALLOWED_ADMIN_CIDR"
export TF_VAR_vpn_instance_type="$VPN_INSTANCE_TYPE"
export TF_VAR_create_vpn_eip="${CREATE_VPN_EIP:-true}"
export TF_VAR_vpn_eip_allocation_id="${VPN_EIP_ALLOCATION_ID:-}"
export TF_VAR_vpn_dcv_control_instance_profile_name="${VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME:-}"
export TF_VAR_dcv_instance_type="$DCV_INSTANCE_TYPE"
export TF_VAR_dcv_instance_count="$DCV_INSTANCE_COUNT"
export TF_VAR_dcv_use_spot="${DCV_USE_SPOT:-true}"
export TF_VAR_dcv_spot_max_price="${DCV_SPOT_MAX_PRICE:-}"
export TF_VAR_vpn_root_volume_size_gb="$VPN_ROOT_VOLUME_SIZE_GB"
export TF_VAR_dcv_root_volume_size_gb="$DCV_ROOT_VOLUME_SIZE_GB"
export TF_VAR_ssh_public_key_path="$SSH_PUBLIC_KEY_PATH"
export TF_VAR_ssh_key_name="$SSH_KEY_NAME"
export TF_VAR_ami_id="${AMI_ID:-}"
export TF_VAR_create_s3_bucket="$CREATE_S3_BUCKET"
export TF_VAR_s3_bucket_name="${S3_BUCKET_NAME:-}"

# USER LIST EXPORT BLOCK
# CONVERTS THE COMMA-SEPARATED VPN USER LIST INTO THE JSON ARRAY TERRAFORM EXPECTS.
IFS=',' read -r -a vpn_users_array <<<"$VPN_USERS_CSV"
vpn_users_json="["

for user in "${vpn_users_array[@]}"; do
  sanitized_user="$(echo "$user" | xargs)"
  if [[ -n "$sanitized_user" ]]; then
    if [[ "$vpn_users_json" != "[" ]]; then
      vpn_users_json+=","
    fi
    vpn_users_json+="\"$sanitized_user\""
  fi
done

vpn_users_json+="]"
export TF_VAR_vpn_users="$vpn_users_json"

# STATIC DCV IPS EXPORT BLOCK
# CONVERTS OPTIONAL COMMA-SEPARATED STATIC IP LIST INTO THE JSON ARRAY TERRAFORM EXPECTS.
IFS=',' read -r -a dcv_private_ips_array <<<"${DCV_PRIVATE_IPS_CSV:-}"
dcv_private_ips_json="["

for raw_ip in "${dcv_private_ips_array[@]}"; do
  sanitized_ip="$(echo "$raw_ip" | xargs)"
  if [[ -n "$sanitized_ip" ]]; then
    if [[ "$dcv_private_ips_json" != "[" ]]; then
      dcv_private_ips_json+=","
    fi
    dcv_private_ips_json+="\"$sanitized_ip\""
  fi
done

dcv_private_ips_json+="]"
export TF_VAR_dcv_private_ips="$dcv_private_ips_json"
