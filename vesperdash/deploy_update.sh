#!/usr/bin/env bash
set -Eeuo pipefail

REPO="vogarf816-debug/extrenal"
REF="${VESPERDASH_DEPLOY_REF:-main}"
APP_DIR="/opt/vesperdash/app"
VENV_PYTHON="/opt/vesperdash/venv/bin/python"
ENV_FILE="/etc/vesperdash.env"
SERVICE="vesperdash"
LOCAL_BASE="${VESPERDASH_LOCAL_URL:-http://127.0.0.1:8080}"
BACKUP_ROOT="/opt/vesperdash/backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/app-legacy-$TIMESTAMP"
STAGE_DIR="/opt/vesperdash/app.legacy-new-$TIMESTAMP"
ROLLBACK_DIR="/opt/vesperdash/app.legacy-old-$TIMESTAMP"
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
  printf 'Health check failed; restoring the previous application.\n' >&2
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "/opt/vesperdash/app.failed-$TIMESTAMP" || true; fi
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
    printf 'Previous application restored; deployment did not complete.\n' >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap handle_error ERR

[[ "$(id -u)" -eq 0 ]] || fail "Run with sudo/root."
[[ "$REF" =~ ^([A-Za-z0-9._/-]+|[0-9a-fA-F]{40})$ ]] || fail "Invalid Git ref."
[[ -d "$APP_DIR" ]] || fail "Missing $APP_DIR; this script updates an existing installation."
[[ -x "$VENV_PYTHON" ]] || fail "Missing VesperDash virtualenv at /opt/vesperdash/venv."
[[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE; the existing systemd environment file is preserved."

for command in curl tar systemctl python3; do command -v "$command" >/dev/null || fail "Required command not found: $command"; done

cat <<NOTICE
This restores the legacy VESPER API behavior from:
  repository: https://github.com/$REPO
  ref:        $REF
It backs up $APP_DIR, preserves /opt/vesperdash/data and $ENV_FILE,
then restarts $SERVICE. The legacy patch manifest and package downloads
will be public; the manifest also exposes the configured package passwords.
NOTICE

if [[ "${VESPERDASH_NONINTERACTIVE:-0}" == "1" ]]; then
  [[ "${VESPERDASH_LEGACY_ACK:-}" == "PUBLIC" ]] || fail "Public legacy API acknowledgement missing."
  [[ "${VESPERDASH_DEPLOY_CONFIRM:-}" == "YES" ]] || fail "Deployment confirmation missing."
else
  read -r -p 'I understand files and package passwords will be public. Type PUBLIC: ' public_answer
  [[ "$public_answer" == "PUBLIC" ]] || fail "Cancelled; no files were changed."
  read -r -p 'Deploy the legacy API now? Type DEPLOY: ' deploy_answer
  [[ "$deploy_answer" == "DEPLOY" ]] || { echo 'Cancelled; no files were changed.'; exit 0; }
fi

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
SOURCE_DIR="$SOURCE_ROOT/vesperdash"
[[ -f "$SOURCE_DIR/server.py" && -f "$SOURCE_DIR/requirements.txt" && -f "$SOURCE_DIR/static/index.html" && -f "$SOURCE_DIR/test_legacy_api.py" ]] || \
  fail "The selected GitHub ref is missing the legacy API files."

python3 - "$ENV_FILE" <<'PY'
import json
import shlex
import sys
from pathlib import Path

value = None
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or not line.startswith("VESPERDASH_PACKAGE_PASSWORDS="):
        continue
    parsed = shlex.split(line.split("=", 1)[1].strip(), posix=True)
    value = parsed[0] if len(parsed) == 1 else None
    break
try:
    passwords = json.loads(value) if value is not None else None
except (TypeError, json.JSONDecodeError):
    passwords = None
if not isinstance(passwords, list) or not 1 <= len(passwords) <= 10 or any(
    not isinstance(item, str) or len(item.strip()) < 16 for item in passwords
):
    print("ERROR: VESPERDASH_PACKAGE_PASSWORDS is missing or invalid in /etc/vesperdash.env.", file=sys.stderr)
    raise SystemExit(1)
PY

"$VENV_PYTHON" -m pip install --disable-pip-version-check -r "$SOURCE_DIR/requirements.txt"
(
  cd "$SOURCE_ROOT"
  "$VENV_PYTHON" -m py_compile vesperdash/server.py
  "$VENV_PYTHON" -m unittest vesperdash.test_legacy_api -v
)

install -d -m 0750 "$BACKUP_ROOT"
chmod 0700 "$BACKUP_ROOT"
cp -a "$APP_DIR" "$BACKUP_DIR"
install -d -m 0750 "$STAGE_DIR/static"
install -m 0644 "$SOURCE_DIR/server.py" "$STAGE_DIR/server.py"
install -m 0644 "$SOURCE_DIR/requirements.txt" "$STAGE_DIR/requirements.txt"
install -m 0644 "$SOURCE_DIR/static/index.html" "$STAGE_DIR/static/index.html"
if [[ -d "$APP_DIR/data" ]]; then cp -a "$APP_DIR/data" "$STAGE_DIR/data"; fi
chown -R vesperdash:www-data "$STAGE_DIR"

if ! systemctl stop "$SERVICE"; then fail "Could not stop $SERVICE; no application files were changed."; fi
SERVICE_STOPPED=1
mv "$APP_DIR" "$ROLLBACK_DIR"
OLD_MOVED=1
mv "$STAGE_DIR" "$APP_DIR"
SWAPPED=1
if ! systemctl start "$SERVICE"; then
  rollback
  fail "Legacy service failed to start; previous application restored."
fi
SERVICE_STOPPED=0

health_code=""
patches_code=""
download_probe_code=""
manifest_password_count=0
deadline=$((SECONDS + 120))
printf 'Waiting up to 120 seconds for the API to become ready...\n'
while (( SECONDS <= deadline )); do
  health_code="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/health" || true)"
  if [[ "$health_code" == "200" ]]; then
    patches_code="$(curl -sS --max-time 5 -o "$TMP_DIR/manifest.json" -w '%{http_code}' "$LOCAL_BASE/api/patches" || true)"
    download_probe_code="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/api/patches/__vesper_public_probe__/download" || true)"
    if [[ "$patches_code" == "200" ]]; then
      manifest_password_count="$(python3 - "$TMP_DIR/manifest.json" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("package_passwords", [])
    print(len(value) if isinstance(value, list) else 0)
except (OSError, json.JSONDecodeError):
    print(0)
PY
)"
    fi
    if [[ "$patches_code" == "200" && "$download_probe_code" == "404" && "$manifest_password_count" -gt 0 ]]; then break; fi
  fi
  sleep 2
done

if [[ "$health_code" != "200" || "$patches_code" != "200" || "$download_probe_code" != "404" || "$manifest_password_count" -eq 0 ]]; then
  rollback
  fail "Post-deploy checks failed (health=$health_code, manifest=$patches_code, download-probe=$download_probe_code, password-count=$manifest_password_count)."
fi

rm -rf "$ROLLBACK_DIR"
SWAPPED=0
OLD_MOVED=0
echo "Legacy deployment succeeded."
echo "Public manifest and download behavior verified; package password count: $manifest_password_count."
echo "Data and environment file were preserved. Backup retained at: $BACKUP_DIR"
