#!/usr/bin/env bash
set -euo pipefail

# SCOPE PARSING BLOCK
# SUPPORTS TARGETED VALIDATION SO TERRAFORM AND ANSIBLE CAN CHECK ONLY WHAT THEY NEED.
VALIDATION_SCOPE="${VALIDATION_SCOPE:-full}"
ENV_FILE_ARG=""

for arg in "$@"; do
  case "$arg" in
    --scope=*)
      VALIDATION_SCOPE="${arg#--scope=}"
      ;;
    *)
      ENV_FILE_ARG="$arg"
      ;;
  esac
done

# ENV VALIDATION ENTRY BLOCK
# LOADS THE CENTRAL CONFIG AND FAILS FAST WHEN REQUIRED INPUTS ARE MISSING.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_env.sh" "${ENV_FILE_ARG:-$ROOT_DIR/.env}"
source "$SCRIPT_DIR/dcv_user_helpers.sh"

common_required_vars=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_REGION
  AWS_AVAILABILITY_ZONE
  PROJECT_NAME
  VPC_CIDR
  PUBLIC_SUBNET_CIDR
  PRIVATE_SUBNET_CIDR
  VPN_CLIENT_CIDR
  ALLOWED_ADMIN_CIDR
  VPN_INSTANCE_TYPE
  DCV_INSTANCE_TYPE
  DCV_INSTANCE_COUNT
  DCV_SWAP_SIZE_GB
  VPN_ROOT_VOLUME_SIZE_GB
  DCV_ROOT_VOLUME_SIZE_GB
  CREATE_S3_BUCKET
  VPN_USERS_CSV
  NICE_DCV_DOWNLOAD_URL
)

terraform_required_vars=(
  SSH_PUBLIC_KEY_PATH
  SSH_KEY_NAME
)

inventory_required_vars=(
  SSH_PRIVATE_KEY_PATH
)

ansible_required_vars=(
  SSH_PRIVATE_KEY_PATH
)

case "$VALIDATION_SCOPE" in
  terraform)
    required_vars=("${common_required_vars[@]}" "${terraform_required_vars[@]}")
    ;;
  inventory)
    required_vars=("${common_required_vars[@]}" "${inventory_required_vars[@]}")
    ;;
  ansible)
    required_vars=("${common_required_vars[@]}" "${inventory_required_vars[@]}" "${ansible_required_vars[@]}")
    ;;
  full)
    required_vars=("${common_required_vars[@]}" "${terraform_required_vars[@]}" "${inventory_required_vars[@]}" "${ansible_required_vars[@]}")
    ;;
  *)
    echo "ERROR: Unsupported validation scope: $VALIDATION_SCOPE" >&2
    exit 1
    ;;
esac

# REQUIRED VALUE CHECK BLOCK
# ENFORCES THE MINIMUM VARIABLES NEEDED TO BUILD, CONFIGURE, AND ACCESS THE STACK.
validation_errors=()

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    validation_errors+=("MISSING REQUIRED VARIABLE: ${var_name}")
  fi
done

if [[ "${CREATE_S3_BUCKET:-}" != "true" ]] && [[ "${CREATE_S3_BUCKET:-}" != "false" ]]; then
  validation_errors+=("CREATE_S3_BUCKET MUST BE 'true' OR 'false'")
fi

if [[ "${CREATE_VPN_EIP:-true}" != "true" ]] && [[ "${CREATE_VPN_EIP:-true}" != "false" ]]; then
  validation_errors+=("CREATE_VPN_EIP MUST BE 'true' OR 'false'")
fi

if [[ "${DCV_USE_SPOT:-true}" != "true" ]] && [[ "${DCV_USE_SPOT:-true}" != "false" ]]; then
  validation_errors+=("DCV_USE_SPOT MUST BE 'true' OR 'false'")
fi

if [[ -n "${VPN_EIP_ALLOCATION_ID:-}" ]] && [[ ! "${VPN_EIP_ALLOCATION_ID:-}" =~ ^eipalloc- ]]; then
  validation_errors+=("VPN_EIP_ALLOCATION_ID MUST START WITH eipalloc- WHEN SET")
fi

if [[ -n "${VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME:-}" ]] && [[ ! "${VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME:-}" =~ ^[A-Za-z0-9+=,.@_-]+$ ]]; then
  validation_errors+=("VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME CONTAINS INVALID CHARACTERS")
fi

if [[ "${CREATE_VPN_EIP:-true}" == "true" ]] && [[ -n "${VPN_EIP_ALLOCATION_ID:-}" ]]; then
  validation_errors+=("USE EITHER CREATE_VPN_EIP=true FOR A TERRAFORM-MANAGED ELASTIC IP OR CREATE_VPN_EIP=false WITH VPN_EIP_ALLOCATION_ID FOR A REUSED ELASTIC IP")
fi

if [[ "${CREATE_S3_BUCKET:-}" == "false" ]] && [[ -z "${S3_BUCKET_NAME:-}" ]]; then
  validation_errors+=("S3_BUCKET_NAME IS REQUIRED WHEN CREATE_S3_BUCKET=false")
fi

if [[ -n "${TF_STATE_BUCKET_NAME:-}" ]] && [[ -z "${TF_STATE_KEY:-}" ]]; then
  validation_errors+=("TF_STATE_KEY IS REQUIRED WHEN TF_STATE_BUCKET_NAME IS SET")
fi

if [[ -n "${TF_STATE_BUCKET_NAME:-}" ]] \
  && [[ -n "${S3_BUCKET_NAME:-}" ]] \
  && [[ "${TF_STATE_BUCKET_NAME:-}" == "${S3_BUCKET_NAME:-}" ]] \
  && [[ "${CREATE_S3_BUCKET:-}" == "true" ]]; then
  validation_errors+=("WHEN TF_STATE_BUCKET_NAME MATCHES S3_BUCKET_NAME, SET CREATE_S3_BUCKET=false AND PRE-CREATE THE SHARED BUCKET")
fi

if [[ ! "${DCV_INSTANCE_COUNT:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_INSTANCE_COUNT MUST BE A POSITIVE INTEGER")
fi

if [[ ! "${VPN_ROOT_VOLUME_SIZE_GB:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("VPN_ROOT_VOLUME_SIZE_GB MUST BE A POSITIVE INTEGER")
fi

if [[ ! "${DCV_ROOT_VOLUME_SIZE_GB:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_ROOT_VOLUME_SIZE_GB MUST BE A POSITIVE INTEGER")
fi

if [[ ! "${DCV_IDLE_TIMEOUT_MINUTES:-10}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_IDLE_TIMEOUT_MINUTES MUST BE A POSITIVE INTEGER")
fi

if [[ ! "${DCV_IDLE_TIMEOUT_WARNING_SECONDS:-120}" =~ ^[0-9]+$ ]]; then
  validation_errors+=("DCV_IDLE_TIMEOUT_WARNING_SECONDS MUST BE A NON-NEGATIVE INTEGER")
fi

if [[ ! "${DCV_STOP_AFTER_IDLE_DISCONNECT_SECONDS:-60}" =~ ^[0-9]+$ ]]; then
  validation_errors+=("DCV_STOP_AFTER_IDLE_DISCONNECT_SECONDS MUST BE A NON-NEGATIVE INTEGER")
fi

if [[ -n "${DCV_SPOT_MAX_PRICE:-}" ]] && [[ ! "${DCV_SPOT_MAX_PRICE:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  validation_errors+=("DCV_SPOT_MAX_PRICE MUST BE A NUMBER WHEN SET")
fi

if [[ ! "${DCV_SWAP_SIZE_GB:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_SWAP_SIZE_GB MUST BE A POSITIVE INTEGER")
fi

if [[ -n "${DCV_SELF_SERVICE_PORT:-}" ]] && [[ ! "${DCV_SELF_SERVICE_PORT:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_SELF_SERVICE_PORT MUST BE A POSITIVE INTEGER WHEN SET")
fi

if [[ "${DCV_SELF_SERVICE_PORT:-8444}" =~ ^[1-9][0-9]*$ ]] && (( ${DCV_SELF_SERVICE_PORT:-8444} > 65535 )); then
  validation_errors+=("DCV_SELF_SERVICE_PORT MUST BE BETWEEN 1 AND 65535")
fi

if [[ -n "${DCV_CONFIG_SERIAL:-}" ]] && [[ ! "${DCV_CONFIG_SERIAL:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_CONFIG_SERIAL MUST BE A POSITIVE INTEGER WHEN SET")
fi

if [[ -n "${DCV_BOOTSTRAP_TIMEOUT_SECONDS:-}" ]] && [[ ! "${DCV_BOOTSTRAP_TIMEOUT_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_BOOTSTRAP_TIMEOUT_SECONDS MUST BE A POSITIVE INTEGER WHEN SET")
fi

if [[ -n "${DCV_BOOTSTRAP_POLL_INTERVAL_SECONDS:-}" ]] && [[ ! "${DCV_BOOTSTRAP_POLL_INTERVAL_SECONDS:-}" =~ ^[1-9][0-9]*$ ]]; then
  validation_errors+=("DCV_BOOTSTRAP_POLL_INTERVAL_SECONDS MUST BE A POSITIVE INTEGER WHEN SET")
fi

if [[ "${AWS_AVAILABILITY_ZONE:-}" != "${AWS_REGION:-}"* ]]; then
  validation_errors+=("AWS_AVAILABILITY_ZONE MUST BELONG TO AWS_REGION")
fi

if [[ -n "${VPN_PRIVATE_IP:-}" ]] && [[ ! "${VPN_PRIVATE_IP:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  validation_errors+=("VPN_PRIVATE_IP MUST BE A VALID IPV4 ADDRESS WHEN SET")
fi

if [[ -n "${DCV_PRIVATE_IPS_CSV:-}" ]]; then
  IFS=',' read -r -a dcv_private_ips_list <<<"${DCV_PRIVATE_IPS_CSV:-}"
  normalized_dcv_ip_count=0

  for ip_value in "${dcv_private_ips_list[@]}"; do
    trimmed_ip="$(echo "$ip_value" | xargs)"
    if [[ -z "$trimmed_ip" ]]; then
      continue
    fi

    if [[ ! "$trimmed_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      validation_errors+=("DCV_PRIVATE_IPS_CSV CONTAINS INVALID IPV4: $trimmed_ip")
    fi

    normalized_dcv_ip_count="$((normalized_dcv_ip_count + 1))"
  done

  if [[ "${DCV_INSTANCE_COUNT:-}" =~ ^[1-9][0-9]*$ ]] && [[ "$normalized_dcv_ip_count" -ne "${DCV_INSTANCE_COUNT:-0}" ]]; then
    validation_errors+=("DCV_PRIVATE_IPS_CSV COUNT MUST MATCH DCV_INSTANCE_COUNT WHEN STATIC IPS ARE USED")
  fi
fi

if [[ " ${required_vars[*]} " == *" SSH_PUBLIC_KEY_PATH "* ]] && [[ ! -f "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
  validation_errors+=("SSH_PUBLIC_KEY_PATH DOES NOT EXIST: ${SSH_PUBLIC_KEY_PATH:-}")
fi

if [[ " ${required_vars[*]} " == *" SSH_PRIVATE_KEY_PATH "* ]] && [[ ! -f "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
  validation_errors+=("SSH_PRIVATE_KEY_PATH DOES NOT EXIST: ${SSH_PRIVATE_KEY_PATH:-}")
fi

if [[ "${AWS_ACCESS_KEY_ID:-}" == YOUR_* ]] || [[ "${AWS_SECRET_ACCESS_KEY:-}" == YOUR_* ]]; then
  validation_errors+=("REPLACE PLACEHOLDER VALUES IN .env BEFORE RUNNING")
fi

declare -A seen_vpn_users=()
legacy_password_fallback_used=false
missing_dcv_password_users=()

normalize_vpn_users_array "${VPN_USERS_CSV:-}"
valid_user_count="${#VPN_USERS_LIST[@]}"

if [[ "$valid_user_count" -eq 0 ]]; then
  validation_errors+=("VPN_USERS_CSV MUST CONTAIN AT LEAST ONE USER")
fi

if [[ "${DCV_INSTANCE_COUNT:-}" =~ ^[1-9][0-9]*$ ]] && [[ "${DCV_INSTANCE_COUNT:-0}" -ne "$valid_user_count" ]]; then
  validation_errors+=("DCV_INSTANCE_COUNT MUST MATCH THE NUMBER OF USERS IN VPN_USERS_CSV FOR DEDICATED USER-TO-HOST MAPPING")
fi

for user in "${VPN_USERS_LIST[@]}"; do
  password_key="$(dcv_password_key_for_user "$user")"
  sudo_key="$(dcv_sudo_key_for_user "$user")"

  if [[ ! "$user" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    validation_errors+=("VPN USERNAME '$user' MUST MATCH ^[a-z][a-z0-9_-]*$")
  fi

  if [[ -n "${seen_vpn_users[$user]:-}" ]]; then
    validation_errors+=("VPN USERNAME '$user' IS DUPLICATED IN VPN_USERS_CSV")
  fi
  seen_vpn_users["$user"]=1

  if [[ "$VALIDATION_SCOPE" == "ansible" || "$VALIDATION_SCOPE" == "full" ]]; then
    if [[ -n "${!password_key:-}" ]] && [[ "${!password_key:-}" != CHANGE_ME* ]]; then
      continue
    fi

    if [[ -n "${DCV_SESSION_PASSWORD:-}" ]] && [[ "${DCV_SESSION_PASSWORD:-}" != CHANGE_ME* ]]; then
      legacy_password_fallback_used=true
      continue
    fi

    missing_dcv_password_users+=("$user")
  fi

  if [[ -n "${!sudo_key:-}" ]] && [[ "${!sudo_key:-}" != "true" ]] && [[ "${!sudo_key:-}" != "false" ]]; then
    validation_errors+=("${sudo_key} MUST BE 'true' OR 'false' WHEN SET")
  fi
done

if [[ "${#missing_dcv_password_users[@]}" -gt 0 ]]; then
  validation_errors+=("DEFINE PER-USER DCV PASSWORDS IN .env FOR: ${missing_dcv_password_users[*]}")
fi

if [[ "${#validation_errors[@]}" -gt 0 ]]; then
  printf 'ERROR: %s\n' "${validation_errors[@]}" >&2
  exit 1
fi

if [[ "${ALLOWED_ADMIN_CIDR:-}" == "0.0.0.0/0" ]]; then
  echo "WARNING: ALLOWED_ADMIN_CIDR IS OPEN TO THE WORLD. SET A TIGHTER CIDR FOR BETTER SECURITY." >&2
fi

if [[ "${CREATE_VPN_EIP:-true}" == "false" ]] && [[ -z "${VPN_EIP_ALLOCATION_ID:-}" ]]; then
  echo "WARNING: VPN PUBLIC IP IS EPHEMERAL. IT CAN CHANGE AFTER STOP/START. SET CREATE_VPN_EIP=true OR PROVIDE VPN_EIP_ALLOCATION_ID FOR A STATIC PUBLIC IP." >&2
fi

if [[ "${CREATE_VPN_EIP:-true}" == "true" ]] && [[ -z "${VPN_EIP_ALLOCATION_ID:-}" ]]; then
  echo "WARNING: TERRAFORM-MANAGED ELASTIC IP STAYS STATIC FOR STOP/START. DESTROY.SH NOW ASKS WHETHER TO PRESERVE IT FOR FUTURE REUSE OR DESTROY IT WITH THE STACK." >&2
fi

if [[ "${LEGACY_ROOT_VOLUME_SIZE_GB_FALLBACK_USED:-false}" == "true" ]]; then
  echo "WARNING: USING LEGACY ROOT_VOLUME_SIZE_GB FALLBACK. DEFINE VPN_ROOT_VOLUME_SIZE_GB AND DCV_ROOT_VOLUME_SIZE_GB IN .env FOR CLEANER PER-ROLE STORAGE CONTROL." >&2
fi

if [[ -z "${VPN_PRIVATE_IP:-}" ]]; then
  echo "WARNING: VPN_PRIVATE_IP IS EMPTY. THE VPN HOST PRIVATE IP MAY CHANGE AFTER A FULL DESTROY/CREATE." >&2
fi

if [[ -z "${DCV_PRIVATE_IPS_CSV:-}" ]]; then
  echo "WARNING: DCV_PRIVATE_IPS_CSV IS EMPTY. PRIVATE DCV HOST IPS MAY CHANGE AFTER A FULL DESTROY/CREATE." >&2
fi

if [[ -n "${VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME:-}" ]]; then
  echo "INFO: USING PRE-CREATED VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME=${VPN_DCV_CONTROL_INSTANCE_PROFILE_NAME}. TERRAFORM WILL SKIP IAM ROLE AND INSTANCE PROFILE CREATION." >&2
fi

if [[ "$legacy_password_fallback_used" == "true" ]]; then
  echo "WARNING: USING LEGACY DCV_SESSION_PASSWORD FALLBACK. DEFINE DCV_PASSWORD_<USER> KEYS FOR UNIQUE USER PASSWORDS." >&2
fi
