import SwiftUI

struct PRCard<Content: View, Trailing: View>: View {
    let title: LocalizedStringKey?
    let trailing: Trailing
    let padded: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ title: LocalizedStringKey? = nil,
        padded: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing()
        self.padded = padded
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    (Text(verbatim: "// ") + Text(title))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundColor(PR.accent)
                    Spacer()
                    trailing
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(PR.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().overlay(PR.border)
            }

            content()
                .padding(padded ? 14 : 0)
        }
        .prGlassSurface(in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous))
    }
}

#Preview("PRCard") {
    VStack(spacing: 12) {
        PRCard("session", trailing: { Text("+ scan") }) {
            Text("content")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(PR.fg)
        }
    }
    .padding()
    .background(PR.bg)
}
