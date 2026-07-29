import Foundation

// MARK: - Terminal Mode
//
// Bidirectional PTY-backed shell over the existing authenticated WebRTC data
// channel. The client opens a session, streams keystrokes as `TerminalInput`,
// receives `TerminalOutput` chunks (raw bytes as written by the shell), and
// resizes the PTY window via `TerminalResize`. `TerminalClose` tears down.
//
// Security: all messages travel the same authenticated + anti-replay envelope
// that gates input commands. The host enforces a single active terminal per
// session (no fan-out, no remote forwarding) and applies hard byte/rate caps.

/// Sent by the client to open a new PTY shell on the host.
public struct TerminalOpenMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    /// Stable identifier the client chooses for this terminal channel. Lets
    /// future versions multiplex multiple terminals over one session.
    public let terminalID: UUID
    /// Initial PTY window size (columns x rows in character cells).
    public let cols: UInt16
    public let rows: UInt16
    /// Suggested $TERM value; host falls back to `xterm-256color` if absent.
    public let term: String?

    public init(sessionID: UUID, terminalID: UUID, cols: UInt16, rows: UInt16, term: String? = "xterm-256color") {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
        self.term = term
    }
}

/// Stdin chunk from the client to the host PTY.
public struct TerminalInputMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    /// Raw bytes to write to the PTY master. UTF-8 keystrokes plus escape
    /// sequences (arrows, F-keys, etc.).
    public let data: Data

    /// 16 KB cap per chunk — typical keystroke is <8 bytes; paste of a whole
    /// page is comfortably under this. Anything larger is dropped.
    public static let maxChunkBytes = 16_384

    public init(sessionID: UUID, terminalID: UUID, data: Data) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.data = data
    }
}

/// Stdout/stderr chunk from the host PTY to the client.
public struct TerminalOutputMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    /// Raw bytes read from the PTY master. May contain VT/ANSI escape
    /// sequences; the client renders them through its terminal emulator.
    public let data: Data
    /// Monotonic sequence number assigned by the host so the client can detect
    /// drops/reorders (data channel is reliable + ordered today, but this
    /// keeps us honest if we ever switch to unreliable).
    public let sequence: UInt64

    /// 32 KB cap per chunk — a single 80×40 screen of utf-8 text fits easily;
    /// `cat` of a large file is split into many chunks by the host pump.
    public static let maxChunkBytes = 32_768

    public init(sessionID: UUID, terminalID: UUID, data: Data, sequence: UInt64) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.data = data
        self.sequence = sequence
    }
}

/// Window resize — the client recomputes cols/rows when its view bounds or
/// font changes and pushes the new size; the host runs `TIOCSWINSZ` on the
/// PTY master.
public struct TerminalResizeMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let cols: UInt16
    public let rows: UInt16

    public init(sessionID: UUID, terminalID: UUID, cols: UInt16, rows: UInt16) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
    }
}

/// Either side may send this. From client: please tear down the shell. From
/// host: the shell exited (`exitCode` set) or was killed by signal
/// (`signal` set). `reason` is for diagnostics; the client never trusts it
/// for security decisions.
public struct TerminalCloseMessage: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let terminalID: UUID
    public let exitCode: Int32?
    public let signal: Int32?
    public let reason: String?

    public init(sessionID: UUID, terminalID: UUID, exitCode: Int32? = nil, signal: Int32? = nil, reason: String? = nil) {
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.exitCode = exitCode
        self.signal = signal
        self.reason = reason
    }
}
