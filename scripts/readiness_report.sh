#!/usr/bin/env bash
set -euo pipefail

# READINESS ENTRY BLOCK
# SUMMARIZES LOCAL PRE-FLIGHT STATUS SO CREATE AND CHECK CAN REPORT CLEAR BLOCKERS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"

checks_total=0
checks_passed=0

run_check() {
  local label="$1"
  shift

  checks_total="$((checks_total + 1))"
  if "$@" >/tmp/readiness_check.out 2>/tmp/readiness_check.err; then
    checks_passed="$((checks_passed + 1))"
    echo "[OK] $label"
  else
    echo "[BLOCKED] $label"
    if [[ -s /tmp/readiness_check.err ]]; then
      sed 's/^/  /' /tmp/readiness_check.err
    elif [[ -s /tmp/readiness_check.out ]]; then
      sed 's/^/  /' /tmp/readiness_check.out
    fi
  fi
}

print_live_access_summary() {
  local vpn_public_ip="$1"
  local vpn_private_ip="$2"
  local vpn_public_endpoint_mode="$3"
  local inventory_scope_ready="false"
  local dcv_index=0

  case "$vpn_public_endpoint_mode" in
    terraform_managed_elastic_ip)
      echo "VPN_PUBLIC_IP_BEHAVIOR=STATIC_ACROSS_STOP_START__NEW_IP_AFTER_FULL_DESTROY_CREATE"
      ;;
    existing_elastic_ip)
      echo "VPN_PUBLIC_IP_BEHAVIOR=STATIC_ACROSS_STOP_START_AND_REUSABLE_ACROSS_DESTROY_CREATE"
      ;;
    *)
      echo "VPN_PUBLIC_IP_BEHAVIOR=EPHEMERAL__CAN_CHANGE_AFTER_STOP_START"
      ;;
  esac

  if "$ROOT_DIR/scripts/validate_env.sh" --scope=inventory "$ROOT_DIR/.env" >/dev/null 2>&1; then
    inventory_scope_ready="true"
    source "$ROOT_DIR/scripts/load_env.sh" "$ROOT_DIR/.env"
  fi

  if [[ "$inventory_scope_ready" == "true" ]]; then
    printf 'VPN_SSH=ssh -i %q ubuntu@%s\n' "$SSH_PRIVATE_KEY_PATH" "$vpn_public_ip"
    printf 'DCV_POWER_HELPER_URL=https://%s:%s/\n' "$vpn_private_ip" "${DCV_SELF_SERVICE_PORT:-8444}"
  else
    echo "VPN_SSH=VALID .ENV SSH KEY PATHS ARE REQUIRED TO RENDER THE EXACT COMMAND"
    echo "DCV_POWER_HELPER_URL=VALID .ENV VALUES ARE REQUIRED TO RENDER THE INTERNAL HTTPS HELPER URL"
  fi

  mapfile -t dcv_private_ips < <(cd "$ROOT_DIR/terraform" && terraform output -json dcv_private_ips | jq -r '.[]')
  for dcv_index in "${!dcv_private_ips[@]}"; do
    echo "DCV_$((dcv_index + 1))_PRIVATE_IP=${dcv_private_ips[$dcv_index]}"
    echo "DCV_$((dcv_index + 1))_URL=https://${dcv_private_ips[$dcv_index]}:8443"

    if [[ "$inventory_scope_ready" == "true" ]]; then
      printf 'DCV_%s_SSH=ssh -o ProxyCommand=%q -i %q ubuntu@%s\n' \
        "$((dcv_index + 1))" \
        "ssh -i $SSH_PRIVATE_KEY_PATH ubuntu@$vpn_public_ip -W %h:%p" \
        "$SSH_PRIVATE_KEY_PATH" \
        "${dcv_private_ips[$dcv_index]}"
    else
      echo "DCV_$((dcv_index + 1))_SSH=USE ./start.sh OPTION 8 AFTER VALIDATING SSH KEY PATHS IN .ENV"
    fi
  done

  echo "VPN_PRIVATE_IP=${vpn_private_ip}"
}

echo "READINESS SUMMARY"
run_check ".env valid for Terraform" "$ROOT_DIR/scripts/validate_env.sh" --scope=terraform "$ROOT_DIR/.env"
run_check ".env valid for inventory/SSH" "$ROOT_DIR/scripts/validate_env.sh" --scope=inventory "$ROOT_DIR/.env"
run_check ".env valid for Ansible configuration" "$ROOT_DIR/scripts/validate_env.sh" --scope=ansible "$ROOT_DIR/.env"
run_check "aws CLI installed" bash -lc "command -v aws >/dev/null 2>&1"
run_check "openssl installed" bash -lc "command -v openssl >/dev/null 2>&1"
run_check "terraform installed" bash -lc "command -v terraform >/dev/null 2>&1"
run_check "ansible-playbook installed" bash -lc "command -v ansible-playbook >/dev/null 2>&1"
run_check "ansible-galaxy installed" bash -lc "command -v ansible-galaxy >/dev/null 2>&1"

readiness_percent=$((checks_passed * 100 / checks_total))
echo
echo "CREATE.SH READINESS: ${readiness_percent}%"

# OUTPUT SUMMARY BLOCK
# PRINTS LIVE CONNECTION DETAILS WHEN TERRAFORM OUTPUTS ARE AVAILABLE.
if command -v terraform >/dev/null 2>&1 \
  && "$SCRIPT_DIR/ensure_terraform_outputs.sh" >/dev/null 2>&1 \
  && (cd "$ROOT_DIR/terraform" && terraform output -json 2>/dev/null | jq -e 'has("vpn_public_ip") and has("vpn_private_ip") and has("s3_bucket_name") and has("dcv_hosts")' >/dev/null 2>&1); then
  vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
  vpn_private_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_private_ip)"
  vpn_public_endpoint_mode="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_endpoint_mode 2>/dev/null || echo unknown)"

  echo
  echo "LIVE OUTPUTS"
  (
    cd "$ROOT_DIR/terraform"
    echo "VPN_PUBLIC_IP=${vpn_public_ip}"
    echo "VPN_PUBLIC_ENDPOINT_MODE=${vpn_public_endpoint_mode}"
    echo "VPN_PRIVATE_IP=${vpn_private_ip}"
    echo "S3_BUCKET=$(terraform output -raw s3_bucket_name)"
    echo "DCV_HOSTS=$(terraform output -json dcv_hosts | jq -c .)"
    if terraform output -json dcv_user_assignments >/dev/null 2>&1; then
      echo "DCV_USER_ASSIGNMENTS=$(terraform output -json dcv_user_assignments | jq -c .)"
    fi
  )
  print_live_access_summary "$vpn_public_ip" "$vpn_private_ip" "$vpn_public_endpoint_mode"
else
  echo
  echo "LIVE OUTPUTS: not available yet because Terraform state/outputs are not present."
fi
