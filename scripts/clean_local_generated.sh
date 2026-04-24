#!/usr/bin/env bash
set -euo pipefail

# LOCAL CLEAN ENTRY BLOCK
# REMOVES SAFE GENERATED LOCAL FILES SO THE REPO FEELS LIKE A FRESH CLONE WITHOUT TOUCHING LIVE INFRASTRUCTURE STATE.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
include_artifacts=false

if [[ "${1:-}" == "--include-artifacts" ]]; then
  include_artifacts=true
fi

# GENERATED FILE CLEANUP BLOCK
# CLEARS REGENERABLE INVENTORY AND OPTIONAL LOCAL ARTIFACT FILES WHILE LEAVING TERRAFORM STATE AND .ENV INTACT.
rm -f "$ROOT_DIR/ansible/inventories/hosts.ini"
rm -f "$ROOT_DIR/terraform/backend_override.tf"

if [[ "$include_artifacts" == "true" ]]; then
  rm -rf "$ROOT_DIR/artifacts"
fi

echo "LOCAL GENERATED FILES CLEANED."
echo "PRESERVED: .env, terraform.tfstate, terraform.tfstate.backup, .venv"
if [[ "$include_artifacts" == "true" ]]; then
  echo "REMOVED: ansible/inventories/hosts.ini, terraform/backend_override.tf, artifacts/"
else
  echo "REMOVED: ansible/inventories/hosts.ini, terraform/backend_override.tf"
  echo "PRESERVED: artifacts/"
fi
