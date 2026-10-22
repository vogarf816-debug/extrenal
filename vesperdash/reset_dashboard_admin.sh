#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/vesperdash.env"
SERVICE="vesperdash"
APP_DIR="${VESPERDASH_APP_DIR:-/opt/vesperdash/app}"
STATIC_FILE="$APP_DIR/static/index.html"
STATIC_URL="https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/static/index.html"
BACKUP_DIR="/opt/vesperdash/backups"

[[ "$(id -u)" -eq 0 ]] || { echo "Run this command as root (use sudo)." >&2; exit 1; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "Run this from an interactive VPS terminal." >&2; exit 1; }
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || { echo "Missing or unsafe $ENV_FILE." >&2; exit 1; }
[[ -f "$STATIC_FILE" && ! -L "$STATIC_FILE" ]] || { echo "Dashboard page not found at $STATIC_FILE." >&2; exit 1; }

ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
if (( (8#$ENV_MODE & 8#077) != 0 )); then
  echo "Refusing to use an environment file accessible by group or others." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
CREDENTIALS="$TMP_DIR/new-admin.json"
NEW_INDEX="$TMP_DIR/index.html"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR"
chown root:root "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
ENV_BACKUP="$TMP_DIR/vesperdash.env.before-admin-reset"
STATIC_BACKUP="$BACKUP_DIR/dashboard-index.before-admin-reset-$STAMP-$$.html"
cp -p "$ENV_FILE" "$ENV_BACKUP"
cp -p "$STATIC_FILE" "$STATIC_BACKUP"
chmod 600 "$ENV_BACKUP" "$STATIC_BACKUP"

ENV_CHANGED=0
STATIC_CHANGED=0
STATIC_TEMP=""
rollback_on_exit() {
  local result=$?
  trap - EXIT
  if (( result != 0 )); then
    if (( STATIC_CHANGED )); then
      cp -p "$STATIC_BACKUP" "$STATIC_FILE" || true
    fi
    if (( ENV_CHANGED )); then
      cp -p "$ENV_BACKUP" "$ENV_FILE" || true
      chmod 600 "$ENV_FILE" || true
      chown root:root "$ENV_FILE" || true
    fi
    if (( ENV_CHANGED || STATIC_CHANGED )); then
      systemctl restart "$SERVICE" >/dev/null 2>&1 || true
      echo "ERROR: the previous dashboard page and credentials were restored where possible." >&2
    fi
  fi
  if [[ -n "$STATIC_TEMP" && -e "$STATIC_TEMP" ]]; then rm -f "$STATIC_TEMP"; fi
  rm -rf "$TMP_DIR"
  exit "$result"
}
trap rollback_on_exit EXIT

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 -o "$NEW_INDEX" "$STATIC_URL"
grep -q 'id="username"' "$NEW_INDEX"
grep -q 'id="password"' "$NEW_INDEX"
if grep -Eqi 'Use legacy admin token|X-Admin-Token|id="token"' "$NEW_INDEX"; then
  echo "Downloaded dashboard page still contains a legacy token prompt; refusing to install it." >&2
  exit 1
fi

ENV_CHANGED=1
python3 - "$ENV_FILE" "$CREDENTIALS" <<'PY'
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
credentials_path = Path(sys.argv[2])
managed = {"VESPERDASH_ADMIN_USERNAME", "VESPERDASH_ADMIN_PASSWORD", "VESPERDASH_ADMIN_TOKEN"}
kept = []
for line in path.read_text(encoding="utf-8").splitlines():
    key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else ""
    if key not in managed:
        kept.append(line)
username = "vesper-" + secrets.token_hex(4)
password = secrets.token_urlsafe(24)
def systemd_quote(value):
    if any(ch in value for ch in "\x00\r\n"):
        raise ValueError("invalid environment value")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
content = "\n".join(kept + [
    f"VESPERDASH_ADMIN_USERNAME={systemd_quote(username)}",
    f"VESPERDASH_ADMIN_PASSWORD={systemd_quote(password)}",
    f"VESPERDASH_ADMIN_TOKEN={systemd_quote('')}",
]).rstrip() + "\n"
fd, temporary = tempfile.mkstemp(prefix=".vesperdash.env.admin.", dir=str(path.parent))
try:
    os.fchmod(fd, 0o600)
    os.fchown(fd, 0, 0)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
os.chmod(path, 0o600)
os.chown(path, 0, 0)
credentials_path.write_text(json.dumps({"username": username, "password": password}), encoding="utf-8")
os.chmod(credentials_path, 0o600)
PY

STATIC_TEMP="$(mktemp "$APP_DIR/static/.index.html.XXXXXX")"
cp "$NEW_INDEX" "$STATIC_TEMP"
chown --reference="$STATIC_FILE" "$STATIC_TEMP"
chmod --reference="$STATIC_FILE" "$STATIC_TEMP"
STATIC_CHANGED=1
mv -f "$STATIC_TEMP" "$STATIC_FILE"

systemctl restart "$SERVICE"
HEALTH_OK=0
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done
[[ "$HEALTH_OK" -eq 1 ]] || { echo "VesperDash health check did not pass." >&2; exit 1; }

python3 - "$CREDENTIALS" <<'PY'
import json
import sys
import urllib.request

credentials = json.load(open(sys.argv[1], encoding="utf-8"))
request = urllib.request.Request(
    "http://127.0.0.1:8080/api/auth/login",
    data=json.dumps(credentials).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        result = json.load(response)
except Exception:
    print("Dashboard username/password check failed.", file=sys.stderr)
    raise SystemExit(1)
if result.get("ok") is not True or result.get("username") != credentials["username"] or result.get("owner") != "vesper":
    print("Dashboard username/password check returned an unexpected result.", file=sys.stderr)
    raise SystemExit(1)
PY

DATA_DIR="$(python3 - "$ENV_FILE" <<'PY'
import shlex
import sys
value = "/opt/vesperdash/data"
for line in open(sys.argv[1], encoding="utf-8"):
    if line.lstrip().startswith("#") or "=" not in line:
        continue
    key, raw = line.split("=", 1)
    if key.strip() == "VESPERDASH_DATA":
        parts = shlex.split(raw, posix=True)
        value = parts[0] if parts else ""
print(value)
PY
)"
DB_FILE="$DATA_DIR/vesperdash.sqlite3"
python3 - "$DB_FILE" <<'PY'
import sqlite3
import sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.is_file():
    print("VesperDash database was not found after restart.", file=sys.stderr)
    raise SystemExit(1)
with sqlite3.connect(path, timeout=10) as connection:
    connection.execute("DELETE FROM sessions WHERE owner='vesper'")
PY

python3 - "$CREDENTIALS" <<'PY'
import json
import sys
credentials = json.load(open(sys.argv[1], encoding="utf-8"))
print("Dashboard updated. Legacy token login is disabled and old Vesper admin sessions were cleared.")
print("Save these new credentials now; the password is shown only once:")
print("Username: " + credentials["username"])
print("Password: " + credentials["password"])
PY
ENV_CHANGED=0
STATIC_CHANGED=0
