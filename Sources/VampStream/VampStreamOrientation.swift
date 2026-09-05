import SwiftUI
import UIKit

/// App streams follow device rotation; the app picker stays portrait.
/// The separate whole-display viewer retains its existing aspect-based orientation.
final class VampStreamAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        VampStreamAppDelegate.orientationMask
    }
}

enum StreamOrientation {
    static func set(aspect: Double?, adaptive: Bool = false) {
        let mask: UIInterfaceOrientationMask = adaptive && aspect != nil
            ? .allButUpsideDown : ((aspect ?? 0) >= 1.08 ? .landscape : .portrait)
        guard VampStreamAppDelegate.orientationMask != mask else { return }
        VampStreamAppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
