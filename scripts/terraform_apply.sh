#!/usr/bin/env bash
set -euo pipefail

# APPLY ENTRY BLOCK
# LOADS THE SHARED TERRAFORM INPUTS AND APPLIES THE INFRASTRUCTURE STACK.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_APPLY_ARGS=("$@")
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/export_tf_vars.sh" "$ROOT_DIR/.env"

# APPLY BLOCK
# INITIALIZES TERRAFORM AND APPLIES CHANGES FOR INFRASTRUCTURE LAYER.
"$SCRIPT_DIR/terraform_init.sh"
cd "$ROOT_DIR/terraform"
terraform fmt
terraform validate
terraform apply -auto-approve -input=false "${TERRAFORM_APPLY_ARGS[@]}"
