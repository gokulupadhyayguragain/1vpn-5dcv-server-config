#!/usr/bin/env bash
set -euo pipefail

# LOCAL TOOLING PATH BLOCK
# PREFERS REPO-LOCAL AND USER-LOCAL BINARIES SO WRAPPER SCRIPTS FIND INSTALLED TOOLS.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="$ROOT_DIR/.venv/bin:$HOME/.local/bin:$PATH"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"
export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/ansible-remote}"
mkdir -p "$ANSIBLE_LOCAL_TEMP" "$ANSIBLE_REMOTE_TEMP"
