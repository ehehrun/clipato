import AppKit
import SwiftUI

@MainActor
final class CollagePreviewWindowController: NSWindowController, NSWindowDelegate {
    init(image: CGImage) {
        let window = EscapeClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("Clipato · 拼图预览")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
        window.contentView = NSHostingView(rootView: CollagePreviewView(image: image) { [weak self] in
            self?.window?.performClose(nil)
        })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func updateLanguage() {
        window?.title = L("Clipato · 拼图预览")
    }

    func showFullScreen() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.toggleFullScreen(nil)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

private struct CollagePreviewView: View {
    let image: CGImage
    let onClose: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var zoom: CGFloat = 1
    @State private var fitsWindow = true

    private var minimumZoom: CGFloat { 1 / CGFloat(max(image.width, image.height)) }
    private let maximumZoom: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("拼图预览")).font(.headline)
                Text("\(image.width) × \(image.height) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L("缩小")).accessibilityLabel(L("缩小")).disabled(zoom <= minimumZoom)
                    .keyboardShortcut("-", modifiers: .command)
                Text(zoom, format: .percent.precision(.fractionLength(0...1)))
                    .font(.caption.monospacedDigit()).frame(minWidth: 48)
                Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("放大")).accessibilityLabel(L("放大")).disabled(zoom >= maximumZoom)
                    .keyboardShortcut("=", modifiers: .command)
                Button(L("100% 原始像素")) { setZoom(1) }
                Button(L("适应屏幕")) { fitsWindow = true }
                Button(L("返回工作台"), action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .background(Palette.card)
            Divider()
            GeometryReader { geometry in
                EditorImageViewport(image: image, annotations: [], tool: .rectangle, color: .clear,
                                    allowsAnnotation: false,
                                    zoom: Binding(get: { zoom }, set: { setZoom($0) }),
                                    minimumZoom: minimumZoom, maximumZoom: maximumZoom,
                                    onAnnotation: { _ in })
                    .onAppear { updateFit(geometry.size) }
                    .onChange(of: geometry.size) { updateFit(geometry.size) }
                    .onChange(of: displayScale) { updateFit(geometry.size) }
                    .onChange(of: fitsWindow) { updateFit(geometry.size) }
            }
            Divider()
            Text(L("滚动平移 · 双指捏合或 ⌘滚动缩放 · Esc 返回工作台"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(10)
                .background(Palette.card)
        }
        .frame(minWidth: 760, minHeight: 420)
        .background(Palette.canvas)
        .tint(Palette.accent)
        .foregroundStyle(Palette.foreground)
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
    }

    private func setZoom(_ value: CGFloat) {
        fitsWindow = false
        zoom = min(max(value, minimumZoom), maximumZoom)
    }

    private func updateFit(_ size: CGSize) {
        guard fitsWindow else { return }
        zoom = max(minimumZoom, min(1, min(max(1, size.width - 32) * displayScale / CGFloat(image.width),
                                          max(1, size.height - 32) * displayScale / CGFloat(image.height))))
    }
}
