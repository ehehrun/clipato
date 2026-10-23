import SwiftUI

extension View {
    func menuLabel(minimumWidth: CGFloat = 72, padding: CGFloat = 8) -> some View {
        modifier(MenuLabelLayout(minimumWidth: minimumWidth, padding: padding))
    }
}

private struct MenuLabelLayout: ViewModifier {
    @Environment(\.consoleFontScale) private var fontScale
    let minimumWidth: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        let scale = max(1, fontScale)
        content.labelStyle(CenteredIconLabelStyle())
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, padding * scale)
            .frame(minWidth: minimumWidth * scale, minHeight: 28 * scale)
    }
}

struct CenteredIconLabelStyle: LabelStyle {
    @Environment(\.consoleFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 5 * max(1, fontScale)) {
            configuration.icon
            configuration.title
        }
    }
}
