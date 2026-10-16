#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
DEFAULT_REF="feat/baba-external-redesign"
REF="${VESPERDASH_DEPLOY_REF:-$DEFAULT_REF}"
APP_DIR="/opt/vesperdash/app"
VENV_PYTHON="/opt/vesperdash/venv/bin/python"
ENV_FILE="/etc/vesperdash.env"
SERVICE="vesperdash"
LOCAL_BASE="${VESPERDASH_LOCAL_URL:-http://127.0.0.1:8080}"
BACKUP_ROOT="/opt/vesperdash/backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/app-$TIMESTAMP"
STAGE_DIR="/opt/vesperdash/app.new-$TIMESTAMP"
ROLLBACK_DIR="/opt/vesperdash/app.rollback-$TIMESTAMP"
TMP_DIR="$(mktemp -d)"
SERVICE_STOPPED=0
OLD_MOVED=0
SWAPPED=0

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  rm -rf "$TMP_DIR"
  if [[ -d "$STAGE_DIR" ]]; then rm -rf "$STAGE_DIR"; fi
}
rollback() {
  printf 'Health check failed; restoring the previous application code.\n' >&2
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if [[ -d "$APP_DIR" ]]; then
    mv "$APP_DIR" "/opt/vesperdash/app.failed-$TIMESTAMP" || true
  fi
  if [[ -d "$ROLLBACK_DIR" ]]; then
    mv "$ROLLBACK_DIR" "$APP_DIR"
  elif [[ -d "$BACKUP_DIR" ]]; then
    cp -a "$BACKUP_DIR" "$APP_DIR"
  fi
  systemctl start "$SERVICE" >/dev/null 2>&1 || true
  SERVICE_STOPPED=0
  OLD_MOVED=0
  SWAPPED=0
}
handle_error() {
  local status=$?
  trap - ERR
  if [[ "$SWAPPED" -eq 1 ]]; then
    rollback
  elif [[ "$SERVICE_STOPPED" -eq 1 ]]; then
    if [[ "$OLD_MOVED" -eq 1 && ! -d "$APP_DIR" && -d "$ROLLBACK_DIR" ]]; then
      mv "$ROLLBACK_DIR" "$APP_DIR" || true
    fi
    systemctl start "$SERVICE" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap handle_error ERR

[[ "$(id -u)" -eq 0 ]] || fail "Run with sudo/root: sudo bash deploy_update.sh"
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Invalid VESPERDASH_DEPLOY_REF"
[[ -d "$APP_DIR" ]] || fail "Missing $APP_DIR; this script updates an existing VesperDash installation"
[[ -x "$VENV_PYTHON" ]] || fail "Missing VesperDash virtualenv at /opt/vesperdash/venv"
[[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE; keep credentials in this protected server-side file"

for required in VESPERDASH_M3SB_PACKAGE_TOKEN VESPERDASH_M3SB_HMAC_SECRET VESPERDASH_PACKAGE_PASSWORDS; do
  grep -Eq "^[[:space:]]*${required}=[^[:space:]]" "$ENV_FILE" || \
    fail "$required is missing or empty in $ENV_FILE. Do not paste secrets into chat."
done

"$VENV_PYTHON" - "$ENV_FILE" <<'PY'
import json
import sys
from pathlib import Path

value = None
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or not line.startswith("VESPERDASH_PACKAGE_PASSWORDS="):
        continue
    value = line.split("=", 1)[1].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    break
try:
    passwords = json.loads(value) if value is not None else None
except (TypeError, json.JSONDecodeError):
    passwords = None
if not isinstance(passwords, list) or not passwords or any(
    not isinstance(item, str) or len(item.strip()) < 16 for item in passwords
):
    print("ERROR: VESPERDASH_PACKAGE_PASSWORDS must be a JSON list of passwords, each at least 16 characters.", file=sys.stderr)
    raise SystemExit(1)
PY

for command in curl tar systemctl; do command -v "$command" >/dev/null || fail "Required command not found: $command"; done

cat <<NOTICE
This will deploy the VesperDash security update from:
  repository: https://github.com/$REPO
  ref:        $REF
It will back up $APP_DIR to $BACKUP_DIR, preserve /opt/vesperdash/data,
keep $ENV_FILE unchanged, restart the $SERVICE service, and verify /health,
the protected patches endpoint, and the client-session route.
New rotated M3SB credentials and new package passwords must already be configured;
re-encrypt/re-upload old .3105 packages before activation.
NOTICE
read -r -p 'Proceed with deployment? [y/N] ' answer
[[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || { echo 'Cancelled; no changes made.'; exit 0; }

ARCHIVE="$TMP_DIR/source.tar.gz"
SOURCE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 -o "$ARCHIVE" "$SOURCE_URL"
mkdir -p "$TMP_DIR/source"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$TMP_DIR/source"
SOURCE_DIR="$TMP_DIR/source/vesperdash"
[[ -f "$SOURCE_DIR/server.py" && -f "$SOURCE_DIR/requirements.txt" && -f "$SOURCE_DIR/static/index.html" ]] || \
  fail "The selected GitHub ref does not contain the VesperDash server files"

"$VENV_PYTHON" -m pip install --disable-pip-version-check -r "$SOURCE_DIR/requirements.txt"
(
  cd "$TMP_DIR/source"
  "$VENV_PYTHON" -m unittest vesperdash.test_security -v
)

install -d -m 0750 "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"
cp -a "$APP_DIR" "$BACKUP_DIR"
install -d -m 0750 "$STAGE_DIR/static"
install -m 0644 "$SOURCE_DIR/server.py" "$STAGE_DIR/server.py"
install -m 0644 "$SOURCE_DIR/requirements.txt" "$STAGE_DIR/requirements.txt"
install -m 0644 "$SOURCE_DIR/static/index.html" "$STAGE_DIR/static/index.html"
# Older installs may keep the SQLite database and patch files beside server.py.
# Preserve that directory if present; the recommended /opt/vesperdash/data is untouched.
if [[ -d "$APP_DIR/data" ]]; then cp -a "$APP_DIR/data" "$STAGE_DIR/data"; fi
chown -R vesperdash:www-data "$STAGE_DIR"

if ! systemctl stop "$SERVICE"; then
  systemctl start "$SERVICE" >/dev/null 2>&1 || true
  fail "Could not stop $SERVICE; no application files were changed"
fi
SERVICE_STOPPED=1
mv "$APP_DIR" "$ROLLBACK_DIR"
OLD_MOVED=1
mv "$STAGE_DIR" "$APP_DIR"
SWAPPED=1
if ! systemctl start "$SERVICE"; then
  rollback
  fail "Service failed to start; previous application code restored"
fi
SERVICE_STOPPED=0

health_code=""
patches_code=""
auth_route_code=""
for _ in $(seq 1 12); do
  health_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/health" || true)"
  patches_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/api/patches" || true)"
  auth_route_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/api/auth/client-session" || true)"
  if [[ "$health_code" == "200" && "$patches_code" == "401" && "$auth_route_code" == "405" ]]; then break; fi
  sleep 2
done

if [[ "$health_code" != "200" || "$patches_code" != "401" || "$auth_route_code" != "405" ]]; then
  rollback
  fail "Post-deploy checks failed (health=$health_code, patches=$patches_code, auth-route=$auth_route_code)"
fi

rm -rf "$ROLLBACK_DIR"
SWAPPED=0
OLD_MOVED=0
echo "Deployment succeeded. Data and environment file were preserved."
echo "Protected API checks passed. Private backup retained at: $BACKUP_DIR"
