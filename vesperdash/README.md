# VesperDash

Flask API used by the VESPER iOS client and admin dashboard. Patch files, database state and runtime secrets are kept outside the replaceable application directory.

## Client security model

- The iOS application contains no M3SB package token or HMAC secret. The M3SB request is signed and sent by the VPS only.
- `POST /api/client/session` verifies the license with M3SB, checks the signed response against the requested license and device, then issues a random, short-lived client session. Only a SHA-256 digest of that session is stored in SQLite.
- The patch manifest, package-password list and `.3105` downloads require `Authorization: Bearer <client_session>`. Logging out revokes the session.
- Client session lifetime is controlled by `VESPERDASH_CLIENT_SESSION_TTL` (default: one hour) and is capped at the license expiration time.
- Obfuscating an API URL in an iOS binary is not a security boundary: a client can discover its network destinations. Access control, TLS and server-side secrets provide the security.

## VPS runtime configuration

Keep these values only in the root-owned `/etc/vesperdash.env` (or the systemd service's equivalent `EnvironmentFile`):

- `VESPERDASH_M3SB_API_BASE_URL` — HTTPS M3SB API base URL.
- `VESPERDASH_M3SB_PACKAGE_TOKEN` — M3SB package token.
- `VESPERDASH_M3SB_HMAC_SECRET` — M3SB HMAC secret.
- `VESPERDASH_PACKAGE_PASSWORDS` — JSON array of `.3105` package passwords.
- `VESPERDASH_DATA=/opt/vesperdash/data` — persistent database and uploaded files.

Do not paste credentials into chat, source code, Xcode settings or GitHub Actions secrets. Because prior IPA artifacts contained M3SB credentials, revoke/rotate both M3SB credentials before enabling the secure server code; deleting an artifact does not invalidate credentials that were already copied.

## Deploying the server update

The server code change is **not deployed automatically** by the iOS build workflow. After rotating credentials and verifying that the new values are present in `/etc/vesperdash.env`, update the existing VPS through its interactive terminal:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh)"
```

The deployment script asks for explicit confirmation, backs up the current application, preserves `/opt/vesperdash/data` and `/etc/vesperdash.env`, runs tests, restarts the service and checks that the health endpoint is available while the patch manifest is no longer public. It does not print secret values. Do not run it until both M3SB credentials have been rotated and configured on the VPS.

## Building the iOS IPA

GitHub Actions builds an **unsigned** IPA on `main` and runs the server security tests. It does not need M3SB Actions secrets. After a successful run, download the artifact named `VESPER-Build-9-unsigned-ipa` and sign it using the usual process. The app requires the secure server update above; the legacy public API is intentionally rejected.

## API routes

- `GET /health` — service health.
- `POST /api/client/session` — verify a license through M3SB and issue a client session.
- `POST /api/client/session/logout` — revoke the authenticated client session.
- `GET /api/patches` and `GET /api/patches/:id/download` — require a valid client Bearer session.
- `GET /api/patches/:id/image`, `/api/settings`, and `/api/resellers` — public display metadata only.
- `POST /api/auth/login` and `/api/admin/*` — existing dashboard authentication and management.

Run the security checks locally with:

```bash
python3 -m unittest vesperdash.test_security vesperdash.test_legacy_api -v
```
