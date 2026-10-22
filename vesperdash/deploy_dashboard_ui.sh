#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${VESPERDASH_APP_DIR:-/opt/vesperdash/app}"
STATIC_DIR="$APP_DIR/static"
TARGET="$STATIC_DIR/index.html"
SOURCE_URL="https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/static/index.html"
BACKUP_DIR="/opt/vesperdash/backups"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: use sudo." >&2; exit 1; }
[[ -d "$STATIC_DIR" && -f "$TARGET" && ! -L "$TARGET" ]] || { echo "Dashboard static page not found at $TARGET." >&2; exit 1; }

TMP_FILE="$(mktemp "$STATIC_DIR/.index.html.XXXXXX")"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 -o "$TMP_FILE" "$SOURCE_URL"

grep -q 'id="patchGameFilter"' "$TMP_FILE"
grep -q 'Free Fire MAX' "$TMP_FILE"
grep -q 'com.dts.freefiremax' "$TMP_FILE"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
chown root:root "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/dashboard-index.before-ffmax-$STAMP-$$.html"
cp -p "$TARGET" "$BACKUP"
chmod 600 "$BACKUP"

chown --reference="$TARGET" "$TMP_FILE"
chmod --reference="$TARGET" "$TMP_FILE"
mv -f "$TMP_FILE" "$TARGET"
trap - EXIT

echo "Dashboard UI updated (Free Fire MAX filter)."
echo "Previous page backup: $BACKUP"
echo "No dashboard credentials, API data, or service processes were changed."
