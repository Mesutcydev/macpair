# Vamp Terminal Linux Host

This is the small Linux companion for terminal sessions. It provides a
loopback-only browser workspace with multiple PTYs, pairing-code authentication,
resize, clipboard messages, and a maximum of eight terminals per browser
connection.

It is intentionally independent from the macOS WebRTC host. The macOS products
(`Vamp Host` and `Vamp Terminal Host`) use the signed pairing/WebRTC stack used
by the iOS app. The Linux companion uses a dependency-free WebSocket endpoint so
Safari can control Linux without an iOS app. This keeps the Linux install small
and makes the network boundary obvious.

## Run

```sh
python3 linux-host/vamp_terminal_host.py
```

Open the printed local URL, enter the six-digit code shown in the host
terminal, then use the tab bar. For tailnet access, keep the process bound to
loopback and run:

```sh
tailscale serve --bg http://127.0.0.1:9475
```

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
arrows, resize messages, copy output, and paste.
