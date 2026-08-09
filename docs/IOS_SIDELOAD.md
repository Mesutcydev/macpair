# Sideload Vamp Terminal

For the current Vamp Terminal IPA and AltStore workflow, use
[VAMP_TERMINAL_SIDELOAD.md](VAMP_TERMINAL_SIDELOAD.md). Vamp Terminal is the
terminal-only iPhone/iPad client; it connects to Vamp Host or Vamp Terminal Host.

## Install

1. Download the `VampTerminal-iOS-…-altstore-unsigned.ipa` file and its checksum
   from the project page or GitHub release.
2. Verify the checksum, import the IPA into AltStore, and let AltStore sign it
   with an Apple ID/team you control.
3. On first launch, allow Local Network access so Vamp Terminal can discover
   Vamp Host or Vamp Terminal Host.

The project does not provide certificates, provisioning profiles, signing
credentials, or a way to bypass Apple's code-signing requirements. Signing and
renewal behavior depends on the account and sideloading tool you choose.

## Build the IPA from source

Requirements: macOS and Xcode 26 or later.

```bash
scripts/package-vamp-terminal-ios.sh --clean
```

Release packaging requires a clean Git tree. For a local development artifact,
add `--allow-dirty`.

The script verifies the bundle ID, display name, device architecture, Bonjour
service, absence of a provisioning profile, and absence of an existing signature
before writing the IPA, checksum, manifest, and CycloneDX SBOM to `dist/`.

## Compatibility

- Client: Vamp Terminal 1.0.0 or later
- Minimum OS: iOS/iPadOS 18
- Hosts: Vamp Host or Vamp Terminal Host
- Discovery: `_screenharbor._tcp` compatibility contract
- Bundle ID before re-signing: `com.mesutcy.remotedesktop.terminal`

Only connect to Macs you own or are authorized to control. Every new client
still requires explicit approval in the selected Vamp host.
