import SwiftUI

/// Featured download card on Stream's connect home. The whole surface opens
/// the latest Vamp Sync build, resolving the current DMG at tap time.
struct VampStreamSyncPromoCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var opening = false

    var body: some View {
        Button {
            Task { await openLatestSync() }
        } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(VampStreamHomeCopy.syncPromoEyebrow)
                            .font(.caption.weight(.semibold))
                            .tracking(1.1)
                            .foregroundStyle(PR.dim)
                        Text(VampStreamHomeCopy.syncPromoTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PR.fg)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(VampStreamHomeCopy.syncPromoDetail)
                            .font(.footnote)
                            .foregroundStyle(PR.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text(VampStreamHomeCopy.syncPromoCTA)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PR.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .prGlassSurface(
                        in: Capsule(style: .continuous),
                        isInteractive: true
                    )
                }

                VampStreamWindowFangsMark()
                    .fill(PR.fg, style: FillStyle(eoFill: true))
                    .opacity(colorScheme == .dark ? 0.28 : 0.16)
                    .frame(width: 78, height: 86)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vampHomeLiveGlass(
                in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                phaseOffset: 2.8
            )
        }
        .buttonStyle(PRGlassPressButtonStyle())
        .disabled(opening)
        .accessibilityLabel(Text(VampStreamHomeCopy.syncPromoTitle))
        .accessibilityHint(Text(VampStreamHomeCopy.syncPromoHint))
        .accessibilityAddTraits(.isLink)
    }

    @MainActor
    private func openLatestSync() async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        openURL(await VampStreamReleaseDownloads.latestSyncDownload())
    }
}

/// Rounded window with two fang notches. A silhouette only — Stream's glass
/// home never places the full-color landscape mark inside a card.
struct VampStreamWindowFangsMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let frame = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.08)
        let radius = min(frame.width, frame.height) * 0.14
        let line = max(1.7, min(frame.width, frame.height) * 0.08)

        path.addRoundedRect(in: frame, cornerSize: CGSize(width: radius, height: radius))

        let hole = frame.insetBy(dx: line, dy: line)
        let holeRadius = max(1, radius - line * 0.55)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: holeRadius, height: holeRadius))

        let barHeight = max(1.4, line * 0.7)
        path.addRect(CGRect(x: hole.minX, y: hole.minY, width: hole.width, height: barHeight))

        let fangWidth = frame.width * 0.15
        let fangHeight = rect.height * 0.14
        let baseY = frame.maxY - line * 0.12
        for centerX in [frame.midX - fangWidth * 0.72, frame.midX + fangWidth * 0.72] {
            path.move(to: CGPoint(x: centerX - fangWidth * 0.5, y: baseY))
            path.addLine(to: CGPoint(x: centerX, y: baseY + fangHeight))
            path.addLine(to: CGPoint(x: centerX + fangWidth * 0.5, y: baseY))
            path.closeSubpath()
        }
        return path
    }
}
