#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
REF="${VESPERDASH_DEPLOY_REF:-main}"
[[ "$(id -u)" -eq 0 ]] || { echo "Run this in the VPS terminal as root (use sudo)." >&2; exit 1; }
[[ "$REF" =~ ^([A-Za-z0-9._/-]+|[0-9a-fA-F]{40})$ ]] || { echo "Invalid Git ref." >&2; exit 1; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "Open the VPS interactive terminal and run this command there." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SCRIPT="$TMP_DIR/deploy_update.sh"
if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  URL="https://raw.githubusercontent.com/$REPO/$REF/vesperdash/deploy_update.sh"
else
  URL="https://raw.githubusercontent.com/$REPO/$REF/vesperdash/deploy_update.sh"
fi
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 -o "$SCRIPT" "$URL"
chmod 0700 "$SCRIPT"
VESPERDASH_DEPLOY_REF="$REF" bash "$SCRIPT"
