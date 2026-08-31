# Sideload Vamp Assistant and Vamp Stream

Both public iPhone/iPad apps are unsigned IPAs intended for AltStore-style
re-signing. They are separate clients with separate Mac-side connection paths.

Add `https://thevamp.app/apps.json` as an AltStore source to keep both Vamp
Assistant and Vamp Stream on their current public builds.

## Install

1. Download the IPA and its `.sha256` file:

   - Vamp Assistant iOS: [Assistant downloads](https://thevamp.app/assistant/#download)
   - Vamp Stream: [Stream downloads](https://thevamp.app/stream/#download)

2. Verify the download:

   ```sh
   shasum -a 256 -c Name-of-download.ipa.sha256
   ```

3. Import the IPA into AltStore, SideStore, Sideloadly, or your own signing
   workflow. Let that tool sign with an Apple ID/team you control.
4. Allow Local Network access when requested.
5. Pair only with a Mac you own or are authorized to control, and compare the
   displayed identity before approval.

The project does not provide certificates, provisioning profiles, signing
credentials, or a way to bypass Apple’s signing requirements.

## Vamp Assistant compatibility

- Minimum OS: iOS/iPadOS 18
- Mac side: Vamp Assistant with Remote Sessions enabled
- Features: chats, Code sessions, bots, approvals/questions, terminal,
  clipboard/files, full-display control, and app-window control
- Transport: authenticated private Assistant Remote Sessions endpoint

Assistant macOS and iOS releases use separate tags. The website resolves each
platform independently instead of assuming the latest Mac release also carries
the latest IPA.

## Vamp Stream compatibility

- Client: Vamp Stream 0.1.0 or later
- Minimum OS: iOS/iPadOS 18
- Bundle ID before re-signing: `com.mesutcy.remotedesktop.stream`
- Mac sides:

  - Vamp Host — signed WebRTC
  - Vamp Sync — signed WebRTC; implementation target `VampMiniHost`
  - Vamp Assistant — authenticated private Remote Sessions endpoint

Screen Recording is required on the selected Mac host for video.
Accessibility is required for keyboard and pointer control. Vamp Host and Vamp
Vamp Sync and Vamp Host share ports, have separate identities/trust stores, and cannot run
together.

## Build Vamp Stream locally

```sh
scripts/package-vamp-stream-ios.sh --clean
```

For a local artifact from a dirty tree, add `--allow-dirty`. The script
regenerates the standalone project from `vampstream-project.yml`, verifies the
bundle and arm64 device executable, confirms the app is unsigned, then writes
the IPA and checksum to `dist/VampStream/`.

Technical sideload documentation for products outside the current promotion
remains in its specialist files and release history.
