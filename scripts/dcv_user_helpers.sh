#!/usr/bin/env bash
set -euo pipefail

# USER PARSING BLOCK
# NORMALIZES THE VPN USER CSV INTO A CLEAN ARRAY THAT OTHER SCRIPTS CAN REUSE.
normalize_vpn_users_array() {
  local vpn_users_csv="${1:-}"
  local raw_users=()
  local raw_user=""
  local trimmed_user=""

  VPN_USERS_LIST=()
  IFS=',' read -r -a raw_users <<<"$vpn_users_csv"

  for raw_user in "${raw_users[@]}"; do
    trimmed_user="$(echo "$raw_user" | xargs)"
    if [[ -n "$trimmed_user" ]]; then
      VPN_USERS_LIST+=("$trimmed_user")
    fi
  done
}

# ENV KEY BLOCK
# CONVERTS A USERNAME INTO THE PER-USER DCV PASSWORD KEY STORED IN .ENV.
dcv_password_key_for_user() {
  local username="$1"
  local sanitized_username=""

  sanitized_username="$(printf '%s' "$username" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g; s/_\+/_/g; s/^_//; s/_$//')"
  printf 'DCV_PASSWORD_%s\n' "$sanitized_username"
}

# SUDO KEY BLOCK
# CONVERTS A USERNAME INTO THE PER-USER DCV SUDO FLAG KEY STORED IN .ENV.
dcv_sudo_key_for_user() {
  local username="$1"
  local sanitized_username=""

  sanitized_username="$(printf '%s' "$username" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g; s/_\+/_/g; s/^_//; s/_$//')"
  printf 'DCV_SUDO_%s\n' "$sanitized_username"
}

# PASSWORD GENERATION BLOCK
# CREATES A STRONG RANDOM PASSWORD SUITABLE FOR DCV USER LOGIN.
generate_dcv_password() {
  openssl rand -base64 24 | tr -d '\n'
}

# ENV UPDATE BLOCK
# UPDATES OR APPENDS A SINGLE KEY IN THE TARGET .ENV FILE.
replace_env_value_in_file() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped_value=""

  escaped_value="$(printf "%s" "$value" | sed "s/'/'\\\\''/g")"
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}='${escaped_value}'|" "$env_file"
  else
    printf "%s='%s'\n" "$key" "$escaped_value" >>"$env_file"
  fi
}
