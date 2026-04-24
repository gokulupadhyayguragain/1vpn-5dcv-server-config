#!/usr/bin/env bash
set -euo pipefail

# LOCAL SETUP ENTRY BLOCK
# PREPARES THE CONTROL MACHINE WITH REQUIRED TOOLS, SSH KEYS, AND A BOOTSTRAPPED .ENV FILE.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/load_local_tooling.sh"
source "$ROOT_DIR/scripts/dcv_user_helpers.sh"

ENV_TEMPLATE="$ROOT_DIR/.env.example"
ENV_FILE="$ROOT_DIR/.env"
VENV_DIR="$ROOT_DIR/.venv"

run_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

can_use_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi

  sudo -n true >/dev/null 2>&1
}

replace_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value=""

  escaped_value="$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

detect_ssh_private_key() {
  local candidate=""

  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    if [[ -f "$candidate" && -f "${candidate}.pub" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ensure_ssh_key_pair() {
  local detected_private_key=""

  if detected_private_key="$(detect_ssh_private_key)"; then
    SSH_PRIVATE_KEY_DETECTED="$detected_private_key"
    SSH_PUBLIC_KEY_DETECTED="${detected_private_key}.pub"
    return 0
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "${USER}@$(hostname)-dcv-improvised"
  SSH_PRIVATE_KEY_DETECTED="$HOME/.ssh/id_ed25519"
  SSH_PUBLIC_KEY_DETECTED="$HOME/.ssh/id_ed25519.pub"
}

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    echo "Created $ENV_FILE from template."
  else
    echo "Using existing $ENV_FILE."
  fi
}

install_terraform() {
  local distro_codename=""

  if command -v terraform >/dev/null 2>&1; then
    echo "Terraform already installed."
    return 0
  fi

  if [[ -r /etc/os-release ]]; then
    # OS DETECTION BLOCK
    # RESTRICTS AUTOMATED TERRAFORM INSTALLATION TO DEBIAN-LIKE LOCAL MACHINES.
    . /etc/os-release
    distro_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  fi

  if [[ -z "$distro_codename" ]]; then
    echo "WARNING: Could not detect Ubuntu/Debian codename. Install Terraform manually."
    return 0
  fi

  if ! can_use_sudo; then
    echo "WARNING: sudo is unavailable for package installation. Install Terraform manually if it is missing."
    return 0
  fi

  run_sudo apt-get update
  run_sudo apt-get install -y gpg
  run_sudo rm -f /usr/share/keyrings/hashicorp-archive-keyring.gpg
  curl -fsSL https://apt.releases.hashicorp.com/gpg | run_sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${distro_codename} main" \
    | run_sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  run_sudo apt-get update
  run_sudo apt-get install -y terraform
}

ensure_base_tools() {
  local missing_tools=()
  local tool_name=""

  for tool_name in aws curl jq openssl ssh-keygen unzip python3 pip3; do
    if ! command -v "$tool_name" >/dev/null 2>&1; then
      missing_tools+=("$tool_name")
    fi
  done

  if [[ "${#missing_tools[@]}" -eq 0 ]]; then
    echo "Base local tools already installed."
    return 0
  fi

  if ! can_use_sudo; then
    echo "ERROR: Missing local tools: ${missing_tools[*]}"
    echo "ERROR: sudo is unavailable, so install the missing tools manually and rerun ./setup.sh."
    exit 1
  fi

  # PACKAGE INSTALL BLOCK
  # INSTALLS THE LOCAL DEPENDENCIES REQUIRED TO RUN TERRAFORM, ANSIBLE, AND HELPER SCRIPTS.
  run_sudo apt-get update
  run_sudo apt-get install -y \
    awscli \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release \
    openssl \
    openssh-client \
    python3 \
    python3-pip \
    python3-venv \
    software-properties-common \
    unzip
}
ensure_base_tools
install_terraform

# PYTHON TOOLING BLOCK
# CREATES A REPO-LOCAL VENV AND INSTALLS ANSIBLE PLUS PYTHON LIBRARIES USED BY THE PROJECT.
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$ROOT_DIR/requirements.txt"
"$VENV_DIR/bin/ansible-galaxy" collection install -r "$ROOT_DIR/ansible/requirements.yml"

ensure_env_file
ensure_ssh_key_pair
replace_env_value "SSH_PRIVATE_KEY_PATH" "$SSH_PRIVATE_KEY_DETECTED"
replace_env_value "SSH_PUBLIC_KEY_PATH" "$SSH_PUBLIC_KEY_DETECTED"

if grep -q '^S3_BUCKET_NAME=5dcv-1-vpn-server-tf-state-file-bucket$' "$ENV_FILE"; then
  replace_env_value "S3_BUCKET_NAME" ""
fi

if ! grep -q '^TF_STATE_KEY=' "$ENV_FILE" || grep -Eq '^TF_STATE_KEY=$' "$ENV_FILE"; then
  replace_env_value "TF_STATE_KEY" "terraform/dcv-improvised.tfstate"
fi

if ! grep -q '^DCV_SELF_SERVICE_PORT=' "$ENV_FILE" || grep -Eq '^DCV_SELF_SERVICE_PORT=$' "$ENV_FILE"; then
  replace_env_value "DCV_SELF_SERVICE_PORT" "8444"
fi

"$ROOT_DIR/scripts/manage_dcv_passwords.sh" ensure "$ENV_FILE"

if grep -Eq '^ALLOWED_ADMIN_CIDR=$|^ALLOWED_ADMIN_CIDR=0\.0\.0\.0/0|^ALLOWED_ADMIN_CIDR=203\.0\.113\.10/32$' "$ENV_FILE"; then
  detected_public_ip="$(curl -fsSL https://checkip.amazonaws.com 2>/dev/null | tr -d '\n' || true)"
  if [[ "$detected_public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    replace_env_value "ALLOWED_ADMIN_CIDR" "${detected_public_ip}/32"
    echo "Detected ALLOWED_ADMIN_CIDR=${detected_public_ip}/32"
  else
    echo "WARNING: Could not auto-detect public IP. Set ALLOWED_ADMIN_CIDR manually."
  fi
fi

source "$ROOT_DIR/scripts/load_env.sh" "$ENV_FILE"
normalize_vpn_users_array "${VPN_USERS_CSV:-}"
if [[ "${DCV_INSTANCE_COUNT:-}" =~ ^[1-9][0-9]*$ ]] && [[ "${#VPN_USERS_LIST[@]}" -ne "${DCV_INSTANCE_COUNT:-0}" ]]; then
  echo "WARNING: DCV_INSTANCE_COUNT=${DCV_INSTANCE_COUNT:-0} DOES NOT MATCH VPN USER COUNT ${#VPN_USERS_LIST[@]}."
  echo "WARNING: SET DCV_INSTANCE_COUNT TO MATCH VPN_USERS_CSV FOR DEDICATED USER-TO-HOST MAPPING."
fi

echo
echo "SETUP COMPLETE"
echo "1. REVIEW $ENV_FILE AND FILL AWS CREDENTIALS IF NEEDED."
echo "2. REVIEW VPN_USERS_CSV, DCV_INSTANCE_COUNT, VPN_PRIVATE_IP, DCV_PRIVATE_IPS_CSV, AND DCV_PASSWORD_<USER> KEYS IN $ENV_FILE."
echo "3. REVIEW CREATE_VPN_EIP AND VPN_EIP_ALLOCATION_ID IF YOU WANT THE SAME VPN PUBLIC IP ACROSS FUTURE DESTROY/CREATE CYCLES."
echo "4. REVIEW DCV_SELF_SERVICE_PORT IF YOU WANT A DIFFERENT INTERNAL HTTPS PORT FOR THE VPN-ONLY DCV POWER HELPER."
echo "5. RUN ./check.sh TO SEE THE UPDATED READINESS STATUS."
echo "6. RUN ./create.sh WHEN READINESS IS 100%."
