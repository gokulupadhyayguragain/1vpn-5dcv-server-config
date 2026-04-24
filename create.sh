#!/usr/bin/env bash
set -euo pipefail

# CREATE ORCHESTRATION BLOCK
# BUILDS THE INFRASTRUCTURE FIRST AND THEN CONFIGURES THE HOSTS WITH ANSIBLE.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/scripts/load_local_tooling.sh"

"$ROOT_DIR/scripts/validate_env.sh" --scope=full "$ROOT_DIR/.env"

if ! command -v terraform >/dev/null 2>&1; then
  echo "ERROR: terraform is not installed"
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ERROR: ansible-playbook is not installed"
  exit 1
fi

if ! command -v ansible-galaxy >/dev/null 2>&1; then
  echo "ERROR: ansible-galaxy is not installed"
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl is not installed"
  exit 1
fi

"$ROOT_DIR/scripts/terraform_apply.sh"
"$ROOT_DIR/scripts/run_ansible.sh"
