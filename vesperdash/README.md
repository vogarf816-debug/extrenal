# VesperDash

A private patch-management server for the IPA integration. It stores encrypted `.3105` packages and provides an authenticated dashboard. The app manifest, patch downloads, and patch images require a short-lived, device-bound client session; license verification and package-password delivery happen on the server.

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
export VESPERDASH_M3SB_API_BASE_URL='https://api.m3sbapi.shop'
export VESPERDASH_M3SB_PACKAGE_TOKEN='load-this-from-a-private-secret-store'
export VESPERDASH_M3SB_HMAC_SECRET='load-this-from-a-private-secret-store'
export VESPERDASH_PACKAGE_PASSWORDS='["replace-with-a-new-random-password-at-least-16-characters"]'
python server.py
```

`VESPERDASH_PACKAGE_PASSWORDS` must be a JSON array of one or more strong package passwords (minimum 16 characters each; use 32+ random characters). These passwords are returned only after a valid license check and are stored on-device in Keychain. Re-encrypt and re-upload packages that used the old short passwords before enabling the protected app flow.

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
# Add the following values to /etc/vesperdash.env from your secret manager/editor,
# then keep the file mode at 600 and restart the service:
# VESPERDASH_M3SB_API_BASE_URL=https://api.m3sbapi.shop
# VESPERDASH_M3SB_PACKAGE_TOKEN=<rotated server-side package token>
# VESPERDASH_M3SB_HMAC_SECRET=<rotated server-side HMAC secret>
# VESPERDASH_PACKAGE_PASSWORDS='["<new 32+ character random package password>"]'
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

Admin credentials and M3SB credentials belong only in `/etc/vesperdash.env` or a protected secret manager. Never put them in an IPA, Git, or build artifacts. `VESPERDASH_CLIENT_SESSION_TTL` defaults to one hour; it may be lowered to reduce the exposure window.

## Security migration (required)

1. The previous repository revision and distributed IPA exposed M3SB credentials and short shared package passwords. Treat both as compromised. Rotate the M3SB package token and HMAC secret with the provider; do not send replacement values in chat.
2. Re-encrypt every `.3105` package using new strong passwords (at least 16 characters; prefer 32+ random characters), then upload the new files in the dashboard. Do not keep the old short passwords in `VESPERDASH_PACKAGE_PASSWORDS`.
3. Add the rotated M3SB credentials and new package password list to the server environment file with mode `0600`, deploy this server revision, and restart VesperDash.
4. Install/distribute the matching new IPA after the server update. Older app versions do not authenticate patch requests and will receive `401` once the API is protected.
5. Remove old credentials from Git history only after coordinating a history rewrite/force-push for every branch and clone. Deleting the file in a new commit alone does not erase prior copies.

## Update an existing VPS

After rotating the M3SB credentials, setting a new `VESPERDASH_PACKAGE_PASSWORDS` JSON list, and re-encrypting/re-uploading the `.3105` packages, run this on the Ubuntu VPS terminal:

```bash
curl -fsSL 'https://raw.githubusercontent.com/vogarf816-debug/extrenal/feat/baba-external-redesign/vesperdash/deploy_update.sh' -o /tmp/vesperdash-deploy.sh && sudo bash /tmp/vesperdash-deploy.sh
```

The script requires explicit acknowledgement that the exposed M3SB credentials were rotated and old packages were re-encrypted/re-uploaded. It validates the server-side environment values and package-password lengths, runs the security tests, backs up the existing app under `/opt/vesperdash/backups`, preserves the data directory and `/etc/vesperdash.env`, restarts the service, and checks that `/api/patches` is private. It attempts to restore the prior code if the post-deploy health checks fail. Set `VESPERDASH_DEPLOY_REF` only when you intentionally want a different Git ref.

The server stores only hashes of client access tokens and binds each session to a device ID. The app stores its session and package passwords in device-only Keychain storage. This prevents unauthenticated scraping, but it cannot prevent a fully authorized or jailbroken device from extracting a package after decryption; no client-side encryption can guarantee that.

## API

`GET /health` and public branding endpoints remain public. `POST /api/auth/client-session` validates the license through M3SB server-to-server and issues a short-lived device-bound session; `POST /api/auth/client-session/logout` revokes it. `GET /api/patches`, patch downloads, and patch images require `Authorization: Bearer <access_token>` plus `X-Device-ID` (images also accept authenticated dashboard sessions); client sessions are pinned to the Vesper tenant and cannot select another tenant with a query parameter. The dashboard continues to use username/password login through `POST /api/auth/login` and an HttpOnly session cookie; the legacy `X-Admin-Token` remains an owner-level maintenance credential. Admin endpoints are `GET /api/admin/patches`, `POST /api/admin/patches` (multipart upload), `POST /api/admin/patches/:id/state`, and `DELETE /api/admin/patches/:id`.

Each uploaded patch may optionally provide `target_path` and `target_path_2`. If both are empty, the IPA uses the target paths embedded in the `.3105` package, matching the legacy `DevicePatchService.apply(project:)` behavior. The API keeps `target_path` for older clients and also returns `target_paths` as an array. Existing catalog rows continue to work unchanged.
