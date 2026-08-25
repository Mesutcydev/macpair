import SwiftUI
import UIKit

/// Keeps the phone orientation aligned with the actual streamed window. A portrait Mac app should
/// stay portrait; a wide app should use landscape. This avoids forcing every target into a
/// landscape canvas and then displaying portrait content with large side bars.
final class VampStreamAppDelegate: NSObject, UIApplicationDelegate {
    static var lockLandscape = false

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        VampStreamAppDelegate.lockLandscape ? .landscape : .portrait
    }
}

enum StreamOrientation {
    static func set(aspect: Double?) {
        let landscape = (aspect ?? 0) >= 1.08
        VampStreamAppDelegate.lockLandscape = landscape
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
