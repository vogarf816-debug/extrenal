import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from pathlib import Path
from functools import wraps

from flask import Flask, jsonify, request, send_from_directory, abort
from werkzeug.utils import secure_filename

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get("VESPERDASH_DATA", "/opt/vesperdash/data"))
PATCH_DIR = DATA / "patches"
IMAGE_DIR = DATA / "images"
DB = DATA / "vesperdash.sqlite3"
ADMIN_TOKEN = os.environ.get("VESPERDASH_ADMIN_TOKEN", "")
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
        bundle_id TEXT NOT NULL, target_path TEXT NOT NULL, filename TEXT NOT NULL,
        stored_filename TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1, paused INTEGER NOT NULL DEFAULT 0,
        version TEXT NOT NULL, image_filename TEXT NOT NULL DEFAULT '', status_text TEXT NOT NULL DEFAULT 'NO STATUS', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )""")
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(patches)")}
    if "category" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN category TEXT NOT NULL DEFAULT 'aim'")
    if "image_filename" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN image_filename TEXT NOT NULL DEFAULT ''")
    if "status_text" not in columns:
        conn.execute("ALTER TABLE patches ADD COLUMN status_text TEXT NOT NULL DEFAULT 'NO STATUS'")
    conn.execute("""CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
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
        if not ADMIN_TOKEN:
            abort(503, "VESPERDASH_ADMIN_TOKEN is not configured")
        token = request.headers.get("X-Admin-Token", "")
        if not hmac.compare_digest(token, ADMIN_TOKEN):
            abort(401, "unauthorized")
        return fn(*args, **kwargs)
    return wrapped


def public_row(row):
    image_url = f"/api/patches/{row['id']}/image" if row["image_filename"] else None
    return {**dict(row), "enabled": bool(row["enabled"]), "paused": bool(row["paused"]), "download_url": f"/api/patches/{row['id']}/download", "image_url": image_url}


def global_paused(conn):
    row = conn.execute("SELECT value FROM settings WHERE key='global_paused'").fetchone()
    return bool(row and row["value"] == "1")


@app.errorhandler(413)
def too_large(_):
    return jsonify(error="file too large"), 413


@app.get("/health")
def health():
    return jsonify(ok=True, service="vesperdash", time=int(time.time()))


@app.get("/api/patches")
def list_patches():
    conn = db(); paused = global_paused(conn); rows = conn.execute("SELECT * FROM patches ORDER BY game, name, version DESC").fetchall(); conn.close()
    all_patches = [public_row(r) for r in rows]
    active_patches = [] if paused else [p for p in all_patches if p["enabled"] and not p["paused"]]
    return jsonify(version=7, global_paused=paused, patches=active_patches, all_patches=all_patches)


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
    conn = db(); paused = global_paused(conn); rows = conn.execute("SELECT * FROM patches ORDER BY updated_at DESC").fetchall(); conn.close()
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
    bundle = request.form["bundle_id"]
    if bundle not in ALLOWED_BUNDLES: return jsonify(error="unsupported bundle_id"), 400
    category = request.form.get("category", "aim").lower()
    if category not in ALLOWED_CATEGORIES: return jsonify(error="unsupported category"), 400
    status_text = request.form.get("status_text", "NO STATUS").strip() or "NO STATUS"
    if len(status_text) > 120: return jsonify(error="status text is limited to 120 characters"), 400
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
    conn.execute("""INSERT INTO patches(id,name,category,game,bundle_id,target_path,filename,stored_filename,sha256,size,version,image_filename,status_text,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,category=excluded.category,game=excluded.game,bundle_id=excluded.bundle_id,target_path=excluded.target_path,filename=excluded.filename,stored_filename=excluded.stored_filename,sha256=excluded.sha256,size=excluded.size,version=excluded.version,image_filename=CASE WHEN excluded.image_filename != '' THEN excluded.image_filename ELSE patches.image_filename END,status_text=excluded.status_text,updated_at=excluded.updated_at""",
        (patch_id, request.form["name"], category, request.form["game"], bundle, request.form["target_path"], filename, stored, digest, len(raw), request.form["version"], image_filename, status_text, now, now))
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
    if not fields: return jsonify(error="send enabled, paused, and/or status_text"), 400
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
