import Combine
import Foundation
import os
import SharedModels
import SharedProtocol
import SharedUtilities
import TransportWebRTC
#if canImport(UIKit)
import QuartzCore
import UIKit
#endif

/// Vamp Stream's input controller. Its wire path deliberately matches Vamp Control:
/// authenticated `sendInputCommand`, one ordered sender, and display-refresh coalescing for
/// pointer/scroll motion. The streamed window is represented as a synthetic single display so
/// the shared viewport mapper handles letterboxing and global-window coordinates consistently.
@MainActor
final class AppStreamInputController: ObservableObject {
    private let webRTC: any WebRTCSessionManaging
    private let logger = Logger(subsystem: "com.mesutcy.remotedesktop.stream", category: "Input")

    @Published private(set) var lastError: String?
    private(set) var commandsSent: UInt64 = 0
    private(set) var dragLocked = false
    var sessionID: UUID?

    private var interpreter: GestureInterpreter?
    private var window: DisplayDescriptor?
    private var viewSize: DesktopSize = .zero

    // Ordered sender, copied in spirit from RemoteInteractionViewModel. Directly calling
    // sendDataMessage for every UIKit sample can overtake clicks/key events and silently drops
    // failures; this queue keeps all input serialized and observable.
    private var sendContinuation: AsyncStream<InputCommandMessage>.Continuation?
    private var senderTask: Task<Void, Never>?
    private var pendingMove: PointerMoveCommand?
    private var pendingScrollDX: Double = 0
    private var pendingScrollDY: Double = 0
    private var hasPendingScroll = false
    private var lastPointerPoint: DesktopPoint?
    #if canImport(UIKit)
    private var flushLink: CADisplayLink?
    #endif

    init(webRTC: any WebRTCSessionManaging) {
        self.webRTC = webRTC
    }

    deinit {
        #if canImport(UIKit)
        flushLink?.invalidate()
        #endif
        sendContinuation?.finish()
        senderTask?.cancel()
    }

    /// The streamed window, as a synthetic display (id = window id, point size, Retina scale).
    func setWindow(_ descriptor: DisplayDescriptor) {
        window = descriptor
        rebuild()
    }

    func setViewSize(_ size: DesktopSize) {
        guard size != viewSize else { return }
        viewSize = size
        rebuild()
    }

    func stop() {
        // A drag-lock is a real mouse-down on the Mac. Always release it before the
        // view goes away; otherwise a disconnect/navigation can leave the host button held.
        if dragLocked {
            if let interpreter, let lastPointerPoint {
                send(interpreter.dragLockEnd(at: lastPointerPoint))
            }
            dragLocked = false
        }
        flushPending()
        #if canImport(UIKit)
        flushLink?.invalidate()
        flushLink = nil
        #endif
        pendingMove = nil
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
        lastPointerPoint = nil
        sessionID = nil
        interpreter = nil
        window = nil

        // Finish the old bounded queue after the release command has been yielded. Do not
        // cancel its task here: cancellation between the mouse-up and the network send can
        // leave the Mac button logically held. A later stream creates a fresh queue.
        sendContinuation?.finish()
        sendContinuation = nil
        senderTask = nil
    }

    private func rebuild() {
        guard let window, viewSize.width > 0, viewSize.height > 0 else {
            interpreter = nil
            return
        }
        let mapper = ViewportCoordinateMapper(
            display: window,
            viewSize: viewSize,
            displayMode: .fitDisplay,
            interactionMode: .absolute
        )
        interpreter = GestureInterpreter(displayID: window.id, mapper: mapper)
    }

    // MARK: - Gestures → input

    func tap(at point: DesktopPoint) { send(interpreter?.tap(at: point)) }
    func doubleTap(at point: DesktopPoint) { send(interpreter?.doubleTap(at: point)) }
    func rightClick(at point: DesktopPoint) { send(interpreter?.twoFingerTap(at: point)) }
    func middleClick(at point: DesktopPoint) { send(interpreter?.threeFingerTap(at: point)) }

    /// One-finger movement matches Vamp Control: it moves the pointer, but does not press the
    /// mouse button. A long press toggles drag-lock for explicit drag/select operations.
    func pointerMoved(at point: DesktopPoint) {
        lastPointerPoint = point
        send(interpreter?.drag(translation: .zero, currentViewPoint: point))
    }

    func pointerEnded() {
        flushPending()
    }

    func toggleDragLock(at point: DesktopPoint) {
        guard let interpreter else { return }
        lastPointerPoint = point
        if dragLocked {
            send(interpreter.dragLockEnd(at: point))
        } else {
            send(interpreter.dragLockBegin(at: point))
        }
        dragLocked.toggle()
    }

    func scroll(deltaX: Double, deltaY: Double) {
        send(interpreter?.scroll(deltaX: deltaX, deltaY: deltaY))
    }

    /// Pointer/hover deltas are relative, like Vamp Control's mouse/hover path.
    func relativePointerMove(deltaX: Double, deltaY: Double) {
        guard let displayID = window?.id else { return }
        route(.pointerMove(PointerMoveCommand(
            location: DesktopPoint(x: deltaX, y: deltaY),
            displayID: displayID,
            isAbsolute: false
        )))
    }

    // MARK: - Keyboard

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        send(interpreter?.textInput(text))
    }

    func sendKey(_ keyCode: UInt16, action: KeyAction, modifiers: KeyboardModifierFlags = []) {
        send(interpreter?.keyPress(keyCode: keyCode, action: action, modifiers: modifiers))
    }

    /// Full key press (down + up), e.g. Return (36), Delete (51), Tab (48), Escape (53).
    func pressKey(_ keyCode: UInt16, modifiers: KeyboardModifierFlags = []) {
        send(interpreter?.keyPress(keyCode: keyCode, action: .down, modifiers: modifiers))
        send(interpreter?.keyPress(keyCode: keyCode, action: .up, modifiers: modifiers))
    }

    // MARK: - Ordered send path

    private func send(_ command: InputCommand?) {
        guard let command else { return }
        route(command)
    }

    private func route(_ command: InputCommand) {
        switch command {
        case .pointerMove(let move):
            coalesceMove(move)
        case .scroll(let scroll):
            coalesceScroll(dx: scroll.deltaX, dy: scroll.deltaY)
        default:
            flushPending()
            enqueue(command)
        }
    }

    private func coalesceMove(_ move: PointerMoveCommand) {
        if move.isAbsolute {
            if pendingMove?.isAbsolute == false { flushPendingMove() }
            pendingMove = move
        } else if let pendingMove,
                  !pendingMove.isAbsolute,
                  pendingMove.displayID == move.displayID {
            self.pendingMove = PointerMoveCommand(
                location: DesktopPoint(
                    x: pendingMove.location.x + move.location.x,
                    y: pendingMove.location.y + move.location.y
                ),
                displayID: pendingMove.displayID,
                isAbsolute: false
            )
        } else {
            if pendingMove?.isAbsolute == true { flushPendingMove() }
            pendingMove = move
        }
        ensureFlushLink()
    }

    private func coalesceScroll(dx: Double, dy: Double) {
        pendingScrollDX += dx
        pendingScrollDY += dy
        hasPendingScroll = true
        ensureFlushLink()
    }

    private func flushPendingMove() {
        if let move = pendingMove {
            enqueue(.pointerMove(move))
            pendingMove = nil
        }
    }

    private func flushPendingScroll() {
        guard hasPendingScroll else { return }
        enqueue(.scroll(ScrollCommand(
            deltaX: pendingScrollDX,
            deltaY: pendingScrollDY,
            isPrecise: true
        )))
        pendingScrollDX = 0
        pendingScrollDY = 0
        hasPendingScroll = false
    }

    private func flushPending() {
        flushPendingMove()
        flushPendingScroll()
        #if canImport(UIKit)
        // The display link is demand-driven. Leaving it attached after the queue is
        // empty wastes a frame callback for the rest of the session.
        guard pendingMove == nil, !hasPendingScroll else { return }
        flushLink?.invalidate()
        flushLink = nil
        #endif
    }

    private func ensureFlushLink() {
        #if canImport(UIKit)
        guard flushLink == nil else { return }
        let link = CADisplayLink(
            target: AppStreamDisplayLinkProxy { [weak self] in self?.flushPending() },
            selector: #selector(AppStreamDisplayLinkProxy.tick)
        )
        link.add(to: .main, forMode: .common)
        flushLink = link
        #else
        flushPending()
        #endif
    }

    private func enqueue(_ command: InputCommand) {
        guard let sessionID else { return }
        startSenderIfNeeded()
        sendContinuation?.yield(InputCommandMessage(sessionID: sessionID, command: command))
    }

    private func startSenderIfNeeded() {
        guard senderTask == nil else { return }
        let stream = AsyncStream<InputCommandMessage>(bufferingPolicy: .bufferingNewest(128)) { continuation in
            sendContinuation = continuation
        }
        senderTask = Task { [weak self] in
            for await message in stream {
                guard let self else { break }
                do {
                    try await webRTC.sendInputCommand(message)
                    commandsSent &+= 1
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                    logger.error("Input send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

#if canImport(UIKit)
private final class AppStreamDisplayLinkProxy {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}
#endif
