import SwiftUI
import UIKit

/// Only a live stream rotates. The connect screen and the app pickers are portrait designs and
/// stay portrait; once a Mac window is on screen the phone is free to turn either way, and opening
/// the stream suggests the orientation that matches the window's shape.
final class VampStreamAppDelegate: NSObject, UIApplicationDelegate {
    static var isStreaming = false

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        StreamOrientation.supportedOrientations(isStreaming: VampStreamAppDelegate.isStreaming)
    }
}

enum StreamOrientation {
    /// Portrait everywhere except a live stream, which may be held either way round.
    static func supportedOrientations(isStreaming: Bool) -> UIInterfaceOrientationMask {
        isStreaming ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    /// The orientation a freshly opened stream should start in, or nil when there is nothing to
    /// suggest (a window whose shape is close enough to square to leave alone).
    static func preferredOrientation(aspect: Double?) -> UIInterfaceOrientationMask? {
        guard let aspect, aspect > 0, aspect.isFinite else { return nil }
        if aspect >= 1.08 { return .landscapeRight }
        if aspect <= 0.93 { return .portrait }
        return nil
    }

    /// `aspect` is the streamed window's width/height, or nil when no stream is running — which
    /// also returns the app to portrait so the pickers are never left sideways.
    static func set(aspect: Double?) {
        VampStreamAppDelegate.isStreaming = aspect != nil
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let mask = aspect == nil ? .portrait : preferredOrientation(aspect: aspect)
        if let mask {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
