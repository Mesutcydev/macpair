import SwiftUI

struct VampStreamHostSourceOnboarding: View {
    let onContinue: (VampStreamHostSource) -> Void
    @State private var draft: VampStreamHostSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(VampStreamHomeCopy.hostOnboardingTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PR.fg)
                Text(VampStreamHomeCopy.hostOnboardingDetail)
                    .font(.subheadline)
                    .foregroundStyle(PR.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VampStreamHostSourceOptions(selection: $draft)

            if let draft {
                VampAssistantActionButton(
                    title: LocalizedStringKey(VampStreamHomeCopy.hostOnboardingContinue),
                    systemImage: "arrow.right",
                    action: { onContinue(draft) }
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct VampStreamHostSourcePickerSheet: View {
    let current: VampStreamHostSource
    let onSelect: (VampStreamHostSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VampStreamHostSource?

    init(current: VampStreamHostSource, onSelect: @escaping (VampStreamHostSource) -> Void) {
        self.current = current
        self.onSelect = onSelect
        _draft = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VampStreamHostSourceOptions(selection: $draft)
                    .padding(18)
            }
            .navigationTitle(VampStreamHomeCopy.changeHost)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let draft {
                            onSelect(draft)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct VampStreamHostSourceOptions: View {
    @Binding var selection: VampStreamHostSource?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(VampStreamHostSource.allCases) { source in
                Button {
                    selection = source
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: source.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PR.fg)
                            .frame(width: 38, height: 38)
                            .prGlassSurface(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.title)
                                .font(.headline)
                                .foregroundStyle(PR.fg)
                            Text(source.detail)
                                .font(.footnote)
                                .foregroundStyle(PR.fg2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: selection == source ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(PR.fg)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vampHomeLiveGlass(
                        in: RoundedRectangle(cornerRadius: PR.r12, style: .continuous),
                        phaseOffset: source == .sync ? 0.2 : (source == .assistant ? 0.9 : 1.6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: PR.r12, style: .continuous)
                            .strokeBorder(selection == source ? PR.fg.opacity(0.28) : Color.clear, lineWidth: 1.5)
                    }
                }
                .buttonStyle(PRGlassPressButtonStyle())
                .accessibilityAddTraits(selection == source ? [.isSelected] : [])
                .accessibilityLabel(source.title)
                .accessibilityHint(source.detail)
            }
        }
    }
}
