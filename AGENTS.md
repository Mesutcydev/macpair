# AGENTS.md — ScreenHarbor

This file is the operational contract for AI agents working with ScreenHarbor.

## Product

ScreenHarbor is an open-source native macOS remote desktop pair:

| Component | Value |
| --- | --- |
| Host app | `ScreenHarbor Host` |
| Client app | `ScreenHarbor` |
| Host bundle ID | `uk.mesut.screenharbor.host` |
| Client bundle ID | `uk.mesut.screenharbor.client` |
| Project | `ScreenHarbor.xcodeproj` |
| Host scheme | `ScreenHarborHost` |
| Client scheme | `ScreenHarborClient` |
| Bonjour service | `_screenharbor._tcp` |
| Signaling ports | `9471` plain, `9473` TLS |
| Data port | `9472` |
| URL scheme | `screenharbor://action/{start,stop,restart}` |
| License | Apache-2.0 |

The public website build is ad-hoc signed. It intentionally requires no Apple team, certificate, provisioning profile, App Store Connect account, or notarization service.

## Build

```bash
xcodegen generate --spec screenharbor-project.yml

xcodebuild -project ScreenHarbor.xcodeproj \
  -scheme ScreenHarborHost -configuration Release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

xcodebuild -project ScreenHarbor.xcodeproj \
  -scheme ScreenHarborClient -configuration Release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Package both website artifacts with:

```bash
scripts/package-screenharbor.sh all --format both --clean
```

Do not add a hard-coded Apple team or private credential to the public project.

## Agent CLI

After the host app is installed, the CLI lives at:

```text
/Applications/ScreenHarbor Host.app/Contents/Resources/screenharbor
```

Its optional PATH symlink is `/usr/local/bin/screenharbor`.

```bash
screenharbor ensure
screenharbor status --json
screenharbor pending --json
screenharbor approve-pairing --fingerprint <verified-hex>
```

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Success / host ready |
| 1 | App not installed |
| 2 | Installed but not advertising |
| 3 | Human permissions required |
| 4 | Bad command or usage |
| 5 | No pending trust request |
| 6 | Trust action did not resolve the request |
| 7 | Fingerprint mismatch |
| 8 | Wait timed out |

## Non-negotiable safety

- Never approve a pairing or connection request merely because it exists.
- Read `pendingPairingRequest`, show its device name and fingerprint to the user, and use `--fingerprint` with an exact independently verified value.
- Never bypass Screen Recording or Accessibility consent. The user must grant these in System Settings.
- Never expose the host ports directly to the public internet. Use a trusted LAN or private VPN.
- Do not commit private keys, `.p8`, `.p12`, certificates, API credentials, pairing secrets, or real user logs.

## Source map

- `Sources/HostApp`: host app UI and runtime coordination
- `MacClient/Sources`: native Mac client UI
- `Sources/Discovery`: Bonjour discovery and signaling
- `Sources/TransportWebRTC`: media/data transport
- `Sources/SharedProtocol`: versioned wire messages and Opus integration
- `Sources/Permissions`: permission and distribution policy
- `ScreenHarbor/Resources`: public app identities, entitlements, and icon
- `scripts/screenharbor`: agent CLI
- `scripts/package-screenharbor.sh`: account-independent website packaging
- `scripts/publish-screenharbor.sh`: Sparkle-sign and stage website releases
- `docs/AGENT_INTEGRATION.md`: agent usage contract

## Verification

For networking, trust, path handling, or protocol changes, run the relevant tests in `Tests/RemoteDesktopToolTests`. Verify both host and client schemes after shared-source changes.

For release artifacts, verify:

```bash
codesign --verify --deep --strict "<app>"
spctl --assess --type execute --verbose=4 "<app>" || true
shasum -a 256 "<artifact>"
```

`spctl` rejection is expected for the account-independent, non-notarized build. A successful `codesign --verify` confirms structural integrity, not Apple trust.
