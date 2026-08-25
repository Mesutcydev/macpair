# Sideload Vamp Stream and Vamp Terminal

Vamp Stream is the focused app-streaming iPhone/iPad client. Vamp Terminal is
the terminal-only client. Both are unsigned IPAs intended for AltStore-style
re-signing and both connect to the signed Vamp Host stack according to their
advertised capabilities.

## Install

1. Download either `VampStream-iOS-…-altstore-unsigned.ipa` or
   `VampTerminal-iOS-…-altstore-unsigned.ipa`, together with its checksum, from
   the project page or GitHub release.
2. Verify the checksum, import the IPA into AltStore, and let AltStore sign it
   with an Apple ID/team you control.
3. On first launch, allow Local Network access so the selected app can discover
   Vamp Host, Vamp Mini Host, or the compatible private Vamp Assistant path.

The project does not provide certificates, provisioning profiles, signing
credentials, or a way to bypass Apple's code-signing requirements. Signing and
renewal behavior depends on the account and sideloading tool you choose.

## Build the IPA from source

Requirements: macOS and Xcode 26 or later.

```bash
scripts/package-vamp-terminal-ios.sh --clean
# Or the focused app-streaming client:
scripts/package-vamp-stream-ios.sh --clean
```

Release packaging requires a clean Git tree. For a local development artifact,
add `--allow-dirty`.

The script verifies the bundle ID, display name, device architecture, Bonjour
service, absence of a provisioning profile, and absence of an existing signature
before writing the IPA, checksum, manifest, and CycloneDX SBOM to `dist/`.

## Vamp Stream compatibility

- Client: Vamp Stream 0.1.0 or later
- Minimum OS: iOS/iPadOS 18
- Hosts: Vamp Host or Vamp Mini Host for app streaming; Vamp Assistant for its
  separate full-screen control surface
- Discovery: `_screenharbor._tcp` compatibility contract
- Bundle ID before re-signing: `com.mesutcydev.remotedesktop.stream`

Vamp Assistant keeps its existing internal wire compatibility while using the
user-facing product name “Vamp Assistant”. Its private control surface uses port
9575 and may run alongside one of the shared-port host runtimes. Do not run
Vamp Host and Vamp Mini Host together on the same Mac.

## Vamp Terminal compatibility

- Client: Vamp Terminal 1.0.0 or later
- Minimum OS: iOS/iPadOS 18
- Hosts: Vamp Host or Vamp Terminal Host
- Discovery: `_screenharbor._tcp` compatibility contract
- Bundle ID before re-signing: `com.mesutcy.remotedesktop.terminal`

Only connect to Macs you own or are authorized to control. Every new client
still requires explicit approval in the selected Vamp host.
