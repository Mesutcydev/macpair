#if os(macOS)
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
public final class HostUpdaterController: NSObject, ObservableObject {
    public static let shared = HostUpdaterController()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private override init() {
        super.init()
        #if canImport(Sparkle)
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    public var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    public func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
        #endif
    }
}
#endif
