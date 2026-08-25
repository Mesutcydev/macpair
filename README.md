# Vamp

**Vamp is an open-source, local-first remote desktop and terminal suite for Mac, iPhone, iPad, Safari, and Linux.** Connections use a trusted LAN or private Tailscale network. Every new device needs visible host approval. There is no product account and no hosted relay.

Four kits share that trust plane:

| Kit | Install | Wire |
| --- | --- | --- |
| Remote desktop | Vamp Host + Vamp Control | signed WebRTC |
| Mac terminal | Vamp Terminal Host + Vamp Terminal or Safari | signed WebRTC / browser on `:9475` |
| Pairing companion | Vamp Mini Host | signed WebRTC, menu-bar control surface |
| App streaming | Vamp Stream + Vamp Host or Vamp Mini Host | signed WebRTC app-window stream |
| Linux shell | Vamp Linux Host + a browser | WebSocket on loopback `:9475` |

Vamp Control and Vamp Terminal cannot attach to Vamp Linux Host. Safari control is built into the macOS hosts; there is no Safari download. Run only one macOS host at a time — both use the same signaling ports.

## Apps

| App | Purpose | Bundle ID |
| --- | --- | --- |
| Vamp Host | Full macOS host: screen, input, clipboard, files, audio, opt-in terminal, Safari control | `com.mesutcy.remotedesktop.host` |
| Vamp Terminal Host | Light macOS host: always-on terminal and Safari control only | `com.mesutcy.remotedesktop.terminalhost` |
| Vamp Mini Host | Separate pairing-first menu-bar host with trusted-device review and permission guidance | `com.mesutcy.remotedesktop.minhost` |
| Vamp Linux Host | Dependency-free Python browser host; not a WebRTC peer | local process |
| Vamp Stream | Focused iPhone/iPad app-window streaming client; also pairs with Vamp Assistant for its separate full-screen control surface | `com.mesutcydev.remotedesktop.stream` |
| Vamp Assistant | Separate compatible macOS full-screen control host on private port `9575` | existing Assistant bundle |
| Vamp Control | Remote-desktop client for macOS, iPhone, and iPad. Terminal Mode is an overlay, not the eight-tab workspace | `com.mesutcy.remotedesktop.macclient` / `com.mesutcy.remotedesktop.ios` |
| Vamp Terminal | Eight-tab terminal client for iPhone and iPad, with agent launchers | `com.mesutcy.remotedesktop.terminal` |

The iOS apps are unsigned IPAs for AltStore-style re-signing. The macOS and Linux hosts are built and run by the owner of the machine.

## Download and install

Current builds are on [thevamp.app](https://thevamp.app/#download). Read the
[install reference](docs/INSTALL.md) and the [AltStore guide](docs/VAMP_TERMINAL_SIDELOAD.md)
before sideloading an iOS build.

The macOS hosts are local utilities, not App Store products. On first launch:

1. Drag the app to `/Applications`.
2. Control-click the app and choose **Open**, if that option is available.
3. Otherwise open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. For Vamp Host, grant **Screen Recording** and **Accessibility** in System Settings → Privacy & Security. Vamp Terminal Host does not request either permission.

Vamp Mini Host also does not request Screen Recording or Accessibility: it is a
pairing-first, terminal-safe/view-only host surface.

Do not disable Gatekeeper globally.

## Build from source

Requirements: macOS 13 or later, Xcode 26 or later, and Python 3 for the Linux host.

```bash
xcodebuild \
  -project RemoteDesktopToolApps.xcodeproj \
  -scheme MacHost \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build the terminal-only macOS host by changing the scheme to `VampTerminalHost`.
Build the pairing-first menu-bar host by changing the scheme to `VampMiniHost`.
Build the current iPhone/iPad and macOS host artifacts with:

```bash
scripts/package-vamp-terminal-ios.sh --clean
scripts/package-vamp-stream-ios.sh --clean
scripts/package-vamp-mini-host.sh --clean
scripts/package-vamp-hosts.sh --clean
```

No Apple account, certificate, provisioning profile, or notarization credential is
required to build the unsigned IPA. AltStore or another sideloading tool must
re-sign it with the installing user's Apple ID/team.

The generated files are written to `dist/VampTerminal/`, `dist/VampStream/`,
`dist/VampMiniHost/`, and `dist/VampTerminalHosts/`. See [docs/INSTALL.md](docs/INSTALL.md) for the
separate iOS, macOS, Safari, and Linux install paths.

Run the Linux host with:

```bash
scripts/vamp-linux-host --listen 127.0.0.1 --port 9475
```

## Agent and automation interface

The repository includes the `vamp` CLI wrapper for the full Vamp Host:

```bash
sudo ln -sf \
  "$PWD/scripts/vamp" \
  /usr/local/bin/vamp
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

Only use Vamp on devices you own or are authorized to control. New peer identities require host approval, terminal access is opt-in on Vamp Host and always-on for Vamp Terminal Host, and the host can be stopped at any time.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Contributing and license

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

Vamp Terminal is licensed under the [Apache License 2.0](LICENSE). Third-party
components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Project governance, support,
release integrity, and name-use policies are documented in
[GOVERNANCE.md](GOVERNANCE.md), [SUPPORT.md](SUPPORT.md),
[docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md), and
[TRADEMARKS.md](TRADEMARKS.md). The
[open-source program readiness checklist](docs/PROGRAM_READINESS.md) records the
evidence to maintain as the project grows.

Vamp Terminal is an independent project. It is not affiliated with, endorsed by, or
sponsored by Apple Inc.
