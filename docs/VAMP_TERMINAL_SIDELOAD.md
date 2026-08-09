# Vamp Terminal AltStore build

Vamp Terminal is distributed as an open-source, device-only unsigned IPA. The
IPA is intentionally not signed by the project. AltStore re-signs it with the
Apple ID/team used on the installing device.

## Latest published build

- [Vamp Terminal IPA build 3](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-3/VampTerminal-iOS-1.0.0-build-3-altstore-unsigned.ipa)
- [Vamp Host](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-3/VampHost-macOS-3.2.0-build-2-adhoc.zip)
- [Vamp Terminal Host](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-3/VampTerminalHost-macOS-1.0.0-build-1-adhoc.zip)
- [All checksums and manifests](https://github.com/Mesutcydev/macpair/releases/tag/vamp-terminal-1.0.0-build-3)

## Build

From the repository root:

```bash
scripts/package-vamp-terminal-ios.sh --clean --allow-dirty
```

The script uses the active `RemoteDesktopToolApps.xcodeproj`, builds the
`VampTerminalApp` scheme for `iphoneos`, verifies arm64, confirms the current
existing `_screenharbor._tcp` Bonjour contract, and writes these files to
`dist/VampTerminal/`:

- `VampTerminal-iOS-…-altstore-unsigned.ipa`
- its `.sha256` checksum
- its `.manifest.json` and SBOM

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
continues from its current state. The launcher menu also has Claude Code,
Codex CLI, Aider, and OpenCode presets; each uses a tmux-backed command so an
agent can keep running while the mobile tab changes or reconnects.

## Control from Safari without the iOS app

Vamp Host includes a terminal-only browser workspace styled as a task chat. It
serves a self-contained HTML/JavaScript client on `127.0.0.1` only. The host
does not open a LAN/public HTTP port and does not provide a hosted relay.

1. Open Vamp Host → Settings → Terminal Mode and enable it.
2. In Settings → Safari control, copy the displayed Tailscale Serve command.
3. Run that command in Terminal on the Mac. It exposes the loopback service as
   a private HTTPS URL on the tailnet; Tailscale must be active on the Mac and
   the Safari device.
4. Open the resulting tailnet URL in Safari and enter the six-digit pairing
   code shown by Vamp Host. The code expires after ten minutes; browser access
   tokens expire after thirty minutes.

The browser workspace supports up to eight concurrent CLI tabs, background
output/unread tab indicators, explicit command approval cards, clipboard
send/receive, Ctrl/Esc/Tab/arrows, tmux/screen handoff, and the same agent
launch workflow. It is terminal-only: screen capture, remote mouse/keyboard,
microphone, and browser-side API credentials are intentionally out of scope.

For a quick manual handoff, use `tmux new-session -A -s work` or
`screen -r work` in the browser tab. Closing Safari or stopping the host ends
browser PTYs; tmux/screen is the supported way to continue a process later.
