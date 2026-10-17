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
BACKUP_DIR="$BACKUP_ROOT/app-$TIMESTAMP"
STAGE_DIR="/opt/vesperdash/app.secure-new-$TIMESTAMP"
ROLLBACK_DIR="/opt/vesperdash/app.secure-old-$TIMESTAMP"
TMP_DIR="$(mktemp -d)"
SWAPPED=0
SERVICE_STOPPED=0

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$TMP_DIR"; [[ ! -d "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"; }
rollback() {
  printf 'Health check failed; restoring the previous application.\n' >&2
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "/opt/vesperdash/app.failed-$TIMESTAMP" || true; fi
  if [[ -d "$ROLLBACK_DIR" ]]; then mv "$ROLLBACK_DIR" "$APP_DIR"; fi
  systemctl start "$SERVICE" >/dev/null 2>&1 || true
  SWAPPED=0
  SERVICE_STOPPED=0
}
handle_error() {
  local status=$?
  trap - ERR
  if [[ "$SWAPPED" -eq 1 || "$SERVICE_STOPPED" -eq 1 ]]; then rollback; fi
  exit "$status"
}
trap cleanup EXIT
trap handle_error ERR

[[ "$(id -u)" -eq 0 ]] || fail "Run with sudo/root."
[[ "$REF" =~ ^([A-Za-z0-9._/-]+|[0-9a-fA-F]{40})$ ]] || fail "Invalid Git ref."
[[ -d "$APP_DIR" ]] || fail "Missing $APP_DIR; this script updates an existing installation."
[[ -x "$VENV_PYTHON" ]] || fail "Missing VesperDash virtualenv at /opt/vesperdash/venv."
[[ -r "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail "Missing or unsafe $ENV_FILE."
[[ -r /dev/tty && -w /dev/tty ]] || fail "Run from the VPS interactive terminal."
for command in curl tar systemctl python3; do command -v "$command" >/dev/null || fail "Required command not found: $command"; done

python3 - "$ENV_FILE" <<'PY'
import json, shlex, sys
from pathlib import Path
from urllib.parse import urlparse
wanted = {"VESPERDASH_M3SB_API_BASE_URL", "VESPERDASH_M3SB_PACKAGE_TOKEN", "VESPERDASH_M3SB_HMAC_SECRET", "VESPERDASH_PACKAGE_PASSWORDS"}
values = {}
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() in wanted:
        parsed = shlex.split(value.strip(), posix=True)
        values[key.strip()] = parsed[0] if len(parsed) == 1 else ""
if set(values) != wanted or any(not values.get(key) for key in wanted):
    raise SystemExit("ERROR: VesperDash M3SB and package settings must exist in /etc/vesperdash.env (values hidden).")
url = urlparse(values["VESPERDASH_M3SB_API_BASE_URL"])
if url.scheme != "https" or not url.netloc or url.username or url.password:
    raise SystemExit("ERROR: configured M3SB API base URL must be HTTPS.")
try:
    passwords = json.loads(values["VESPERDASH_PACKAGE_PASSWORDS"])
except json.JSONDecodeError:
    raise SystemExit("ERROR: package-password JSON is invalid (values hidden).")
if not isinstance(passwords, list) or not 1 <= len(passwords) <= 10 or any(not isinstance(x, str) or not x.strip() for x in passwords):
    raise SystemExit("ERROR: package-password list is invalid (values hidden).")
PY

cat <<NOTICE
This installs the authenticated VesperDash server from:
  repository: https://github.com/$REPO
  ref:        $REF
It backs up $APP_DIR, preserves /opt/vesperdash/data and $ENV_FILE,
then restarts $SERVICE. Patch manifests, package passwords and downloads
will require a valid, short-lived client session.
NOTICE
if [[ "${VESPERDASH_KEEP_EXISTING_M3SB_CREDENTIALS:-0}" == "1" ]]; then
  cat <<'RISK'
WARNING: You chose to keep the existing M3SB credentials. Earlier IPA files
contained credentials, so they may be compromised. This update preserves
/etc/vesperdash.env unchanged and does not rotate or print those values.
RISK
  read -r -p 'Accept this risk and keep existing credentials? Type KEEP-EXPOSED-SECRETS: ' keep_answer </dev/tty
  [[ "$keep_answer" == "KEEP-EXPOSED-SECRETS" ]] || fail "Cancelled; existing credentials were not deployed."
elif [[ "${VESPERDASH_KEEP_EXISTING_M3SB_CREDENTIALS:-0}" == "0" ]]; then
  read -r -p 'Have you revoked/rotated the previously exposed M3SB token and HMAC secret? Type ROTATED: ' rotation_answer </dev/tty
  [[ "$rotation_answer" == "ROTATED" ]] || fail "Cancelled; rotate the exposed credentials first."
else
  fail "Invalid credential deployment mode."
fi
read -r -p 'Deploy the authenticated server update now? Type DEPLOY: ' deploy_answer </dev/tty
[[ "$deploy_answer" == "DEPLOY" ]] || { echo 'Cancelled; no application files were changed.'; exit 0; }

ARCHIVE="$TMP_DIR/source.tar.gz"
if [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  SOURCE_URL="https://github.com/$REPO/archive/$REF.tar.gz"
else
  SOURCE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
fi
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 -o "$ARCHIVE" "$SOURCE_URL"
mkdir -p "$TMP_DIR/source"
tar -xzf "$ARCHIVE" --strip-components=1 --no-same-owner --no-same-permissions -C "$TMP_DIR/source"
SOURCE_DIR="$TMP_DIR/source/vesperdash"
[[ -f "$SOURCE_DIR/server.py" && -f "$SOURCE_DIR/requirements.txt" && -f "$SOURCE_DIR/test_security.py" && -f "$SOURCE_DIR/static/index.html" ]] || fail "Selected GitHub ref is missing secure server files."

(
  cd "$TMP_DIR/source"
  "$VENV_PYTHON" -m py_compile vesperdash/server.py
  "$VENV_PYTHON" -m unittest vesperdash.test_security vesperdash.test_legacy_api -v
)
"$VENV_PYTHON" -m pip install --disable-pip-version-check -r "$SOURCE_DIR/requirements.txt"

install -d -m 0700 "$BACKUP_ROOT"
cp -a "$APP_DIR" "$BACKUP_DIR"
mkdir -p "$STAGE_DIR"
cp -a "$SOURCE_DIR/." "$STAGE_DIR/"
chown -R vesperdash:www-data "$STAGE_DIR"
chmod 0750 "$STAGE_DIR"

systemctl stop "$SERVICE"
SERVICE_STOPPED=1
mv "$APP_DIR" "$ROLLBACK_DIR"
mv "$STAGE_DIR" "$APP_DIR"
SWAPPED=1
systemctl start "$SERVICE"
SERVICE_STOPPED=0

health_code=""
manifest_code=""
download_code=""
deadline=$((SECONDS + 120))
printf 'Waiting for the service and protected routes (up to 120 seconds)...\n'
while (( SECONDS <= deadline )); do
  health_code="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/health" || true)"
  if [[ "$health_code" == "200" ]]; then
    manifest_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/api/patches" || true)"
    download_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/api/patches/__unauthenticated_probe__/download" || true)"
    if [[ "$manifest_code" == "401" && "$download_code" == "401" ]]; then break; fi
  fi
  sleep 2
done
if [[ "$health_code" != "200" || "$manifest_code" != "401" || "$download_code" != "401" ]]; then
  rollback
  fail "Post-deploy checks failed (health=$health_code, manifest=$manifest_code, download=$download_code)."
fi
rm -rf "$ROLLBACK_DIR"
SWAPPED=0
echo "Authenticated VesperDash deployment succeeded."
echo "Public manifest and unauthenticated download probes both return HTTP 401."
echo "Data and environment file were preserved; backup retained at $BACKUP_DIR."
