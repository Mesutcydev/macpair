<<<<<<< HEAD
# MacPair

<p align="center">
  <a href="https://mesut.uk/apps/macpair">
    <img src="https://raw.githubusercontent.com/Mesutcydev/macpair/main/ScreenHarbor/Resources/ClientAssets.xcassets/AppIcon.appiconset/icon_1024.png" alt="MacPair logo" width="160">
  </a>
</p>

**MacPair is an open-source, native Mac remote desktop for macOS, iOS, and iPadOS.** It pairs a lightweight Mac host with Mac and iPhone/iPad clients for low-latency screen sharing, keyboard and pointer control, clipboard sync, file transfer, audio, and an opt-in remote terminal.

The project is local-first. Discovery uses Bonjour on your LAN, peer identities are signed, and every new client must be visibly approved on the host. For access beyond the local network, use a private network you control, such as Tailscale; MacPair does not require a hosted relay or account.
=======
# Vamp Terminal

**Vamp Terminal is an open-source terminal workspace for iPhone, iPad, Safari, macOS, and Linux.** It gives users readable multi-tab PTYs, clipboard exchange, tmux/screen handoff, and safe access to coding agents from anywhere on a private Tailscale network.

Vamp Terminal can use either the complete Vamp Host or the focused terminal-only host. Discovery uses Bonjour on the LAN, peer identities are signed, and every new client must be visibly approved on the host. Remote access stays private: there is no hosted relay, public port forwarding, account backend, or vendor-controlled session persistence.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

## Apps

| App | Purpose | Bundle ID |
| --- | --- | --- |
<<<<<<< HEAD
| MacPair Host | Runs on the Mac being controlled | `uk.mesut.screenharbor.host` |
| MacPair for Mac | Connects to an approved host | `uk.mesut.screenharbor.client` |
| MacPair for iOS | Sideloadable iPhone/iPad client | `uk.mesut.screenharbor.ios` |
=======
| Vamp Host | Full macOS host with remote clients and optional terminal mode | `com.mesutcy.remotedesktop.host` |
| Vamp Terminal Host | Light macOS host with only terminal/Safari control | `com.mesutcy.remotedesktop.terminalhost` |
| Vamp Terminal | Terminal-only iPhone/iPad client with multi-tab PTYs | `com.mesutcy.remotedesktop.terminal` |
| Vamp Terminal Linux Host | Dependency-free Python browser host | local process |
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

The iOS app is distributed as an unsigned IPA for AltStore-style re-signing. The
macOS and Linux hosts are built and run directly by the owner of the machine.

## Download and install

<<<<<<< HEAD
Download the [MacPair client](https://mesut.uk/apps/macpair) and
[MacPair Host](https://mesut.uk/apps/macpair-host) DMGs directly from the project website.
The unsigned iOS 18+ IPA and its checksum are available from the
[MacPair client page](https://mesut.uk/apps/macpair); read the
[sideloading guide](docs/IOS_SIDELOAD.md) before installing it.
=======
Use the [Vamp Terminal GitHub page](https://mesutcydev.github.io/macpair/) for
the current IPA, host guides, CLI command list, and Safari preview. Read the
[AltStore guide](docs/VAMP_TERMINAL_SIDELOAD.md) before installing the iOS build.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

The macOS hosts are local utilities, not App Store products. On first launch:

1. Drag the app to `/Applications`.
2. Control-click the app and choose **Open**, if that option is available.
3. Otherwise open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. For Vamp Host, grant **Screen Recording** and **Accessibility** in System Settings → Privacy & Security. Vamp Terminal Host does not request either permission.

Do not disable Gatekeeper globally.

## Build from source

Requirements: macOS 13 or later, Xcode 26 or later, and Python 3 for the Linux host.

```bash
xcodebuild \
<<<<<<< HEAD
  -project MacPair.xcodeproj \
  -scheme ScreenHarborHost \
=======
  -project RemoteDesktopToolApps.xcodeproj \
  -scheme MacHost \
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build the terminal-only macOS host by changing the scheme to `VampTerminalHost`.
Build the iPhone/iPad client with:

```bash
scripts/package-vamp-terminal-ios.sh --clean --allow-dirty
```

No Apple account, certificate, provisioning profile, or notarization credential is
required to build the unsigned IPA. AltStore or another sideloading tool must
re-sign it with the installing user's Apple ID/team.

Run the Linux host with:

```bash
scripts/vamp-linux-host --listen 127.0.0.1 --port 9475
```

## Agent and automation interface

The repository includes the `vamp` CLI wrapper for the full Vamp Host:

```bash
sudo ln -sf \
<<<<<<< HEAD
  "/Applications/MacPair Host.app/Contents/Resources/screenharbor" \
  /usr/local/bin/screenharbor
=======
  "$PWD/scripts/vamp" \
  /usr/local/bin/vamp
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
```

Useful commands:

```bash
vamp ensure
vamp status --json
vamp pending --json
vamp approve-pairing --fingerprint <verified-hex>
```

Agents must never approve an unknown pairing request. Present the device name and fingerprint to the user and require an exact fingerprint match. See [docs/AGENT_INTEGRATION.md](docs/AGENT_INTEGRATION.md) and [llms.txt](llms.txt).

## Network contract

- Bonjour: `_screenharbor._tcp` (the existing discovery contract retained for paired-client compatibility)
- Signaling: TCP `9471`
- Data: UDP/TCP `9472`
- TLS signaling: TCP `9473`
- URL actions: `vamphost://action/{start,stop,restart}`
- Agent status: `~/Library/Application Support/Vamp Host/host.widget.snapshot.json`

## Security

<<<<<<< HEAD
Only use MacPair on devices you own or are authorized to control. New peer identities require host approval, terminal access is opt-in, and the host can be stopped at any time.
=======
Only use Vamp on devices you own or are authorized to control. New peer identities require host approval, terminal access is opt-in on Vamp Host and always-on for Vamp Terminal Host, and the host can be stopped at any time.
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Contributing and license

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

<<<<<<< HEAD
MacPair is licensed under the [Apache License 2.0](LICENSE). Third-party
=======
Vamp Terminal is licensed under the [Apache License 2.0](LICENSE). Third-party
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Project governance, support,
release integrity, and name-use policies are documented in
[GOVERNANCE.md](GOVERNANCE.md), [SUPPORT.md](SUPPORT.md),
[docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md), and
[TRADEMARKS.md](TRADEMARKS.md). The
[open-source program readiness checklist](docs/PROGRAM_READINESS.md) records the
evidence to maintain as the project grows.

<<<<<<< HEAD
MacPair is an independent project. It is not affiliated with, endorsed by, or
=======
Vamp Terminal is an independent project. It is not affiliated with, endorsed by, or
>>>>>>> c989667 (Add Vamp Terminal multi-tab hosts)
sponsored by Apple Inc.
