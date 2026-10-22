#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/vesperdash.env"
SERVICE="vesperdash"
LOCAL_BASE="${VESPERDASH_LOCAL_URL:-http://127.0.0.1:8080}"
[[ "$(id -u)" -eq 0 ]] || { echo "Run this in the VPS terminal as root (use sudo)." >&2; exit 1; }
[[ -f "$ENV_FILE" && -r "$ENV_FILE" && ! -L "$ENV_FILE" ]] || { echo "Missing or unsafe $ENV_FILE." >&2; exit 1; }
[[ "$(stat -c '%u' "$ENV_FILE")" == "0" ]] || { echo "$ENV_FILE must be owned by root." >&2; exit 1; }
ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
(( (8#$ENV_MODE & 8#037) == 0 )) || { echo "$ENV_FILE must not be readable by others or writable/executable by its group. Use chmod 600." >&2; exit 1; }
[[ -r /dev/tty && -w /dev/tty ]] || { echo "Run from the interactive VPS terminal." >&2; exit 1; }
for command in python3 curl systemctl stat; do command -v "$command" >/dev/null || { echo "Required command not found: $command." >&2; exit 1; }; done

TMP_DIR="$(mktemp -d)"
chmod 0700 "$TMP_DIR"
BACKUP="${ENV_FILE}.before-admin-reset-$(date -u +%Y%m%dT%H%M%SZ)-$$"
CREDENTIALS="$TMP_DIR/new-admin.json"
cp -p "$ENV_FILE" "$BACKUP"
chmod 0600 "$BACKUP"
CHANGED=0

rollback_on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$CHANGED" -eq 1 ]]; then
    cp -p "$BACKUP" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    echo "Admin credential change failed; the previous environment was restored." >&2
  fi
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap rollback_on_exit EXIT

CHANGED=1
python3 - "$ENV_FILE" "$CREDENTIALS" <<'PY'
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
credential_path = Path(sys.argv[2])
lines = path.read_text(encoding="utf-8").splitlines()
remove = {"VESPERDASH_ADMIN_USERNAME", "VESPERDASH_ADMIN_PASSWORD", "VESPERDASH_ADMIN_TOKEN"}
kept = []
for line in lines:
    name = line.split("=", 1)[0].strip() if "=" in line else ""
    if name.startswith("export "):
        name = name[7:].strip()
    if name not in remove:
        kept.append(line)
username = "vesper-admin-" + secrets.token_hex(3)
password = secrets.token_urlsafe(24)
content = "\n".join(kept).rstrip() + f"\nVESPERDASH_ADMIN_USERNAME={username}\nVESPERDASH_ADMIN_PASSWORD={password}\n"
fd, temporary = tempfile.mkstemp(prefix=".vesperdash-env-", dir=str(path.parent))
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.chown(temporary, 0, 0)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
fd = os.open(credential_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    json.dump({"username": username, "password": password}, stream)
    stream.flush()
    os.fsync(stream.fileno())
PY
systemctl restart "$SERVICE"

ready=0
for _ in $(seq 1 60); do
  if [[ "$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$LOCAL_BASE/health" || true)" == "200" ]]; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || { echo "VesperDash health check did not pass after restart." >&2; exit 1; }

python3 - "$LOCAL_BASE" "$CREDENTIALS" <<'PY'
import json
import sys
import urllib.error
import urllib.request
base, credentials_path = sys.argv[1], sys.argv[2]
credentials = json.load(open(credentials_path, encoding="utf-8"))
body = json.dumps(credentials).encode()
request = urllib.request.Request(
    base.rstrip("/") + "/api/auth/login",
    data=body,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        result = json.loads(response.read(65536))
        if response.status != 200 or not result.get("ok"):
            raise SystemExit("Dashboard login verification failed.")
except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError):
    raise SystemExit("Dashboard login verification failed.")
PY

python3 - "$ENV_FILE" <<'PY'
import shlex
import sqlite3
import sys
from pathlib import Path

env_file = Path(sys.argv[1])
data_dir = Path("/opt/vesperdash/data")
for line in env_file.read_text(encoding="utf-8").splitlines():
    if "=" not in line:
        continue
    name, value = line.split("=", 1)
    if name.strip() == "VESPERDASH_DATA":
        parsed = shlex.split(value.strip(), posix=True)
        if parsed:
            data_dir = Path(parsed[0])
        break
db_path = data_dir / "vesperdash.sqlite3"
if db_path.exists():
    with sqlite3.connect(db_path, timeout=8) as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(sessions)")}
        if "owner" in columns:
            connection.execute("DELETE FROM sessions WHERE owner='vesper'")
PY

python3 - "$CREDENTIALS" <<'PY'
import json
import sys
credentials = json.load(open(sys.argv[1], encoding="utf-8"))
print("New VESPER Control Center login (save it now):")
print("Username: " + credentials["username"])
print("Password: " + credentials["password"])
print("Existing VESPER admin sessions were revoked; the legacy admin token is disabled.")
PY
CHANGED=0
echo "Dashboard account reset succeeded. Backup: $BACKUP"
