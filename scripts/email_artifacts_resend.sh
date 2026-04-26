#!/usr/bin/env bash
set -euo pipefail

# RESEND ARTIFACT EMAIL BLOCK
# EMAILS THE GENERATED PER-USER WIREGUARD PROFILES AND CONNECTION INFO FILES.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/load_env.sh" "$ROOT_DIR/.env"
source "$SCRIPT_DIR/dcv_user_helpers.sh"

RESEND_TO="${RESEND_TO:-info@gocools.com}"
RESEND_FROM="${RESEND_FROM:-DCV Access <info@gocools.com>}"

if [[ -z "${RESEND_API_KEY:-}" ]]; then
  echo "ERROR: Set RESEND_API_KEY before running this script." >&2
  exit 1
fi

normalize_vpn_users_array "${VPN_USERS_CSV:-}"
if [[ "${#VPN_USERS_LIST[@]}" -eq 0 ]]; then
  echo "ERROR: VPN_USERS_CSV has no users." >&2
  exit 1
fi

RESEND_TO="$RESEND_TO" RESEND_FROM="$RESEND_FROM" RESEND_API_KEY="$RESEND_API_KEY" python3 - "$ROOT_DIR" "${VPN_USERS_LIST[@]}" <<'PY'
import base64
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

root = pathlib.Path(sys.argv[1])
users = sys.argv[2:]

files = []
missing = []
for user in users:
    user_dir = root / "artifacts" / user
    for path in (user_dir / f"{user}.conf", user_dir / f"connection-info-{user}.txt"):
        if path.exists():
            files.append(path)
        else:
            missing.append(path)

if missing:
    print("ERROR: Missing artifact files:", file=sys.stderr)
    for path in missing:
        print(f"  {path}", file=sys.stderr)
    sys.exit(1)

attachments = [
    {
        "filename": f"{path.parent.name}-{path.name}",
        "content": base64.b64encode(path.read_bytes()).decode("ascii"),
    }
    for path in files
]

payload = {
    "from": os.environ["RESEND_FROM"],
    "to": [os.environ["RESEND_TO"]],
    "subject": "DCV VPN profiles and connection info",
    "text": (
        "Attached are the per-user WireGuard VPN profiles and DCV connection info files. "
        "Each user should import only their matching .conf file, connect to the VPN, "
        "then use the matching connection-info file."
    ),
    "attachments": attachments,
}

request = urllib.request.Request(
    "https://api.resend.com/emails",
    data=json.dumps(payload).encode("utf-8"),
    headers={
        "Authorization": f"Bearer {os.environ['RESEND_API_KEY']}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "dcv-improvised-artifact-mailer/1.0",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read().decode("utf-8", errors="replace")
        print(f"INFO: Resend accepted artifact email to {os.environ['RESEND_TO']}.")
        print(body)
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(f"ERROR: Resend rejected the artifact email with HTTP {exc.code}.", file=sys.stderr)
    print(body, file=sys.stderr)
    sys.exit(1)
PY
