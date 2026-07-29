import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle in-app updater for the Developer-ID (website) build, mirroring the
/// host's `HostUpdaterController`. The feed + signing key live in
/// `MacClient-Info.plist` (`SUFeedURL` / `SUPublicEDKey`); this just owns the
/// updater and exposes a "Check for Updates…" action.
///
/// Compiles to a no-op when Sparkle is not linked, so the rest of the app is
/// unaffected.
@MainActor
final class MacUpdaterController: NSObject, ObservableObject {
    static let shared = MacUpdaterController()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private override init() {
        super.init()
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
        #endif
    }
}
