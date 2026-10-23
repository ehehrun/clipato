import AppKit
import SwiftUI

struct WindowColorPicker: NSViewRepresentable {
    let title: String
    @Binding var selection: Color

    func makeNSView(context: Context) -> WindowColorWell {
        WindowColorWell(title: title) { selection = Color(nsColor: $0) }
    }

    func updateNSView(_ view: WindowColorWell, context: Context) {
        view.setAccessibilityLabel(title)
        let color = NSColor(selection)
        if view.color != color { view.color = color }
        view.onChange = { selection = Color(nsColor: $0) }
    }

    static func dismantleNSView(_ view: WindowColorWell, coordinator: ()) {
        view.deactivate()
    }
}

final class WindowColorWell: NSColorWell {
    var onChange: (NSColor) -> Void

    init(title: String, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        focusRingType = .none
        colorWellStyle = .default
        supportsAlpha = false
        target = self
        action = #selector(colorChanged)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func activate(_ exclusive: Bool) {
        guard let window, let screen = window.screen else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, anchor: anchor, within: screen.visibleFrame))
        // Each appearance control edits one field, even when Shift is held.
        super.activate(true)
    }

    static func panelOrigin(size: CGSize, anchor: CGRect, within visibleFrame: CGRect) -> CGPoint {
        let gap: CGFloat = 12
        let right = anchor.maxX + gap
        let x = right + size.width <= visibleFrame.maxX ? right : anchor.minX - gap - size.width
        return CGPoint(x: max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width)),
                       y: min(max(anchor.maxY - size.height, visibleFrame.minY), visibleFrame.maxY - size.height))
    }

    @objc private func colorChanged() { onChange(color) }
}
