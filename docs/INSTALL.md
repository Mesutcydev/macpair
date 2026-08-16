# Vamp Terminal install reference

This is the current install path for the Vamp Suite 2.1 host line. The project has
four separate install surfaces:

| Surface | Artifact | Use it for |
| --- | --- | --- |
| iPhone / iPad | `VampTerminal-iOS-2.3.0-build-41-altstore-unsigned.ipa` | Multi-tab terminal client |
| iPhone / iPad | `VampControl-iOS-2.3.0-build-41-altstore-unsigned.ipa` | Vamp Host remote-control client |
| macOS | `VampControl-macOS-2.3.0-build-41-adhoc.zip` | Vamp Host remote-control client |
| macOS | `VampHost-macOS-2.3.0-build-41-adhoc.zip` | Full Vamp Host: remote clients plus optional Terminal Mode |
| macOS | `VampTerminalHost-macOS-2.3.0-build-41-adhoc.zip` | Terminal-only host with Safari control and Tailscale |
| Linux | `linux-host/vamp_terminal_host.py` | Browser-only terminal host |

The current downloads are in the [latest Vamp Suite GitHub release](https://github.com/Mesutcydev/macpair/releases/latest).

## 1. Install the iPhone or iPad client

1. Download the [latest Vamp Terminal IPA](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminal-iOS-2.3.0-build-41-altstore-unsigned.ipa) and its `.sha256` file from the same release.
2. Verify the download:

   ```sh
   shasum -a 256 -c VampTerminal-iOS-2.3.0-build-41-altstore-unsigned.ipa.sha256
   ```

3. Import the IPA in AltStore with **+ → Sideload IPA**.
4. Allow Local Network access when Vamp Terminal asks.
5. Pair with a running Vamp Host or Vamp Terminal Host and approve the request
   on the Mac.

The IPA is intentionally unsigned. AltStore signs it with the Apple ID/team
configured on the installing device. No project certificate or provisioning
profile is distributed.

## Remote-control client downloads

The current Vamp Control builds are attached to the [latest Vamp Suite release](https://github.com/Mesutcydev/macpair/releases/latest):

- [iOS IPA](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-iOS-2.3.0-build-41-altstore-unsigned.ipa) — unsigned; import with AltStore or another compatible sideloader.
- [iOS checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-iOS-2.3.0-build-41-altstore-unsigned.ipa.sha256)
- [macOS ZIP](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-macOS-2.3.0-build-41-adhoc.zip) — unzip and move Vamp Control to Applications.
- [macOS checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-macOS-2.3.0-build-41-adhoc.zip.sha256)

## 2. Install a macOS host

Download one of the ad-hoc signed ZIPs:

- [Vamp Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampHost-macOS-2.3.0-build-41-adhoc.zip) for remote display, remote input, remote clients, and optional Terminal Mode.
- [Vamp Terminal Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminalHost-macOS-2.3.0-build-41-adhoc.zip) for terminal tabs, Safari control, pairing, and Tailscale only.

Then:

1. Unzip the download.
2. Move the selected app to `/Applications`.
3. Control-click it and choose **Open** the first time. If macOS shows a
   security warning, use **System Settings → Privacy & Security → Open Anyway**.
4. Enable **Terminal Mode** in Vamp Host. It is always enabled in Vamp
   Terminal Host.
5. Approve the device pairing request in the host dashboard.

Only run one host at a time on a Mac because both use the same signed transport
port. The host dashboard shows the LAN and Tailscale addresses for Safari.

## 3. Use Safari without the iOS app

1. Open the host dashboard and enable Terminal Mode.
2. Open **Safari control** and use the displayed QR code or direct Tailscale
   address.
3. From an iPhone or iPad, use the host's `http://100.x.y.z:9475/` address or
   its HTTPS Tailscale Serve address. Do not use `127.0.0.1`; on a phone that
   points back to the phone itself.
4. Enter the current six-digit pairing code and approve the browser on the
   Mac.

The browser workspace supports up to eight terminal tabs. Long-running work
should use tmux or screen so it can be reattached after a browser connection
ends.

## 4. Run the Linux host

The Linux host is a dependency-free Python browser host. Download and extract
the latest archive, then install it without root access:

```sh
./install.sh
vamp-terminal-host
```

To build the archive locally:

```sh
scripts/package-vamp-linux-host.sh
```

For a source checkout, it can also be run directly:

```sh
scripts/vamp-linux-host --listen 127.0.0.1 --port 9475
```

Keep it on loopback. If remote Safari access is needed, expose that loopback
listener through Tailscale Serve:

```sh
tailscale serve --bg http://127.0.0.1:9475
```

See [`linux-host/README.md`](../linux-host/README.md) for the Linux-specific
requirements, user-level systemd service, and pairing flow. Pairing codes are
single-use; after a successful pair the host prints the replacement code.

## 5. Build the current artifacts

Run these commands from the repository root on macOS with Xcode installed:

```sh
scripts/package-vamp-terminal-ios.sh --clean
scripts/package-vamp-hosts.sh --clean
scripts/package-vamp-linux-host.sh
```

The active project is `RemoteDesktopToolApps.xcodeproj`. The generated files
are placed under:

```text
dist/VampTerminal/
dist/VampTerminalHosts/
```

The build scripts also create SHA-256 checksums, JSON manifests, and CycloneDX
SBOMs. Do not use the retired `screenharbor-project.yml`,
`package-screenharbor.sh`, or DMG instructions for Vamp Terminal releases.
