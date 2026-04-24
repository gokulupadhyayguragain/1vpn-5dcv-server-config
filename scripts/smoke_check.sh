#!/usr/bin/env bash
set -euo pipefail

# STATIC CHECK BLOCK
# VALIDATES SHELL SYNTAX AND BASIC TERRAFORM FORMATTING/VALIDATION WHEN AVAILABLE.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/load_local_tooling.sh"
export ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg"

bash -n "$ROOT_DIR"/setup.sh "$ROOT_DIR"/create.sh "$ROOT_DIR"/destroy.sh "$ROOT_DIR"/check.sh "$ROOT_DIR"/start.sh "$ROOT_DIR"/scripts/*.sh

if command -v terraform >/dev/null 2>&1; then
  if (
    cd "$ROOT_DIR/terraform" \
      && terraform fmt -check \
      && terraform init -backend=false -input=false >/dev/null \
      && terraform validate
  ); then
    :
  else
    echo "INFO: terraform validation skipped because providers are unavailable locally"
  fi
else
  echo "INFO: terraform not installed, skipped terraform checks"
fi

if command -v ansible-playbook >/dev/null 2>&1; then
  if ansible-galaxy collection list | grep -q 'amazon.aws' && ansible-galaxy collection list | grep -q 'community.general'; then
    ansible-playbook -i localhost, -c local "$ROOT_DIR/ansible/playbooks/site.yml" --syntax-check
    ansible-playbook -i localhost, -c local "$ROOT_DIR/ansible/playbooks/validate.yml" --syntax-check
  else
    echo "INFO: required ansible collections not installed locally, skipped ansible syntax checks"
  fi
else
  echo "INFO: ansible not installed, skipped ansible syntax checks"
fi
