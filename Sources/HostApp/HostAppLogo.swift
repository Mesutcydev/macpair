import SwiftUI
#if os(macOS)
import AppKit

// MARK: - Menu Bar Template Icon

/// Returns a template NSImage for use in the macOS menu bar tray.
/// Draws a rounded square with a bold "m" letterform cut through it,
/// matching the app icon. Template images adapt automatically to
/// light/dark mode and menu-bar accent color.
func makeMenuBarTemplateIcon(size: CGFloat = 18) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

        let radius = rect.width * 0.22
        let inset  = rect.insetBy(dx: 0.5, dy: 0.5)

        // 1. Fill the rounded square background (black = opaque in template).
        let bgPath = CGPath(
            roundedRect: inset,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(bgPath)
        ctx.fillPath()

        // 2. Punch out the letter "m" using destination-out blending so those
        //    pixels become transparent — the system renders the gap as the
        //    background (invisible in the tray), giving the appearance of the
        //    app icon design (black bg, white/clear letter).
        let fontSize = size * 0.52
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: NSColor.black
        ]
        let str = NSAttributedString(string: "m", attributes: attrs)
        let strSize = str.size()
        let strOrigin = CGPoint(
            x: (rect.width  - strSize.width)  / 2,
            y: (rect.height - strSize.height) / 2 + 0.5
        )
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        str.draw(at: strOrigin)
        ctx.restoreGState()

        return true
    }
    image.isTemplate = true
    return image
}

#endif

// MARK: - App Logo View

/// Colored rounded-square logo used in the sidebar header and other surfaces.
/// Replicates the app-icon design: black background with a white bold "m".
struct HostAppLogo: View {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)

            Text("m")
                .font(.system(size: size * 0.55, weight: .bold, design: .default))
                .foregroundStyle(Color.white)
                .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HStack(spacing: 16) {
        HostAppLogo(size: 20, cornerRadius: 5)
        HostAppLogo(size: 28, cornerRadius: 8)
        HostAppLogo(size: 44, cornerRadius: 12)
        HostAppLogo(size: 64, cornerRadius: 16)
    }
    .padding()
}
#endif
