#if os(macOS)
import Foundation
import Darwin
import SharedProtocol
import TransportWebRTC
import os

// MARK: - libutil bridge
//
// `forkpty(3)` lives in libutil.dylib on macOS and is not exposed by Swift's
// Darwin module. Declaring it with @_silgen_name lets us call it directly
// without adding a bridging header or C shim module.
@_silgen_name("forkpty")
private func c_forkpty(
    _ amaster: UnsafeMutablePointer<Int32>?,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafePointer<termios>?,
    _ winp: UnsafePointer<winsize>?
) -> pid_t

/// Hosts an interactive shell over a PTY for the connected iOS client. One
/// service instance manages at most one active terminal per session — a fresh
/// `TerminalOpen` from the same session replaces the previous shell.
///
/// Threading: all public mutators hop to an internal serial queue so the PTY
/// fd, child PID, and pump tasks are touched from a single context. Output
/// arrives on the same queue and is forwarded via the injected send closure.
final class HostTerminalService: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.remotedesktop.host", category: "Terminal")
    private let queue = DispatchQueue(label: "host.terminal.service")

    /// Maximum byte rate written to the data channel from a single terminal
    /// (defensive — runaway `yes` or `cat /dev/urandom`). Excess bytes are
    /// dropped on the floor with a single log line; we never block the PTY.
    private let outputByteBudgetPerSecond = 4 * 1024 * 1024
    private var budgetWindowStart = Date()
    private var budgetSpent = 0

    /// Pump read buffer — 16 KB is a good balance between throughput on
    /// `cat large.txt` and latency for keystroke echo.
    private let readBufferSize = 16 * 1024

    private var activeSession: ActiveSession?

    /// Set by the environment; called whenever the service produces an
    /// outgoing envelope (output chunk or close notice).
    var sendEnvelope: ((DataChannelEnvelope) -> Void)?

    // MARK: - API

    /// Open or replace the terminal for `sessionID`. Idempotent: if a
    /// terminal is already running for this session, it's torn down first.
    func handleOpen(_ message: TerminalOpenMessage) {
        queue.async { [weak self] in
            self?._handleOpen(message)
        }
    }

    func handleInput(_ message: TerminalInputMessage) {
        queue.async { [weak self] in
            self?._handleInput(message)
        }
    }

    func handleResize(_ message: TerminalResizeMessage) {
        queue.async { [weak self] in
            self?._handleResize(message)
        }
    }

    func handleClose(_ message: TerminalCloseMessage) {
        queue.async { [weak self] in
            self?._teardown(reason: message.reason ?? "client-requested", notifyClient: false)
        }
    }

    /// Called by the coordinator when the session ends, the data channel
    /// drops, or the host pipeline resets. Kills the shell and cleans up.
    func sessionDidEnd() {
        queue.async { [weak self] in
            self?._teardown(reason: "session-ended", notifyClient: false)
        }
    }

    // MARK: - Internal (queue-isolated)

    private func _handleOpen(_ message: TerminalOpenMessage) {
        if let existing = activeSession {
            logger.info("Replacing existing terminal \(existing.terminalID.uuidString) on open")
            _teardown(reason: "replaced", notifyClient: true)
        }

        let cols = clampDimension(message.cols, fallback: 80)
        let rows = clampDimension(message.rows, fallback: 24)

        var master: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        let pid = c_forkpty(&master, nil, nil, &ws)
        if pid < 0 {
            let err = String(cString: strerror(errno))
            logger.error("forkpty failed: \(err)")
            sendCloseNotice(
                sessionID: message.sessionID,
                terminalID: message.terminalID,
                exitCode: nil,
                signal: nil,
                reason: "forkpty failed: \(err)"
            )
            return
        }

        if pid == 0 {
            // Child process — replace with the user's shell.
            execShellAndExit(term: message.term ?? "xterm-256color")
            // execShellAndExit never returns; defensive fallback below.
            _exit(127)
        }

        // Parent — record the session and start pumps.
        let session = ActiveSession(
            sessionID: message.sessionID,
            terminalID: message.terminalID,
            masterFD: master,
            childPID: pid,
            outputSequence: 0
        )
        activeSession = session
        logger.info("Spawned PTY shell pid=\(pid) for terminal \(message.terminalID.uuidString)")

        startReadPump(for: session)
        startReaperTask(for: session)
    }

    private func _handleInput(_ message: TerminalInputMessage) {
        guard let session = activeSession,
              session.sessionID == message.sessionID,
              session.terminalID == message.terminalID else {
            return
        }
        guard !message.data.isEmpty,
              message.data.count <= TerminalInputMessage.maxChunkBytes else {
            return
        }

        var remaining = message.data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(session.masterFD, base, raw.count)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }  // PTY buffer full; drop rest
                let err = String(cString: strerror(errno))
                logger.warning("write to PTY failed: \(err)")
                return
            }
            if written >= remaining.count { return }
            remaining = remaining.subdata(in: written..<remaining.count)
        }
    }

    private func _handleResize(_ message: TerminalResizeMessage) {
        guard let session = activeSession,
              session.sessionID == message.sessionID,
              session.terminalID == message.terminalID else {
            return
        }
        var ws = winsize(
            ws_row: clampDimension(message.rows, fallback: 24),
            ws_col: clampDimension(message.cols, fallback: 80),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(session.masterFD, TIOCSWINSZ, &ws) != 0 {
            let err = String(cString: strerror(errno))
            logger.warning("TIOCSWINSZ failed: \(err)")
        }
    }

    private func _teardown(reason: String, notifyClient: Bool) {
        guard let session = activeSession else { return }
        activeSession = nil

        session.readSource?.cancel()
        session.readSource = nil
        session.reaperTask?.cancel()

        // Try a clean shutdown first; escalate if it doesn't take.
        kill(session.childPID, SIGHUP)
        close(session.masterFD)

        if notifyClient {
            sendCloseNotice(
                sessionID: session.sessionID,
                terminalID: session.terminalID,
                exitCode: nil,
                signal: nil,
                reason: reason
            )
        }
        logger.info("Terminal \(session.terminalID.uuidString) torn down (\(reason))")
    }

    // MARK: - Read pump

    private func startReadPump(for session: ActiveSession) {
        let source = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: queue)
        session.readSource = source
        let bufferSize = readBufferSize

        source.setEventHandler { [weak self, weak session] in
            guard let self, let session, session === self.activeSession else { return }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                read(session.masterFD, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                self.dispatchOutput(Data(buffer.prefix(n)), session: session)
            } else if n == 0 {
                self.logger.info("PTY master EOF for terminal \(session.terminalID.uuidString)")
                self._teardown(reason: "eof", notifyClient: true)
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                let err = String(cString: strerror(errno))
                self.logger.warning("PTY read failed: \(err)")
                self._teardown(reason: "read-error: \(err)", notifyClient: true)
            }
        }
        source.setCancelHandler { /* fd closed by _teardown */ }
        source.resume()
    }

    private func dispatchOutput(_ data: Data, session: ActiveSession) {
        // Refill rate budget every 1 s.
        let now = Date()
        if now.timeIntervalSince(budgetWindowStart) >= 1.0 {
            budgetWindowStart = now
            budgetSpent = 0
        }
        guard budgetSpent < outputByteBudgetPerSecond else {
            // Already saturated this second — drop to protect the link.
            return
        }
        var chunk = data
        let headroom = outputByteBudgetPerSecond - budgetSpent
        if chunk.count > headroom {
            chunk = chunk.prefix(headroom)
        }
        budgetSpent += chunk.count

        // Split into envelope-sized pieces; the envelope cap is 1 MB but
        // staying well under that keeps RTC fragmentation predictable.
        let maxChunk = TerminalOutputMessage.maxChunkBytes
        var offset = 0
        while offset < chunk.count {
            let end = min(offset + maxChunk, chunk.count)
            session.outputSequence += 1
            let slice = chunk.subdata(in: offset..<end)
            let message = TerminalOutputMessage(
                sessionID: session.sessionID,
                terminalID: session.terminalID,
                data: slice,
                sequence: session.outputSequence
            )
            if let envelope = try? DataChannelEnvelope.terminalOutput(message) {
                sendEnvelope?(envelope)
            }
            offset = end
        }
    }

    // MARK: - Child reaper

    private func startReaperTask(for session: ActiveSession) {
        let pid = session.childPID
        let terminalID = session.terminalID
        let sessionID = session.sessionID
        let task = Task { [weak self] in
            // Poll waitpid; SIGCHLD handling in Swift is awkward and this loop
            // is cheap (sleep, single syscall).
            while !Task.isCancelled {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    guard let self else { return }
                    let (exitCode, signal) = self.decodeWaitStatus(status)
                    self.handleChildExit(
                        sessionID: sessionID,
                        terminalID: terminalID,
                        exitCode: exitCode,
                        signal: signal
                    )
                    return
                } else if result < 0 {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        session.reaperTask = task
    }

    private func handleChildExit(sessionID: UUID, terminalID: UUID, exitCode: Int32?, signal: Int32?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let session = self.activeSession,
                  session.sessionID == sessionID,
                  session.terminalID == terminalID else { return }
            self.logger.info("Child pid=\(session.childPID) exited (code=\(exitCode ?? -1), signal=\(signal ?? -1))")
            self.activeSession = nil
            session.readSource?.cancel()
            close(session.masterFD)
            self.sendCloseNotice(
                sessionID: sessionID,
                terminalID: terminalID,
                exitCode: exitCode,
                signal: signal,
                reason: "shell-exited"
            )
        }
    }

    private func sendCloseNotice(sessionID: UUID, terminalID: UUID, exitCode: Int32?, signal: Int32?, reason: String?) {
        let message = TerminalCloseMessage(
            sessionID: sessionID,
            terminalID: terminalID,
            exitCode: exitCode,
            signal: signal,
            reason: reason
        )
        if let envelope = try? DataChannelEnvelope.terminalClose(message) {
            sendEnvelope?(envelope)
        }
    }

    // MARK: - Child exec

    private func execShellAndExit(term: String) {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let home = env["HOME"] ?? NSHomeDirectory()

        // Build env with TERM forced to xterm-256color so curses-style apps
        // (vim/nano/htop/less) render correctly. Strip the variables we want
        // to override before reconstructing.
        var envDict = env
        envDict["TERM"] = term
        envDict["HOME"] = home
        envDict["LANG"] = envDict["LANG"] ?? "en_US.UTF-8"
        envDict["LC_ALL"] = envDict["LC_ALL"] ?? "en_US.UTF-8"

        var envStrings = envDict.map { "\($0.key)=\($0.value)" }
        envStrings.sort()
        var envCPtrs = envStrings.map { strdup($0) } as [UnsafeMutablePointer<CChar>?]
        envCPtrs.append(nil)

        // Argv: pass `-l` so the shell runs as a login shell and sources the
        // user's profile (.zprofile / .zshrc, .bash_profile / .bashrc, etc.).
        let argv0 = strdup("-" + (URL(fileURLWithPath: shell).lastPathComponent))
        let argvArr: [UnsafeMutablePointer<CChar>?] = [argv0, nil]

        // chdir to $HOME so the shell opens in a sensible place.
        _ = chdir(home)

        envCPtrs.withUnsafeBufferPointer { envBuf in
            argvArr.withUnsafeBufferPointer { argBuf in
                _ = execve(
                    shell,
                    UnsafeMutablePointer(mutating: argBuf.baseAddress),
                    UnsafeMutablePointer(mutating: envBuf.baseAddress)
                )
            }
        }
        // execve only returns on failure.
        perror("execve")
        _exit(127)
    }

    // MARK: - Helpers

    private func clampDimension(_ value: UInt16, fallback: UInt16) -> UInt16 {
        guard value > 0 else { return fallback }
        return min(value, 1000)
    }

    private func decodeWaitStatus(_ status: Int32) -> (exitCode: Int32?, signal: Int32?) {
        // WIFEXITED / WIFSIGNALED — open-coded because Swift doesn't import
        // the macros from <sys/wait.h>.
        let lowByte = status & 0x7f
        if lowByte == 0 {
            return ((status >> 8) & 0xff, nil)
        }
        if lowByte != 0x7f {
            return (nil, lowByte)
        }
        return (nil, nil)
    }

    private final class ActiveSession {
        let sessionID: UUID
        let terminalID: UUID
        let masterFD: Int32
        let childPID: pid_t
        var outputSequence: UInt64
        var readSource: DispatchSourceRead?
        var reaperTask: Task<Void, Never>?

        init(sessionID: UUID, terminalID: UUID, masterFD: Int32, childPID: pid_t, outputSequence: UInt64) {
            self.sessionID = sessionID
            self.terminalID = terminalID
            self.masterFD = masterFD
            self.childPID = childPID
            self.outputSequence = outputSequence
        }
    }
}
#endif
