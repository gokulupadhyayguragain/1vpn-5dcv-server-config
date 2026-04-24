#!/usr/bin/env bash
set -euo pipefail

# DESTROY ENTRY BLOCK
# LOADS THE SHARED TERRAFORM INPUTS AND DESTROYS THE PROVISIONED STACK.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
source "$SCRIPT_DIR/export_tf_vars.sh" "$ROOT_DIR/.env"

# DESTROY BLOCK
# INITIALIZES TERRAFORM AND REMOVES ALL MANAGED AWS RESOURCES.
"$SCRIPT_DIR/terraform_init.sh"
cd "$ROOT_DIR/terraform"
terraform destroy -auto-approve -input=false
