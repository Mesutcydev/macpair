# Install Vamp on iPhone or iPad

Choose **Control or Stream** to reach a Mac running Sync. **Assistant for iOS**
is a separate companion for the Assistant Mac app. You do not need all three.

All public IPAs are unsigned and need AltStore-style re-signing with your own
Apple ID/team.

## Install

1. Get the latest IPA and its checksum:

   - [Vamp Control](https://thevamp.app/#download-control-ios)
   - [Vamp Stream](https://thevamp.app/#download-stream-ios)
   - [Vamp Assistant](https://thevamp.app/assistant/#download)

2. Run `shasum -a 256 Name-of-download.ipa` and compare the complete hash with
   the downloaded `.sha256` file.
3. Import the IPA into AltStore, SideStore, Sideloadly, or your own signing
   workflow. Let that tool sign with an Apple ID/team you control.
4. Allow Local Network access when requested.
5. Connect over a trusted LAN or private Tailscale network. Pair only with a
   Mac you own or are authorized to control. For Sync, compare the complete
   device fingerprint on both devices before approval on the Mac.

The [AltStore source](https://thevamp.app/apps.json) includes Stream and
Assistant, alongside Boo Player. Control is currently a direct IPA download.

## Which Mac app do I need?

| iOS app | Mac app | What you use remotely |
| --- | --- | --- |
| Control | Sync | A selected Mac app window |
| Stream | Sync | A selected Mac app window, with a focused mobile interface |
| Assistant | Assistant with Remote Sessions enabled | AI chats, Code sessions, tools, and Mac control |

Stream can also pair directly with Assistant’s Remote Sessions for an app
window or full display. This is optional and uses a separate pairing.

Screen Recording is required on the Mac for video. Accessibility is required
for keyboard and pointer control. Run only one macOS host at a time and keep
host ports private.

Stream and Assistant require iOS/iPadOS 18 or later. Website downloads resolve
each app and platform independently, including releases in separate tags.

## Build Stream locally

```sh
scripts/package-vamp-stream-ios.sh --clean
```

For a local artifact from a dirty tree, add `--allow-dirty`. The script generates
the project from `vampstream-project.yml`, checks the device executable, and
writes the unsigned IPA and checksum to `dist/VampStream/`.

The project provides no signing credentials or provisioning profiles. Older
builds and specialist terminal instructions remain in release history and
their technical guides.
