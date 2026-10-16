# VesperDash

Flask patch server used by the VESPER iOS app. It stores `.3105` packages and serves the public patch manifest and downloads. The dashboard remains protected by its existing admin/session credentials.

## Legacy public API behavior

The VESPER client has been returned to the legacy license/API flow at the owner's request. **Anyone who can reach the API can list enabled patches and download their `.3105` files.** To keep packages re-encrypted with the current passwords usable by the restored client, `GET /api/patches` also returns the configured `VESPERDASH_PACKAGE_PASSWORDS` list for the default `vesper` tenant. This intentionally makes those package passwords public too. Do not deploy this mode if that exposure is not acceptable.

License activation is performed directly by the iOS app using its M3SB configuration. Build secrets are supplied to GitHub Actions; do not paste them into chat or commit them as plain text.

## One-command VPS deployment

After the required package-password JSON is already present in `/etc/vesperdash.env`, run this from the VPS's interactive terminal as root:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/vogarf816-debug/extrenal/main/vesperdash/deploy_from_vps.sh)"
```

The script asks you to type `PUBLIC` to acknowledge that the manifest, package files, and package passwords are public, then `DEPLOY` to proceed. It:

- validates the existing `VESPERDASH_PACKAGE_PASSWORDS` without printing values;
- backs up `/opt/vesperdash/app` under `/opt/vesperdash/backups/`;
- leaves `/opt/vesperdash/data` and `/etc/vesperdash.env` unchanged;
- runs the legacy API tests, swaps the server code, restarts systemd, and waits up to 120 seconds for readiness;
- checks that the manifest is public, includes package passwords, and the download route does not demand a client session; and
- restores the previous app if deployment or health checks fail.

Do not run the command with `bash -c` from a non-interactive process: the script needs the VPS terminal for its two acknowledgements.

## Build the iOS IPA

The GitHub Actions workflow `.github/workflows/build.yml` builds the unsigned IPA on `main`. It requires these **repository Actions secrets**:

- `M3SB_PACKAGE_TOKEN`
- `M3SB_HMAC_SECRET`

Open **GitHub → vogarf816-debug/extrenal → Settings → Secrets and variables → Actions** and add/update them there. The values must be the working M3SB credentials used by the pre-security app version. Download the artifact named `HYper-Regedit-Key-Enabled-unsigned-ipa` after the workflow succeeds.

The app presents the license gate before the main interface; the activation screen has a Contact button linking to `https://t.me/YAGAMIxIOS`.

## API

- `GET /health` — service health.
- `GET /api/patches` — public enabled manifest for the requested tenant (default: `vesper`); in legacy mode, the Vesper response includes package passwords.
- `GET /api/patches/:id/download` — public download for an enabled patch.
- `GET /api/patches/:id/image` — public image for an enabled patch.
- `POST /api/auth/login` and the `/api/admin/*` endpoints — dashboard login and management.

Set `VESPERDASH_DATA=/opt/vesperdash/data` in the systemd service to keep database and uploaded files outside the replaceable application directory. Keep the admin credentials in the root-owned `/etc/vesperdash.env` file.
