import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from functools import wraps

from flask import Flask, jsonify, request, send_from_directory, abort, make_response, redirect
from werkzeug.utils import secure_filename

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get("VESPERDASH_DATA", "/opt/vesperdash/data"))
PATCH_DIR = DATA / "patches"
IMAGE_DIR = DATA / "images"
RESELLERS_FILE = DATA / "resellers.json"
SETTINGS_FILE = DATA / "app_settings.json"
DB = DATA / "vesperdash.sqlite3"
ADMIN_TOKEN = os.environ.get("VESPERDASH_ADMIN_TOKEN", "")
ADMIN_USERNAME = os.environ.get("VESPERDASH_ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("VESPERDASH_ADMIN_PASSWORD", "")
JEFRY_USERNAME = os.environ.get("VESPERDASH_JEFRY_USERNAME", "jefry")
JEFRY_PASSWORD = os.environ.get("VESPERDASH_JEFRY_PASSWORD", "")
SESSION_TTL = int(os.environ.get("VESPERDASH_SESSION_TTL", str(7 * 24 * 60 * 60)))
CLIENT_SESSION_TTL = int(os.environ.get("VESPERDASH_CLIENT_SESSION_TTL", str(60 * 60)))
M3SB_API_BASE_URL = os.environ.get("VESPERDASH_M3SB_API_BASE_URL", "").rstrip("/")
M3SB_PACKAGE_TOKEN = os.environ.get("VESPERDASH_M3SB_PACKAGE_TOKEN", os.environ.get("M3SB_PACKAGE_TOKEN", ""))
M3SB_HMAC_SECRET = os.environ.get("VESPERDASH_M3SB_HMAC_SECRET", os.environ.get("M3SB_HMAC_SECRET", ""))
VESPERDASH_PACKAGE_PASSWORDS = os.environ.get("VESPERDASH_PACKAGE_PASSWORDS", "")
MAX_UPLOAD = int(os.environ.get("VESPERDASH_MAX_UPLOAD", str(80 * 1024 * 1024)))
ALLOWED_BUNDLES = {"com.dts.freefireth", "com.dts.freefiremax"}
ALLOWED_CATEGORIES = {"aim", "esp", "hologram", "skin"}
VESPER_IPA_DOWNLOAD_URL = "https://github.com/vogarf816-debug/extrenal/releases/latest/download/VESPER-Build-35-unsigned.ipa"

app = Flask(__name__, static_folder=str(ROOT / "static"), static_url_path="/static")
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD

_DB_INIT_LOCK = threading.Lock()
_DB_INITIALIZED: set[str] = set()

def _initialize_database(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS patches (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, owner TEXT NOT NULL DEFAULT 'vesper', category TEXT NOT NULL DEFAULT 'aim', game TEXT NOT NULL,
        bundle_id TEXT NOT NULL, target_path TEXT NOT NULL, target_paths TEXT NOT NULL DEFAULT '[]', filename TEXT NOT NULL,
        stored_filename TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1, paused INTEGER NOT NULL DEFAULT 0,
        version TEXT NOT NULL, image_filename TEXT NOT NULL DEFAULT '', status_text TEXT NOT NULL DEFAULT 'NO STATUS', sort_order INTEGER NOT NULL DEFAULT 1000, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )""")
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(patches)")}
    if "owner" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN owner TEXT NOT NULL DEFAULT 'vesper'")
    if "category" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN category TEXT NOT NULL DEFAULT 'aim'")
    if "image_filename" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN image_filename TEXT NOT NULL DEFAULT ''")
    if "status_text" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN status_text TEXT NOT NULL DEFAULT 'NO STATUS'")
    if "sort_order" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 1000")
    if "target_paths" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN target_paths TEXT NOT NULL DEFAULT '[]'")
    conn.execute("""CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, username TEXT NOT NULL, expires_at INTEGER NOT NULL
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS client_sessions (
        token_hash TEXT PRIMARY KEY, license_hash TEXT NOT NULL, device_hash TEXT NOT NULL, expires_at INTEGER NOT NULL
    )""")
    client_session_columns = {row["name"] for row in conn.execute("PRAGMA table_info(client_sessions)")}
    if "device_hash" not in client_session_columns:
        conn.execute("ALTER TABLE client_sessions ADD COLUMN device_hash TEXT NOT NULL DEFAULT ''")
        if "device_id" in client_session_columns:
            legacy_rows = conn.execute("SELECT token_hash, device_id FROM client_sessions").fetchall()
            migrated = []
            for row in legacy_rows:
                legacy_device = str(row["device_id"] or "").strip()
                if not legacy_device:
                    continue
                if len(legacy_device) == 64 and all(ch in "0123456789abcdefABCDEF" for ch in legacy_device):
                    digest = legacy_device.lower()
                else:
                    digest = hashlib.sha256(legacy_device.encode()).hexdigest()
                migrated.append((digest, row["token_hash"]))
            conn.executemany("UPDATE client_sessions SET device_hash=? WHERE token_hash=?", migrated)
    session_columns = {row["name"] for row in conn.execute("PRAGMA table_info(sessions)")}
    if "owner" not in session_columns:
        conn.execute("ALTER TABLE sessions ADD COLUMN owner TEXT NOT NULL DEFAULT 'vesper'")
    setting_keys = {row["key"] for row in conn.execute("SELECT key FROM settings WHERE key IN ('global_paused', 'global_paused_vesper')")}
    if "global_paused" not in setting_keys:
        conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES('global_paused', '0')")
    if "global_paused_vesper" not in setting_keys:
        conn.execute("INSERT OR IGNORE INTO settings(key, value) SELECT 'global_paused_vesper', value FROM settings WHERE key='global_paused'")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_patches_owner_order ON patches(owner, category, game, sort_order, name)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_client_sessions_expires ON client_sessions(expires_at)")
    conn.commit()


def db():
    DATA.mkdir(parents=True, exist_ok=True)
    PATCH_DIR.mkdir(parents=True, exist_ok=True)
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB, timeout=8.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=8000")
    database_id = str(Path(DB).resolve())
    if database_id not in _DB_INITIALIZED:
        with _DB_INIT_LOCK:
            if database_id not in _DB_INITIALIZED:
                try:
                    journal_mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
                    if str(journal_mode).lower() != "wal":
                        conn.execute("PRAGMA journal_mode=WAL")
                    conn.execute("BEGIN IMMEDIATE")
                    _initialize_database(conn)
                    _DB_INITIALIZED.add(database_id)
                except Exception:
                    conn.rollback()
                    conn.close()
                    raise
    return conn


def auth_required(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        token = request.headers.get("X-Admin-Token", "")
        if ADMIN_TOKEN and hmac.compare_digest(token, ADMIN_TOKEN):
            request.environ["vesper_scope"] = None  # legacy token = owner access
            return fn(*args, **kwargs)
        session_token = request.cookies.get("vesperdash_session", "")
        if session_token:
            digest = hashlib.sha256(session_token.encode()).hexdigest()
            conn = db()
            row = conn.execute("SELECT owner, expires_at FROM sessions WHERE token_hash=?", (digest,)).fetchone()
            if row and int(row["expires_at"]) > int(time.time()):
                request.environ["vesper_scope"] = row["owner"]
                conn.close()
                return fn(*args, **kwargs)
            conn.execute("DELETE FROM sessions WHERE token_hash=?", (digest,)); conn.commit(); conn.close()
        if not ADMIN_TOKEN and not ADMIN_PASSWORD and not JEFRY_PASSWORD:
            abort(503, "admin login is not configured")
        abort(401, "unauthorized")
    return wrapped


def client_auth_required(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        authorization = request.headers.get("Authorization", "")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token or len(token) > 256:
            abort(401, "client session required")
        digest = hashlib.sha256(token.encode()).hexdigest()
        conn = db()
        row = conn.execute(
            "SELECT license_hash, device_hash, expires_at FROM client_sessions WHERE token_hash=?",
            (digest,),
        ).fetchone()
        if not row or int(row["expires_at"]) <= int(time.time()):
            conn.execute("DELETE FROM client_sessions WHERE token_hash=?", (digest,))
            conn.commit()
            conn.close()
            abort(401, "client session expired")
        conn.close()
        request.environ["vesper_client_session"] = dict(row)
        request.environ["vesper_scope"] = "vesper"
        return fn(*args, **kwargs)
    return wrapped


def auth_scope():
    return request.environ.get("vesper_scope")

def is_superuser():
    token = request.headers.get("X-Admin-Token", "")
    return bool(ADMIN_TOKEN and hmac.compare_digest(token, ADMIN_TOKEN))

def requested_tenant():
    scope = auth_scope()
    if scope:
        return scope
    value = request.args.get("tenant", "vesper").strip().lower()
    return value if value in {"vesper", "jefry"} else "vesper"


def default_settings(tenant="vesper"):
    if tenant == "jefry":
        return {"app_name":"Jefry External","developer_name":"Jefry","developer_subtitle":"Jefry External Control","channel_name":"Jefry Official Channel","channel_handle":"@JefryExternal","channel_url":"https://t.me/JefryExternal","owner_name":"Jefry","owner_handle":"@JefryExternal","owner_url":"https://t.me/JefryExternal","footer_text":"JEFRY • READY"}
    return {
        "app_name": "Vesper",
        "developer_name": "Vesper",
        "developer_subtitle": "Vesper Developer",
        "channel_name": "Vesper Official Channel",
        "channel_handle": "@VesperExtrenal",
        "channel_url": "https://t.me/VesperExtrenal",
        "owner_name": "Vesper Owner",
        "owner_handle": "@VesperExtrenal",
        "owner_url": "https://t.me/VesperExtrenal",
        "footer_text": "VESPER • READY"
    }


def scoped_file(base, tenant):
    if tenant == "vesper":
        return base
    return base.with_name(f"{base.stem}_{tenant}{base.suffix}")

def load_settings(tenant="vesper"):
    try:
        payload = json.loads(scoped_file(SETTINGS_FILE, tenant).read_text())
        if isinstance(payload, dict):
            result = default_settings(tenant); result.update(payload); return result
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return default_settings(tenant)


def valid_settings(payload, tenant="vesper"):
    if not isinstance(payload, dict): return None
    result = default_settings(tenant)
    for key in result:
        if key in payload:
            value = str(payload[key]).strip()
            if len(value) > 180: return None
            result[key] = value
    for key in ("channel_url", "owner_url"):
        if not result[key].startswith(("https://t.me/", "https://wa.me/", "https://www.tiktok.com/")): return None
    return result


@app.get("/api/settings")
def public_settings():
    return jsonify(load_settings(requested_tenant()))


@app.get("/api/admin/settings")
@auth_required
def admin_settings():
    return jsonify(load_settings(requested_tenant()))


@app.post("/api/admin/settings")
@auth_required
def save_settings():
    payload = valid_settings(request.get_json(silent=True), requested_tenant())
    if payload is None: return jsonify(error="invalid settings or link"), 400
    DATA.mkdir(parents=True, exist_ok=True)
    settings_file = scoped_file(SETTINGS_FILE, requested_tenant())
    temporary = settings_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(settings_file)
    return jsonify(payload)


def default_resellers(tenant="vesper"):
    if tenant == "jefry":
        return [{"id":"jefry-official","name":"Jefry Official","handle":"@JefryExternal","url":"https://t.me/JefryExternal","note":"Jefry External updates"}]
    return [
        {"id": "nullzth", "name": "NullZth Official", "handle": "@NullZth", "url": "https://t.me/NullZth", "note": "Owner / official contact"},
        {"id": "vesper-channel", "name": "Vesper Official Channel", "handle": "@VesperExtrenal", "url": "https://t.me/VesperExtrenal", "note": "Official updates and reseller announcements"},
    ]


def load_resellers(tenant="vesper"):
    try:
        payload = json.loads(scoped_file(RESELLERS_FILE, tenant).read_text())
        if isinstance(payload, list):
            return payload
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return default_resellers(tenant)


def valid_resellers(payload):
    if not isinstance(payload, list) or len(payload) > 100:
        return None
    result = []
    for item in payload:
        if not isinstance(item, dict):
            return None
        values = {key: str(item.get(key, '')).strip() for key in ('id', 'name', 'handle', 'url', 'note')}
        if not values['id'] or not values['name'] or not values['url']:
            return None
        if not values['url'].startswith(('https://t.me/', 'https://wa.me/', 'https://www.tiktok.com/')):
            return None
        result.append(values)
    return result


@app.get("/api/resellers")
def public_resellers():
    return jsonify(load_resellers(requested_tenant()))


@app.get("/api/admin/resellers")
@auth_required
def admin_resellers():
    return jsonify(load_resellers(requested_tenant()))


@app.post("/api/admin/resellers")
@auth_required
def save_resellers():
    payload = valid_resellers(request.get_json(silent=True))
    if payload is None:
        return jsonify(error="send a list of reseller objects with approved https links"), 400
    DATA.mkdir(parents=True, exist_ok=True)
    resellers_file = scoped_file(RESELLERS_FILE, requested_tenant())
    temporary = resellers_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(resellers_file)
    return jsonify(payload)


def public_row(row):
    owner = str(row["owner"] or "vesper")
    tenant_query = f"?tenant={owner}"
    image_url = f"/api/patches/{row['id']}/image{tenant_query}" if row["image_filename"] else None
    try:
        target_paths = json.loads(row["target_paths"] or "[]")
    except (TypeError, json.JSONDecodeError):
        target_paths = []
    target_paths = [str(path).strip() for path in target_paths if str(path).strip()]
    if not target_paths and row["target_path"]:
        target_paths = [row["target_path"]]
    return {**dict(row), "target_paths": target_paths, "enabled": bool(row["enabled"]), "paused": bool(row["paused"]), "download_url": f"/api/patches/{row['id']}/download{tenant_query}", "image_url": image_url}


def global_paused(conn, tenant="vesper"):
    key = "global_paused_" + tenant
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES(?, '0')", (key,))
    row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return bool(row and row["value"] == "1")


@app.errorhandler(413)
def too_large(_):
    return jsonify(error="file too large"), 413


@app.get("/health")
def health():
    return jsonify(ok=True, service="vesperdash", time=int(time.time()))


@app.get("/download/vesper.ipa")
def download_vesper_ipa():
    """Stable website URL for the current Vesper unsigned IPA release."""
    return redirect(VESPER_IPA_DOWNLOAD_URL, code=302)


@app.post("/api/auth/login")
def login():
    body = request.get_json(silent=True) or {}
    username = str(body.get("username", "")).strip()
    password = str(body.get("password", ""))
    accounts = []
    if ADMIN_PASSWORD:
        accounts.append((ADMIN_USERNAME, ADMIN_PASSWORD, "vesper"))
    if JEFRY_PASSWORD:
        accounts.append((JEFRY_USERNAME, JEFRY_PASSWORD, "jefry"))
    account = next((item for item in accounts if hmac.compare_digest(username, item[0]) and hmac.compare_digest(password, item[1])), None)
    if not accounts:
        return jsonify(error="username/password login is not configured"), 503
    if not account:
        return jsonify(error="invalid username or password"), 401
    owner = account[2]
    raw_token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(raw_token.encode()).hexdigest()
    expires = int(time.time()) + SESSION_TTL
    conn = db(); conn.execute("INSERT INTO sessions(token_hash,username,owner,expires_at) VALUES(?,?,?,?)", (digest, username, owner, expires)); conn.commit(); conn.close()
    response = make_response(jsonify(ok=True, username=username, owner=owner, expires_at=expires))
    response.set_cookie("vesperdash_session", raw_token, max_age=SESSION_TTL, httponly=True, secure=request.is_secure, samesite="Lax")
    return response


@app.post("/api/auth/logout")
def logout():
    session_token = request.cookies.get("vesperdash_session", "")
    if session_token:
        digest = hashlib.sha256(session_token.encode()).hexdigest()
        conn = db(); conn.execute("DELETE FROM sessions WHERE token_hash=?", (digest,)); conn.commit(); conn.close()
    response = make_response(jsonify(ok=True)); response.delete_cookie("vesperdash_session")
    return response


@app.get("/api/auth/me")
@auth_required
def auth_me():
    return jsonify(ok=True)


def _signature_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def _m3sb_response_trust_error(payload, expected_key, expected_device_hash):
    signature = payload.get("sig_v2")
    raw_timestamp = payload.get("ts")
    if not isinstance(signature, str) or not signature:
        return "signature_missing"
    if isinstance(raw_timestamp, bool):
        return "timestamp_invalid"
    try:
        timestamp = float(raw_timestamp)
    except (TypeError, ValueError):
        return "timestamp_invalid"
    if timestamp > 10_000_000_000:
        timestamp /= 1000.0
    if abs(time.time() - timestamp) > 300:
        return "timestamp_expired"
    fields = ("valid", "status", "license", "device_hash", "expires_at", "devices_left", "allow_inject", "ts")
    parts = []
    for field in fields:
        value = payload.get(field)
        parts.append(f"{field}=" if value is None else f"{field}={_signature_value(value)}")
    canonical = "&".join(parts)
    expected = hmac.new(M3SB_HMAC_SECRET.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return "signature_mismatch"
    if payload.get("license") != expected_key:
        return "license_identity_mismatch"
    if payload.get("device_hash") != expected_device_hash:
        return "device_identity_mismatch"
    return None


def _m3sb_response_is_trusted(payload, expected_key, expected_device_hash):
    return _m3sb_response_trust_error(payload, expected_key, expected_device_hash) is None


def _expiry_timestamp(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        timestamp = float(value)
        return timestamp / 1000.0 if timestamp > 10_000_000_000 else timestamp
    if isinstance(value, str) and value.strip():
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.timestamp()
        except ValueError:
            return None
    return None


class LicenseProviderHTTPError(RuntimeError):
    def __init__(self, status_code):
        self.status_code = int(status_code)
        super().__init__(f"license provider rejected request (HTTP {self.status_code})")


def _verify_license_with_m3sb(key, device_id, body):
    if not M3SB_API_BASE_URL or not M3SB_PACKAGE_TOKEN or not M3SB_HMAC_SECRET:
        raise RuntimeError("license service is not configured")
    payload = {
        "token": M3SB_PACKAGE_TOKEN,
        "key": key,
        "device_id": device_id,
        "dylibs": str(max(0, min(int(body.get("dylibs", 0)), 128))),
        "udid": hashlib.sha256(device_id.encode()).hexdigest(),
        "device_hash": hashlib.sha256(device_id.encode()).hexdigest(),
        "device_name": str(body.get("device_name", "iOS device"))[:100],
        "system_info": str(body.get("system_info", "iOS"))[:100],
        "os_info": str(body.get("os_info", ""))[:50],
    }
    body_data = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    timestamp = str(int(time.time()))
    # Match the original iOS client: UUID().uuidString without hyphens.
    nonce = uuid.uuid4().hex.upper()
    body_hash = hashlib.sha256(body_data).hexdigest()
    canonical = "\n".join(("M3SB-API-SIGNATURE-V3", "POST", "/api/sdk/verify", timestamp, nonce, body_hash, M3SB_PACKAGE_TOKEN, key, device_id))
    signature = hmac.new(M3SB_HMAC_SECRET.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        f"{M3SB_API_BASE_URL}/api/sdk/verify",
        data=body_data,
        headers={
            "Content-Type": "application/json",
            "X-APON-Client": "APON/3.0 (iOS)",
            "X-M3SB-Signature-Version": "3",
            "X-M3SB-Timestamp": timestamp,
            "X-M3SB-Nonce": nonce,
            "X-M3SB-Body-SHA256": body_hash,
            "X-M3SB-Signature": signature,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            raw = response.read(1024 * 1024)
    except urllib.error.HTTPError as exc:
        raw = exc.read(1024 * 1024)
        try:
            error_result = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            error_result = None
        status = str(error_result.get("status", "")).strip().lower().replace("-", "_") if isinstance(error_result, dict) else ""
        license_statuses = {
            "invalid", "invalid_license", "license_invalid", "expired", "banned",
            "revoked", "inactive", "not_found", "notfound", "license_not_found",
        }
        if exc.code in {400, 403, 422} and isinstance(error_result, dict) and (
            error_result.get("valid") is False or status in license_statuses
        ) and status not in {"forbidden", "unauthorized", "invalid_token", "token_invalid", "invalid_signature", "signature_invalid", "bad_signature"}:
            error_result.setdefault("valid", False)
            return error_result
        raise LicenseProviderHTTPError(exc.code) from None
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise RuntimeError("invalid license response")
    return result


@app.post("/api/client/session")
def create_client_session():
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return jsonify(valid=False, message="invalid request"), 400
    key = str(body.get("key", "")).strip()
    device_id = str(body.get("device_id", "")).strip()
    if not 8 <= len(key) <= 256 or not 8 <= len(device_id) <= 128:
        return jsonify(valid=False, message="key or device identifier is invalid"), 400
    try:
        result = _verify_license_with_m3sb(key, device_id, body)
    except LicenseProviderHTTPError as exc:
        return jsonify(
            valid=False,
            status="provider_rejected",
            message=f"license provider rejected request (HTTP {exc.status_code})",
        ), 502
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
        return jsonify(valid=False, message="license service is temporarily unavailable"), 502
    if result.get("valid") is not True:
        return jsonify(
            valid=False,
            status=str(result.get("status", "invalid"))[:80],
            expires_at=result.get("expires_at"),
            message=str(result.get("message", "license is not active"))[:180],
        ), 403

    device_hash = hashlib.sha256(device_id.encode()).hexdigest()
    if not _m3sb_response_is_trusted(result, key, device_hash):
        return jsonify(valid=False, message="license response could not be verified"), 502
    return _issue_client_session(result, key, device_id)


def _issue_client_session(result, key, device_id):
    status = str(result.get("status", "")).strip().lower()
    rejected_statuses = {"expired", "banned", "revoked", "invalid", "inactive", "not_found", "notfound", "license_invalid"}
    if result.get("valid") is not True or status in rejected_statuses:
        return jsonify(valid=False, status=status or "invalid", message="license is not active"), 403
    device_hash = hashlib.sha256(device_id.encode()).hexdigest()
    raw_token = secrets.token_urlsafe(32)
    token_hash = hashlib.sha256(raw_token.encode()).hexdigest()
    license_hash = hashlib.sha256(key.encode()).hexdigest()
    ttl = max(60, min(CLIENT_SESSION_TTL, 24 * 60 * 60))
    now = time.time()
    license_expires = _expiry_timestamp(result.get("expires_at"))
    if license_expires is not None and license_expires <= now:
        return jsonify(valid=False, status="expired", expires_at=result.get("expires_at"), message="license is expired"), 403
    expires = int(min(now + ttl, license_expires) if license_expires is not None else now + ttl)
    conn = db()
    conn.execute(
        "DELETE FROM client_sessions WHERE license_hash=? AND device_hash=?",
        (license_hash, device_hash),
    )
    client_columns = {row["name"] for row in conn.execute("PRAGMA table_info(client_sessions)")}
    insert_columns = ["token_hash", "license_hash", "device_hash", "expires_at"]
    insert_values = [token_hash, license_hash, device_hash, expires]
    if "device_id" in client_columns:
        insert_columns.append("device_id")
        insert_values.append(device_id)
    if "owner" in client_columns:
        insert_columns.append("owner")
        insert_values.append("vesper")
    if "created_at" in client_columns:
        insert_columns.append("created_at")
        insert_values.append(int(now))
    columns_sql = ",".join(insert_columns)
    placeholders = ",".join("?" for _ in insert_values)
    conn.execute(
        f"INSERT INTO client_sessions({columns_sql}) VALUES({placeholders})",
        insert_values,
    )
    conn.commit()
    conn.close()
    response = jsonify(
        valid=True,
        status=result.get("status"),
        expires_at=result.get("expires_at"),
        telegram_username=result.get("telegram_username"),
        message=result.get("message"),
        client_session=raw_token,
        client_session_expires_at=expires,
    )
    response.headers["Cache-Control"] = "no-store"
    return response


@app.post("/api/client/session/logout")
@client_auth_required
def delete_client_session():
    authorization = request.headers.get("Authorization", "")
    _, _, token = authorization.partition(" ")
    digest = hashlib.sha256(token.encode()).hexdigest()
    conn = db()
    conn.execute("DELETE FROM client_sessions WHERE token_hash=?", (digest,))
    conn.commit()
    conn.close()
    return jsonify(ok=True)


def server_package_passwords(tenant):
    """Load package keys from server-only configuration for authenticated clients."""
    if tenant != "vesper":
        return []
    try:
        values = json.loads(os.environ.get("VESPERDASH_PACKAGE_PASSWORDS", ""))
    except (TypeError, json.JSONDecodeError):
        return []
    if not isinstance(values, list):
        return []
    return [value.strip() for value in values[:10] if isinstance(value, str) and 1 <= len(value.strip()) <= 128]


@app.get("/api/patches")
@client_auth_required
def list_patches():
    conn = db(); scope = requested_tenant(); paused = global_paused(conn, scope)
    if is_superuser() and request.args.get("tenant") is None:
        rows = conn.execute("SELECT * FROM patches ORDER BY category, game, sort_order, name").fetchall()
    else:
        rows = conn.execute("SELECT * FROM patches WHERE owner=? ORDER BY category, game, sort_order, name", (scope,)).fetchall()
    conn.close()
    all_patches = [public_row(r) for r in rows]
    active_patches = [] if paused else [p for p in all_patches if p["enabled"] and not p["paused"]]
    tenant = requested_tenant()
    response = jsonify(
        version=9,
        tenant=tenant,
        global_paused=paused,
        patches=active_patches,
        all_patches=all_patches,
        package_passwords=server_package_passwords(tenant),
    )
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/api/patches/<patch_id>/download")
@client_auth_required
def download_patch(patch_id):
    conn = db(); scope = requested_tenant(); paused = global_paused(conn, scope); row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, scope)).fetchone(); conn.close()
    if paused or not row or not row["enabled"] or row["paused"]:
        abort(404)
    path = PATCH_DIR / row["stored_filename"]
    if not path.is_file(): abort(404)
    return send_from_directory(PATCH_DIR, row["stored_filename"], as_attachment=True, download_name=row["filename"])


@app.get("/api/patches/<patch_id>/image")
def patch_image(patch_id):
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, requested_tenant())).fetchone(); conn.close()
    if not row or not row["enabled"] or row["paused"] or not row["image_filename"]:
        abort(404)
    path = IMAGE_DIR / row["image_filename"]
    if not path.is_file(): abort(404)
    return send_from_directory(IMAGE_DIR, row["image_filename"])


@app.get("/api/admin/patches")
@auth_required
def admin_patches():
    scope = requested_tenant(); conn = db(); paused = global_paused(conn, scope)
    if is_superuser() and request.args.get("tenant") is None:
        rows = conn.execute("SELECT * FROM patches ORDER BY category, game, sort_order, name").fetchall()
    else:
        rows = conn.execute("SELECT * FROM patches WHERE owner=? ORDER BY category, game, sort_order, name", (scope,)).fetchall()
    conn.close()
    return jsonify(tenant=scope, global_paused=paused, patches=[public_row(r) for r in rows])


@app.get("/api/admin/state")
@auth_required
def admin_state():
    conn = db(); paused = global_paused(conn, requested_tenant()); conn.close()
    return jsonify(global_paused=paused, tenant=requested_tenant())


@app.post("/api/admin/state")
@auth_required
def set_admin_state():
    body = request.get_json(silent=True) or {}
    if "global_paused" not in body:
        return jsonify(error="send global_paused"), 400
    conn = db(); tenant = requested_tenant(); key = "global_paused_" + tenant; conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES(?, ?)", (key, "1" if bool(body["global_paused"]) else "0")); conn.commit(); paused = global_paused(conn, tenant); conn.close()
    return jsonify(global_paused=paused)


@app.post("/api/admin/patches")
@auth_required
def upload_patch():
    required = ["id", "name", "game", "bundle_id", "version"]
    if not all(request.form.get(k) for k in required): return jsonify(error="missing metadata"), 400
    raw_target_paths = [request.form.get("target_path", ""), request.form.get("target_path_2", "")]
    target_paths = []
    for path in raw_target_paths:
        path = path.strip()
        if path and path not in target_paths:
            target_paths.append(path)
    bundle = request.form["bundle_id"]
    if bundle not in ALLOWED_BUNDLES: return jsonify(error="unsupported bundle_id"), 400
    category = request.form.get("category", "aim").lower()
    if category not in ALLOWED_CATEGORIES: return jsonify(error="unsupported category"), 400
    status_text = request.form.get("status_text", "NO STATUS").strip() or "NO STATUS"
    if len(status_text) > 120: return jsonify(error="status text is limited to 120 characters"), 400
    try: sort_order = int(request.form.get("sort_order", "1000"))
    except ValueError: return jsonify(error="order number must be an integer"), 400
    if not 0 <= sort_order <= 9999: return jsonify(error="order number must be between 0 and 9999"), 400
    uploaded = request.files.get("file")
    if not uploaded or not uploaded.filename: return jsonify(error="missing file"), 400
    filename = secure_filename(uploaded.filename)
    if not filename.endswith(".3105"): return jsonify(error="only .3105 packages are accepted"), 400
    patch_id = secure_filename(request.form["id"])
    if not patch_id: return jsonify(error="invalid id"), 400
    raw = uploaded.read()
    if not raw.startswith(b"3105PATCH\x00"): return jsonify(error="invalid 3105 package header"), 400
    digest = hashlib.sha256(raw).hexdigest(); stored = f"{patch_id}-{digest[:12]}.3105"
    PATCH_DIR.mkdir(parents=True, exist_ok=True); (PATCH_DIR / stored).write_bytes(raw)
    image_filename = ""
    image = request.files.get("image")
    if image and image.filename:
        image_raw = image.read()
        if len(image_raw) > 5 * 1024 * 1024: return jsonify(error="image too large; maximum is 5 MB"), 400
        if image_raw.startswith(b"\x89PNG\r\n\x1a\n"):
            extension = "png"
        elif image_raw.startswith(b"\xff\xd8\xff"):
            extension = "jpg"
        elif image_raw.startswith(b"RIFF") and image_raw[8:12] == b"WEBP":
            extension = "webp"
        else:
            return jsonify(error="image must be PNG, JPEG, or WebP"), 400
        image_digest = hashlib.sha256(image_raw).hexdigest()
        image_filename = f"{patch_id}-cover-{image_digest[:12]}.{extension}"
        IMAGE_DIR.mkdir(parents=True, exist_ok=True); (IMAGE_DIR / image_filename).write_bytes(image_raw)
    owner = requested_tenant()
    now = int(time.time()); conn = db()
    existing = conn.execute("SELECT owner FROM patches WHERE id=?", (patch_id,)).fetchone()
    if existing and existing["owner"] != owner:
        conn.close()
        try: (PATCH_DIR / stored).unlink()
        except FileNotFoundError: pass
        if image_filename:
            try: (IMAGE_DIR / image_filename).unlink()
            except FileNotFoundError: pass
        return jsonify(error="patch id belongs to another tenant"), 409
    conn.execute("""INSERT INTO patches(id,name,owner,category,game,bundle_id,target_path,target_paths,filename,stored_filename,sha256,size,version,image_filename,status_text,sort_order,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,owner=excluded.owner,category=excluded.category,game=excluded.game,bundle_id=excluded.bundle_id,target_path=excluded.target_path,target_paths=excluded.target_paths,filename=excluded.filename,stored_filename=excluded.stored_filename,sha256=excluded.sha256,size=excluded.size,version=excluded.version,image_filename=CASE WHEN excluded.image_filename != '' THEN excluded.image_filename ELSE patches.image_filename END,status_text=excluded.status_text,sort_order=excluded.sort_order,updated_at=excluded.updated_at""",
        (patch_id, request.form["name"], owner, category, request.form["game"], bundle, target_paths[0] if target_paths else "", json.dumps(target_paths), filename, stored, digest, len(raw), request.form["version"], image_filename, status_text, sort_order, now, now))
    conn.commit(); row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, owner)).fetchone(); conn.close()
    return jsonify(patch=public_row(row)), 201


@app.post("/api/admin/patches/<patch_id>/state")
@auth_required
def patch_state(patch_id):
    body = request.get_json(silent=True) or {}
    fields = {k: int(bool(body[k])) for k in ("enabled", "paused") if k in body}
    if "status_text" in body:
        status_text = str(body["status_text"]).strip() or "NO STATUS"
        if len(status_text) > 120: return jsonify(error="status text is limited to 120 characters"), 400
        fields["status_text"] = status_text
    if "sort_order" in body:
        try: sort_order = int(body["sort_order"])
        except (TypeError, ValueError): return jsonify(error="order number must be an integer"), 400
        if not 0 <= sort_order <= 9999: return jsonify(error="order number must be between 0 and 9999"), 400
        fields["sort_order"] = sort_order
    if not fields: return jsonify(error="send enabled, paused, status_text, and/or sort_order"), 400
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, requested_tenant())).fetchone()
    if not row: conn.close(); abort(404)
    conn.execute("UPDATE patches SET " + ", ".join(f"{k}=?" for k in fields) + ", updated_at=? WHERE id=? AND owner=?", (*fields.values(), int(time.time()), patch_id, requested_tenant())); conn.commit()
    row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, requested_tenant())).fetchone(); conn.close(); return jsonify(patch=public_row(row))


@app.delete("/api/admin/patches/<patch_id>")
@auth_required
def delete_patch(patch_id):
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=? AND owner=?", (patch_id, requested_tenant())).fetchone()
    if not row: conn.close(); abort(404)
    conn.execute("DELETE FROM patches WHERE id=? AND owner=?", (patch_id, requested_tenant())); conn.commit(); conn.close()
    try: (PATCH_DIR / row["stored_filename"]).unlink()
    except FileNotFoundError: pass
    if row["image_filename"]:
        try: (IMAGE_DIR / row["image_filename"]).unlink()
        except FileNotFoundError: pass
    return jsonify(ok=True)


@app.get("/")
def index():
    return send_from_directory(ROOT / "static", "index.html")


if __name__ == "__main__":
    db()
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8080")))
