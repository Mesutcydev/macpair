# Vamp

**Vamp currently promotes two open-source, local-first products: Vamp Assistant and Vamp Stream.** Connections use a trusted LAN or private Tailscale network. Every new device needs visible approval. There is no product account and no hosted relay.

| Product | Purpose | Platforms |
| --- | --- | --- |
| [Vamp Assistant](https://thevamp.app/assistant/) | Native AI chat, local/BYOK models, Code workspaces, specialist bots, approval-gated tools, and private remote sessions | macOS, iPhone, iPad, browser |
| [Vamp Stream](https://thevamp.app/stream/) | Focused visual client for a Mac display or app window | iPhone, iPad |

Vamp Stream can use Vamp Host, the lightweight **Vamp Stream Host** (the
`VampMiniHost` implementation), or Vamp Assistant as its Mac side. Host and
Vamp Stream Host use the signed WebRTC stack; Assistant uses its authenticated
private Remote Sessions endpoint. Terminal, Terminal Host, Control, standalone
browser control, and Linux Host source and technical documentation remain in
the repository, but they are not part of the current public promotion.

## Current public apps

| App | Purpose | Bundle ID |
| --- | --- | --- |
| Vamp Stream | Focused iPhone/iPad visual streaming client | `com.mesutcy.remotedesktop.stream` |
| Vamp Assistant | Native macOS AI product with its own iOS and browser remotes | See [Assistant source](https://github.com/Mesutcydev/vamp-assistant) |

The iOS apps are unsigned IPAs for AltStore-style re-signing. Supporting Mac
hosts are installed and run by the owner of the machine.

## Download and install

Current builds are on [thevamp.app](https://thevamp.app/#download). Read the
[install reference](docs/INSTALL.md) and the [iOS sideload guide](docs/IOS_SIDELOAD.md)
before sideloading an iOS build.

The macOS hosts are local utilities, not App Store products. On first launch:

1. Drag the app to `/Applications`.
2. Control-click the app and choose **Open**, if that option is available.
3. Otherwise open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. For Vamp Stream Host, grant **Screen Recording** for video and
   **Accessibility** for keyboard/pointer control in System Settings → Privacy
   & Security.

Do not disable Gatekeeper globally.

## Build from source

Requirements: macOS 13 or later and Xcode 26 or later.

```bash
xcodebuild \
  -project RemoteDesktopToolApps.xcodeproj \
  -scheme MacHost \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Build the Stream client and its lightweight supporting host with:

```bash
scripts/package-vamp-stream-ios.sh --clean
scripts/package-vamp-mini-host.sh --clean
```

No Apple account, certificate, provisioning profile, or notarization credential is
required to build the unsigned IPA. AltStore or another sideloading tool must
re-sign it with the installing user's Apple ID/team.

The generated files are written under `dist/VampStream/` and
`dist/VampStreamHost/`. See [docs/INSTALL.md](docs/INSTALL.md) for the supported
Assistant and Stream install paths.

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
