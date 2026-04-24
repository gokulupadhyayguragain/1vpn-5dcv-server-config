#!/usr/bin/env bash
set -euo pipefail

# PASSWORD MANAGEMENT ENTRY BLOCK
# CREATES, ROTATES, AND LISTS PER-USER DCV PASSWORD KEYS INSIDE THE CENTRAL .ENV FILE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/dcv_user_helpers.sh"

command_name="${1:-ensure}"
target_user="${2:-}"
custom_password="${3:-}"
env_file="${4:-$ROOT_DIR/.env}"

case "$command_name" in
  ensure|reset-all|show)
    env_file="${2:-$ROOT_DIR/.env}"
    ;;
  reset)
    env_file="${4:-$ROOT_DIR/.env}"
    ;;
  *)
    :
    ;;
esac

if [[ ! -f "$env_file" ]]; then
  echo "ERROR: .env file not found at $env_file"
  exit 1
fi

source "$SCRIPT_DIR/load_env.sh" "$env_file"
normalize_vpn_users_array "${VPN_USERS_CSV:-}"

if [[ "${#VPN_USERS_LIST[@]}" -eq 0 ]]; then
  echo "ERROR: VPN_USERS_CSV must contain at least one user before managing DCV passwords."
  exit 1
fi

ensure_passwords() {
  local user_name=""
  local env_key=""

  for user_name in "${VPN_USERS_LIST[@]}"; do
    env_key="$(dcv_password_key_for_user "$user_name")"
    if [[ -z "${!env_key:-}" ]] || [[ "${!env_key:-}" == CHANGE_ME* ]]; then
      replace_env_value_in_file "$env_file" "$env_key" "$(generate_dcv_password)"
      echo "Generated ${env_key} for ${user_name} in ${env_file}."
    fi
  done
}

reset_one_password() {
  local user_name="$1"
  local requested_password="${2:-}"
  local env_key=""
  local resolved_password=""
  local known_user=false
  local existing_user=""

  for existing_user in "${VPN_USERS_LIST[@]}"; do
    if [[ "$existing_user" == "$user_name" ]]; then
      known_user=true
      break
    fi
  done

  if [[ "$known_user" != "true" ]]; then
    echo "ERROR: ${user_name} is not present in VPN_USERS_CSV."
    exit 1
  fi

  env_key="$(dcv_password_key_for_user "$user_name")"
  resolved_password="${requested_password:-$(generate_dcv_password)}"
  replace_env_value_in_file "$env_file" "$env_key" "$resolved_password"
  echo "Updated ${env_key} for ${user_name} in ${env_file}."
}

show_password_keys() {
  local user_name=""

  echo "DCV USER PASSWORD KEYS"
  for user_name in "${VPN_USERS_LIST[@]}"; do
    echo "  ${user_name} -> $(dcv_password_key_for_user "$user_name")"
  done
}

case "$command_name" in
  ensure)
    ensure_passwords
    ;;
  reset)
    if [[ -z "$target_user" ]]; then
      echo "ERROR: Usage: ./scripts/manage_dcv_passwords.sh reset <user> [password] [env_file]"
      exit 1
    fi
    reset_one_password "$target_user" "$custom_password"
    ;;
  reset-all)
    for user_name in "${VPN_USERS_LIST[@]}"; do
      reset_one_password "$user_name"
    done
    ;;
  show)
    show_password_keys
    ;;
  *)
    echo "ERROR: Unsupported command: $command_name"
    echo "USAGE:"
    echo "  ./scripts/manage_dcv_passwords.sh ensure [env_file]"
    echo "  ./scripts/manage_dcv_passwords.sh reset <user> [password] [env_file]"
    echo "  ./scripts/manage_dcv_passwords.sh reset-all [env_file]"
    echo "  ./scripts/manage_dcv_passwords.sh show [env_file]"
    exit 1
    ;;
esac
