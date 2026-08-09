<<<<<<< HEAD
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
=======
# AGENTS.md — Vamp Terminal

This file is the operational contract for AI agents working with Vamp Terminal.

## Product

Vamp Terminal is an open-source terminal workspace that reuses the signed host,
pairing, trust, Tailscale, and authenticated WebRTC stack in this repository.

| Component | Value |
| --- | --- |
| Full host | `Vamp Host` — remote display, input, and optional Terminal Mode |
| Light host | `Vamp Terminal Host` — terminal and Safari control only |
| iOS/iPadOS client | `Vamp Terminal` — eight concurrent terminal tabs |
| Linux companion | `Vamp Terminal Linux Host` — dependency-free browser host |
| Full host bundle ID | `com.mesutcy.remotedesktop.host` |
| Light host bundle ID | `com.mesutcy.remotedesktop.terminalhost` |
| iOS bundle ID | `com.mesutcy.remotedesktop.terminal` |
| Project | `RemoteDesktopToolApps.xcodeproj` |
| Full host scheme | `MacHost` |
| Light host scheme | `VampTerminalHost` |
| iOS scheme | `VampTerminalApp` |
| Bonjour service | `_screenharbor._tcp` (wire-compatibility contract only) |
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
| Signaling ports | `9471` plain, `9473` TLS |
| Data port | `9472` |
| Browser control | loopback `9475`, exposed privately with Tailscale Serve |
| URL scheme | `vamphost://action/{start,stop,restart}` |
| License | Apache-2.0 |

The iOS build is an unsigned device IPA for AltStore-style re-signing. No
project-owned Apple team, certificate, provisioning profile, App Store Connect
account, hosted relay, or public port forwarding is required.

## Build

```bash
swift test

<<<<<<< HEAD
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
=======
xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme MacHost \
  -configuration Release CODE_SIGNING_ALLOWED=NO build

xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme VampTerminalHost \
  -configuration Release CODE_SIGNING_ALLOWED=NO build

xcodebuild -project RemoteDesktopToolApps.xcodeproj -scheme VampTerminalApp \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
```

Package an AltStore-ready IPA with:

```bash
scripts/package-vamp-terminal-ios.sh --clean --allow-dirty
```

Do not add a hard-coded Apple team or private credential to the public project.

## Agent CLI

<<<<<<< HEAD
After the host app is installed, the CLI lives at:

```text
/Applications/MacPair Host.app/Contents/Resources/screenharbor
```

Its optional PATH symlink is `/usr/local/bin/screenharbor`.
=======
The repository includes the `vamp` wrapper. After installing Vamp Host, agents
can use:
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

```bash
vamp ensure
vamp status --json
vamp pending --json
vamp approve-pairing --fingerprint <verified-hex>
vamp terminal list
vamp terminal start --session work
vamp terminal attach work
vamp terminal agent codex --session codex
vamp browser serve
```

The CLI exits with `0` for success, `1` when the host is not installed, `2` when
it is installed but not advertising, `3` when human permissions are required,
`4` for invalid usage, `5` when no trust request is pending, `6` when a trust
action did not resolve, `7` for a fingerprint mismatch, and `8` on timeout.

## Non-negotiable safety

- Never approve a pairing or connection request merely because it exists.
- Show the user the pending device name and fingerprint and require an exact,
  independently verified fingerprint before approving.
- Never bypass Screen Recording or Accessibility consent. These permissions are
  granted by the user in System Settings for Vamp Host only.
- Never expose host or browser ports directly to the public internet. Use a
  trusted LAN or private Tailscale network.
- Do not commit private keys, certificates, provisioning profiles, API
  credentials, pairing secrets, or real user logs.
- Terminal-only mode must reject display, pointer, keyboard, microphone, and
  file-transfer commands.

## Source map

- `Sources/HostApp`: full host, light host mode, terminal PTY service, and Safari control
- `Sources/ClientiOS`: shared connection services and the Vamp Terminal client
- `Sources/SharedProtocol`: versioned wire messages and terminal routing
- `Sources/SharedModels`: capability metadata and shared session models
- `Sources/TransportWebRTC`: signed signaling and data transport
- `Sources/Permissions`: host permission and distribution policy
- `linux-host`: dependency-free Safari/WebSocket host
- `scripts/vamp`: agent CLI wrapper
- `scripts/package-vamp-terminal-ios.sh`: unsigned iOS packaging
- `docs/index.html`: GitHub Pages product site

## Verification

For protocol, trust, terminal routing, or PTY changes, run `swift test` and the
Linux host tests. Build all three active Xcode schemes after shared-source
changes. Verify the IPA checksum and manifest before sideloading.

Never weaken pairing approval, replay protection, session-ID validation, or
terminal-ID validation for convenience.
