import Combine
import Foundation

/// Owns the explicit Vamp Assistant connection flow. Vamp Assistant is deliberately not folded into Vamp
/// discovery: its one-time pairing code and bearer token belong to a separate HTTP protocol.
@MainActor
final class BeetCodeRemoteSessionViewModel: ObservableObject {
    struct Session {
        let client: BeetCodeRemoteClient
        let address: String
        let displayName: String
        let status: BeetCodeControlStatus
    }

    @Published private(set) var session: Session?
    @Published private(set) var savedAddress: String?
    @Published private(set) var isPairing = false
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let savedAddressKey = "vampstream.beetcode.savedAddress"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedAddress = defaults.string(forKey: savedAddressKey)
    }

    func pair(address: String, code: String) async {
        isPairing = true
        lastError = nil
        defer { isPairing = false }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: address, pairingCode: code)
            guard let pairingCode = endpoint.pairingCode else {
                throw BeetCodeRemoteError.invalidPairingCode
            }
            let pairingClient = BeetCodeRemoteClient(endpoint: endpoint)
            let response = try await pairingClient.pair(code: pairingCode)
            guard !response.token.isEmpty else { throw BeetCodeRemoteError.invalidResponse }

            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: response.token)
            let status = try await client.controlStatus()
            var tokenWasPersisted = true
            do {
                try BeetCodeTokenStore.save(response.token, for: endpoint.url)
            } catch {
                #if targetEnvironment(simulator)
                // Unsigned simulator builds can reject Keychain writes even though the
                // live session itself is valid. Keep this token memory-only for the test
                // session; never weaken the production device storage path.
                tokenWasPersisted = false
                #else
                throw error
                #endif
            }
        let displayName = response.product?.isEmpty == false ? response.product! : "Vamp Assistant Mac"
            if tokenWasPersisted {
                save(address: endpoint.url.absoluteString)
            }
            session = Session(
                client: client,
                address: endpoint.url.absoluteString,
                displayName: displayName,
                status: status)
        } catch {
            lastError = Self.userFacingConnectionError(error)
        }
    }

    func reconnectSaved() async {
        guard let savedAddress else {
            lastError = BeetCodeRemoteError.invalidAddress.localizedDescription
            return
        }
        isPairing = true
        lastError = nil
        defer { isPairing = false }

        do {
            let endpoint = try BeetCodeRemoteEndpoint.parse(address: savedAddress)
            guard let token = BeetCodeTokenStore.load(for: endpoint.url), !token.isEmpty else {
                throw BeetCodeRemoteError.notConnected
            }
            let client = BeetCodeRemoteClient(baseURL: endpoint.url, token: token)
            let status = try await client.controlStatus()
            session = Session(
                client: client,
                address: endpoint.url.absoluteString,
                displayName: "Vamp Assistant Mac",
                status: status)
        } catch {
            session = nil
            lastError = "Reconnect failed: \(Self.userFacingConnectionError(error))"
        }
    }

    func disconnect(clearSaved: Bool = false) {
        session = nil
        lastError = nil
        guard clearSaved, let savedAddress,
              let endpoint = try? BeetCodeRemoteEndpoint.parse(address: savedAddress) else { return }
        BeetCodeTokenStore.clear(for: endpoint.url)
        defaults.removeObject(forKey: savedAddressKey)
        self.savedAddress = nil
    }

    @discardableResult
    func refreshStatus() async -> String? {
        guard let session else { return BeetCodeRemoteError.notConnected.localizedDescription }
        do {
            let status = try await session.client.controlStatus()
            self.session = Session(
                client: session.client,
                address: session.address,
                displayName: session.displayName,
                status: status)
            lastError = nil
            return nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            return message
        }
    }

    private func save(address: String) {
        defaults.set(address, forKey: savedAddressKey)
        savedAddress = address
    }

    private static func userFacingConnectionError(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .appTransportSecurityRequiresSecureConnection:
            return "Vamp Stream could not open this private HTTP connection. Install the latest build and try the LAN or Tailscale address shown by Vamp Assistant."
        case .cannotConnectToHost, .cannotFindHost:
            return "Vamp Assistant could not be reached. Keep it open on the Mac and confirm the private address and port 9575."
        case .timedOut:
            return "Vamp Assistant did not respond in time. Check that both devices are on the same LAN or private Tailscale network."
        case .notConnectedToInternet, .networkConnectionLost:
            return "The private network connection was lost. Reconnect Wi-Fi or Tailscale, then try again."
        default:
            return error.localizedDescription
        }
    }
}
