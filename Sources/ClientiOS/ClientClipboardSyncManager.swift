import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SharedProtocol
import TransportWebRTC

/// Manages bidirectional clipboard sync between this Mac and the paired Mac host.
/// All operations are explicit/user-triggered — no background polling or auto-sync.
@MainActor
final class ClientClipboardSyncManager: ObservableObject {

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedText: String?

    // Set by the view when a session is active.
    var sessionID: UUID?
    var sendEnvelope: ((DataChannelEnvelope) throws -> Void)?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "client.clipboard.enabled") as? Bool ?? true
    }

    // MARK: - Incoming (host → client)

    /// Called by ClientSessionCoordinator when a clipboardSync arrives from the host.
    func receive(_ message: ClipboardSyncMessage) {
        guard isEnabled,
              message.source == "host",
              !message.text.isEmpty else { return }
        ClipboardBridge.setString(message.text)
        lastSyncedText = message.text
    }

    // MARK: - Outgoing (client → host)

    /// Push the client Mac's current clipboard text to the host.
    func pushToHost() {
        guard isEnabled,
              let sessionID, let sendEnvelope,
              let text = ClipboardBridge.string, !text.isEmpty else { return }
        let message = ClipboardSyncMessage(sessionID: sessionID, text: text, source: "client")
        guard let envelope = try? DataChannelEnvelope.clipboardSync(message) else { return }
        try? sendEnvelope(envelope)
    }

    /// Ask the host to push its current clipboard to us.
    func requestFromHost() {
        guard isEnabled, let sessionID, let sendEnvelope else { return }
        isSyncing = true
        let message = ClipboardRequestMessage(sessionID: sessionID)
        guard let envelope = try? DataChannelEnvelope.clipboardRequest(message) else {
            isSyncing = false
            return
        }
        try? sendEnvelope(envelope)
        // Reset syncing flag after a short window — host reply clears it via receive(_:).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            isSyncing = false
        }
    }

    // MARK: - Session lifecycle

    func activate(sessionID: UUID, send: @escaping (DataChannelEnvelope) throws -> Void) {
        self.sessionID = sessionID
        self.sendEnvelope = send
        lastSyncedText = nil
    }

    func deactivate() {
        sessionID = nil
        sendEnvelope = nil
        isSyncing = false
        lastSyncedText = nil
    }
}

private enum ClipboardBridge {
    static var string: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }

    static func setString(_ newValue: String?) {
        #if canImport(UIKit)
        UIPasteboard.general.string = newValue
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        if let newValue {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(newValue, forType: .string)
        }
        #endif
    }
}
