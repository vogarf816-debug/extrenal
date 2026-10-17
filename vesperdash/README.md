# VesperDash

Flask API used by the VESPER iOS client and admin dashboard. Patch files, database state and runtime secrets are kept outside the replaceable application directory.

## Activation and patch-download flow

- The iOS app sends the M3SB `/api/sdk/verify` request directly, using a package token and HMAC secret supplied to the build workflow as GitHub Actions secrets.
- The app validates the provider's signed response locally, then sends the original provider response, license key and device ID to `POST /api/client/session/bridge`.
- VesperDash independently checks the provider HMAC signature, timestamp freshness, license identity and device hash before issuing a short-lived client session. Only the session digest is stored in SQLite.
- Patch manifests, package passwords and `.3105` downloads require `Authorization: Bearer <client_session>`. Logging out revokes the session.
- The build stores the M3SB values as XOR/Base64-obfuscated strings in the IPA. This is obfuscation, **not encryption or secure secret storage**; a determined user can recover the values from the app. This mode is used because the VPS-origin M3SB request currently receives HTTP 403, while the legacy iOS request worked.

## Credentials

Keep values out of source files and chat. Configure the same `M3SB_PACKAGE_TOKEN` and `M3SB_HMAC_SECRET` as GitHub Actions repository secrets for building, and as `VESPERDASH_M3SB_PACKAGE_TOKEN` and `VESPERDASH_M3SB_HMAC_SECRET` in the root-owned `/etc/vesperdash.env` for provider-response verification by the VPS. Also configure:

- `VESPERDASH_M3SB_API_BASE_URL` — HTTPS M3SB API base URL.
- `VESPERDASH_PACKAGE_PASSWORDS` — JSON array of `.3105` package passwords.
- `VESPERDASH_DATA=/opt/vesperdash/data` — persistent database and uploaded files.

Earlier IPA artifacts contained these credentials. Rotation is recommended because deleting an artifact cannot invalidate values already copied from it. If retaining the old credentials, accept that they remain recoverable from an IPA.

## Deploying the server update

Server code changes are not deployed by the iOS build workflow. The normal mode asks for confirmation that both M3SB credentials were rotated:

```bash
curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh | sudo bash
```

If you intentionally keep the existing credentials, use the explicit code-update mode:

```bash
curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh | sudo bash -s -- --keep-current-m3sb-credentials
```

That mode preserves `/etc/vesperdash.env` and requires the exact confirmations `KEEP-EXPOSED-SECRETS` and `DEPLOY`. Both modes back up the current application, preserve `/opt/vesperdash/data`, run tests, restart the service and verify health plus protected routes. Secret values are never printed.

## Building the iOS IPA

GitHub Actions builds an unsigned Build 10 IPA on `main`. It requires the repository secrets `M3SB_PACKAGE_TOKEN` and `M3SB_HMAC_SECRET`; the build injects only their obfuscated representation and verifies that the plaintext values are absent from the app bundle. The executable receives 150 MB of dot padding and the IPA is compressed using ZIP level 9. The workflow reports the actual compressed size; it cannot guarantee an exact 2 MB because other app assets also contribute.

After a successful workflow, download `VESPER-Build-10-unsigned-ipa` and sign it using the usual process. The new client requires the VesperDash `/api/client/session/bridge` endpoint so it can obtain the short-lived download session after direct M3SB verification.

## API routes

- `GET /health` — service health.
- `POST /api/client/session` — server-side M3SB verification (retained as a server API path).
- `POST /api/client/session/bridge` — validate a signed M3SB result from iOS and issue a client session.
- `POST /api/client/session/logout` — revoke the authenticated client session.
- `GET /api/patches` and `GET /api/patches/:id/download` — require a valid client Bearer session.
- `GET /api/patches/:id/image`, `/api/settings`, and `/api/resellers` — public display metadata only.
- `POST /api/auth/login` and `/api/admin/*` — existing dashboard authentication and management.

Run server tests locally with:

```bash
python3 -m unittest discover -s vesperdash -v
```
