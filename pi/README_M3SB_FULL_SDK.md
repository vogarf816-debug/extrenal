# M3SB API SDK

## Contents

- `M3SBInAppGate.h` / `M3SBInAppGate.m`: license gate and verification UI.
- `M3SBV3TweakBridge.h` / `M3SBV3TweakBridge.m`: Signature v3 requests, Keychain Instance ID, response validation, and heartbeat.
- `APONLicenseSDK.swift`: Swift integration layer.
- `APONGate.m`: Objective-C integration layer.
- `M3SB_API_Config.example.json`: placeholder-only example. Create a real `M3SB_API_Config.json` locally from a protected secret store; never commit it.
- `M3SB_Target_Info.plist`: target Bundle ID and package metadata.

## Integration

Add the source files to the target and provision configuration locally. The Bundle ID in `M3SB_Target_Info.plist` must match the target application. Do not copy server credentials into a public IPA.

The SDK uses Signature v3, a Keychain-persistent Instance ID, device binding, license status checks, and a recurring heartbeat. The server remains authoritative for license validity, package status, device limits, expiry, and injection policy.

Keep real M3SB values out of Git and client bundles. The example files contain placeholders only. Credentials found in repository history or a distributed IPA must be treated as compromised and rotated with the provider.

## Package Policy

`Allow Inject` and `Block Inject` are controlled by the package settings on the server. When injection is blocked, the server enforces the configured maximum dylib count. Injection policy does not replace license validation.

## Requirements

- iOS 15 or later.
- Objective-C or Swift target integration.
- A valid package configuration generated for the target Bundle ID.
- Signature v3 enabled on the API server.
