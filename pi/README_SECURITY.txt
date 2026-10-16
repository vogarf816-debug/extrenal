M3SB package tokens and HMAC secrets are server credentials. Never commit real values, embed them in an IPA, or distribute a real M3SB_API_Config.json file.

For the Vesper app, license verification and patch-package authorization must run through the VesperDash server. Keep real M3SB credentials only in the server environment (for example, /etc/vesperdash.env with mode 0600); do not place them in client Info.plist files or GitHub build variables that are injected into an app.

The previously tracked configuration was exposed in repository history and prior IPA builds. Treat its credentials as compromised, revoke/rotate them with the M3SB provider, and remove the old values from Git history before considering the exposure remediated. Never send replacement secrets in chat.
