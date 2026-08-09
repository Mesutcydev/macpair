#!/usr/bin/env python3
"""Small, dependency-free Linux terminal host for Vamp Terminal workflows.

The Linux host deliberately exposes a loopback WebSocket endpoint. Put it behind
`tailscale serve` when it needs to be reached away from the LAN. It does not
open a public listener, implement a relay, or pretend to be the iOS WebRTC
host; it is the Safari/browser companion for Linux machines.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import pty
import secrets
import signal
import socket
import struct
import threading
import time
import urllib.parse
import uuid
from pathlib import Path
from typing import Any


VERSION = "1.0.0"
DEFAULT_PORT = 9475
DEFAULT_MAX_TERMINALS = 8
PAIRING_TTL_SECONDS = 600
ROOT = Path(__file__).resolve().parent


def now() -> float:
    return time.time()


def clamp(value: Any, minimum: int, maximum: int, default: int) -> int:
    try:
        return max(minimum, min(maximum, int(value)))
    except (TypeError, ValueError):
        return default


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def websocket_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", 0x80 | opcode, length)
    elif length <= 0xFFFF:
        header = struct.pack("!BBH", 0x80 | opcode, 126, length)
    else:
        header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
    return header + payload


def read_websocket_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    if length > 4 * 1024 * 1024:
        raise ValueError("websocket message is too large")
    mask = read_exact(sock, 4) if masked else b""
    payload = bytearray(read_exact(sock, length))
    if masked:
        for index in range(length):
            payload[index] ^= mask[index % 4]
    return opcode, bytes(payload)


class PairingState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.code = ""
        self.expires_at = 0.0
        self.token = ""
        self.rotate()

    def rotate(self) -> None:
        with self._lock:
            self.code = f"{secrets.randbelow(1_000_000):06d}"
            self.expires_at = now() + PAIRING_TTL_SECONDS
            self.token = ""

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "code": self.code,
                "expiresAt": self.expires_at,
                "paired": bool(self.token and self.expires_at > now()),
            }

    def pair(self, code: str) -> str | None:
        with self._lock:
            if now() > self.expires_at or not secrets.compare_digest(code.strip(), self.code):
                return None
            self.token = secrets.token_urlsafe(32)
            self.expires_at = now() + PAIRING_TTL_SECONDS
            return self.token

    def valid_token(self, token: str) -> bool:
        with self._lock:
            return bool(
                self.token
                and now() < self.expires_at
                and secrets.compare_digest(token, self.token)
            )


class TerminalConnection:
    """One authenticated browser connection and its independent PTYs."""

    def __init__(self, host: "VampTerminalHost", sock: socket.socket) -> None:
        self.host = host
        self.sock = sock
        self.send_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.terminals: dict[str, PtyTerminal] = {}

    def send(self, message: dict[str, Any]) -> None:
        if self.stop_event.is_set():
            return
        payload = json_bytes(message)
        try:
            with self.send_lock:
                self.sock.sendall(websocket_frame(payload))
        except OSError:
            self.stop_event.set()

    def send_error(self, code: str, message: str, terminal_id: str | None = None) -> None:
        body: dict[str, Any] = {"type": "error", "code": code, "message": message}
        if terminal_id:
            body["terminalID"] = terminal_id
        self.send(body)

    def open_terminal(self, payload: dict[str, Any]) -> None:
        terminal_id = str(payload.get("terminalID") or uuid.uuid4())
        if len(terminal_id) > 96 or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for character in terminal_id):
            self.send_error("invalid-terminal", "terminalID must contain only letters, numbers, '-' or '_'")
            return
        if terminal_id in self.terminals:
            self.send_error("duplicate-terminal", "That terminal tab is already open", terminal_id)
            return
        if len(self.terminals) >= self.host.max_terminals:
            self.send_error("capacity", f"This connection is limited to {self.host.max_terminals} terminals")
            return

        title = str(payload.get("title") or "Terminal")[:80]
        terminal = PtyTerminal(self, terminal_id, title)
        self.terminals[terminal_id] = terminal
        try:
            terminal.start()
        except OSError as error:
            self.terminals.pop(terminal_id, None)
            self.send_error("spawn-failed", str(error), terminal_id)
            return

        self.send({
            "type": "terminalReady",
            "terminalID": terminal_id,
            "title": title,
            "capabilities": {
                "supportsTerminal": True,
                "supportsMultipleTerminals": True,
                "maxTerminals": self.host.max_terminals,
                "supportsClipboard": True,
                "supportsResize": True,
            },
        })
        command = payload.get("command")
        if isinstance(command, str) and command.strip():
            terminal.write(command.rstrip() + "\n")

    def close_terminal(self, terminal_id: str, reason: str = "closed", notify: bool = True) -> None:
        terminal = self.terminals.pop(terminal_id, None)
        if terminal:
            terminal.close()
            if notify:
                self.send({"type": "terminalClosed", "terminalID": terminal_id, "reason": reason})
        elif notify:
            self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)

    def terminal_exited(self, terminal_id: str, reason: str) -> None:
        terminal = self.terminals.pop(terminal_id, None)
        if terminal:
            self.send({"type": "terminalClosed", "terminalID": terminal_id, "reason": reason})

    def handle(self, payload: dict[str, Any]) -> None:
        message_type = payload.get("type")
        terminal_id = str(payload.get("terminalID") or "")
        if message_type == "open":
            self.open_terminal(payload)
            return
        if message_type == "input":
            terminal = self.terminals.get(terminal_id)
            if not terminal:
                self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)
                return
            data = payload.get("data")
            if isinstance(data, str) and len(data) <= 1_000_000:
                terminal.write(data)
            return
        if message_type == "resize":
            terminal = self.terminals.get(terminal_id)
            if not terminal:
                self.send_error("unknown-terminal", "No terminal with that ID is open", terminal_id)
                return
            terminal.resize(
                clamp(payload.get("cols"), 2, 500, 80),
                clamp(payload.get("rows"), 2, 300, 24),
            )
            return
        if message_type == "close":
            self.close_terminal(terminal_id)
            return
        if message_type == "clipboardSet":
            data = payload.get("data")
            if isinstance(data, str) and len(data) <= 2_000_000:
                self.host.clipboard = data
                self.send({"type": "clipboardChanged", "length": len(data)})
            return
        if message_type == "clipboardGet":
            self.send({"type": "clipboard", "data": self.host.clipboard})
            return
        if message_type == "ping":
            self.send({"type": "pong"})
            return
        self.send_error("unsupported-message", f"Unsupported message type: {message_type}")

    def run(self) -> None:
        try:
            self.send({
                "type": "hostReady",
                "product": "Vamp Terminal Linux Host",
                "protocolVersion": 1,
                "maxTerminals": self.host.max_terminals,
            })
            while not self.stop_event.is_set():
                opcode, raw = read_websocket_frame(self.sock)
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    with self.send_lock:
                        self.sock.sendall(websocket_frame(raw, opcode=0xA))
                    continue
                if opcode != 0x1:
                    continue
                payload = json.loads(raw.decode("utf-8"))
                if isinstance(payload, dict):
                    self.handle(payload)
        except (ConnectionError, OSError, ValueError, json.JSONDecodeError):
            pass
        finally:
            self.stop_event.set()
            for terminal_id in list(self.terminals):
                self.close_terminal(terminal_id, reason="connection-closed", notify=False)
            self.host.remove_connection(self)
            try:
                self.sock.close()
            except OSError:
                pass


class PtyTerminal:
    def __init__(self, connection: TerminalConnection, terminal_id: str, title: str) -> None:
        self.connection = connection
        self.terminal_id = terminal_id
        self.title = title
        self.pid: int | None = None
        self.fd: int | None = None
        self.closed = threading.Event()

    def start(self) -> None:
        pid, fd = pty.fork()
        if pid == 0:
            shell = os.environ.get("SHELL", "/bin/bash")
            environment = os.environ.copy()
            environment.setdefault("TERM", "xterm-256color")
            environment["VAMP_TERMINAL"] = "1"
            os.execvpe(shell, [shell, "-l"], environment)
        self.pid = pid
        self.fd = fd
        self.resize(80, 24)
        threading.Thread(target=self._read_loop, name=f"vamp-pty-{self.terminal_id}", daemon=True).start()

    def write(self, data: str) -> None:
        if self.closed.is_set() or self.fd is None:
            return
        try:
            os.write(self.fd, data.encode("utf-8", errors="replace"))
        except OSError:
            self.close()

    def resize(self, cols: int, rows: int) -> None:
        if self.closed.is_set() or self.fd is None:
            return
        import fcntl
        import termios

        size = struct.pack("HHHH", rows, cols, 0, 0)
        try:
            fcntl.ioctl(self.fd, termios.TIOCSWINSZ, size)
        except OSError:
            pass

    def close(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        if self.pid:
            try:
                os.killpg(self.pid, signal.SIGTERM)
            except OSError:
                pass
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None

    def _read_loop(self) -> None:
        assert self.fd is not None
        try:
            while not self.closed.is_set():
                output = os.read(self.fd, 64 * 1024)
                if not output:
                    break
                self.connection.send({
                    "type": "terminalOutput",
                    "terminalID": self.terminal_id,
                    "data": output.decode("utf-8", errors="replace"),
                })
        except OSError:
            pass
        finally:
            if not self.closed.is_set():
                self.closed.set()
                self.connection.terminal_exited(self.terminal_id, "process-exited")


class VampTerminalHost:
    def __init__(self, max_terminals: int) -> None:
        self.max_terminals = max(1, min(max_terminals, 8))
        self.pairing = PairingState()
        self.clipboard = ""
        self._lock = threading.Lock()
        self.connections: set[TerminalConnection] = set()

    def add_connection(self, connection: TerminalConnection) -> None:
        with self._lock:
            self.connections.add(connection)

    def remove_connection(self, connection: TerminalConnection) -> None:
        with self._lock:
            self.connections.discard(connection)

    def status(self) -> dict[str, Any]:
        with self._lock:
            terminal_count = sum(len(connection.terminals) for connection in self.connections)
            connection_count = len(self.connections)
        return {
            "product": "Vamp Terminal Linux Host",
            "version": VERSION,
            "protocolVersion": 1,
            "maxTerminalsPerConnection": self.max_terminals,
            "connections": connection_count,
            "terminals": terminal_count,
            "pairing": self.pairing.snapshot(),
        }

    def close(self) -> None:
        with self._lock:
            connections = list(self.connections)
        for connection in connections:
            connection.stop_event.set()
            try:
                connection.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class RequestHandler(http.server.BaseHTTPRequestHandler):
    server: "VampHTTPServer"

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _send_json(self, status: int, value: Any) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/status":
            self._send_json(200, self.server.host.status())
            return
        if parsed.path == "/ws":
            self._upgrade_websocket(parsed)
            return
        if parsed.path in ("/", "/index.html"):
            self._serve_file(ROOT / "index.html", "text/html; charset=utf-8")
            return
        self._send_json(404, {"error": "not-found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/pair":
            self._send_json(404, {"error": "not-found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 8_192:
                raise ValueError("request too large")
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            code = str(body.get("code", ""))
        except (ValueError, TypeError, json.JSONDecodeError):
            self._send_json(400, {"error": "invalid-json"})
            return
        token = self.server.host.pairing.pair(code)
        if token is None:
            self._send_json(403, {"error": "invalid-or-expired-code"})
            return
        self._send_json(200, {"token": token, "expiresAt": self.server.host.pairing.expires_at})

    def _serve_file(self, path: Path, content_type: str) -> None:
        try:
            body = path.read_bytes()
        except OSError:
            self._send_json(404, {"error": "missing-asset"})
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _upgrade_websocket(self, parsed: urllib.parse.ParseResult) -> None:
        token = urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
        if not self.server.host.pairing.valid_token(token):
            self._send_json(403, {"error": "pair-first"})
            return
        key = self.headers.get("Sec-WebSocket-Key")
        if not key or self.headers.get("Upgrade", "").lower() != "websocket":
            self._send_json(400, {"error": "websocket-upgrade-required"})
            return
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        connection = TerminalConnection(self.server.host, self.connection)
        self.server.host.add_connection(connection)
        connection.run()


class VampHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], host: VampTerminalHost) -> None:
        self.host = host
        super().__init__(address, RequestHandler)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Vamp Terminal Linux browser host")
    parser.add_argument("--listen", default="127.0.0.1", help="Bind address; loopback is the safe default")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--max-terminals", type=int, default=DEFAULT_MAX_TERMINALS)
    parser.add_argument("--version", action="version", version=f"vamp-terminal-host {VERSION}")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("--port must be between 1 and 65535")
    if args.listen not in ("127.0.0.1", "localhost", "::1"):
        print("warning: non-loopback binding is unsafe; prefer Tailscale Serve over a public listener", flush=True)

    host = VampTerminalHost(args.max_terminals)
    server = VampHTTPServer((args.listen, args.port), host)
    print("Vamp Terminal Linux Host", VERSION, flush=True)
    print(f"Local URL: http://{args.listen}:{args.port}/", flush=True)
    print(f"Pairing code: {host.pairing.code} (expires in {PAIRING_TTL_SECONDS // 60} minutes)", flush=True)
    print("Remote access: tailscale serve --bg http://127.0.0.1:%d" % args.port, flush=True)

    def stop(_signum: int, _frame: Any) -> None:
        host.close()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        server.serve_forever()
    finally:
        host.close()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
