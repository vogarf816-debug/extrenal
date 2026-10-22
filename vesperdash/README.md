# VesperDash

Flask API and private operations dashboard for the VESPER iOS client. Uploaded patch files, database state and runtime secrets are stored outside the replaceable application directory.

## License verification and client sessions

- The iOS app sends only its license key and a device identifier to `POST /api/client/session`.
- VesperDash calls M3SB server-to-server using `VESPERDASH_M3SB_API_BASE_URL`, `VESPERDASH_M3SB_PACKAGE_TOKEN` and `VESPERDASH_M3SB_HMAC_SECRET` from `/etc/vesperdash.env`.
- The server verifies the signed provider result, its timestamp, the license identity and the device identity before issuing a short-lived client session. Only a digest of that session token is stored in SQLite.
- The old `POST /api/client/session/bridge` endpoint, which accepted a provider response from the app, is disabled.
- Patch manifests, package passwords and `.3105` downloads require `Authorization: Bearer <client_session>`. Logout revokes the session.
- M3SB secrets are never passed to the iOS build or embedded in its Info.plist. GitHub Actions builds the app without M3SB repository secrets.

The VesperDash hostname is lightly obfuscated in the client to avoid casual string searches, but it is not a secret: an API hostname required by an installed app can be recovered through network inspection or reverse engineering. Security is enforced by server-side license checks and authenticated routes, not by hiding a public hostname. Previously shipped IPA credentials must be rotated at the provider; deleting a release cannot revoke a copied secret.

## Runtime configuration

Keep secrets out of source files and chat. Configure these values in the root-owned `/etc/vesperdash.env` on the VPS:

- `VESPERDASH_M3SB_API_BASE_URL` — HTTPS M3SB API base URL.
- `VESPERDASH_M3SB_PACKAGE_TOKEN` — M3SB package token.
- `VESPERDASH_M3SB_HMAC_SECRET` — M3SB HMAC secret.
- `VESPERDASH_PACKAGE_PASSWORDS` — JSON array of `.3105` package passwords.
- `VESPERDASH_DATA=/opt/vesperdash/data` — persistent database and uploaded files.

Do not commit this file. Protect it from group/world reads and preserve a secure backup.

## One-command VPS update and new dashboard login

Run in an interactive VPS terminal as root:

```bash
curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh | sudo bash -s -- --new-admin
```

After confirming the M3SB credentials on the VPS were rotated, enter `ROTATED` and then `DEPLOY`. The script does not ask you to paste any token or password into chat. Following a successful update, it generates a new VESPER dashboard username/password, verifies the login locally, revokes existing VESPER admin sessions, disables the legacy admin token, and prints the new login once in the VPS terminal. Save the credentials and use the `Username` and `Password` fields in the Control Center. The separate Jefry account is unchanged.

The updater backs up the application and environment file, preserves `/opt/vesperdash/data`, runs the backend tests, restarts the service, and verifies health plus protected manifest/download behavior. It rolls back application files if health checks fail. The admin reset itself also restores the previous environment and restarts the service if its login check fails.

Do not confirm `ROTATED` if credentials previously embedded in an IPA are still active. Rotate them at M3SB and update the VPS environment file first.

## Dashboard

Control Center login uses the configured username and password. The legacy admin-token entry has been removed from the web UI; admin APIs remain protected by the authenticated session.

## Building the iOS IPA

GitHub Actions builds unsigned `VESPER-Build-35-unsigned.ipa` on pushes to `main` or by manual dispatch. Local macOS builds use the shared Xcode scheme `3105`:

```bash
./build_unsigned.sh
```

No M3SB values are needed in the iOS build environment. The workflow checks the release metadata, embedded resources, localization table, secure local package cache, and absence of raw M3SB credentials or upstream verification URLs in the app bundle. The executable currently receives 690 MB of padding, packages are fetched only when injected and stored in the encrypted local vault, and app-wide Files/Finder document sharing remains disabled. The output is unsigned and must be signed with the normal process before installation.

After a successful workflow, download `VESPER-Build-35-unsigned.ipa` from the GitHub release attached to that workflow.

## API routes

- `GET /health` — service health.
- `POST /api/client/session` — server-side M3SB verification and short-lived session issuance.
- `POST /api/client/session/logout` — revoke the authenticated client session.
- `GET /api/patches` and `GET /api/patches/:id/download` — require a valid client Bearer session.
- `GET /api/patches/:id/image`, `/api/settings`, and `/api/resellers` — public display metadata only.
- `POST /api/auth/login` and `/api/admin/*` — authenticated dashboard access and management.

Run tests locally with:

```bash
python3 -m unittest discover -s vesperdash -v
```
