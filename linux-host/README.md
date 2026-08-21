# Vamp Terminal Linux Host

This is the small Linux companion for terminal sessions. It provides a
loopback-only browser workspace with multiple PTYs, one-time pairing approval,
long-lived per-browser tokens, resize, clipboard messages, safe workspace roots,
and a maximum of eight terminals per browser connection.

It is intentionally independent from the macOS WebRTC host. The macOS products
(`Vamp Host` and `Vamp Terminal Host`) use the signed pairing/WebRTC stack used
by the iOS app. The Linux companion uses a dependency-free WebSocket endpoint so
Safari can control Linux without an iOS app. This keeps the Linux install small
and makes the network boundary obvious.

## Install

Download and extract the latest Linux archive, then run:

```sh
./install.sh
```

This installs the host under `~/.local/lib/vamp-terminal-host`, creates the
`~/.local/bin/vamp-terminal-host` command, and installs an optional user-level
systemd service. No root access is required.

Start it interactively:

```sh
vamp-terminal-host
```

Or enable it at login on systemd-based desktops:

```sh
systemctl --user enable --now vamp-terminal-host.service
```

## Run from source

```sh
python3 linux-host/vamp_terminal_host.py
```

Open the printed local URL, enter the six-digit code shown in the host
terminal, then use the tab bar. For private tailnet access, keep the process
bound to loopback and run:

```sh
tailscale serve --bg http://127.0.0.1:9475
```

If Tailscale is not available, a named Cloudflare Tunnel also works because
the host speaks HTTP/1.1 for reverse-proxy WebSocket upgrades. Keep the tunnel
behind a Cloudflare Access policy; do not use an unauthenticated quick tunnel
for this terminal surface.

Create a tunnel ingress that targets the loopback listener:

```yaml
# ~/.cloudflared/config.yml
tunnel: <TUNNEL_UUID>
credentials-file: /home/<you>/.cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: vamp.example.com
    service: http://127.0.0.1:9475
  - service: http_status:404
```

Then start the configured tunnel and open its hostname from an authorized
device:

```sh
cloudflared tunnel run vamp-terminal
```

Cloudflare Tunnel forwards the browser's WebSocket connection as well as the
pairing request. If the hostname is protected by Cloudflare Access, complete
that sign-in first, then enter the six-digit Vamp pairing code.

Do not bind this process to a public interface or use port forwarding. The
pairing code is a short-lived bearer credential, not an account or identity
system.

## Options

```text
--listen 127.0.0.1       Bind address (loopback by default)
--port 9475              Browser service port
--max-terminals 8        Per-connection PTY limit, capped at 8
```

Agent sessions can be created from the host shell with `tmux` or `screen`, then
attached through a tab. The browser client also supports Ctrl-C, Escape, Tab,
arrows, resize messages, copy output, and paste. PTY output is transported as
base64 bytes and decoded incrementally in the browser so split UTF-8 characters
are not corrupted.

## Current capability boundary

The Linux companion currently provides terminal tabs, clipboard, resize, and
workspace selection. It deliberately reports semantic Chat, structured task
plans, and remote desktop as unsupported. Use the macOS Vamp Host when those
features are required. This avoids presenting a terminal text log as an
authoritative agent conversation.
