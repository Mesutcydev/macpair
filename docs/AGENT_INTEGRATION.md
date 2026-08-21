# Agent integration

Vamp Host is a normal menu-bar macOS app, not a daemon. Launching the app starts its runtime automatically after required permissions are available. Vamp Terminal Host exposes the same terminal workflow without the screen-capture or remote-input surfaces.

## Discovery and readiness

```bash
vamp ensure
vamp status --json
```

`ensure` exits `0` when the host is ready, `1` when it is not installed, `2` when installed but not advertising, and `3` when the user must grant permissions.

The JSON status object includes `installed`, `running`, `phase`, `advertising`, `primaryAddress`, `appPath`, and `pendingPairingRequest`.

## Pairing safety

Inspect before approval:

```bash
vamp pending --json
```

An agent must:

1. show the user `displayName`, `fingerprint`, and `deadline`;
2. ask the user to verify the fingerprint through a trusted channel;
3. approve only with the exact fingerprint:

   ```bash
   vamp approve-pairing --fingerprint <verified-hex> --json
   ```

Never approve merely because a request exists. Reject suspicious requests with `vamp reject-pairing --json`.

## Commands

| Command | Purpose |
| --- | --- |
| `vamp start` | Launch Vamp Host and start hosting |
| `vamp stop` | Stop hosting |
| `vamp restart` | Restart hosting |
| `vamp open` | Open Vamp Host without a runtime action |
| `vamp status --json` | Read machine status |
| `vamp ensure` | Start if necessary and wait for readiness |
| `vamp version --json` | Read installed version/build |
| `vamp pending --json` | Inspect the current trust request |
| `vamp wait-pending --timeout 60 --json` | Wait for a trust request |
| `vamp approve-pairing --fingerprint <hex>` | Safely approve a verified peer |
| `vamp reject-pairing` | Reject a peer |

## Persistent terminal and agent handoff

Vamp Terminal deliberately opens a fresh PTY for each tab. To hand off a shell
or coding agent that is already running in Terminal.app, keep the process in a
terminal multiplexer:

```bash
vamp terminal start --session work
# run a command, then detach with Ctrl-b d
vamp terminal agent claude --session claude
```

From Vamp Terminal, choose `+` → `Attach / create tmux` and enter `work` or
`claude`. The host sends `tmux new-session -A -s <name>` as the tab's startup
command, so the existing process continues at its current point. The same
workflow is available for GNU screen with `vamp terminal attach` and
the `Attach screen` tab action.

Supported agent launchers are `opencode`, `pi`, `commandcode`, `chatgpt`,
`claude`, `kimi`, `qwen`, `codex`, `aider`, and `grok` when the corresponding
CLI is installed on the Mac. Vamp starts each launcher inside its own named
tmux session; an unavailable executable produces the normal shell error in
that tab. The app does not proxy agent APIs or credentials; it only transports
the authenticated PTY and preserves the normal CLI's input/output behavior.

## Permissions

Screen Recording and Accessibility apply only to Vamp Host and require a human decision in System Settings → Privacy & Security. Vamp Terminal Host does not request those permissions. Agents cannot and must not attempt to bypass system prompts.

## Network

The host advertises `_screenharbor._tcp` through Bonjour for compatibility with the existing signed pairing contract. It listens on `9471` for plain signaling, `9473` for TLS signaling, and normally uses `9472` for data. Safari control uses `9475`; on a Mac, `127.0.0.1:9475` is local only, while another tailnet device should use the displayed direct `http://100.x.y.z:9475/` URL. Tailscale Serve HTTPS is optional. The Linux browser host can also sit behind a named Cloudflare Tunnel protected by Cloudflare Access, with its origin kept on `127.0.0.1:9475`. Do not expose these ports directly to the public internet; use a trusted LAN, private VPN, or an authenticated private tunnel.
