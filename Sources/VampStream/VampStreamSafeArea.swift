import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Stream surfaces deliberately ignore the safe area so the video is full-bleed, which zeroes the
/// insets a `GeometryReader` inside them reports. The chrome floating on top still has to clear the
/// notch once the phone is rotated into landscape, so read the real insets from the key window —
/// the same approach `MirrorScreen`'s `deviceSafeAreaInsets` takes for its overlays.
enum VampStreamSafeArea {
    static var current: EdgeInsets {
#if canImport(UIKit) && !os(macOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        if let insets = window?.safeAreaInsets {
            return EdgeInsets(top: insets.top, leading: insets.left,
                              bottom: insets.bottom, trailing: insets.right)
        }
#endif
        return EdgeInsets()
    }
}
