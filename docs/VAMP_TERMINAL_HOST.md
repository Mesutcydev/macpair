# Vamp host products

[Download the latest Vamp Host](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-7/VampHost-macOS-3.2.0-build-5-adhoc.zip) ·
[Download Vamp Terminal Host build 5](https://github.com/Mesutcydev/macpair/releases/download/vamp-terminal-1.0.0-build-7/VampTerminalHost-macOS-1.0.0-build-5-adhoc.zip)

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

`linux-host/vamp_terminal_host.py` is a dependency-free browser companion. It
is intentionally a WebSocket/Safari path rather than a second WebRTC
implementation. Run it on loopback, then expose it through Tailscale Serve:

```sh
python3 linux-host/vamp_terminal_host.py
tailscale serve --bg http://127.0.0.1:9475
```

The printed six-digit code pairs the browser. Each authenticated connection
can open eight tabs, resize each PTY, send/receive clipboard text, and close
terminals independently.

## Safari and Tailscale

On the Mac, `127.0.0.1:9475` is the local browser service. On an iPhone or
iPad, `127.0.0.1` points back to the phone/tablet, so it will not open the
Mac. Use one of the addresses shown in the host dashboard instead:

- Recommended: the `https://<mac>.ts.net/` Tailscale Serve URL.
- Fallback: `http://100.x.y.z:9475/`, using `tailscale ip -4` on the Mac.

Both devices must be signed in to the same tailnet and have Tailscale enabled.
If the HTTPS hostname does not resolve, enable Tailscale DNS/MagicDNS or use
the direct 100.x fallback. Do not use public port forwarding.
