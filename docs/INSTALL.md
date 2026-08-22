# Vamp install reference

This is the current install path for Vamp Suite 2.3.0 build 46. Downloads also
live on [thevamp.app](https://thevamp.app/#download). The project has six
installable surfaces plus Safari control built into the macOS hosts:

| Surface | Artifact | Use it for |
| --- | --- | --- |
| iPhone / iPad | `VampTerminal-iOS-2.3.0-build-46-altstore-unsigned.ipa` | Eight-tab terminal client and agent launchers |
| iPhone / iPad | `VampControl-iOS-2.3.0-build-46-altstore-unsigned.ipa` | Touch-first remote screen, Picture in Picture, remote Command-Tab, and smoother zoom |
| macOS | `VampControl-macOS-2.3.0-build-46-adhoc.zip` | Remote screen client with explicit remote Command-Tab control |
| macOS | `VampHost-macOS-2.3.0-build-46-adhoc.zip` | Full Vamp Host: remote clients, low-latency Apple Silicon streaming, watchdog support, and optional Terminal Mode |
| macOS | `VampTerminalHost-macOS-2.3.0-build-46-adhoc.zip` | Always-on terminal host with Safari control. Do not run beside Vamp Host |
| Linux | `VampTerminalHost-Linux-2.3.6.zip` | Browser-only host. Vamp Control and Vamp Terminal cannot attach |
| Safari | none — use the Mac host dashboard | Eight tabs on loopback `9475`, Tailscale Serve, or Cloudflare Access |

The current downloads are in the [latest Vamp Suite GitHub release](https://github.com/Mesutcydev/macpair/releases/latest).

## 1. Install the iPhone or iPad client

1. Download the [latest Vamp Terminal IPA](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminal-iOS-2.3.0-build-46-altstore-unsigned.ipa) and its `.sha256` file from the same release.
2. Verify the download:

   ```sh
   shasum -a 256 -c VampTerminal-iOS-2.3.0-build-46-altstore-unsigned.ipa.sha256
   ```

3. Import the IPA in AltStore with **+ → Sideload IPA**.
4. Allow Local Network access when Vamp Terminal asks.
5. Pair with a running Vamp Host or Vamp Terminal Host and approve the request
   on the Mac.

The iOS apps are unsigned IPAs for AltStore-style re-signing. AltStore signs
each IPA with the Apple ID/team on the installing device. No project certificate
or provisioning profile is distributed. Vamp Control's in-session Terminal Mode
overlay is emergency-only; sideload Vamp Terminal for eight tabs and agent
launchers.

## Remote-control client downloads

The current Vamp Control builds are attached to the [latest Vamp Suite release](https://github.com/Mesutcydev/macpair/releases/latest):

- [iOS IPA](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-iOS-2.3.0-build-46-altstore-unsigned.ipa) — unsigned; import with AltStore or another compatible sideloader.
- [iOS checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-iOS-2.3.0-build-46-altstore-unsigned.ipa.sha256)
- [macOS ZIP](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-macOS-2.3.0-build-46-adhoc.zip) — unzip and move Vamp Control to Applications.
- [macOS checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampControl-macOS-2.3.0-build-46-adhoc.zip.sha256)

## 2. Install a macOS host

Download one of the ad-hoc signed ZIPs and the matching `.sha256` file:

- [Vamp Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampHost-macOS-2.3.0-build-46-adhoc.zip) ([checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampHost-macOS-2.3.0-build-46-adhoc.zip.sha256)) for remote display, remote input, remote clients, and optional Terminal Mode.
- [Vamp Terminal Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminalHost-macOS-2.3.0-build-46-adhoc.zip) ([checksum](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminalHost-macOS-2.3.0-build-46-adhoc.zip.sha256)) for terminal tabs, Safari control, pairing, and Tailscale only.

Then:

1. Verify the download:

   ```sh
   shasum -a 256 -c VampHost-macOS-2.3.0-build-46-adhoc.zip.sha256
   ```

2. Unzip the download.
3. Move the selected app to `/Applications`.
4. Control-click it and choose **Open** the first time. If macOS shows a
   security warning, use **System Settings → Privacy & Security → Open Anyway**.
5. Enable **Terminal Mode** in Vamp Host. It is always enabled in Vamp
   Terminal Host.
6. Approve the device pairing request in the host dashboard.

Only run one host at a time on a Mac because both use the same signed transport
port. The host dashboard shows the LAN and Tailscale addresses for Safari.

### Optional unattended-recovery watchdog

A source checkout can install a per-user watchdog for the full Vamp Host:

```sh
scripts/install-vamp-host-watchdog.sh
```

The host writes a main-run-loop heartbeat every five seconds. The watchdog
relaunches the app after a crash and restarts it when that heartbeat is stale
for more than 20 seconds. It does not approve connections, change macOS privacy
permissions, or open network ports. Choosing **Quit** intentionally pauses
recovery; opening Vamp Host again resumes it.

Remove only the watchdog with:

```sh
scripts/install-vamp-host-watchdog.sh --uninstall
```

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

The Linux host is a dependency-free Python browser host. It speaks WebSocket,
not the signed WebRTC stack, so Vamp Control and Vamp Terminal cannot attach.
Download and extract `VampTerminalHost-Linux-2.3.6.zip` from the same suite
release, then verify it and install it without root access:

```sh
shasum -a 256 -c VampTerminalHost-Linux-2.3.6.zip.sha256
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

Cloudflare Tunnel is also supported for a named tunnel whose ingress points to
`http://127.0.0.1:9475`. Protect the hostname with Cloudflare Access, then run
`cloudflared tunnel run vamp-terminal`. The Linux host uses HTTP/1.1 so the
terminal WebSocket survives the reverse-proxy upgrade. Do not use an
unauthenticated quick tunnel or expose port `9475` directly.

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
