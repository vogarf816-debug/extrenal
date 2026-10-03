# VesperDash

A small private patch-management server for the IPA integration. It stores encrypted `.3105` packages, exposes an IPA manifest, and provides an authenticated dashboard for upload, replacement, enable/disable, pause/resume, and deletion.

## Accounts and tenant isolation

The dashboard supports two isolated workspaces:

- `vesper` — the existing Vesper workspace.
- `jefry` — the Jefry External workspace.

Set the Jefry password only on the server environment; never put it in the repository or in an IPA:

```bash
sudo sh -c 'printf "\\nVESPERDASH_JEFRY_USERNAME=jefry\\nVESPERDASH_JEFRY_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_PASSWORD\\n" >> /etc/vesperdash.env'
sudo chmod 600 /etc/vesperdash.env
sudo systemctl restart vesperdash
```

Jefry sessions can only list, upload, edit, pause, or delete Jefry-owned catalog entries. Jefry settings and resellers are stored separately in `app_settings_jefry.json` and `resellers_jefry.json`; existing Vesper data remains in the original files. The legacy `X-Admin-Token` remains an owner-level maintenance credential and must stay private.

## Local run

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install flask gunicorn
export VESPERDASH_ADMIN_TOKEN='use-a-long-random-token'
export VESPERDASH_ADMIN_USERNAME='admin'
export VESPERDASH_ADMIN_PASSWORD='use-a-long-password'
export VESPERDASH_JEFRY_USERNAME='jefry'
export VESPERDASH_JEFRY_PASSWORD='use-a-different-long-password'
python server.py
```

## VPS install

Run as `root` on the Ubuntu VPS:

```bash
apt update && apt install -y python3-venv nginx
mkdir -p /opt/vesperdash/app
# Copy the `vesperdash/` directory here, including server.py and static/index.html.
python3 -m venv /opt/vesperdash/venv
/opt/vesperdash/venv/bin/pip install --upgrade pip flask gunicorn
TOKEN=$(openssl rand -hex 32)
JEFRY_PASSWORD=$(openssl rand -base64 24)
printf 'VESPERDASH_ADMIN_TOKEN=%s\nVESPERDASH_ADMIN_USERNAME=admin\nVESPERDASH_ADMIN_PASSWORD=CHANGE_ME_TO_A_LONG_PASSWORD\nVESPERDASH_JEFRY_USERNAME=jefry\nVESPERDASH_JEFRY_PASSWORD=%s\n' "$TOKEN" "$JEFRY_PASSWORD" > /etc/vesperdash.env
chmod 600 /etc/vesperdash.env
cat >/etc/systemd/system/vesperdash.service <<'UNIT'
[Unit]
Description=VesperDash patch API
After=network-online.target

[Service]
User=vesperdash
Group=www-data
WorkingDirectory=/opt/vesperdash/app
EnvironmentFile=/etc/vesperdash.env
Environment=VESPERDASH_DATA=/opt/vesperdash/data
ExecStart=/opt/vesperdash/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8080 server:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
chown -R vesperdash:www-data /opt/vesperdash
systemctl daemon-reload && systemctl enable --now vesperdash
```

The admin token is stored only in `/etc/vesperdash.env`. The dashboard asks for it in the browser and sends it as `X-Admin-Token`; do not put it in the IPA or publish it.

## API

`GET /health` is public. `GET /api/patches` returns enabled, non-paused patches for the requested tenant. The dashboard supports username/password login through `POST /api/auth/login` and an HttpOnly session cookie; the legacy `X-Admin-Token` header remains supported. Admin endpoints are `GET /api/admin/patches`, `POST /api/admin/patches` (multipart upload), `POST /api/admin/patches/:id/state`, and `DELETE /api/admin/patches/:id`.

Each uploaded patch may optionally provide `target_path` and `target_path_2`. If both are empty, the IPA uses the target paths embedded in the `.3105` package, matching the legacy `DevicePatchService.apply(project:)` behavior. The API keeps `target_path` for older clients and also returns `target_paths` as an array. Existing catalog rows continue to work unchanged.
