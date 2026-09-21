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
DB = DATA / "vesperdash.sqlite3"
ADMIN_TOKEN = os.environ.get("VESPERDASH_ADMIN_TOKEN", "")
ADMIN_USERNAME = os.environ.get("VESPERDASH_ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.environ.get("VESPERDASH_ADMIN_PASSWORD", "")
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
        id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'aim', game TEXT NOT NULL,
        bundle_id TEXT NOT NULL, target_path TEXT NOT NULL, target_paths TEXT NOT NULL DEFAULT '[]', filename TEXT NOT NULL,
        stored_filename TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1, paused INTEGER NOT NULL DEFAULT 0,
        version TEXT NOT NULL, image_filename TEXT NOT NULL DEFAULT '', status_text TEXT NOT NULL DEFAULT 'NO STATUS', sort_order INTEGER NOT NULL DEFAULT 1000, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )""")
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(patches)")}
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
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES('global_paused', '0')")
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
            return fn(*args, **kwargs)
        session_token = request.cookies.get("vesperdash_session", "")
        if session_token:
            digest = hashlib.sha256(session_token.encode()).hexdigest()
            conn = db()
            row = conn.execute("SELECT expires_at FROM sessions WHERE token_hash=?", (digest,)).fetchone()
            if row and int(row["expires_at"]) > int(time.time()):
                conn.close()
                return fn(*args, **kwargs)
            conn.execute("DELETE FROM sessions WHERE token_hash=?", (digest,)); conn.commit(); conn.close()
        if not ADMIN_TOKEN and not ADMIN_PASSWORD:
            abort(503, "admin login is not configured")
        abort(401, "unauthorized")
        return fn(*args, **kwargs)
    return wrapped


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


def global_paused(conn):
    row = conn.execute("SELECT value FROM settings WHERE key='global_paused'").fetchone()
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
    if not ADMIN_PASSWORD:
        return jsonify(error="username/password login is not configured"), 503
    if not hmac.compare_digest(username, ADMIN_USERNAME) or not hmac.compare_digest(password, ADMIN_PASSWORD):
        return jsonify(error="invalid username or password"), 401
    raw_token = secrets.token_urlsafe(32)
    digest = hashlib.sha256(raw_token.encode()).hexdigest()
    expires = int(time.time()) + SESSION_TTL
    conn = db(); conn.execute("INSERT INTO sessions(token_hash,username,expires_at) VALUES(?,?,?)", (digest, username, expires)); conn.commit(); conn.close()
    response = make_response(jsonify(ok=True, username=username, expires_at=expires))
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
    conn = db(); paused = global_paused(conn); rows = conn.execute("SELECT * FROM patches ORDER BY category, game, sort_order, name").fetchall(); conn.close()
    all_patches = [public_row(r) for r in rows]
    active_patches = [] if paused else [p for p in all_patches if p["enabled"] and not p["paused"]]
    return jsonify(version=8, global_paused=paused, patches=active_patches, all_patches=all_patches)


@app.get("/api/patches/<patch_id>/download")
def download_patch(patch_id):
    conn = db(); paused = global_paused(conn); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close()
    if paused or not row or not row["enabled"] or row["paused"]:
        abort(404)
    path = PATCH_DIR / row["stored_filename"]
    if not path.is_file(): abort(404)
    return send_from_directory(PATCH_DIR, row["stored_filename"], as_attachment=True, download_name=row["filename"])


@app.get("/api/patches/<patch_id>/image")
def patch_image(patch_id):
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close()
    if not row or not row["enabled"] or row["paused"] or not row["image_filename"]:
        abort(404)
    path = IMAGE_DIR / row["image_filename"]
    if not path.is_file(): abort(404)
    return send_from_directory(IMAGE_DIR, row["image_filename"])


@app.get("/api/admin/patches")
@auth_required
def admin_patches():
    conn = db(); paused = global_paused(conn); rows = conn.execute("SELECT * FROM patches ORDER BY category, game, sort_order, name").fetchall(); conn.close()
    return jsonify(global_paused=paused, patches=[public_row(r) for r in rows])


@app.get("/api/admin/state")
@auth_required
def admin_state():
    conn = db(); paused = global_paused(conn); conn.close()
    return jsonify(global_paused=paused)


@app.post("/api/admin/state")
@auth_required
def set_admin_state():
    body = request.get_json(silent=True) or {}
    if "global_paused" not in body:
        return jsonify(error="send global_paused"), 400
    conn = db(); conn.execute("UPDATE settings SET value=? WHERE key='global_paused'", ("1" if bool(body["global_paused"]) else "0",)); conn.commit(); paused = global_paused(conn); conn.close()
    return jsonify(global_paused=paused)


@app.post("/api/admin/patches")
@auth_required
def upload_patch():
    required = ["id", "name", "game", "bundle_id", "target_path", "version"]
    if not all(request.form.get(k) for k in required): return jsonify(error="missing metadata"), 400
    raw_target_paths = [request.form.get("target_path", ""), request.form.get("target_path_2", "")]
    target_paths = []
    for path in raw_target_paths:
        path = path.strip()
        if path and path not in target_paths:
            target_paths.append(path)
    if not target_paths:
        return jsonify(error="at least one target path is required"), 400
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
    now = int(time.time()); conn = db()
    conn.execute("""INSERT INTO patches(id,name,category,game,bundle_id,target_path,target_paths,filename,stored_filename,sha256,size,version,image_filename,status_text,sort_order,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,category=excluded.category,game=excluded.game,bundle_id=excluded.bundle_id,target_path=excluded.target_path,target_paths=excluded.target_paths,filename=excluded.filename,stored_filename=excluded.stored_filename,sha256=excluded.sha256,size=excluded.size,version=excluded.version,image_filename=CASE WHEN excluded.image_filename != '' THEN excluded.image_filename ELSE patches.image_filename END,status_text=excluded.status_text,sort_order=excluded.sort_order,updated_at=excluded.updated_at""",
        (patch_id, request.form["name"], category, request.form["game"], bundle, target_paths[0], json.dumps(target_paths), filename, stored, digest, len(raw), request.form["version"], image_filename, status_text, sort_order, now, now))
    conn.commit(); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close()
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
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone()
    if not row: conn.close(); abort(404)
    conn.execute("UPDATE patches SET " + ", ".join(f"{k}=?" for k in fields) + ", updated_at=? WHERE id=?", (*fields.values(), int(time.time()), patch_id)); conn.commit()
    row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close(); return jsonify(patch=public_row(row))


@app.delete("/api/admin/patches/<patch_id>")
@auth_required
def delete_patch(patch_id):
    conn = db(); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone()
    if not row: conn.close(); abort(404)
    conn.execute("DELETE FROM patches WHERE id=?", (patch_id,)); conn.commit(); conn.close()
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
