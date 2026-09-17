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
DB = DATA / "vesperdash.sqlite3"
ADMIN_TOKEN = os.environ.get("VESPERDASH_ADMIN_TOKEN", "")
MAX_UPLOAD = int(os.environ.get("VESPERDASH_MAX_UPLOAD", str(80 * 1024 * 1024)))
ALLOWED_BUNDLES = {"com.dts.freefireth", "com.dts.freefiremax"}

app = Flask(__name__, static_folder=str(ROOT / "static"), static_url_path="/static")
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD


def db():
    DATA.mkdir(parents=True, exist_ok=True)
    PATCH_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS patches (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, game TEXT NOT NULL,
        bundle_id TEXT NOT NULL, target_path TEXT NOT NULL, filename TEXT NOT NULL,
        stored_filename TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1, paused INTEGER NOT NULL DEFAULT 0,
        version TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY, value TEXT NOT NULL
    )""")
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES('global_paused', '0')")
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
    return {**dict(row), "enabled": bool(row["enabled"]), "paused": bool(row["paused"]), "download_url": f"/api/patches/{row['id']}/download"}


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
    return jsonify(version=2, global_paused=paused, patches=[] if paused else [public_row(r) for r in rows if r["enabled"] and not r["paused"]])


@app.get("/api/patches/<patch_id>/download")
def download_patch(patch_id):
    conn = db(); paused = global_paused(conn); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close()
    if paused or not row or not row["enabled"] or row["paused"]:
        abort(404)
    path = PATCH_DIR / row["stored_filename"]
    if not path.is_file(): abort(404)
    return send_from_directory(PATCH_DIR, row["stored_filename"], as_attachment=True, download_name=row["filename"])


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
    now = int(time.time()); conn = db()
    conn.execute("""INSERT INTO patches(id,name,game,bundle_id,target_path,filename,stored_filename,sha256,size,version,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,game=excluded.game,bundle_id=excluded.bundle_id,target_path=excluded.target_path,filename=excluded.filename,stored_filename=excluded.stored_filename,sha256=excluded.sha256,size=excluded.size,version=excluded.version,updated_at=excluded.updated_at""",
        (patch_id, request.form["name"], request.form["game"], bundle, request.form["target_path"], filename, stored, digest, len(raw), request.form["version"], now, now))
    conn.commit(); row = conn.execute("SELECT * FROM patches WHERE id=?", (patch_id,)).fetchone(); conn.close()
    return jsonify(patch=public_row(row)), 201


@app.post("/api/admin/patches/<patch_id>/state")
@auth_required
def patch_state(patch_id):
    body = request.get_json(silent=True) or {}
    fields = {k: int(bool(body[k])) for k in ("enabled", "paused") if k in body}
    if not fields: return jsonify(error="send enabled and/or paused"), 400
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
    return jsonify(ok=True)


@app.get("/")
def index():
    return send_from_directory(ROOT / "static", "index.html")


if __name__ == "__main__":
    db()
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8080")))
