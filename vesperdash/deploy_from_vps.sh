#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
REF="${VESPERDASH_DEPLOY_REF:-main}"
CREDENTIAL_MODE="rotate"
CREDENTIAL_MODE_SELECTED=0
RESET_ADMIN=0
for argument in "$@"; do
  case "$argument" in
    --rotate-m3sb-credentials)
      [[ "$CREDENTIAL_MODE_SELECTED" -eq 0 ]] || { echo "Choose only one M3SB credential mode." >&2; exit 2; }
      CREDENTIAL_MODE="rotate"
      CREDENTIAL_MODE_SELECTED=1
      ;;
    --keep-current-m3sb-credentials)
      [[ "$CREDENTIAL_MODE_SELECTED" -eq 0 ]] || { echo "Choose only one M3SB credential mode." >&2; exit 2; }
      CREDENTIAL_MODE="keep"
      CREDENTIAL_MODE_SELECTED=1
      ;;
    --new-admin)
      [[ "$RESET_ADMIN" -eq 0 ]] || { echo "--new-admin was specified more than once." >&2; exit 2; }
      RESET_ADMIN=1
      ;;
    *) echo "Usage: deploy_from_vps.sh [--rotate-m3sb-credentials|--keep-current-m3sb-credentials] [--new-admin]" >&2; exit 2 ;;
  esac
done
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
if [[ "$CREDENTIAL_MODE" == "keep" ]]; then
  VESPERDASH_DEPLOY_REF="$REF" VESPERDASH_KEEP_EXISTING_M3SB_CREDENTIALS=1 VESPERDASH_RESET_ADMIN="$RESET_ADMIN" bash "$SCRIPT"
else
  VESPERDASH_DEPLOY_REF="$REF" VESPERDASH_KEEP_EXISTING_M3SB_CREDENTIALS=0 VESPERDASH_RESET_ADMIN="$RESET_ADMIN" bash "$SCRIPT"
fi
