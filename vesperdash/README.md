# VesperDash

A small private patch-management server for the IPA integration. It stores encrypted `.3105` packages, exposes an IPA manifest, and provides an authenticated dashboard for upload, replacement, enable/disable, pause/resume, and deletion.

## Local run

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install flask gunicorn
export VESPERDASH_ADMIN_TOKEN='use-a-long-random-token'
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
printf 'VESPERDASH_ADMIN_TOKEN=%s\n' "$TOKEN" > /etc/vesperdash.env
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
cat >/etc/nginx/sites-available/vesperdash <<'NGINX'
server {
    listen 80;
    server_name vesperdash.com api.vesperdash.com panel.vesperdash.com;
    client_max_body_size 80M;
    location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }
}
NGINX
ln -sf /etc/nginx/sites-available/vesperdash /etc/nginx/sites-enabled/vesperdash
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
apt install -y certbot python3-certbot-nginx
certbot --nginx -d vesperdash.com -d api.vesperdash.com -d panel.vesperdash.com
```

After Certbot asks for the email/terms, the dashboard is at `https://panel.vesperdash.com/` and the IPA manifest is at `https://api.vesperdash.com/api/patches`.

The admin token is stored only in `/etc/vesperdash.env`. The dashboard asks for it in the browser and sends it as `X-Admin-Token`; do not put it in the IPA or publish it.

## API

`GET /health` is public. `GET /api/patches` returns enabled, non-paused patches. Admin endpoints require `X-Admin-Token`: `GET /api/admin/patches`, `POST /api/admin/patches` (multipart upload), `POST /api/admin/patches/:id/state`, and `DELETE /api/admin/patches/:id`.

This first server deliberately does not overwrite the IPA's local patch flow. Remote download and signature verification must be added to the IPA before remote files can be applied; the server is ready to provide the manifest and files.
