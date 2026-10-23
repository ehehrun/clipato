import CoreMedia
import ImageIO
import XCTest
@testable import Clipato

final class KeyframeWriterTests: XCTestCase {
    func testLegacyManifestRoundTripPreservesFieldsWithoutInventingName() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","createdAt":"2026-10-20T00:00:00Z","duration":2,"sampleRate":2,
         "threshold":0.025,"width":64,"height":48,"frames":[{"file":"frames/000001.png","time":0}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(KeyframeManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.name)
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.frames.map(\.file), ["frames/000001.png"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "createdAt", "duration", "sampleRate", "threshold", "width", "height", "frames"]))
        XCTAssertEqual(object["id"] as? String, id.uuidString)
    }

    func testNamedRecordingWritesNameWithoutChangingFramesOrBreakingPlayerData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_792_454_400)
        let name = "演示_001 </script><script>alert(1)</script>"
        let writer = KeyframeWriter(directory: directory, id: id, createdAt: createdAt, started: time(100),
            sampleRate: 2, threshold: 0.01, width: 64, height: 48,
            onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) }, name: name)
        try append(writer, at: 100, color: (0, 255, 0))
        let count = try await writer.finish(duration: 2).get()
        XCTAssertEqual(count, 1)

        let manifest = try readManifest(directory)
        XCTAssertEqual(manifest.name, name)
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.createdAt, createdAt)
        XCTAssertEqual(manifest.frames.map(\.file), ["frames/000001.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("frames").path), ["000001.png"])
        let html = try String(contentsOf: directory.appendingPathComponent("player.html"), encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<script id=\"session\" type=\"application/json\">"))
        let end = try XCTUnwrap(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        let playerData = Data(html[start.upperBound..<end.lowerBound].utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let playerManifest = try decoder.decode(KeyframeManifest.self, from: playerData)
        XCTAssertEqual(playerManifest.name, name)
        XCTAssertEqual(playerManifest.id, id)
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }

    func testResumedSnapshotAndFollowingFramesUseContinuousTimeline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = makeWriter(directory: directory)
        try append(writer, at: 100, color: (0, 0, 255))
        writer.queue.sync { writer.pause(at: time(102)) }
        try append(writer, at: 105, color: (255, 0, 0))
        await writer.resume(at: time(112))
        try append(writer, at: 111, color: (255, 0, 0), initialSnapshot: true)
        try append(writer, at: 106, color: (0, 0, 0))
        try append(writer, at: 113, color: (0, 255, 0))
        writer.queue.sync { writer.pause(at: time(114)) }
        await writer.resume(at: time(124))
        // Unchanged resumed content must not create a duplicate keyframe.
        try append(writer, at: 123, color: (0, 255, 0), initialSnapshot: true)
        let count = try await writer.finish(duration: 5).get()
        XCTAssertEqual(count, 3)
        let manifest = try readManifest(directory)
        XCTAssertEqual(manifest.frames.map(\.time), [0, 2, 3])
        XCTAssertEqual(manifest.duration, 5)
        XCTAssertEqual(manifest.width, 64)
        XCTAssertEqual(manifest.height, 48)
        for frame in manifest.frames {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(frame.file) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
        }
    }

    func testStopWhilePausedKeepsFrozenDurationAndNoPausedImages() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = makeWriter(directory: directory)
        try append(writer, at: 100, color: (0, 0, 255))
        writer.queue.sync { writer.pause(at: time(102.5)) }
        try append(writer, at: 110, color: (255, 0, 0))
        writer.queue.sync { writer.pause(at: time(120)) }
        let count = try await writer.finish(duration: 2.5).get()
        XCTAssertEqual(count, 1)
        let manifest = try readManifest(directory)
        XCTAssertEqual(manifest.duration, 2.5)
        XCTAssertEqual(manifest.frames.map(\.time), [0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("frames").path), ["000001.png"])
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }

    private func append(_ writer: KeyframeWriter, at seconds: Double, color: (UInt8, UInt8, UInt8), initialSnapshot: Bool = false) throws {
        let buffer = try recordingSample(at: seconds, color: color)
        writer.queue.sync { writer.append(buffer, initialSnapshot: initialSnapshot) }
    }

    private func makeWriter(directory: URL) -> KeyframeWriter {
        KeyframeWriter(directory: directory, id: UUID(), createdAt: Date(), started: time(100), sampleRate: 2,
            threshold: 0.01, width: 64, height: 48, onFrame: { _ in }, onFailure: { error, _ in XCTFail(error.localizedDescription) })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-keyframe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("frames"), withIntermediateDirectories: true)
        return url
    }

    private func readManifest(_ directory: URL) throws -> KeyframeManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeyframeManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }
}
