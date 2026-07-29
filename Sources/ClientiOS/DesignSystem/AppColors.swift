import Foundation
import SwiftUI

enum AppColor {
    static let backgroundPrimary = Color(red: 0.965, green: 0.975, blue: 0.995)
    static let backgroundSecondary = Color(red: 0.925, green: 0.945, blue: 0.985)
    static let surface = Color.white.opacity(0.58)
    static let surfaceElevated = Color.white.opacity(0.72)
    static let glassSurface = Color.white.opacity(0.34)
    static let primaryAccent = Color(red: 0.18, green: 0.48, blue: 1.0)
    static let secondaryAccent = Color(red: 0.38, green: 0.80, blue: 1.0)
    static let relayAccent = Color(red: 0.50, green: 0.38, blue: 1.0)
    static let lanAccent = Color(red: 0.10, green: 0.70, blue: 0.55)
    static let success = Color(red: 0.18, green: 0.70, blue: 0.34)
    static let warning = Color(red: 0.96, green: 0.62, blue: 0.16)
    static let error = Color(red: 0.94, green: 0.22, blue: 0.22)
    static let disconnected = Color.secondary
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.72)
    static let borderSubtle = Color.white.opacity(0.46)

    static let accentGradient = LinearGradient(
        colors: [primaryAccent, secondaryAccent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let commandGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.48, blue: 1.0),
            Color(red: 0.50, green: 0.36, blue: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum HostNameColor {
    /// Deterministic vivid text color per host UUID.
    static func color(for id: UUID) -> Color {
        let key = id.uuidString.lowercased()
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.72, brightness: 0.96)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppColor.backgroundPrimary,
                    AppColor.backgroundSecondary,
                    Color.white.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppColor.primaryAccent.opacity(0.14))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 130, y: -260)

            Circle()
                .fill(AppColor.relayAccent.opacity(0.10))
                .frame(width: 250, height: 250)
                .blur(radius: 70)
                .offset(x: -140, y: -160)

            Circle()
                .fill(AppColor.lanAccent.opacity(0.08))
                .frame(width: 280, height: 280)
                .blur(radius: 76)
                .offset(x: -160, y: 240)
        }
    }
}
