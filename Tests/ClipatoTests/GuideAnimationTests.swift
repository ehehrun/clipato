import AppKit
import Foundation
import QuartzCore
import XCTest
@testable import Clipato

@MainActor
final class GuideAnimationTests: XCTestCase {
    func testBundledAnimationsRemainSmallOfflineVectorsWithStillInitialFrames() throws {
        var totalBytes = 0
        var totalTracks = 0
        for animation in GuideAnimation.allCases {
            let url = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: "guide-\(animation.rawValue).svg", withExtension: "deflate"))
            totalBytes += try Data(contentsOf: url).count
            let svg = try animation.svg()
            let document = try XMLDocument(xmlString: svg)
            let root = try XCTUnwrap(document.rootElement())
            XCTAssertEqual(root.attribute(forName: "viewBox")?.stringValue, "28 104 904 620", animation.rawValue)
            XCTAssertEqual(root.attribute(forName: "width")?.stringValue, "960", animation.rawValue)
            let tracks = try document.nodes(forXPath: "//*[local-name()='animate' or local-name()='animateTransform']")
            XCTAssertFalse(tracks.isEmpty, animation.rawValue)
            totalTracks += tracks.count
            for case let track as XMLElement in tracks {
                XCTAssertEqual(track.attribute(forName: "begin")?.stringValue, "indefinite", animation.rawValue)
                XCTAssertEqual(track.attribute(forName: "dur")?.stringValue, "9.6s", animation.rawValue)
            }
            XCTAssertFalse(svg.contains("<script"), animation.rawValue)
            XCTAssertFalse(svg.contains("<image"), animation.rawValue)
            XCTAssertFalse(svg.contains("href="), animation.rawValue)
        }
        XCTAssertEqual(totalBytes, 25_804, "Playback must reuse the existing small assets rather than add full-frame image sequences.")
        XCTAssertEqual(totalTracks, 126)
        XCTAssertEqual(GuideAnimation.previewWidth, 272)
        XCTAssertEqual(GuideAnimation.aspectRatio, 904.0 / 620)
    }

    func testMissingBundleResourceReportsAnError() {
        XCTAssertThrowsError(try GuideAnimation.captureRegion.svg(bundle: .main)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoSuchFile.rawValue)
        }
    }

    func testEveryBundledSceneBuildsCompleteNativeTimelinesWithoutRendering() throws {
        var count = 0
        for animation in GuideAnimation.allCases {
            let scene = try GuideAnimationScene(svg: animation.svg())
            XCTAssertEqual(scene.viewBox, CGRect(x: 28, y: 104, width: 904, height: 620), animation.rawValue)
            XCTAssertEqual(scene.duration, 9.6, accuracy: 0.000_001, animation.rawValue)
            let tracks = animations(in: scene.layer)
            XCTAssertFalse(tracks.isEmpty, animation.rawValue)
            count += tracks.count
            for track in tracks {
                XCTAssertEqual(track.duration, 9.6, accuracy: 0.000_001, animation.rawValue)
                XCTAssertEqual(track.repeatCount, .infinity, animation.rawValue)
                let values = try XCTUnwrap(track.values, animation.rawValue)
                let keyTimes = try XCTUnwrap(track.keyTimes, animation.rawValue)
                XCTAssertEqual(values.count, keyTimes.count, animation.rawValue)
                XCTAssertEqual(keyTimes.first?.doubleValue, 0, animation.rawValue)
                XCTAssertEqual(keyTimes.last?.doubleValue, 1, animation.rawValue)
                XCTAssertTrue(zip(keyTimes, keyTimes.dropFirst()).allSatisfy { pair in
                    pair.0.doubleValue <= pair.1.doubleValue
                }, animation.rawValue)
                let keyPath = try XCTUnwrap(track.keyPath)
                XCTAssertTrue(["transform", "opacity", "fillColor", "position.x"].contains(keyPath), animation.rawValue)
                if let timingFunctions = track.timingFunctions, !timingFunctions.isEmpty {
                    XCTAssertEqual(timingFunctions.count, values.count - 1, animation.rawValue)
                }
            }
            let textLayers = layers(in: scene.layer).compactMap { $0 as? CATextLayer }
            XCTAssertFalse(textLayers.isEmpty, animation.rawValue)
            for text in textLayers {
                XCTAssertNotNil(text.font, animation.rawValue)
                XCTAssertGreaterThan(text.fontSize, 0, animation.rawValue)
            }
        }
        XCTAssertEqual(count, 121, "All nonconstant source tracks must survive; the five constant tracks only need a model value.")
    }

    func testNativeTransformsUseTheFirstKeyframeAndReplaceTheStaticTransform() throws {
        let scene = try GuideAnimationScene(svg: svg("""
        <g id="translate" transform="translate(99 99)">
          <animateTransform attributeName="transform" type="translate" values="4 5;24 15;4 5" keyTimes="0;0.5;1" calcMode="spline" keySplines=".33 0 .67 1;.33 0 .67 1" begin="indefinite" dur="9.6s" repeatCount="indefinite"/>
          <rect x="0" y="0" width="10" height="10" fill="#ff0000"/>
        </g>
        <g id="scale" transform="scale(9 9)">
          <animateTransform attributeName="transform" type="scale" values="1 2;3 4;1 2" keyTimes="0;0.5;1" begin="indefinite" dur="9.6s" repeatCount="indefinite"/>
          <rect x="0" y="0" width="10" height="10" fill="#0000ff"/>
        </g>
        """))
        let translated = try named("translate", in: scene.layer)
        XCTAssertEqual(translated.affineTransform().tx, 4, accuracy: 0.000_001)
        XCTAssertEqual(translated.affineTransform().ty, 5, accuracy: 0.000_001)
        let translatedTrack = try XCTUnwrap(animations(in: translated).first { $0.keyPath == "transform" })
        let translatedValues = try XCTUnwrap(translatedTrack.values as? [NSValue])
        XCTAssertEqual(translatedValues.map { $0.caTransform3DValue.m41 }, [4, 24, 4])
        XCTAssertEqual(translatedValues.map { $0.caTransform3DValue.m42 }, [5, 15, 5])
        XCTAssertEqual(translatedTrack.timingFunctions?.count, 2)
        let scaled = try named("scale", in: scene.layer)
        XCTAssertEqual(scaled.affineTransform().a, 1, accuracy: 0.000_001)
        XCTAssertEqual(scaled.affineTransform().d, 2, accuracy: 0.000_001)
        let scaledTrack = try XCTUnwrap(animations(in: scaled).first { $0.keyPath == "transform" })
        let scaledValues = try XCTUnwrap(scaledTrack.values as? [NSValue])
        XCTAssertEqual(scaledValues.map { $0.caTransform3DValue.m11 }, [1, 3, 1])
        XCTAssertEqual(scaledValues.map { $0.caTransform3DValue.m22 }, [2, 4, 2])
    }

    func testOpacityFillAndCircleMotionPreserveVisibleModelGeometry() throws {
        let scene = try GuideAnimationScene(svg: svg("""
        <rect id="opacity" x="10" y="20" width="30" height="40" fill="#ff0000" opacity="0.8">
          <animate attributeName="opacity" values="0.2;0.6;0.2" keyTimes="0;0.5;1" begin="indefinite" dur="9.6s" repeatCount="indefinite"/>
        </rect>
        <rect id="fill" x="50" y="20" width="20" height="20" fill="#000000">
          <animate attributeName="fill" values="#ff0000;#00ff00;#ff0000" keyTimes="0;0.5;1" begin="indefinite" dur="9.6s" repeatCount="indefinite"/>
        </rect>
        <circle id="circle" cx="3" cy="20" r="4" fill="#ffffff">
          <animate attributeName="cx" values="10;20;10" keyTimes="0;0.5;1" begin="indefinite" dur="9.6s" repeatCount="indefinite"/>
        </circle>
        """))
        let opacity = try named("opacity", in: scene.layer)
        XCTAssertEqual(opacity.opacity, 0.2, accuracy: 0.000_001)
        let opacityShape = try XCTUnwrap(opacity as? CAShapeLayer)
        XCTAssertEqual(opacityShape.convert(try XCTUnwrap(opacityShape.path).boundingBoxOfPath, to: scene.layer),
                       CGRect(x: 10, y: 20, width: 30, height: 40))
        let fill = try XCTUnwrap(named("fill", in: scene.layer) as? CAShapeLayer)
        let color = try XCTUnwrap(fill.fillColor?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil))
        XCTAssertEqual(try XCTUnwrap(color.components), [1, 0, 0, 1])
        let circle = try XCTUnwrap(named("circle", in: scene.layer) as? CAShapeLayer)
        XCTAssertEqual(circle.convert(try XCTUnwrap(circle.path).boundingBoxOfPath, to: scene.layer),
                       CGRect(x: 6, y: 16, width: 8, height: 8))
        let motion = try XCTUnwrap(animations(in: circle).first { $0.keyPath == "position.x" })
        let values = try XCTUnwrap(motion.values as? [NSNumber])
        XCTAssertEqual(values[1].doubleValue - values[0].doubleValue, 10, accuracy: 0.000_001)
    }

    func testUnsupportedOrCorruptGuideDataFailsRatherThanDisplayingAnIncompleteScene() {
        for document in [
            "<svg>",
            svg("<image href=\"https://example.invalid/image.png\"/>"),
            svg("<script>document.location='https://example.invalid';</script>"),
            svg("<g><animateTransform attributeName=\"transform\" type=\"rotate\" values=\"0;90\" keyTimes=\"0;1\" begin=\"indefinite\" dur=\"9.6s\" repeatCount=\"indefinite\"/></g>"),
            svg("<rect x=\"0\" y=\"0\" width=\"20\" height=\"20\"><animate attributeName=\"opacity\" values=\"0;1;0\" keyTimes=\"0;1\" begin=\"indefinite\" dur=\"9.6s\" repeatCount=\"indefinite\"/></rect>"),
        ] {
            XCTAssertThrowsError(try GuideAnimationScene(svg: document), document)
        }
    }

    func testDetachedPlayerRemainsPausedEvenWhenPlaybackIsRequested() throws {
        _ = NSApplication.shared
        let player = GuideAnimationPlayer()
        try player.load(.captureRegion)
        XCTAssertTrue(player.isReady)
        XCTAssertNil(player.window)
        XCTAssertNil(player.hitTest(.zero))
        XCTAssertFalse(player.acceptsFirstResponder)
        let scene = try XCTUnwrap(player.sceneLayer)
        XCTAssertEqual(scene.speed, 0)
        XCTAssertEqual(scene.timeOffset, 0)
        player.setPlayback(playing: true, replay: 0)
        XCTAssertEqual(scene.speed, 0, "A requested animation must not run without a visible window.")
        XCTAssertEqual(scene.timeOffset, 0)
        player.stop()
    }

    func testPauseAndReplayKeepTheNativeClockStoppedWithoutAWindow() throws {
        let player = GuideAnimationPlayer()
        try player.load(.captureRegion)
        let scene = try XCTUnwrap(player.sceneLayer)
        scene.timeOffset = 4.9
        player.setPlayback(playing: false, replay: 0)
        XCTAssertEqual(scene.timeOffset, 4.9, accuracy: 0.000_001)
        player.setPlayback(playing: true, replay: 0)
        XCTAssertEqual(scene.speed, 0)
        XCTAssertEqual(scene.timeOffset, 4.9, accuracy: 0.000_001)
        player.setPlayback(playing: false, replay: 1)
        XCTAssertEqual(scene.speed, 0)
        XCTAssertEqual(scene.timeOffset, 0)
        player.stop()
    }

    func testPlayerFitsTheDeclaredViewBoxWithoutChangingItsCoordinateSystem() throws {
        let player = GuideAnimationPlayer()
        player.frame.size = CGSize(width: 272, height: 272 / GuideAnimation.aspectRatio)
        try player.load(.captureRegion)
        player.layout()
        let scene = try XCTUnwrap(player.sceneLayer)
        let canvas = try XCTUnwrap(player.layer)
        let origin = scene.convert(CGPoint(x: 28, y: 104), to: canvas)
        let end = scene.convert(CGPoint(x: 932, y: 724), to: canvas)
        XCTAssertEqual(origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, player.bounds.width, accuracy: 0.001)
        XCTAssertEqual(end.y, player.bounds.height, accuracy: 0.001)
        XCTAssertTrue(canvas.masksToBounds)
        player.stop()
    }

    func testLoadingAnotherAnimationDetachesAndStopsThePreviousScene() throws {
        let player = GuideAnimationPlayer()
        try player.load(.captureRegion)
        let previous = try XCTUnwrap(player.sceneLayer)
        try player.load(.screenCapturePermission)
        let current = try XCTUnwrap(player.sceneLayer)
        XCTAssertFalse(current === previous)
        // Core Animation can retain a detached layer until its transaction commits.
        XCTAssertNil(previous.superlayer)
        XCTAssertEqual(previous.speed, 0)
        XCTAssertTrue(animations(in: previous).isEmpty)
        XCTAssertEqual(player.layer?.sublayers?.count, 1)
        XCTAssertTrue(player.layer?.sublayers?.first === current)
        XCTAssertTrue(player.isReady)
        XCTAssertEqual(current.speed, 0)
        player.stop()
    }

    func testStopRemovesAnimationsAndThePlayerCanBeReleased() throws {
        weak var releasedPlayer: GuideAnimationPlayer?
        try autoreleasepool {
            var player: GuideAnimationPlayer? = GuideAnimationPlayer()
            releasedPlayer = player
            try player!.load(.captureRegion)
            let scene = try XCTUnwrap(player!.sceneLayer)
            XCTAssertFalse(animations(in: scene).isEmpty)
            player!.stop()
            XCTAssertFalse(player!.isReady)
            XCTAssertNil(player!.sceneLayer)
            XCTAssertNil(scene.superlayer)
            XCTAssertTrue(animations(in: scene).isEmpty)
            player = nil
        }
        XCTAssertNil(releasedPlayer)
    }

    private func svg(_ body: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" viewBox=\"0 0 100 100\">\(body)</svg>"
    }

    private func layers(in layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
    }

    private func animations(in layer: CALayer) -> [CAKeyframeAnimation] {
        layers(in: layer).flatMap { node in
            (node.animationKeys() ?? []).compactMap { node.animation(forKey: $0) as? CAKeyframeAnimation }
        }
    }

    private func named(_ name: String, in layer: CALayer) throws -> CALayer {
        try XCTUnwrap(layers(in: layer).first { $0.name == name }, "Missing SVG node \(name)")
    }
}
