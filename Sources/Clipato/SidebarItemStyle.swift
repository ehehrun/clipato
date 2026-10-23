import SwiftUI

struct SidebarItemStyle: ButtonStyle {
    let isSelected: Bool
    var isDropTarget = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Palette.onAccent : isDropTarget ? Palette.accent : Palette.foreground)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Palette.accent : Palette.accent.opacity(isDropTarget ? 0.14 : isHovered ? 0.07 : 0))
            }
            .overlay {
                if isDropTarget {
                    SurfaceBorder(color: isSelected ? Palette.onAccent.opacity(0.7) : Palette.accent,
                                  cornerRadius: 8, lineWidth: 1.5)
                } else if isSelected || isHovered {
                    SurfaceBorder(color: isSelected ? Palette.onAccent.opacity(0.16) : Palette.line,
                                  cornerRadius: 8, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { isHovered = $0 }
    }
}

struct SidebarCount: View {
    let count: Int
    let isSelected: Bool

    var body: some View {
        Text("\(count)").consoleFont(10, weight: .medium, design: .monospaced)
            .foregroundStyle(isSelected ? Palette.onAccent.opacity(0.9) : Palette.muted)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(isSelected ? Palette.onAccent.opacity(0.14) : Palette.foreground.opacity(0.05), in: Capsule())
            .fixedSize()
    }
}
