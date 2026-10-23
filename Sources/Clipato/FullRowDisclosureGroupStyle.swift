import SwiftUI

struct FullRowDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.consoleFontScale) private var fontScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .consoleFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12 * max(1, fontScale))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28 * max(1, fontScale), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .environment(\.isFocusEffectEnabled, true)
            .accessibilityValue(Text(configuration.isExpanded ? L("已展开") : L("已折叠")))

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
