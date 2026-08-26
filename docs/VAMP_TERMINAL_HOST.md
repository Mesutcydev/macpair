# Vamp host products

[Download latest Vamp Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampHost-macOS-2.3.0-build-47-adhoc.zip) ·
[Download latest Vamp Terminal Host](https://github.com/Mesutcydev/macpair/releases/latest/download/VampTerminalHost-macOS-2.3.0-build-47-adhoc.zip) ·
[Vamp Sync product page](mini-host/)

Vamp Terminal is the iPhone/iPad client. It can connect to either of these
macOS host products:

## Vamp Host

The original host remains the complete remote client: remote display, input,
and terminal mode. Terminal mode is an explicit setting. When enabled, a
single authenticated client session can own up to eight independent PTYs.

## Vamp Terminal Host

This is the light macOS target in `RemoteDesktopToolApps.xcodeproj`:

- Product: `Vamp Terminal Host`
- Bundle identifier: `com.mesutcy.remotedesktop.terminalhost`
- Scheme: `VampTerminalHost`

## Vamp Sync

Vamp Sync is a separate menu-bar product for pairing review, trusted-device
management, and permission guidance. It has its own bundle ID, host identity, and
trusted-peer store, but still uses the shared private-network signaling ports.

- Product: `Vamp Sync`
- Bundle ID: `com.mesutcy.remotedesktop.minhost`
- Scheme: `VampMiniHost`
- URL scheme: `vampminihost://`
- UI: menu-bar popover only; no Dock dashboard
- Safety boundary: no Screen Recording or Accessibility permission required
- Terminal mode is always enabled.
- The host advertises terminal and multiple-terminal capabilities only.
- It never starts ScreenCaptureKit, remote input, multi-display, or audio
  surfaces.
- Its dashboard focuses on pairing, Tailscale address, Safari control, and CLI
  handoff.

The two products share the signed identity, discovery, pairing, trust, and
authenticated transport code. A terminal-only host rejects clients that do not
advertise terminal capability.

## Linux companion

`linux-host/vamp_terminal_host.py` is Vamp Linux Host, a dependency-free browser
companion. It is intentionally a WebSocket/Safari path rather than a second
WebRTC implementation. Vamp Control and Vamp Terminal cannot attach to it. Run
it on loopback; Tailscale Serve is optional when you want an HTTPS hostname:

```sh
python3 linux-host/vamp_terminal_host.py
tailscale serve --bg http://127.0.0.1:9475
```

The Linux origin explicitly uses HTTP/1.1 so a configured Cloudflare Tunnel
can carry the WebSocket upgrade. For Cloudflare access, point a named tunnel
at `http://127.0.0.1:9475`, protect its hostname with Cloudflare Access, and
run it with:

```sh
cloudflared tunnel run vamp-terminal
```

Do not use an unauthenticated quick tunnel or expose port `9475` directly.

The printed 12-digit code pairs the browser. Each authenticated connection
can open eight tabs, resize each PTY, send/receive clipboard text, and close
terminals independently.

## Safari and Tailscale

On the Mac, `127.0.0.1:9475` is the local browser service. On an iPhone or
iPad, `127.0.0.1` points back to the phone/tablet, so it will not open the
Mac. Use one of the addresses shown in the host dashboard instead:

- Recommended: `http://100.x.y.z:9475/`, using `tailscale ip -4` on the Mac.
- Optional: the `https://<mac>.ts.net/` Tailscale Serve URL after running the
  command above.

Both devices must be signed in to the same tailnet and have Tailscale enabled.
If the HTTPS hostname does not resolve or Serve has not been enabled, use the
direct 100.x address. Do not use public port forwarding.
