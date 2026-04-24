#!/usr/bin/env bash
set -euo pipefail

# ENV LOADING BLOCK
# EXPORTS CENTRAL VARIABLES FROM .ENV SO TOOLS USE A SINGLE SOURCE OF TRUTH.
ENV_FILE="${1:-$PWD/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  exit 1
fi

# PATH NORMALIZATION BLOCK
# EXPANDS USER-HOME PREFIXES SO DOWNSTREAM TOOLS RECEIVE REAL ABSOLUTE PATHS.
expand_path() {
  local raw_path="${1:-}"

  if [[ "$raw_path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$raw_path" == "~/"* ]]; then
    printf '%s\n' "$HOME/${raw_path:2}"
  else
    printf '%s\n' "$raw_path"
  fi
}

# ENV PARSING BLOCK
# LOADS KEY=VALUE PAIRS WITHOUT TREATING THE .ENV FILE AS AN EXECUTABLE SHELL SCRIPT SO CSV VALUES WITH SPACES KEEP WORKING.
load_env_key_values() {
  local raw_line=""
  local line=""
  local key=""
  local raw_value=""
  local trimmed_value=""
  local parsed_value=""

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(printf '%s' "$raw_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "ERROR: Unsupported .env line: $raw_line" >&2
      exit 1
    fi

    key="${line%%=*}"
    raw_value="${line#*=}"
    trimmed_value="$(printf '%s' "$raw_value" | sed 's/^[[:space:]]*//')"

    if [[ "$trimmed_value" == \"* ]]; then
      parsed_value="${trimmed_value#\"}"
      parsed_value="${parsed_value%%\"*}"
    elif [[ "$trimmed_value" == \'* ]]; then
      parsed_value="${trimmed_value#\'}"
      parsed_value="${parsed_value%%\'*}"
    else
      parsed_value="$(printf '%s' "$trimmed_value" | sed 's/^#.*$//; s/[[:space:]]\+#.*$//; s/[[:space:]]*$//')"
    fi

    printf -v "$key" '%s' "$parsed_value"
    export "$key"
  done <"$ENV_FILE"
}

# EXPORT BLOCK
# TRANSFORMS .ENV KEYS INTO EXPORTED ENVIRONMENT VARIABLES FOR THE CURRENT SHELL SESSION.
load_env_key_values

# LEGACY ROOT VOLUME FALLBACK BLOCK
# MAPS THE OLD SHARED ROOT VOLUME KEY TO THE NEW PER-ROLE KEYS SO EXISTING .ENV FILES KEEP WORKING DURING THE TRANSITION.
LEGACY_ROOT_VOLUME_SIZE_GB_FALLBACK_USED="false"
if [[ -n "${ROOT_VOLUME_SIZE_GB:-}" ]]; then
  if [[ -z "${VPN_ROOT_VOLUME_SIZE_GB:-}" ]]; then
    VPN_ROOT_VOLUME_SIZE_GB="${ROOT_VOLUME_SIZE_GB}"
    LEGACY_ROOT_VOLUME_SIZE_GB_FALLBACK_USED="true"
  fi

  if [[ -z "${DCV_ROOT_VOLUME_SIZE_GB:-}" ]]; then
    DCV_ROOT_VOLUME_SIZE_GB="${ROOT_VOLUME_SIZE_GB}"
    LEGACY_ROOT_VOLUME_SIZE_GB_FALLBACK_USED="true"
  fi
fi

SSH_PUBLIC_KEY_PATH="$(expand_path "${SSH_PUBLIC_KEY_PATH:-}")"
SSH_PRIVATE_KEY_PATH="$(expand_path "${SSH_PRIVATE_KEY_PATH:-}")"

export ENV_FILE
export SSH_PUBLIC_KEY_PATH
export SSH_PRIVATE_KEY_PATH
export VPN_ROOT_VOLUME_SIZE_GB
export DCV_ROOT_VOLUME_SIZE_GB
export LEGACY_ROOT_VOLUME_SIZE_GB_FALLBACK_USED
export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
