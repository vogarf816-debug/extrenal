import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from pathlib import Path
from functools import wraps

from flask import Flask, jsonify, request, send_from_directory, abort, make_response
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
MAX_UPLOAD = int(os.environ.get("VESPERDASH_MAX_UPLOAD", str(80 * 1024 * 1024)))
ALLOWED_BUNDLES = {"com.dts.freefireth", "com.dts.freefiremax"}
ALLOWED_CATEGORIES = {"aim", "esp", "hologram", "skin"}

app = Flask(__name__, static_folder=str(ROOT / "static"), static_url_path="/static")
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD


def db():
    DATA.mkdir(parents=True, exist_ok=True)
    PATCH_DIR.mkdir(parents=True, exist_ok=True)
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
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
    session_columns = {row["name"] for row in conn.execute("PRAGMA table_info(sessions)")}
    if "owner" not in session_columns:
        conn.execute("ALTER TABLE sessions ADD COLUMN owner TEXT NOT NULL DEFAULT 'vesper'")
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES('global_paused', '0')")
    conn.execute("INSERT OR IGNORE INTO settings(key, value) SELECT 'global_paused_vesper', value FROM settings WHERE key='global_paused'")
    reset = conn.execute("SELECT value FROM settings WHERE key='catalog_reset_20260918'").fetchone()
    if not reset:
        stale_rows = conn.execute("SELECT stored_filename, image_filename FROM patches").fetchall()
        conn.execute("DELETE FROM patches")
        conn.execute("INSERT INTO settings(key, value) VALUES('catalog_reset_20260918', 'done')")
        for stale in stale_rows:
            try: (PATCH_DIR / stale["stored_filename"]).unlink()
            except FileNotFoundError: pass
            if stale["image_filename"]:
                try: (IMAGE_DIR / stale["image_filename"]).unlink()
                except FileNotFoundError: pass
    conn.commit()
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


def valid_settings(payload):
    if not isinstance(payload, dict): return None
    result = default_settings()
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
    payload = valid_settings(request.get_json(silent=True))
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
    image_url = f"/api/patches/{row['id']}/image" if row["image_filename"] else None
    try:
        target_paths = json.loads(row["target_paths"] or "[]")
    except (TypeError, json.JSONDecodeError):
        target_paths = []
    target_paths = [str(path).strip() for path in target_paths if str(path).strip()]
    if not target_paths and row["target_path"]:
        target_paths = [row["target_path"]]
    return {**dict(row), "target_paths": target_paths, "enabled": bool(row["enabled"]), "paused": bool(row["paused"]), "download_url": f"/api/patches/{row['id']}/download", "image_url": image_url}


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


@app.get("/api/patches")
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
    return jsonify(version=9, tenant=tenant, global_paused=paused, patches=active_patches, all_patches=all_patches)


@app.get("/api/patches/<patch_id>/download")
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
        conn.close(); return jsonify(error="patch id belongs to another tenant"), 409
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
