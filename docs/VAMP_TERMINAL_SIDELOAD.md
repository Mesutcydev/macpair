# Vamp Terminal install guide

Vamp Terminal is distributed as an open-source, device-only unsigned IPA. The
IPA is intentionally not signed by the project. AltStore re-signs it with the
Apple ID/team used on the installing device.

## Latest published build

- [Vamp Terminal IPA build 13](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-13/VampTerminal-iOS-1.0.0-build-13-altstore-unsigned.ipa)
- [Vamp Host build 13](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-13/VampHost-macOS-3.2.0-build-13-adhoc.zip)
- [Vamp Terminal Host build 13](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-13/VampTerminalHost-macOS-1.0.0-build-13-adhoc.zip)
- [All checksums and manifests](https://github.com/Mesutcydev/macpair/releases/tag/vamp-terminal-1.0.0-build-13)

## Build the current Vamp artifacts

From the repository root:

```bash
scripts/package-vamp-terminal-ios.sh --clean
scripts/package-vamp-hosts.sh --clean
```

The scripts use the active `RemoteDesktopToolApps.xcodeproj`, never the retired
`screenharbor-project.yml`. They build the `VampTerminalApp`, `MacHost`, and
`VampTerminalHost` schemes, verify arm64, preserve the existing
`_screenharbor._tcp` Bonjour compatibility contract, and write:

- `VampTerminal-iOS-…-altstore-unsigned.ipa`
- its `.sha256` checksum
- its `.manifest.json` and SBOM

Host ZIPs and their metadata are written to `dist/VampTerminalHosts/`.

For a local development tree only, `--allow-dirty` may be added. Do not use it
for a release artifact.

## Install with AltStore

1. Verify the checksum from the artifact directory with
   `(cd dist/VampTerminal && shasum -a 256 -c VampTerminal-iOS-…-altstore-unsigned.ipa.sha256)`.
2. Import the IPA into AltStore using **+ → Sideload IPA**.
3. Let AltStore sign and install it with the Apple ID configured in AltStore.
4. Allow Local Network access on first launch.

The project does not include a certificate, provisioning profile, Apple ID, or
an attempt to bypass iOS code signing. A free Apple ID normally requires the
usual AltStore refresh cadence; a paid team has the normal longer signing
window. The bundle ID is `com.mesutcy.remotedesktop.terminal`.

## Resume an existing shell or agent

Vamp Terminal starts one new PTY per tab. To continue a process already running
in Mac Terminal, start it in tmux first:

```bash
vamp terminal start --session work
# run the shell or agent, then detach with Ctrl-b d
```

In the app, choose `+` → `Attach / create tmux`, enter `work`, and the process
continues from its current state. The launcher menu also has OpenCode, Pi,
CommandCode, ChatGPT CLI, Claude Code, Kimi, Qwen Code, Codex CLI, Aider, and
Grok CLI presets; each uses a named tmux-backed command so an agent can keep
running while the mobile tab changes or reconnects.

## Control from Safari without the iOS app

Vamp Host includes a terminal-only browser workspace styled as a task chat. It
serves a self-contained HTML/JavaScript client on Mac loopback and, when
Tailscale is available, on the private Tailscale interface. The host rejects
ordinary LAN paths, does not open a public HTTP port, and does not provide a
hosted relay.

1. Open Vamp Host → Settings → Terminal Mode and enable it.
2. In Settings → Safari control, scan the displayed QR or copy the direct
   Tailscale URL. The QR includes the current six-digit code.
3. If HTTPS is preferred, copy the Tailscale Serve command and run it in
   Terminal on the Mac. Tailscale must be active on the Mac and the Safari
   device.
4. Open the direct `http://100.x.y.z:9475/` URL (or the Serve URL) in Safari.
   The code expires after ten minutes; browser access tokens expire after
   thirty minutes.

`127.0.0.1:9475` only works in a browser on the Mac itself. From an iPhone or
iPad, use the direct `http://100.x.y.z:9475/` URL shown in the host dashboard,
or the HTTPS Serve URL if enabled. The Mac and mobile device must be on the
same Tailscale tailnet; MagicDNS/Tailscale DNS is only required for the
`.ts.net` name.

The browser workspace supports up to eight concurrent CLI tabs, background
output/unread tab indicators, explicit command approval cards, clipboard
send/receive, Ctrl/Esc/Tab/arrows, tmux/screen handoff, and the same agent
launch workflow. It is terminal-only: screen capture, remote mouse/keyboard,
microphone, and browser-side API credentials are intentionally out of scope.

For a quick manual handoff, use `tmux new-session -A -s work` or
`screen -r work` in the browser tab. Closing Safari or stopping the host ends
browser PTYs; tmux/screen is the supported way to continue a process later.
