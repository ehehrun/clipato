import AppKit
import QuartzCore

@MainActor
final class GuideAnimationPlayer: NSView {
    private var scene: GuideAnimationScene?
    private var requestedPlaying = false
    private var replay = 0
    private var windowObservers: [NSObjectProtocol] = []

    var isReady: Bool { scene != nil }
    var sceneLayer: CALayer? { scene?.layer }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer!.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func load(_ animation: GuideAnimation) throws {
        stop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scene = try GuideAnimationScene(svg: animation.svg())
        scene.layer.speed = 0
        scene.layer.timeOffset = 0
        scene.layer.beginTime = 0
        scene.layer.anchorPoint = .zero
        scene.layer.bounds = scene.viewBox
        scene.layer.masksToBounds = true
        self.scene = scene
        layer!.addSublayer(scene.layer)
        layoutScene()
        observeWindow()
    }

    func setPlayback(playing: Bool, replay: Int) {
        requestedPlaying = playing
        if self.replay != replay {
            self.replay = replay
            if let sceneLayer {
                sceneLayer.speed = 0
                sceneLayer.timeOffset = 0
                sceneLayer.beginTime = 0
            }
        }
        synchronizePlayback()
    }

    func stop() {
        requestedPlaying = false
        replay = 0
        removeWindowObservers()
        guard let scene else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scene.layer.speed = 0
        removeAnimations(from: scene.layer)
        scene.layer.removeFromSuperlayer()
        self.scene = nil
    }

    override func layout() {
        super.layout()
        layoutScene()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        synchronizePlayback()
    }

    private func layoutScene() {
        guard let scene else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scene.layer.isHidden = bounds.width <= 0 || bounds.height <= 0
        guard !scene.layer.isHidden else { return }
        let scale = min(bounds.width / scene.viewBox.width, bounds.height / scene.viewBox.height)
        scene.layer.position = CGPoint(x: bounds.minX + (bounds.width - scene.viewBox.width * scale) / 2,
                                       y: bounds.minY + (bounds.height - scene.viewBox.height * scale) / 2)
        // bounds.origin already places the SVG viewBox origin at the layer's zero anchor.
        scene.layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    }

    private func synchronizePlayback() {
        guard let sceneLayer else { return }
        let shouldPlay: Bool
        if let window {
            shouldPlay = requestedPlaying && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        } else {
            shouldPlay = false
        }
        if shouldPlay, sceneLayer.speed == 0 {
            let pausedTime = sceneLayer.timeOffset
            sceneLayer.speed = 1
            sceneLayer.timeOffset = 0
            sceneLayer.beginTime = 0
            sceneLayer.beginTime = sceneLayer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        } else if !shouldPlay, sceneLayer.speed != 0 {
            let pausedTime = sceneLayer.convertTime(CACurrentMediaTime(), from: nil)
            sceneLayer.speed = 0
            sceneLayer.timeOffset = pausedTime
        }
    }

    private func observeWindow() {
        removeWindowObservers()
        guard isReady, let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == NSWindow.willCloseNotification { self.stop() }
                    else { self.synchronizePlayback() }
                }
            }
            windowObservers.append(observer)
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }

    private func removeAnimations(from layer: CALayer) {
        layer.removeAllAnimations()
        if let children = layer.sublayers {
            for child in children { removeAnimations(from: child) }
        }
    }
}
