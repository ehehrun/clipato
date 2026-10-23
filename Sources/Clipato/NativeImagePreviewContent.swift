import AppKit
import VisionKit

final class NativeImagePreviewContent: NSView {
    let scrollView = NativeImagePreviewScrollView(frame: .zero)
    let imageView = NSImageView(frame: .zero)
    let overlay = ImageAnalysisOverlayView(frame: .zero)
    var onError: ((Error) -> Void)?
    var supportsLiveText: Bool { ImageAnalyzer.isSupported }
    var zoom: CGFloat { scrollView.magnification }

    private let analyzer = ImageAnalyzer()
    private var image: CGImage?
    private var needsInitialFit = false
    private var analysisTask: Task<Void, Never>?
    private var analyzing = false
    private var pendingAnalysis: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView = NativeImagePreviewClipView()
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = imageView
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.focusRingType = .none
        overlay.frame = imageView.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.trackingImageView = imageView
        overlay.preferredInteractionTypes = .automaticTextOnly
        imageView.addSubview(overlay)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: CGImage) {
        analysisTask?.cancel()
        overlay.analysis = nil
        overlay.resetSelection()
        self.image = image
        needsInitialFit = true
        updateImageGeometry()
        fitImage()
        pendingAnalysis = supportsLiveText ? image : nil
        startNextAnalysis()
    }

    func clear() {
        analysisTask?.cancel()
        analysisTask = nil
        pendingAnalysis = nil
        image = nil
        imageView.image = nil
        imageView.setFrameSize(.zero)
        overlay.analysis = nil
        overlay.resetSelection()
        needsInitialFit = false
        scrollView.magnification = 1
    }

    override func layout() {
        super.layout()
        if needsInitialFit { fitImage() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateImageGeometry()
        if needsInitialFit { fitImage() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateImageGeometry()
    }

    func fitImage() {
        guard image != nil, window != nil else { return }
        let viewport = scrollView.contentView.frame.size
        let size = imageView.frame.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        needsInitialFit = false
        setZoom(min(1, viewport.width / size.width, viewport.height / size.height))
        let visible = scrollView.contentView.bounds.size
        scrollView.contentView.scroll(to: NSPoint(x: (size.width - visible.width) / 2,
                                                  y: (size.height - visible.height) / 2))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func setZoom(_ zoom: CGFloat) {
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(zoom, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
    }

    func analyzeIfVisible() {
        startNextAnalysis()
    }

    private func updateImageGeometry() {
        guard let image, let window else { return }
        let scale = window.backingScaleFactor
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.setFrameSize(size)
        overlay.setContentsRectNeedsUpdate()
    }

    private func startNextAnalysis() {
        guard window?.isVisible == true, !analyzing, let image = pendingAnalysis else { return }
        pendingAnalysis = nil
        analyzing = true
        analysisTask = Task { [weak self, analyzer] in
            do {
                try Task.checkCancellation()
                let analysis = try await analyzer.analyze(image, orientation: .up, configuration: .init([.text]))
                try Task.checkCancellation()
                self?.overlay.analysis = analysis
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.onError?(error) }
            }
            guard let self else { return }
            self.analysisTask = nil
            self.analyzing = false
            self.startNextAnalysis()
        }
    }
}

final class NativeImagePreviewScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true
        minMagnification = 0.001
        maxMagnification = 32
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        borderType = .noBorder
        drawsBackground = false
        contentView.drawsBackground = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let focus = contentView.convert(event.locationInWindow, from: nil)
            setMagnification(magnification * exp(event.scrollingDeltaY * 0.01), centeredAt: focus)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class NativeImagePreviewClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}
