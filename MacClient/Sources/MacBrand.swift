import SwiftUI

/// Neutral, appearance-adaptive design tokens for the Mac client.
///
/// Reskinned to match the host's native macOS redesign: the app follows the
/// system appearance (light/dark) and uses the user's system accent color
/// rather than a fixed brand color. Tokens map to system colors so everything
/// adapts for free.
enum MacBrand {
    static let accent = Color.accentColor

    /// Neutral adaptive page backdrop — the native window background, no wash.
    static var pageBackdrop: some View {
        MacWindowBackdrop()
    }

    static let cardCornerRadius: CGFloat = 12
}

/// A colorless, system-rendered window surface. With the AppKit window kept
/// transparent this gives Liquid Glass real desktop pixels to refract.
private struct MacWindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        } else if #available(macOS 26.0, *) {
            // Use the neutral clear variant directly. A material fill here
            // would frost the whole window gray before child glass surfaces
            // can sample it, which makes otherwise-clear cards look tinted.
            Color.clear
                .glassEffect(.clear, in: Rectangle())
                .ignoresSafeArea()
        } else {
            // Older systems do not expose Liquid Glass. Keep the native live
            // material fallback rather than approximating it with a color.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
    }
}

private struct MacGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let isInteractive: Bool
    let role: MacGlassSurfaceRole

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .glassEffect(nativeGlass, in: shape)
                        .allowsHitTesting(false)
                }
            }
        } else {
            if role == .content {
                content.background(.thinMaterial, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        // Chrome can stay highly transparent, while information-bearing rows
        // need Apple's denser neutral glass to remain legible over busy desktop
        // content. Neither variant applies a tint.
        let glass: Glass = role == .content ? .regular : .clear
        return glass.interactive(isInteractive)
    }
}

private enum MacGlassSurfaceRole {
    case chrome
    case content
}

extension View {
    /// Native, colorless Liquid Glass. The effect is rendered in a geometry-
    /// locked background so it never steals the first click from its controls.
    func macGlassSurface<S: InsettableShape>(
        in shape: S,
        isInteractive: Bool = false,
        contentLegibility: Bool = false
    ) -> some View {
        modifier(
            MacGlassSurfaceModifier(
                shape: shape,
                isInteractive: isInteractive,
                role: contentLegibility ? .content : .chrome
            )
        )
    }

    /// High-contrast session chrome that stays readable over bright remote video.
    func sessionControlSurface<S: InsettableShape>(in shape: S) -> some View {
        self
            .macGlassSurface(in: shape, isInteractive: true, contentLegibility: true)
            .background {
                shape.fill(.black.opacity(0.42))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
    }
}

/// A reusable native glass card shared by the hosts and connection screens.
struct BrandCard<Content: View>: View {
    var hovering: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .macGlassSurface(
                in: RoundedRectangle(cornerRadius: MacBrand.cardCornerRadius, style: .continuous),
                isInteractive: true,
                contentLegibility: true
            )
            .brightness(hovering ? 0.025 : 0)
    }
}
