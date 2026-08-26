# Vamp install reference

The current public lineup is [Vamp Assistant](https://thevamp.app/assistant/)
and [Vamp Stream](https://thevamp.app/stream/). Download links on those pages
resolve independently to the latest release for each platform.

## Vamp Assistant

1. Download the current macOS DMG and `.sha256` from the Assistant page.
2. Verify the checksum with `shasum -a 256 -c <download>.sha256`.
3. Drag Vamp Assistant to `/Applications`, then Control-click **Open**. If
   needed, use **System Settings → Privacy & Security → Open Anyway**. Never
   disable Gatekeeper globally.
4. Choose a local MLX/GGUF model or add your own provider key. Provider secrets
   are stored in Keychain.
5. To use iPhone, iPad, or a browser, enable Remote Sessions in the Mac app and
   pair only after comparing the code or device identity on both sides.

The Assistant iOS IPA is unsigned. Re-sign it with AltStore, SideStore,
Sideloadly, or your own provisioning profile. The project does not distribute
Apple credentials, certificates, or provisioning profiles.

## Vamp Stream

1. Download `VampStream-iOS-…-altstore-unsigned.ipa` and its checksum from the
   Stream page.
2. Verify the checksum, import the IPA into your sideloading tool, and allow
   Local Network access when iOS asks.
3. Choose one Mac side:

   - **Vamp Sync** — the focused menu-bar companion designed for Stream.
   - **Vamp Host** — the full signed-WebRTC host.
   - **Vamp Assistant** — its authenticated private Remote Sessions endpoint.

4. On the Mac, grant **Screen Recording** for video. Grant
   **Accessibility** only when keyboard or pointer control is required.
5. Compare the displayed pairing identity before approving the iPhone or iPad.

Vamp Host and Vamp Sync share host ports and cannot run together.
Vamp Sync uses its own identity and trust store, so an approval in Vamp Host
does not carry over. Keep every host on a trusted LAN or private Tailscale
network and never expose its ports publicly.

## Build Stream from source

Requirements: macOS, Xcode 26 or later, XcodeGen, and the checked-in build
inputs under `Configuration/`.

```sh
scripts/package-vamp-stream-ios.sh --clean
scripts/package-vamp-mini-host.sh --clean
```

Release packaging requires a clean Git tree. For a local development artifact,
add `--allow-dirty`. The scripts write checksummed artifacts under
`dist/VampStream/` and `dist/VampStreamHost/`.

The implementation target and bundle identity retain the technical names
`VampMiniHost` and `com.mesutcy.remotedesktop.minhost` for compatibility; the
public product and artifact name is **Vamp Sync**.

## Optional supporting-host watchdog

A source checkout can install a per-user watchdog for the full Vamp Host:

```sh
scripts/install-vamp-host-watchdog.sh
```

The host writes a main-run-loop heartbeat every five seconds. The watchdog
relaunches the app after a crash and restarts it when that heartbeat is stale
for more than 20 seconds. It does not approve connections, change macOS privacy
permissions, or open network ports. Choosing **Quit** pauses recovery for one
minute so the app stays closed while you finish an update or maintenance task;
opening Vamp Host resumes it immediately, and an abandoned pause expires on its
own.

Remove only the watchdog with:

```sh
scripts/install-vamp-host-watchdog.sh --uninstall
```

Specialist Terminal and Linux source and documentation remain in the
repository but are intentionally excluded from this public install guide.
