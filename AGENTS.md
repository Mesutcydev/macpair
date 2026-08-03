# AGENTS.md — MacPair

This file is the operational contract for AI agents working with MacPair.

## Product

MacPair is an open-source native Mac remote desktop suite:

| Component | Value |
| --- | --- |
| Host app | `MacPair Host` |
| Client app | `MacPair` |
| Host bundle ID | `uk.mesut.screenharbor.host` |
| Client bundle ID | `uk.mesut.screenharbor.client` |
| iOS client bundle ID | `uk.mesut.screenharbor.ios` |
| Project | `MacPair.xcodeproj` |
| Host scheme | `ScreenHarborHost` |
| Client scheme | `ScreenHarborClient` |
| iOS client scheme | `ScreenHarborIOS` |
| Bonjour service | `_screenharbor._tcp` |
| Signaling ports | `9471` plain, `9473` TLS |
| Data port | `9472` |
| URL scheme | `screenharbor://action/{start,stop,restart}` |
| License | Apache-2.0 |

The public Mac builds are ad-hoc signed and the iOS IPA is unsigned for a sideload
tool to re-sign. They intentionally require no project-owned Apple team, certificate,
provisioning profile, App Store Connect account, or notarization service.

## Build

```bash
xcodegen generate --spec screenharbor-project.yml

xcodebuild -project MacPair.xcodeproj \
  -scheme ScreenHarborHost -configuration Release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

xcodebuild -project MacPair.xcodeproj \
  -scheme ScreenHarborClient -configuration Release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build

xcodebuild -project MacPair.xcodeproj \
  -scheme ScreenHarborIOS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
```

Package both website artifacts with:

```bash
scripts/package-screenharbor.sh all --format both --clean
scripts/package-screenharbor-ios.sh --clean
```

Do not add a hard-coded Apple team or private credential to the public project.

## Agent CLI

After the host app is installed, the CLI lives at:

```text
/Applications/MacPair Host.app/Contents/Resources/screenharbor
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
- `Sources/ClientiOS`: native iPhone/iPad client UI
- `Sources/Discovery`: Bonjour discovery and signaling
- `Sources/TransportWebRTC`: media/data transport
- `Sources/SharedProtocol`: versioned wire messages and Opus integration
- `Sources/Permissions`: permission and distribution policy
- `ScreenHarbor/Resources`: public app identities, entitlements, and icon
- `scripts/screenharbor`: agent CLI
- `scripts/package-screenharbor.sh`: account-independent website packaging
- `scripts/package-screenharbor-ios.sh`: unsigned iOS IPA packaging for user-controlled re-signing
- `scripts/publish-screenharbor.sh`: stage website release files and metadata
- `docs/AGENT_INTEGRATION.md`: agent usage contract

## Verification

For networking, trust, path handling, or protocol changes, run the relevant tests in `Tests/RemoteDesktopToolTests`. Verify the host, Mac client, and iOS client schemes after shared-source changes.

For release artifacts, verify:

```bash
codesign --verify --deep --strict "<app>"
spctl --assess --type execute --verbose=4 "<app>" || true
shasum -a 256 "<artifact>"
```

`spctl` rejection is expected for the account-independent, non-notarized build. A successful `codesign --verify` confirms structural integrity, not Apple trust.
