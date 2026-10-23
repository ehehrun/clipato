import AppKit
import SwiftUI

struct CollageImagePreview: View {
    let image: CGImage
    @Environment(\.displayScale) private var displayScale
    @Binding var zoom: CGFloat
    @Binding var fitsWindow: Bool

    private var minimumZoom: CGFloat { 1 / CGFloat(max(image.width, image.height)) }
    private let maximumZoom: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                EditorImageViewport(image: image, annotations: [], tool: .rectangle, color: .clear,
                                    allowsAnnotation: false,
                                    zoom: Binding(get: { zoom }, set: { setZoom($0) }),
                                    minimumZoom: minimumZoom, maximumZoom: maximumZoom,
                                    onAnnotation: { _ in })
                    .id(ObjectIdentifier(image))
                    .onAppear {
                        zoom = min(max(zoom, minimumZoom), maximumZoom)
                        updateFit(geometry.size)
                    }
                    .onChange(of: geometry.size) { updateFit(geometry.size) }
                    .onChange(of: displayScale) { updateFit(geometry.size) }
                    .onChange(of: fitsWindow) { updateFit(geometry.size) }
                    .onChange(of: ObjectIdentifier(image)) {
                        zoom = min(max(zoom, minimumZoom), maximumZoom)
                        updateFit(geometry.size)
                    }
            }
            Divider()
            HStack(spacing: 6) {
                Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L("缩小预览")).accessibilityLabel(L("缩小预览")).disabled(zoom <= minimumZoom)
                Text(zoom, format: .percent.precision(.fractionLength(0...5)))
                    .font(.caption.monospacedDigit()).frame(minWidth: 56)
                Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("放大预览")).accessibilityLabel(L("放大预览")).disabled(zoom >= maximumZoom)
                Spacer(minLength: 4)
                Button("100%") { setZoom(1) }
                    .help(L("100% 原始像素")).accessibilityLabel(L("100% 原始像素"))
                Button { fitsWindow = true } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help(L("适应窗口")).accessibilityLabel(L("适应窗口"))
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(Palette.card)
            .help(L("仅缩放预览，输出尺寸不变 · 滚动平移 · 双指捏合或 ⌘滚动缩放"))
        }
        .background(Palette.canvas)
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
