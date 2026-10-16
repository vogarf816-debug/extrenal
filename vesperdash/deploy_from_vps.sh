#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
REF="${VESPERDASH_DEPLOY_REF:-main}"
ENV_FILE="/etc/vesperdash.env"
[[ "$(id -u)" -eq 0 ]] || { echo "Run this in the VPS terminal as root (use sudo)." >&2; exit 1; }
[[ "$REF" =~ ^([A-Za-z0-9._/-]+|[0-9a-fA-F]{40})$ ]] || { echo "Invalid Git ref." >&2; exit 1; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "Open the VPS interactive terminal and run this command there." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  SOURCE_URL="https://github.com/$REPO/archive/$REF.tar.gz"
else
  SOURCE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
fi
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 -o "$ARCHIVE" "$SOURCE_URL"
mkdir -p "$TMP_DIR/source"
tar -xzf "$ARCHIVE" --strip-components=1 --no-same-owner --no-same-permissions -C "$TMP_DIR/source"
SOURCE_ROOT="$TMP_DIR/source"
[[ -f "$SOURCE_ROOT/vesperdash/apply_env_patch.py" && -f "$SOURCE_ROOT/vesperdash/deploy_update.sh" ]] || {
  echo "The GitHub version is missing required deployment files." >&2
  exit 1
}

read -r -p 'Have you rotated the M3SB token and HMAC secret? Type ROTATED: ' answer </dev/tty
[[ "$answer" == "ROTATED" ]] || { echo "Stopped. Rotate both M3SB secrets first."; exit 1; }
read -r -p 'Have you re-encrypted and uploaded every .3105 package? Type READY: ' answer </dev/tty
[[ "$answer" == "READY" ]] || { echo "Stopped. Re-encrypt and upload all packages first."; exit 1; }
read -r -p 'To deploy the server update, type DEPLOY: ' answer </dev/tty
[[ "$answer" == "DEPLOY" ]] || { echo "Cancelled; no deployment was made."; exit 0; }

read -r -p 'Are the NEW secrets already saved in /etc/vesperdash.env? Type EXISTING or NEW: ' secret_mode </dev/tty
case "$secret_mode" in
  EXISTING)
    [[ -r "$ENV_FILE" ]] || { echo "Cannot read $ENV_FILE. Choose NEW to enter the secrets." >&2; exit 1; }
    echo "Using the protected environment file already on this VPS."
    ;;
  NEW)
    echo "Enter the new values below. Typing is hidden; values are not printed."
    PAYLOAD_FILE="$TMP_DIR/secrets.json"
    (umask 077; python3 - "$SOURCE_ROOT/vesperdash" > "$PAYLOAD_FILE" <<'PY'
import getpass
import json
import sys

sys.path.insert(0, sys.argv[1])
from apply_env_patch import validate

with open('/dev/tty', 'r', encoding='utf-8') as tty_in, open('/dev/tty', 'w', encoding='utf-8') as tty_out:
    print('Number of DIFFERENT package passwords (1-10): ', end='', file=tty_out, flush=True)
    raw_count = tty_in.readline().strip()
try:
    count = int(raw_count)
    if not 1 <= count <= 10:
        raise ValueError
except ValueError:
    print('Enter a number from 1 to 10.', file=sys.stderr)
    raise SystemExit(2)

payload = {
    'VESPERDASH_M3SB_API_BASE_URL': 'https://api.m3sbapi.shop',
    'VESPERDASH_M3SB_PACKAGE_TOKEN': getpass.getpass('New M3SB package token (hidden): '),
    'VESPERDASH_M3SB_HMAC_SECRET': getpass.getpass('New M3SB HMAC secret (hidden): '),
}
passwords = []
for index in range(count):
    password = getpass.getpass(f'Package password {index + 1} (hidden): ')
    if len(password.strip()) < 16:
        print('Each package password must be at least 16 characters. No values were saved.', file=sys.stderr)
        raise SystemExit(2)
    passwords.append(password)
payload['VESPERDASH_PACKAGE_PASSWORDS'] = json.dumps(passwords)
try:
    validate(payload)
except ValueError as error:
    print(f'Input check failed: {error}. No values were saved.', file=sys.stderr)
    raise SystemExit(2)
json.dump(payload, sys.stdout)
PY
    )
    python3 "$SOURCE_ROOT/vesperdash/apply_env_patch.py" < "$PAYLOAD_FILE"
    rm -f "$PAYLOAD_FILE"
    ;;
  *)
    echo "Type exactly EXISTING or NEW." >&2
    exit 1
    ;;
esac

VESPERDASH_NONINTERACTIVE=1 \
VESPERDASH_M3SB_ROTATED_ACK=ROTATED \
VESPERDASH_PACKAGES_REENCRYPTED_ACK=READY \
VESPERDASH_DEPLOY_CONFIRM=YES \
VESPERDASH_DEPLOY_REF="$REF" \
bash "$SOURCE_ROOT/vesperdash/deploy_update.sh"
