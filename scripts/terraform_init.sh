#!/usr/bin/env bash
set -euo pipefail

# TERRAFORM INIT MODE BLOCK
# INITIALIZES TERRAFORM WITH EITHER LOCAL STATE OR AN OPTIONAL S3 BACKEND FROM .ENV.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/export_tf_vars.sh" "$ROOT_DIR/.env"

BACKEND_REGION="${TF_STATE_REGION:-${AWS_REGION:-}}"
BACKEND_KEY="${TF_STATE_KEY:-terraform/${PROJECT_NAME:-dcv-improvised}.tfstate}"
BACKEND_OVERRIDE_FILE="$ROOT_DIR/terraform/backend_override.tf"

cd "$ROOT_DIR/terraform"

# BACKEND CONFIG BLOCK
# USES LOCAL STATE BY DEFAULT AND GENERATES AN S3 BACKEND BLOCK ONLY WHEN TF_STATE_BUCKET_NAME IS PROVIDED.
if [[ -n "${TF_STATE_BUCKET_NAME:-}" ]]; then
  backend_config_file="$(mktemp)"
  trap 'rm -f "$backend_config_file"' EXIT

  cat >"$BACKEND_OVERRIDE_FILE" <<'EOF'
terraform {
  backend "s3" {}
}
EOF

  cat >"$backend_config_file" <<EOF
bucket       = "${TF_STATE_BUCKET_NAME}"
key          = "${BACKEND_KEY}"
region       = "${BACKEND_REGION}"
encrypt      = true
use_lockfile = true
EOF

  terraform init -input=false -reconfigure -backend-config="$backend_config_file"
else
  rm -f "$BACKEND_OVERRIDE_FILE"
  terraform init -input=false -reconfigure
fi
