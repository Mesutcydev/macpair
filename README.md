# ScreenHarbor

**ScreenHarbor is an open-source, native remote desktop for macOS.** It pairs a lightweight Mac host with a Mac client for low-latency screen sharing, keyboard and pointer control, clipboard sync, file transfer, audio, and an opt-in remote terminal.

The project is local-first. Discovery uses Bonjour on your LAN, peer identities are signed, and every new client must be visibly approved on the host. For access beyond the local network, use a private network you control, such as Tailscale; ScreenHarbor does not require a hosted relay or account.

## Apps

| App | Purpose | Bundle ID |
| --- | --- | --- |
| ScreenHarbor Host | Runs on the Mac being controlled | `uk.mesut.screenharbor.host` |
| ScreenHarbor | Connects to an approved host | `uk.mesut.screenharbor.client` |

Both apps are distributed directly from the project website and can be built without
App Store services.

## Download and install

Download the [Mac client](https://mesut.uk/apps/screenharbor) and
[host](https://mesut.uk/apps/screenharbor-host) DMGs directly from the project website.

Current website builds are ad-hoc signed, not Developer ID signed or Apple-notarized.
Verify the adjacent SHA-256 checksum and manifest before opening a download. On first
launch:

1. Drag the app to `/Applications`.
2. Control-click the app and choose **Open**, if that option is available.
3. Otherwise open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. For the host, grant **Screen Recording** and **Accessibility** in System Settings → Privacy & Security.

Do not disable Gatekeeper globally.

## Build from source

Requirements: macOS 13 or later, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate --spec screenharbor-project.yml

xcodebuild \
  -project ScreenHarbor.xcodeproj \
  -scheme ScreenHarborHost \
  -configuration Release \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build
```

Build the client by changing the scheme to `ScreenHarborClient`. Create website-ready DMG and ZIP artifacts with:

```bash
scripts/package-screenharbor.sh all --format both --clean
```

No Apple account, certificate, provisioning profile, or notarization credential is
required for a local build.

## Agent and automation interface

The host bundles the `screenharbor` CLI. Install it after copying the host app:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -sf \
  "/Applications/ScreenHarbor Host.app/Contents/Resources/screenharbor" \
  /usr/local/bin/screenharbor
```

Useful commands:

```bash
screenharbor ensure
screenharbor status --json
screenharbor pending --json
screenharbor approve-pairing --fingerprint <verified-hex>
```

Agents must never approve an unknown pairing request. Present the device name and fingerprint to the user and require an exact fingerprint match. See [docs/AGENT_INTEGRATION.md](docs/AGENT_INTEGRATION.md) and [llms.txt](llms.txt).

## Network contract

- Bonjour: `_screenharbor._tcp`
- Signaling: TCP `9471`
- Data: UDP/TCP `9472`
- TLS signaling: TCP `9473`
- URL actions: `screenharbor://action/{start,stop,restart}`
- Agent status: `~/Library/Application Support/ScreenHarbor/host.widget.snapshot.json`

## Security

Only use ScreenHarbor on devices you own or are authorized to control. New peer identities require host approval, terminal access is opt-in, and the host can be stopped at any time.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Contributing and license

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

ScreenHarbor is licensed under the [Apache License 2.0](LICENSE). Third-party
components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Project governance, support,
release integrity, and name-use policies are documented in
[GOVERNANCE.md](GOVERNANCE.md), [SUPPORT.md](SUPPORT.md),
[docs/RELEASE_PROCESS.md](docs/RELEASE_PROCESS.md), and
[TRADEMARKS.md](TRADEMARKS.md). The
[open-source program readiness checklist](docs/PROGRAM_READINESS.md) records the
evidence to maintain as the project grows.

ScreenHarbor is an independent project. It is not affiliated with, endorsed by, or
sponsored by Apple Inc.
