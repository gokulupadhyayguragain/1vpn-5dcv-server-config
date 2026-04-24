#!/usr/bin/env bash
set -euo pipefail

# INTERACTIVE MENU BLOCK
# PROVIDES A SINGLE ENTRYPOINT TO CREATE, CHECK, DESTROY, AND SSH INTO THE STACK.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/load_local_tooling.sh"
source "$ROOT_DIR/scripts/dcv_user_helpers.sh"
SSH_MENU_ARGS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
)

build_proxy_command() {
  local vpn_public_ip="$1"

  printf 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=15 -i %q ubuntu@%s -W %%h:%%p' "$SSH_PRIVATE_KEY_PATH" "$vpn_public_ip"
}

load_valid_env() {
  local validation_scope="${1:-inventory}"
  source "$ROOT_DIR/scripts/validate_env.sh" "--scope=${validation_scope}" "$ROOT_DIR/.env"
}

load_env_only() {
  source "$ROOT_DIR/scripts/load_env.sh" "$ROOT_DIR/.env"
}

show_outputs() {
  "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null
  (
    cd "$ROOT_DIR/terraform"
    terraform output
  )

  if (cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_endpoint_mode >/dev/null 2>&1); then
    vpn_public_endpoint_mode="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_endpoint_mode)"
    vpn_eip_allocation_id="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_eip_allocation_id 2>/dev/null || true)"
    echo

    case "$vpn_public_endpoint_mode" in
      terraform_managed_elastic_ip)
        echo "VPN PUBLIC IP MODE: TERRAFORM-MANAGED ELASTIC IP"
        echo "PUBLIC IP BEHAVIOR: SAME IP ACROSS EC2 STOP/START, BUT A FULL DESTROY/CREATE WILL CREATE A NEW EIP."
        ;;
      existing_elastic_ip)
        echo "VPN PUBLIC IP MODE: REUSED EXISTING ELASTIC IP"
        echo "PUBLIC IP BEHAVIOR: SAME IP ACROSS EC2 STOP/START AND CAN STAY THE SAME ACROSS FUTURE DESTROY/CREATE."
        ;;
      *)
        echo "VPN PUBLIC IP MODE: EPHEMERAL PUBLIC IP"
        echo "PUBLIC IP BEHAVIOR: CAN CHANGE AFTER STOP/START. SET CREATE_VPN_EIP=true OR PROVIDE VPN_EIP_ALLOCATION_ID."
        ;;
    esac

    if [[ -n "$vpn_eip_allocation_id" ]]; then
      echo "VPN EIP ALLOCATION ID: $vpn_eip_allocation_id"
    fi
  fi
}

show_operator_flow() {
  cat <<'EOF'

RECOMMENDED FLOW
FRESH MACHINE OR FRESH GIT CLONE
  1) RUN ./setup.sh
  2) REVIEW .env
  3) RUN ./create.sh
  4) RUN ./check.sh

IF YOU PREFER THE INTERACTIVE MENU
  1) RUN ./start.sh
  2) CHOOSE S TO RUN SETUP
  3) CHOOSE 1 TO CREATE INFRA + CONFIGURE HOSTS
  4) CHOOSE 4 TO CHECK STATUS

WHEN TO USE EACH SCRIPT
  ./setup.sh   = INSTALL LOCAL TOOLS AND PREPARE .env
  ./create.sh  = TERRAFORM + ANSIBLE + VALIDATION
  ./check.sh   = READINESS + LIVE VALIDATION
  ./destroy.sh = REMOVE TERRAFORM-MANAGED AWS RESOURCES
  ./start.sh   = MENU WRAPPER AROUND THE SAME OPERATIONS

WHEN INFRA ALREADY EXISTS
  OPTION 2 = TERRAFORM ONLY
  OPTION 3 = ANSIBLE ONLY
  OPTION M = SCALE DCV HOST COUNT AND AMI SETTINGS
  OPTION 5 = REGENERATE INVENTORY
  OPTION 6 = SHOW CURRENT IPS AND OUTPUTS
  OPTION P = START, STOP, OR CHECK A USER'S DCV INSTANCE
  OPTION X = DESTROY AND RECREATE THE FULL STACK
  OPTION I = SHOW THE FASTER AMI-BASED SCALE-OUT GUIDANCE

EOF
}

show_scaling_guidance() {
  cat <<'EOF'

SCALING AND AMI GUIDANCE
TYPICAL PATH
  1) KEEP AMI_ID EMPTY
  2) SET VPN_USERS_CSV, DCV_INSTANCE_COUNT, AND DCV_PRIVATE_IPS_CSV IN .env
  3) RUN OPTION 2 OR ./scripts/terraform_apply.sh
  4) RUN OPTION 3 OR ./scripts/run_ansible.sh
  5) EXPECT ABOUT 20 TO 40 MINUTES FOR A FRESH UBUNTU + GNOME + DCV HOST

FASTER PATH WITH A CLEAN CUSTOM AMI
  1) BUILD ONE CLEAN GOLDEN DCV HOST FIRST
  2) CREATE A CUSTOM AMI FROM THAT HOST AFTER REMOVING USER-SPECIFIC SENSITIVE DATA
  3) SET AMI_ID IN .env TO THAT CUSTOM AMI
  4) INCREASE DCV_INSTANCE_COUNT, KEEP VPN_USERS_CSV MATCHED, AND EXTEND DCV_PRIVATE_IPS_CSV
  5) RUN OPTION 2 TO SCALE FASTER WITH THE PREBUILT IMAGE
  6) RUN OPTION 3 ONLY IF YOU STILL NEED TO REFRESH USER PASSWORDS, VPN ARTIFACTS, OR HOST CONFIG

IMPORTANT NOTES
  THIS REPO SUPPORTS A CUSTOM AMI THROUGH AMI_ID, BUT IT DOES NOT YET AUTOMATE PACKER OR AMI CREATION.
  DO NOT CREATE AN AMI FROM A HOST THAT STILL CONTAINS ACTIVE USER SESSIONS, KEYS, OR OTHER SENSITIVE DATA.
  IF YOU NEED THE SAME VPN PUBLIC IP AFTER A FULL DESTROY/CREATE, USE CREATE_VPN_EIP=false WITH VPN_EIP_ALLOCATION_ID.

EOF
}

render_csv_from_array() {
  local joined_csv=""
  local item=""

  for item in "$@"; do
    if [[ -n "$joined_csv" ]]; then
      joined_csv+=","
    fi
    joined_csv+="$item"
  done

  printf '%s\n' "$joined_csv"
}

env_key_exists() {
  local key="$1"
  grep -q "^${key}=" "$ROOT_DIR/.env"
}

persist_env_value() {
  local key="$1"
  local value="$2"

  replace_env_value_in_file "$ROOT_DIR/.env" "$key" "$value"
}

build_scaled_vpn_users() {
  local desired_count="$1"
  local next_user_number=1
  local candidate_user=""
  local existing_user=""
  local candidate_exists=false

  SCALED_VPN_USERS_LIST=("${VPN_USERS_LIST[@]}")

  if (( desired_count < ${#SCALED_VPN_USERS_LIST[@]} )); then
    SCALED_VPN_USERS_LIST=("${SCALED_VPN_USERS_LIST[@]:0:desired_count}")
    return 0
  fi

  while (( ${#SCALED_VPN_USERS_LIST[@]} < desired_count )); do
    candidate_user="user${next_user_number}"
    candidate_exists=false

    for existing_user in "${SCALED_VPN_USERS_LIST[@]}"; do
      if [[ "$existing_user" == "$candidate_user" ]]; then
        candidate_exists=true
        break
      fi
    done

    if [[ "$candidate_exists" == "false" ]]; then
      SCALED_VPN_USERS_LIST+=("$candidate_user")
    fi

    next_user_number="$((next_user_number + 1))"
  done
}

build_scaled_private_ips() {
  local desired_count="$1"
  local subnet_prefix=""
  local subnet_match_octets=()
  local raw_existing_ip=""
  local trimmed_existing_ip=""
  local existing_ip=""
  local candidate_ip=""
  local host_octet=10
  local existing_count=0
  declare -A seen_ips=()

  SCALED_DCV_PRIVATE_IPS_LIST=()
  IFS=',' read -r -a raw_existing_dcv_ips <<<"${DCV_PRIVATE_IPS_CSV:-}"

  for raw_existing_ip in "${raw_existing_dcv_ips[@]}"; do
    trimmed_existing_ip="$(echo "$raw_existing_ip" | xargs)"
    if [[ -n "$trimmed_existing_ip" ]]; then
      SCALED_DCV_PRIVATE_IPS_LIST+=("$trimmed_existing_ip")
      seen_ips["$trimmed_existing_ip"]=1
    fi
  done

  existing_count="${#SCALED_DCV_PRIVATE_IPS_LIST[@]}"
  if (( desired_count < existing_count )); then
    SCALED_DCV_PRIVATE_IPS_LIST=("${SCALED_DCV_PRIVATE_IPS_LIST[@]:0:desired_count}")
    return 0
  fi

  if (( desired_count == existing_count )); then
    return 0
  fi

  if [[ ! "${PRIVATE_SUBNET_CIDR:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]]; then
    echo "Cannot auto-expand DCV_PRIVATE_IPS_CSV because PRIVATE_SUBNET_CIDR is not a /24 subnet."
    echo "Please update DCV_PRIVATE_IPS_CSV manually in .env for the new host count."
    return 1
  fi

  subnet_match_octets=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
  subnet_prefix="${subnet_match_octets[0]}.${subnet_match_octets[1]}.${subnet_match_octets[2]}"

  while (( ${#SCALED_DCV_PRIVATE_IPS_LIST[@]} < desired_count )); do
    candidate_ip="${subnet_prefix}.${host_octet}"
    if [[ -z "${seen_ips[$candidate_ip]:-}" ]]; then
      SCALED_DCV_PRIVATE_IPS_LIST+=("$candidate_ip")
      seen_ips["$candidate_ip"]=1
    fi
    host_octet="$((host_octet + 1))"

    if (( host_octet > 254 )); then
      echo "Cannot auto-expand DCV_PRIVATE_IPS_CSV because the /24 subnet ran out of host addresses."
      return 1
    fi
  done
}

configure_scaled_ami_setting() {
  local current_ami_display=""
  local ami_choice=""

  current_ami_display="${AMI_ID:-}"
  if [[ -z "$current_ami_display" ]]; then
    current_ami_display="LATEST_UBUNTU_24_04"
  fi

  echo "Current AMI setting: $current_ami_display"
  echo "K) Keep current AMI setting"
  echo "L) Use latest Ubuntu 24.04 base AMI"
  echo "C) Use a custom AMI ID for faster scaling"
  read -r -p "Choose AMI mode [K/L/C]: " ami_choice

  case "$ami_choice" in
    L|l)
      SCALED_AMI_ID=""
      ;;
    C|c)
      read -r -p "Enter custom AMI ID (for example ami-0123456789abcdef0): " SCALED_AMI_ID
      if [[ -z "$SCALED_AMI_ID" ]]; then
        echo "Custom AMI ID cannot be empty."
        return 1
      fi
      ;;
    *)
      SCALED_AMI_ID="${AMI_ID:-}"
      ;;
  esac
}

show_scaled_env_summary() {
  local resolved_ami_label=""

  resolved_ami_label="${SCALED_AMI_ID:-LATEST_UBUNTU_24_04}"
  echo
  echo "SCALING SUMMARY"
  echo "DCV_INSTANCE_COUNT=${#SCALED_VPN_USERS_LIST[@]}"
  echo "VPN_USERS_CSV=$(render_csv_from_array "${SCALED_VPN_USERS_LIST[@]}")"
  echo "DCV_PRIVATE_IPS_CSV=$(render_csv_from_array "${SCALED_DCV_PRIVATE_IPS_LIST[@]}")"
  echo "AMI_ID=${resolved_ami_label}"
  if [[ -z "${SCALED_AMI_ID:-}" ]]; then
    echo "BUILD_MODE=TYPICAL_FULL_BUILD_AROUND_20_TO_40_MINUTES"
  else
    echo "BUILD_MODE=CUSTOM_AMI_REUSE_CAN_BE_FASTER_BUT_MUST_BE_CLEAN_AND_SANITIZED"
  fi
}

apply_scaled_env_changes() {
  local user_name=""
  local user_sudo_key=""

  persist_env_value "DCV_INSTANCE_COUNT" "${#SCALED_VPN_USERS_LIST[@]}"
  persist_env_value "VPN_USERS_CSV" "$(render_csv_from_array "${SCALED_VPN_USERS_LIST[@]}")"
  persist_env_value "DCV_PRIVATE_IPS_CSV" "$(render_csv_from_array "${SCALED_DCV_PRIVATE_IPS_LIST[@]}")"
  persist_env_value "AMI_ID" "${SCALED_AMI_ID:-}"

  for user_name in "${SCALED_VPN_USERS_LIST[@]}"; do
    user_sudo_key="$(dcv_sudo_key_for_user "$user_name")"
    if ! env_key_exists "$user_sudo_key"; then
      persist_env_value "$user_sudo_key" "true"
    fi
  done

  "$ROOT_DIR/scripts/manage_dcv_passwords.sh" ensure "$ROOT_DIR/.env"
}

scale_dcv_fleet() {
  local desired_count=""
  local apply_choice=""

  load_env_only
  normalize_vpn_users_array "${VPN_USERS_CSV:-}"

  echo "Current DCV instance count: ${DCV_INSTANCE_COUNT:-0}"
  echo "Current VPN users: ${VPN_USERS_CSV:-NONE}"
  echo "Current DCV private IPs: ${DCV_PRIVATE_IPS_CSV:-NONE}"
  echo "Current AMI_ID: ${AMI_ID:-LATEST_UBUNTU_24_04}"
  echo
  read -r -p "Enter the new DCV instance count: " desired_count

  if [[ ! "$desired_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid DCV instance count."
    return
  fi

  build_scaled_vpn_users "$desired_count"
  if ! build_scaled_private_ips "$desired_count"; then
    return
  fi

  if ! configure_scaled_ami_setting; then
    return
  fi

  apply_scaled_env_changes
  show_scaled_env_summary
  echo
  echo "1) Save only"
  echo "2) Save and run Terraform only"
  echo "3) Save and run Terraform + Ansible"
  read -r -p "Choose what to do next [1/2/3]: " apply_choice

  case "$apply_choice" in
    2)
      "$ROOT_DIR/scripts/terraform_apply.sh"
      ;;
    3)
      "$ROOT_DIR/create.sh"
      ;;
    *)
      echo "Saved the scaling changes in .env."
      ;;
  esac
}

ssh_vpn_host() {
  load_valid_env inventory
  "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null
  vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
  ssh "${SSH_MENU_ARGS[@]}" -i "$SSH_PRIVATE_KEY_PATH" "ubuntu@$vpn_public_ip"
}

ssh_dcv_host() {
  local selected_index=""
  local vpn_public_ip=""
  local selected_ip=""

  load_valid_env inventory
  "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null
  vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
  mapfile -t dcv_private_ips < <(cd "$ROOT_DIR/terraform" && terraform output -json dcv_private_ips | jq -r '.[]')

  if [[ "${#dcv_private_ips[@]}" -eq 0 ]]; then
    echo "No DCV hosts were found in Terraform outputs."
    return
  fi

  echo "Available DCV hosts:"
  for index in "${!dcv_private_ips[@]}"; do
    echo "  $((index + 1))) ${dcv_private_ips[$index]}"
  done

  read -r -p "Select DCV host number: " selected_index
  if [[ ! "$selected_index" =~ ^[1-9][0-9]*$ ]] || (( selected_index > ${#dcv_private_ips[@]} )); then
    echo "Invalid selection."
    return
  fi

  selected_ip="${dcv_private_ips[$((selected_index - 1))]}"
  ssh "${SSH_MENU_ARGS[@]}" -o "ProxyCommand=$(build_proxy_command "$vpn_public_ip")" -i "$SSH_PRIVATE_KEY_PATH" "ubuntu@$selected_ip"
}

control_dcv_power_state() {
  local selected_index=""
  local selected_user=""
  local selected_private_ip=""
  local selected_action=""
  local vpn_public_ip=""
  local assignment_entries=()

  load_valid_env inventory
  "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null
  vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
  mapfile -t assignment_entries < <(cd "$ROOT_DIR/terraform" && terraform output -json dcv_user_assignments | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  if [[ "${#assignment_entries[@]}" -eq 0 ]]; then
    echo "No DCV user assignments were found in Terraform outputs."
    return
  fi

  echo "Available DCV assignments:"
  for index in "${!assignment_entries[@]}"; do
    selected_user="${assignment_entries[$index]%%$'\t'*}"
    selected_private_ip="${assignment_entries[$index]#*$'\t'}"
    echo "  $((index + 1))) ${selected_user} -> ${selected_private_ip}"
  done

  read -r -p "Select assignment number: " selected_index
  if [[ ! "$selected_index" =~ ^[1-9][0-9]*$ ]] || (( selected_index > ${#assignment_entries[@]} )); then
    echo "Invalid selection."
    return
  fi

  selected_user="${assignment_entries[$((selected_index - 1))]%%$'\t'*}"
  echo "1) status"
  echo "2) start"
  echo "3) stop"
  read -r -p "Choose action [1/2/3]: " selected_action

  case "$selected_action" in
    1)
      selected_action="status"
      ;;
    2)
      selected_action="start"
      ;;
    3)
      selected_action="stop"
      ;;
    *)
      echo "Invalid action."
      return
      ;;
  esac

  ssh "${SSH_MENU_ARGS[@]}" -i "$SSH_PRIVATE_KEY_PATH" "ubuntu@$vpn_public_ip" \
    "/usr/local/bin/dcv-instance-control --admin ${selected_action} ${selected_user}"
}

show_dcv_build_log() {
  local selected_index=""
  local vpn_public_ip=""
  local selected_ip=""

  load_valid_env inventory
  "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null
  vpn_public_ip="$(cd "$ROOT_DIR/terraform" && terraform output -raw vpn_public_ip)"
  mapfile -t dcv_private_ips < <(cd "$ROOT_DIR/terraform" && terraform output -json dcv_private_ips | jq -r '.[]')

  if [[ "${#dcv_private_ips[@]}" -eq 0 ]]; then
    echo "No DCV hosts were found in Terraform outputs."
    return
  fi

  echo "Available DCV hosts:"
  for index in "${!dcv_private_ips[@]}"; do
    echo "  $((index + 1))) ${dcv_private_ips[$index]}"
  done

  read -r -p "Select DCV host number: " selected_index
  if [[ ! "$selected_index" =~ ^[1-9][0-9]*$ ]] || (( selected_index > ${#dcv_private_ips[@]} )); then
    echo "Invalid selection."
    return
  fi

  selected_ip="${dcv_private_ips[$((selected_index - 1))]}"
  ssh "${SSH_MENU_ARGS[@]}" -o "ProxyCommand=$(build_proxy_command "$vpn_public_ip")" -i "$SSH_PRIVATE_KEY_PATH" "ubuntu@$selected_ip" "sudo tail -n 200 /var/log/dcv-desktop-bootstrap.log"
}

confirm_destroy() {
  local confirmation=""

  read -r -p "Type DESTROY to remove all managed resources: " confirmation
  if [[ "$confirmation" == "DESTROY" ]]; then
    "$ROOT_DIR/destroy.sh"
  else
    echo "Destroy cancelled."
  fi
}

confirm_recreate() {
  local confirmation=""

  read -r -p "Type RECREATE to destroy the current stack and build it again: " confirmation
  if [[ "$confirmation" == "RECREATE" ]]; then
    "$ROOT_DIR/destroy.sh"
    "$ROOT_DIR/create.sh"
  else
    echo "Recreate cancelled."
  fi
}

prompt_apply_dcv_password_changes() {
  local apply_now=""

  if ! command -v terraform >/dev/null 2>&1 || ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Saved password changes to .env. Run ./scripts/run_ansible.sh later to apply them on live DCV hosts."
    return
  fi

  if ! "$ROOT_DIR/scripts/ensure_terraform_outputs.sh" >/dev/null 2>&1; then
    echo "Saved password changes to .env. Apply them after infrastructure exists."
    return
  fi

  read -r -p "Apply updated DCV passwords to the live hosts now? [y/N]: " apply_now
  if [[ "$apply_now" =~ ^[Yy]$ ]]; then
    "$ROOT_DIR/scripts/run_ansible.sh"
  else
    echo "Password changes were saved in .env only."
  fi
}

reset_single_dcv_password() {
  local selected_index=""
  local selected_user=""
  local provided_password=""

  load_env_only
  normalize_vpn_users_array "${VPN_USERS_CSV:-}"

  if [[ "${#VPN_USERS_LIST[@]}" -eq 0 ]]; then
    echo "No users are defined in VPN_USERS_CSV."
    return
  fi

  echo "Available DCV users:"
  for index in "${!VPN_USERS_LIST[@]}"; do
    echo "  $((index + 1))) ${VPN_USERS_LIST[$index]}"
  done

  read -r -p "Select user number to reset: " selected_index
  if [[ ! "$selected_index" =~ ^[1-9][0-9]*$ ]] || (( selected_index > ${#VPN_USERS_LIST[@]} )); then
    echo "Invalid selection."
    return
  fi

  selected_user="${VPN_USERS_LIST[$((selected_index - 1))]}"
  read -r -s -p "Enter a new password or press Enter to auto-generate one: " provided_password
  echo

  if [[ -n "$provided_password" ]]; then
    "$ROOT_DIR/scripts/manage_dcv_passwords.sh" reset "$selected_user" "$provided_password" "$ROOT_DIR/.env"
  else
    "$ROOT_DIR/scripts/manage_dcv_passwords.sh" reset "$selected_user" "" "$ROOT_DIR/.env"
  fi

  prompt_apply_dcv_password_changes
}

reset_all_dcv_passwords() {
  "$ROOT_DIR/scripts/manage_dcv_passwords.sh" reset-all "$ROOT_DIR/.env"
  prompt_apply_dcv_password_changes
}

while true; do
  cat <<'EOF'

DCV IMPROVISED CONTROL MENU
H) SHOW RECOMMENDED FLOW
I) SHOW SCALING AND AMI GUIDANCE
S) SET UP LOCAL MACHINE
1) CREATE INFRASTRUCTURE AND CONFIGURE HOSTS
2) CREATE OR UPDATE INFRASTRUCTURE ONLY
3) RUN ANSIBLE CONFIGURATION ONLY
M) SCALE DCV HOST COUNT AND AMI SETTINGS
4) RUN CHECKS
5) REGENERATE INVENTORY
6) SHOW TERRAFORM OUTPUTS
7) SSH TO VPN SERVER
8) SSH TO A DCV SERVER
P) CONTROL DCV POWER STATE
L) SHOW DCV BUILD LOG
R) RESET ONE DCV USER PASSWORD
A) RESET ALL DCV USER PASSWORDS
X) DESTROY AND RECREATE EVERYTHING
9) DESTROY EVERYTHING
0) EXIT

EOF

  read -r -p "Choose an option: " selected_option

  case "$selected_option" in
    H|h)
      show_operator_flow
      ;;
    I|i)
      show_scaling_guidance
      ;;
    S|s)
      "$ROOT_DIR/setup.sh"
      ;;
    1)
      "$ROOT_DIR/create.sh"
      ;;
    2)
      "$ROOT_DIR/scripts/terraform_apply.sh"
      ;;
    3)
      "$ROOT_DIR/scripts/run_ansible.sh"
      ;;
    M|m)
      scale_dcv_fleet
      ;;
    4)
      "$ROOT_DIR/check.sh"
      ;;
    5)
      "$ROOT_DIR/scripts/generate_inventory.sh"
      ;;
    6)
      show_outputs
      ;;
    7)
      ssh_vpn_host
      ;;
    8)
      ssh_dcv_host
      ;;
    P|p)
      control_dcv_power_state
      ;;
    L|l)
      show_dcv_build_log
      ;;
    R|r)
      reset_single_dcv_password
      ;;
    A|a)
      reset_all_dcv_passwords
      ;;
    X|x)
      confirm_recreate
      ;;
    9)
      confirm_destroy
      ;;
    0)
      exit 0
      ;;
    *)
      echo "Invalid option."
      ;;
  esac
done
