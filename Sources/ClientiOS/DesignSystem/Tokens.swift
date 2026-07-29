import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum PR {
    static let bg = Color.dynamic(light: 0xF4F7F9, dark: 0x0B0D0E)
    static let bg2 = Color.dynamic(light: 0xECF1F5, dark: 0x0F1214)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x15191D)
    static let cardHi = Color.dynamic(light: 0xF8FBFD, dark: 0x1A1F24)

    static let border = Color.dynamic(light: 0xD3DBE4, dark: 0xFFFFFF, lightAlpha: 0.90, darkAlpha: 0.08)
    static let borderHi = Color.dynamic(light: 0xBBC8D6, dark: 0xFFFFFF, lightAlpha: 0.95, darkAlpha: 0.14)

    static let fg = Color.dynamic(light: 0x0F1722, dark: 0xE6EAEE)
    static let fg2 = Color.dynamic(light: 0x3F4F62, dark: 0xA8B0BA)
    static let dim = Color.dynamic(light: 0x607080, dark: 0x6B7480)

    static let accent = Color.dynamic(light: 0x159A73, dark: 0x22D3A1)
    static let accent2 = Color.dynamic(light: 0x187EA9, dark: 0x7DD3FC)
    static let warn = Color.dynamic(light: 0xA56D1B, dark: 0xF4C674)
    static let err = Color.dynamic(light: 0xC44343, dark: 0xF87171)

    static let r6: CGFloat = 6
    static let r8: CGFloat = 8
    static let r12: CGFloat = 12
}

/// A restrained, neutral canvas behind every system-rendered glass surface.
///
/// Clear Liquid Glass needs real spatial detail behind it to refract. The grid
/// and broad luminance fields are backdrop content only: cards remain untinted
/// `.clear` system glass and Apple owns their blur, refraction, edge light, and
/// scrolling response.
struct PRAppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
#if canImport(UIKit)
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            if !reduceTransparency {
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemGroupedBackground),
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .opacity(colorScheme == .dark ? 0.40 : 0.34),
                        Color(uiColor: .systemGroupedBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.075 : 0.42),
                                Color.white.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 230
                        )
                    )
                    .frame(width: 500, height: 410)
                    .blur(radius: 38)
                    .offset(x: 155, y: -235)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(colorScheme == .dark ? 0.20 : 0.055),
                                Color.black.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 245
                        )
                    )
                    .frame(width: 520, height: 430)
                    .blur(radius: 44)
                    .offset(x: -180, y: 235)

                PRBackdropGrid()

                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.025 : 0.075),
                        Color.clear,
                        Color.black.opacity(colorScheme == .dark ? 0.075 : 0.022)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
#else
        PR.bg.ignoresSafeArea()
#endif
    }
}

/// Fine neutral detail for the native material to sample as it moves.
/// This is deliberately background artwork, never a simulated glass overlay.
private struct PRBackdropGrid: View {
    @Environment(\.colorScheme) private var colorScheme

    private let spacing: CGFloat = 26
    private let majorInterval = 4

    var body: some View {
        Canvas { context, size in
            var minorLines = Path()
            var majorLines = Path()

            addLines(
                through: size.width,
                crossAxisLength: size.height,
                vertical: true,
                minorPath: &minorLines,
                majorPath: &majorLines
            )
            addLines(
                through: size.height,
                crossAxisLength: size.width,
                vertical: false,
                minorPath: &minorLines,
                majorPath: &majorLines
            )

            context.stroke(
                minorLines,
                with: .color(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.045)),
                lineWidth: 0.5
            )
            context.stroke(
                majorLines,
                with: .color(Color.primary.opacity(colorScheme == .dark ? 0.105 : 0.078)),
                lineWidth: 0.75
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func addLines(
        through length: CGFloat,
        crossAxisLength: CGFloat,
        vertical: Bool,
        minorPath: inout Path,
        majorPath: inout Path
    ) {
        let count = Int(ceil(length / spacing))

        for index in 0...count {
            let position = CGFloat(index) * spacing + 0.25
            let isMajor = index.isMultiple(of: majorInterval)

            if vertical {
                if isMajor {
                    majorPath.move(to: CGPoint(x: position, y: 0))
                    majorPath.addLine(to: CGPoint(x: position, y: crossAxisLength))
                } else {
                    minorPath.move(to: CGPoint(x: position, y: 0))
                    minorPath.addLine(to: CGPoint(x: position, y: crossAxisLength))
                }
            } else if isMajor {
                majorPath.move(to: CGPoint(x: 0, y: position))
                majorPath.addLine(to: CGPoint(x: crossAxisLength, y: position))
            } else {
                minorPath.move(to: CGPoint(x: 0, y: position))
                minorPath.addLine(to: CGPoint(x: crossAxisLength, y: position))
            }
        }
    }
}

extension View {
    /// Native, colorless Liquid Glass on current iOS, with a live material
    /// fallback on earlier releases. The material is geometry-locked behind
    /// the foreground so buttons keep their original first-touch hit target.
    ///
    @ViewBuilder
    func prGlassSurface<S: InsettableShape>(
        in shape: S,
        isInteractive: Bool = false
    ) -> some View {
#if os(iOS)
        if #available(iOS 26.0, *) {
            self.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(
                            prNativeGlass(isInteractive: isInteractive),
                            in: shape
                        )
                }
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
        }
#else
        self
            .background(.ultraThinMaterial, in: shape)
#endif
    }

}

#if os(iOS)
@available(iOS 26.0, *)
private func prNativeGlass(isInteractive: Bool) -> Glass {
    // Apple's high-transparency, neutral Liquid Glass variant. It remains
    // colorless because no tint is supplied, while the system still owns its
    // blur, refraction, edge light, and interactive response.
    var glass: Glass = .clear
    if isInteractive {
        glass = glass.interactive()
    }
    return glass
}
#endif

struct PRGlassPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
#if canImport(UIKit)
        Color(
            UIColor { traits in
                if traits.userInterfaceStyle == .dark {
                    return UIColor(hex: dark, alpha: darkAlpha)
                }
                return UIColor(hex: light, alpha: lightAlpha)
            }
        )
#else
        Color(hex: dark, alpha: darkAlpha)
#endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif

#Preview("PR Tokens") {
    VStack(spacing: 12) {
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.bg)
            .frame(height: 44)
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.card)
            .frame(height: 44)
        RoundedRectangle(cornerRadius: PR.r8)
            .fill(PR.accent)
            .frame(height: 44)
    }
    .padding()
    .background(PR.bg2)
}
