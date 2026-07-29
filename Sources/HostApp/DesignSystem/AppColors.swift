import SwiftUI

/// Appearance-adaptive palette for the native, system-rendered dashboard.
enum AppColor {
    // Backgrounds — system window/control colors (adapt to light/dark).
    static let backgroundPrimary    = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary  = Color(nsColor: .underPageBackgroundColor)
    static let surface              = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated      = Color(nsColor: .controlBackgroundColor)
    static let glassSurface         = Color.primary.opacity(0.05)

    // Accent + status — system accent for primary, conventional semantics for status.
    static let mint     = Color.accentColor
    static let mintDim  = Color.accentColor.opacity(0.65)
    static let cyan     = Color.accentColor
    static let amber    = Color.orange
    static let red      = Color.red

    static let primaryAccent    = Color.accentColor
    static let secondaryAccent  = Color.accentColor
    static let relayAccent      = Color.orange
    static let lanAccent        = Color.green
    static let success          = Color.green
    static let warning          = Color.orange
    static let error            = Color.red
    static let disconnected     = Color.secondary

    static let textPrimary      = Color.primary
    static let textSecondary    = Color.secondary
    static let textTertiary     = Color.secondary.opacity(0.55)
    static let borderSubtle     = Color.primary.opacity(0.08)

    // Flat system accent retained for source compatibility with existing call sites.
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let card   = Color(nsColor: .controlBackgroundColor)
    static let cardHi = Color(nsColor: .controlBackgroundColor)
}

/// A neutral native material behind Host's glass surfaces. It intentionally has
/// no custom gradient or color bloom, so macOS provides the tint and contrast.
struct AppBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: Rectangle())
                .ignoresSafeArea()
        } else {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
    }
}
