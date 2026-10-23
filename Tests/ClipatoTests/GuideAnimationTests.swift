import AppKit
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import Clipato

@MainActor
final class GuideAnimationTests: XCTestCase {
    func testBundledAnimationsAreSmallOfflineVectorsWithStillInitialFrames() throws {
        var totalBytes = 0
        for animation in GuideAnimation.allCases {
            let url = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: "guide-\(animation.rawValue).svg", withExtension: "deflate"))
            totalBytes += try Data(contentsOf: url).count
            let document = try animation.document()
            let start = try XCTUnwrap(document.range(of: "<svg "))
            let end = try XCTUnwrap(document.range(of: "</svg>"))
            let svg = String(document[start.lowerBound..<end.upperBound])
            let parser = XMLParser(data: Data(svg.utf8))
            XCTAssertTrue(parser.parse(), "\(animation): \(String(describing: parser.parserError))")
            XCTAssertTrue(svg.contains("viewBox=\"28 104 904 620\""), animation.rawValue)
            XCTAssertTrue(svg.contains("width=\"960\""), animation.rawValue)
            XCTAssertTrue(svg.contains("begin=\"indefinite\""), animation.rawValue)
            XCTAssertFalse(svg.contains("<script"), animation.rawValue)
            XCTAssertFalse(svg.contains("<image"), animation.rawValue)
            XCTAssertFalse(svg.contains("href="), animation.rawValue)
            XCTAssertTrue(document.contains("default-src 'none'"))
        }
        XCTAssertLessThan(totalBytes, 64 * 1024, "Guide assets should remain a small vector addition to the App.")
    }

    func testMissingBundleResourceReportsAnError() {
        XCTAssertThrowsError(try GuideAnimation.captureRegion.document(bundle: .main)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoSuchFile.rawValue)
        }
    }

    func testGuideKeepsPreviewsOnTheRightAndLoadsOnlyTheActivePlayer() async throws {
        _ = NSApplication.shared
        func content(_ active: GuideAnimation?, hovered: GuideAnimation? = nil) -> some View {
            ScrollView {
                VStack {
                    ForEach(GuideAnimation.allCases, id: \.self) { animation in
                        GuideAnimationRow(animation: animation, active: .constant(active), hovered: .constant(hovered),
                                          viewport: CGSize(width: 820, height: 900), applicationActive: true) {
                            Text(animation.title)
                        }
                    }
                }
            }.coordinateSpace(name: "guide-viewport")
        }
        func players(in view: NSView) -> [WKWebView] {
            if let player = view as? WKWebView { return [player] }
            return view.subviews.flatMap { players(in: $0) }
        }
        let host = NSHostingView(rootView: content(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(players(in: host).isEmpty, "Static vector previews should not create WebKit instances.")
        host.rootView = content(.captureRegion, hovered: .captureRegion)
        let deadline = ContinuousClock.now + .seconds(5)
        while players(in: host).isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let activePlayers = players(in: host)
        XCTAssertEqual(activePlayers.count, 1)
        let player = try XCTUnwrap(activePlayers.first)
        XCTAssertLessThanOrEqual(player.frame.width, 272)
        XCTAssertGreaterThan(player.frame.width, 200)
        XCTAssertEqual(player.frame.height / player.frame.width, 620.0 / 904, accuracy: 0.01)
        let frame = host.convert(player.bounds, from: player)
        XCTAssertGreaterThan(frame.minX, 500, "The preview belongs beside the description, on the right.")
        XCTAssertEqual(frame.maxX, host.bounds.maxX, accuracy: 20)
        while player.isLoading && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Hover state is the same input written by the row's onHover handler.
        host.rootView = content(.captureRegion)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let pausedAfterLeaving = try await player.evaluateJavaScript("document.querySelector('svg').animationsPaused()", in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(pausedAfterLeaving as? Bool, true)
        host.rootView = content(nil)
        while !players(in: host).isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(players(in: host).isEmpty, "Removing the active row should release its native player.")
    }

    func testStaticPreviewsUseTheSameVectorAssetsAtThumbnailSize() throws {
        for animation in GuideAnimation.allCases {
            let image = try animation.poster()
            XCTAssertEqual(image.size.width, 272)
            XCTAssertEqual(image.size.height / image.size.width, 620.0 / 904, accuracy: 0.001)
            let rendered = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertLessThanOrEqual(rendered.width, 544)
            XCTAssertGreaterThan(rendered.height, 100)
        }
    }

    func testNativePlayerCanStartPauseSeekAndReplayWithoutPageScripts() async throws {
        _ = NSApplication.shared
        var playbackError: Error?
        let player = GuideAnimationPlayer { playbackError = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 659),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = player.webView
        defer { player.stop(); window.close() }
        try player.load(.captureRegion)
        let deadline = ContinuousClock.now + .seconds(15)
        while !player.isReady && playbackError == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if let playbackError { throw playbackError }
        XCTAssertTrue(player.isReady, "The actual bundled SVG must load in WebKit.")
        guard player.isReady else { return }
        XCTAssertFalse(player.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(player.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(player.webView.hitTest(.zero), "The illustration must not capture guide scrolling or selection.")
        let initiallyPaused = try await paused(player)
        XCTAssertTrue(initiallyPaused)
        let initialTime = try await time(player)
        XCTAssertEqual(initialTime, 0, accuracy: 0.01)

        player.setPlayback(playing: true, replay: 0)
        let playingPaused = try await paused(player)
        XCTAssertFalse(playingPaused)
        player.setPlayback(playing: false, replay: 0)
        let manuallyPaused = try await paused(player)
        XCTAssertTrue(manuallyPaused)
        _ = try await player.webView.evaluateJavaScript("document.querySelector('svg').setCurrentTime(4.9)", in: nil, contentWorld: .defaultClient)
        let pausedTime = try await time(player)
        try await Task.sleep(for: .milliseconds(80))
        let laterTime = try await time(player)
        XCTAssertEqual(laterTime, pausedTime, accuracy: 0.01)
        player.setPlayback(playing: false, replay: 1)
        let replayTime = try await time(player)
        XCTAssertEqual(replayTime, 0, accuracy: 0.01)
        let replayPaused = try await paused(player)
        XCTAssertTrue(replayPaused, "Replay may reset a reduced-motion illustration without autoplay.")

        // Optional local QA snapshots use the same WebKit renderer as the shipped guide.
        if let directory = ProcessInfo.processInfo.environment["CLIPATO_GUIDE_QA_DIRECTORY"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for animation in GuideAnimation.allCases {
                try player.load(animation)
                let loadDeadline = ContinuousClock.now + .seconds(10)
                while !player.isReady && playbackError == nil && ContinuousClock.now < loadDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                if let playbackError { throw playbackError }
                XCTAssertTrue(player.isReady, animation.rawValue)
                for second in [0.0, 4.9, 8.2] {
                    _ = try await player.webView.evaluateJavaScript("document.querySelector('svg').setCurrentTime(\(second))", in: nil, contentWorld: .defaultClient)
                    let image = try await player.webView.takeSnapshot(configuration: nil)
                    let bitmap = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
                    let png = try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
                    try png.write(to: destination.appendingPathComponent("\(animation.rawValue)-\(second).png"))
                }
            }
        }
        XCTAssertNil(playbackError)
        player.stop()
        XCTAssertFalse(player.isReady)
    }

    private func paused(_ player: GuideAnimationPlayer) async throws -> Bool {
        let value = try await player.webView.evaluateJavaScript("document.querySelector('svg').animationsPaused()", in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? Bool)
    }

    private func time(_ player: GuideAnimationPlayer) async throws -> Double {
        let value = try await player.webView.evaluateJavaScript("document.querySelector('svg').getCurrentTime()", in: nil, contentWorld: .defaultClient)
        return try XCTUnwrap(value as? Double)
    }
}
