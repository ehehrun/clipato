import AppKit
import SwiftUI
import WebKit

enum GuideAnimation: String, CaseIterable {
    static let previewWidth: CGFloat = 272
    static let aspectRatio: CGFloat = 904.0 / 620

    case captureRegion = "capture-region"
    case pinMoveScale = "pin-move-scale"
    case dragToCollection = "drag-to-collection"
    case collectionReorder = "collection-reorder"
    case collageReorder = "collage-reorder"
    case freeformMoveResize = "freeform-move-resize"
    case squareCropGrid = "square-crop-grid"
    case sidebarResize = "sidebar-resize"
    case screenCapturePermission = "screen-capture-permission"

    var title: String {
        switch self {
        case .captureRegion: return L("截图选区与调整")
        case .pinMoveScale: return L("贴图移动与缩放")
        case .dragToCollection: return L("拖入收藏夹")
        case .collectionReorder: return L("收藏夹拖拽排序")
        case .collageReorder: return L("调整拼图顺序")
        case .freeformMoveResize: return L("自由拼图移动与缩放")
        case .squareCropGrid: return L("正方形裁切与宫格")
        case .sidebarResize: return L("调整侧栏宽度")
        case .screenCapturePermission: return L("拖拽添加屏幕录制权限")
        }
    }

    func svg(bundle: Bundle = LanguageSettings.resourceBundle) throws -> String {
        let name = "guide-\(rawValue).svg"
        guard let url = bundle.url(forResource: name, withExtension: "deflate") else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".deflate"])
        }
        let data = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
        guard let svg = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return svg
    }

    func poster() throws -> NSImage {
        guard let image = NSImage(data: Data(try svg().utf8)) else { throw CocoaError(.fileReadCorruptFile) }
        image.size = CGSize(width: Self.previewWidth, height: Self.previewWidth / Self.aspectRatio)
        return image
    }

    func document(bundle: Bundle = LanguageSettings.resourceBundle) throws -> String {
        let svg = try svg(bundle: bundle)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>html,body{margin:0;overflow:hidden;background:#f7f8fa}svg{display:block;width:100%;height:100vh;pointer-events:none;user-select:none}</style>
        </head><body>\(svg)</body></html>
        """
    }
}

// The illustration has no interactive content. Wheel and drag events belong to the guide's ScrollView.
private final class GuideAnimationCanvas: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class GuideAnimationPlayer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var isReady = false
    private var playing = false
    private var replay = 0
    private var stopped = false
    var onReady: () -> Void
    var onFailure: (Error) -> Void

    init(onReady: @escaping () -> Void = {}, onFailure: @escaping (Error) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = GuideAnimationCanvas(frame: .zero, configuration: configuration)
        self.onReady = onReady
        self.onFailure = onFailure
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ animation: GuideAnimation) throws {
        isReady = false
        webView.loadHTMLString(try animation.document(), baseURL: nil)
    }

    func setPlayback(playing: Bool, replay: Int) {
        guard self.playing != playing || self.replay != replay else { return }
        let restart = self.replay != replay
        self.playing = playing
        self.replay = replay
        if isReady { synchronize(restart: restart) }
    }

    func stop() {
        stopped = true
        isReady = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.evaluateJavaScript("document.querySelector('svg').pauseAnimations()", in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Assets begin indefinitely so Reduce Motion never flashes an autoplaying frame during loading.
        evaluate("""
        const svg = document.querySelector('svg');
        svg.pauseAnimations(); svg.setCurrentTime(0);
        svg.querySelectorAll('animate,animateTransform').forEach(a => a.beginElement());
        svg.setCurrentTime(0);
        """) { [weak self] in
            guard let self, !self.stopped else { return }
            self.isReady = true
            self.synchronize(restart: false)
            self.onReady()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !stopped { onFailure(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !stopped { onFailure(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !stopped { onFailure(WKError(.webContentProcessTerminated)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func synchronize(restart: Bool) {
        evaluate("""
        const svg = document.querySelector('svg');
        \(restart ? "svg.setCurrentTime(0);" : "")
        svg.\(playing ? "unpauseAnimations" : "pauseAnimations")();
        """)
    }

    private func evaluate(_ script: String, completion: @escaping () -> Void = {}) {
        webView.evaluateJavaScript("(() => { \(script) })()", in: nil, in: .defaultClient) { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success: completion()
            case .failure(let error): self.onFailure(error)
            }
        }
    }
}

private struct GuideAnimationWebView: NSViewRepresentable {
    let animation: GuideAnimation
    let playing: Bool
    let replay: Int
    let onReady: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> GuideAnimationPlayer { GuideAnimationPlayer(onReady: onReady, onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        do { try context.coordinator.load(animation) }
        catch { Task { @MainActor in onFailure(error) } }
        return context.coordinator.webView
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFailure = onFailure
        context.coordinator.setPlayback(playing: playing, replay: replay)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: GuideAnimationPlayer) { coordinator.stop() }
}

private struct GuideAnimationFrame: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct GuideAnimationRow<Content: View>: View {
    let animation: GuideAnimation
    @Binding var active: GuideAnimation?
    @Binding var hovered: GuideAnimation?
    let viewport: CGSize
    let applicationActive: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: NSImage?
    @State private var ready = false
    @State private var manuallyPlaying = false
    @State private var isVisible = false
    @State private var failure: String?

    private var playing: Bool { manuallyPlaying || (hovered == animation && !reduceMotion) }

    var body: some View {
        let width = min(GuideAnimation.previewWidth, viewport.width * 0.3)
        HStack(alignment: .top, spacing: 20) {
            content().frame(maxWidth: .infinity, alignment: .leading)
            preview.frame(width: width, height: width / GuideAnimation.aspectRatio)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = animation
                if !reduceMotion { active = animation }
            } else if hovered == animation {
                hovered = nil
                manuallyPlaying = false
            }
        }
        .task {
            do { poster = try animation.poster() }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: active) { _, selected in
            if selected != animation { ready = false; manuallyPlaying = false }
        }
        .onChange(of: reduceMotion) { _, _ in manuallyPlaying = false }
        .accessibilityAction(named: Text(L("播放"))) { togglePlayback() }
    }

    private var preview: some View {
        ZStack {
            Palette.canvas
            if let poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            }
            if let failure {
                Label(L("无法播放演示"), systemImage: "exclamationmark.triangle")
                    .consoleFont(11).foregroundStyle(Palette.muted).padding(10).help(failure)
            } else if active == animation {
                GuideAnimationWebView(animation: animation, playing: playing && isVisible && applicationActive,
                                      replay: 0, onReady: { ready = true },
                                      onFailure: { failure = $0.localizedDescription })
                    .opacity(ready ? 1 : 0).accessibilityHidden(true)
            }
            if reduceMotion && failure == nil {
                Button { togglePlayback() } label: {
                    Image(systemName: manuallyPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28)).foregroundStyle(Palette.foreground, Palette.card)
                }.buttonStyle(.plain).accessibilityLabel(manuallyPlaying ? L("暂停") : L("播放"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.line, lineWidth: 1) }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: GuideAnimationFrame.self,
                                       value: proxy.frame(in: .named("guide-viewport")))
            }
        }
        .onPreferenceChange(GuideAnimationFrame.self) {
            isVisible = $0.intersects(CGRect(origin: .zero, size: viewport))
        }
    }

    private func togglePlayback() {
        let pause = active == animation && playing
        active = animation
        manuallyPlaying = !pause
    }
}
