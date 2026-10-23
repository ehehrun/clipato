import CoreFoundation
import Darwin
import Foundation
import XCTest
@testable import Clipato

final class MCPAccessLogTests: XCTestCase {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-Logs-\(UUID())")
        let suite = "Clipato-MCP-Log-Tests-\(UUID())"
        let defaults: UserDefaults
        var file: URL { root.appendingPathComponent("access.log") }

        init(maximumMB: Int = 1) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(maximumMB, forKey: MCPAccessLog.maximumMBKey)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func files() -> [URL] { [file] + (1...3).map { file.appendingPathExtension(String($0)) } }

        func totalBytes() throws -> UInt64 {
            try files().reduce(0) { total, file in
                guard FileManager.default.fileExists(atPath: file.path) else { return total }
                return total + (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value
            }
        }

        func entries() throws -> [[String: Any]] {
            try files().reversed().flatMap { file -> [[String: Any]] in
                guard FileManager.default.fileExists(atPath: file.path) else { return [] }
                let data = try Data(contentsOf: file)
                XCTAssertTrue(data.isEmpty || data.last == 10)
                return try data.split(separator: 10).map {
                    try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
                }
            }
        }
    }

    func testConcurrentWritersProduceCompletePrivateJSONLines() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.file
        let writers = [MCPAccessLog(fileURL: file, defaults: fixture.defaults),
                       MCPAccessLog(fileURL: file, defaults: fixture.defaults)]
        let session = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await writers[index % 2].append(.init(sessionID: session, client: ["name": "test", "version": "1"],
                                                            id: String(index), method: "tools/call", tool: "vault_list", status: "completed"))
                }
            }
            try await group.waitForAll()
        }
        let lines = try String(contentsOf: file).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        let entries = try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(Set(entries.compactMap { $0["id"] as? String }).count, 100)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testParametersRemainJSONObjectsWithOriginalKeysTypesAndMetadata() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        let sessionID = UUID()
        let params: [String: Any] = ["name": "image_resize", "arguments": [
            "files": ["/tmp/图片\n\"原图\".png"], "output": "/tmp/处理结果", "quality": 87,
            "overwrite": false, "scale": 0.75, "nullable": NSNull(),
            "crop": ["x": 12, "y": 23, "width": 640, "height": 640],
            "sizes": [["width": 640, "height": 480], ["width": 1280, "height": 720]]
        ]]
        try await log.append(.init(timestamp: Date(timeIntervalSince1970: 0), sessionID: sessionID,
                                   client: ["name": "日志测试", "version": "1"], id: "request-1",
                                   method: "tools/call", tool: "image_resize", status: "received", params: params))
        try await log.append(.init(sessionID: sessionID, client: nil, id: "request-1", method: "tools/call",
                                   tool: "image_resize", status: "completed", durationMs: 125,
                                   assets: ["image:original"], message: "Saved"))
        try await log.append(.init(sessionID: sessionID, client: nil, id: "empty", method: "ping",
                                   tool: nil, status: "received", params: [:]))
        let entries = try fixture.entries()
        XCTAssertEqual(entries.count, 3)
        let received = entries[0]
        XCTAssertEqual(received["timestamp"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual(received["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(received["client"] as? [String: String], ["name": "日志测试", "version": "1"])
        XCTAssertEqual(Set(received.keys), ["timestamp", "sessionID", "client", "id", "method", "tool", "status", "params"])
        let recorded = try XCTUnwrap(received["params"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: recorded).isEqual(to: params))
        let arguments = try XCTUnwrap(recorded["arguments"] as? [String: Any])
        XCTAssertTrue(arguments["nullable"] is NSNull)
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(arguments["overwrite"] as? NSNumber)), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(arguments["quality"] as? NSNumber)), CFBooleanGetTypeID())
        XCTAssertNil(entries[1]["params"])
        XCTAssertNil(entries[1]["client"])
        XCTAssertEqual(entries[1]["durationMs"] as? Int, 125)
        XCTAssertEqual(entries[1]["assets"] as? [String], ["image:original"])
        XCTAssertEqual(entries[1]["message"] as? String, "Saved")
        XCTAssertEqual((entries[2]["params"] as? [String: Any])?.count, 0)
        XCTAssertNil(entries[2]["tool"])
    }

    func testParameterBytesCountTowardsTheTotalLogCapacityWithoutTruncation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        let payload = String(repeating: "原", count: 150_000)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "accepted", method: "tools/call",
                                   tool: "image_resize", status: "received", params: ["name": "image_resize", "arguments": ["prefix": payload]]))
        let accepted = try XCTUnwrap(try fixture.entries().first)
        let arguments = try XCTUnwrap((accepted["params"] as? [String: Any])?["arguments"] as? [String: String])
        XCTAssertEqual(arguments["prefix"], payload)
        XCTAssertGreaterThan(try fixture.totalBytes(), 450_000)
        let before = try Data(contentsOf: fixture.file)
        do {
            try await log.append(.init(sessionID: UUID(), client: nil, id: "too-large", method: "tools/call",
                                       tool: "image_resize", status: "received", params: ["arguments": ["prefix": String(repeating: "x", count: 1_000_000)]]))
            XCTFail("Parameter bytes must obey the same total limit as log metadata")
        } catch { XCTAssertEqual(error as? MCPAccessLogError, .oversizedEntry) }
        XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
    }

    func testTailIsBoundedAndRefreshesAfterAnAppend() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let file = fixture.file
        let log = MCPAccessLog(fileURL: file, defaults: fixture.defaults)
        let empty = try await log.recentText()
        XCTAssertEqual(empty, "")
        let line = String(repeating: "中", count: 100) + "\n"
        try Data(String(repeating: line, count: 2000).utf8).write(to: file)
        let tail = try await log.recentText()
        XCTAssertLessThanOrEqual(tail.utf8.count, 262_144)
        XCTAssertFalse(tail.contains("�"))
        XCTAssertTrue(tail.hasSuffix(line))
        try await log.append(.init(sessionID: UUID(), client: nil, id: "new", method: "tools/call", tool: "permissions", status: "completed"))
        let updated = try await log.recentText()
        XCTAssertTrue(updated.contains("\"id\":\"new\""))
    }

    func testUnavailableLogDestinationFailsExplicitly() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try Data("not a directory".utf8).write(to: fixture.root)
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        do {
            try await log.append(.init(sessionID: UUID(), client: nil, id: nil, method: "connect", tool: nil, status: "connected"))
            XCTFail("A log write failure must be reported")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try String(contentsOf: fixture.root), "not a directory")
    }

    func testTailCommandQuotesTheEntirePath() {
        let path = URL(fileURLWithPath: "/tmp/Clipato 'QA'; $(touch ignored)/access.log")
        XCTAssertEqual(MCPAccessLog.tailCommand(for: path), "tail -F -- '/tmp/Clipato '\\''QA'\\''; $(touch ignored)/access.log'")
    }

    func testRotationRetainsCompleteNewestGenerationsWithinTotalLimit() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        for index in 0..<12 {
            try await log.append(.init(sessionID: UUID(), client: nil, id: String(index), method: "tools/call",
                                       tool: "vault_list", status: "completed", message: String(repeating: "a", count: 100_000)))
        }
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, (4..<12).map(String.init))
        for file in fixture.files() {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue, 0o600)
        }
    }

    func testConcurrentWritersStayWithinBudgetDuringRotation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let writers = (0..<4).map { _ in MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    try await writers[index % writers.count].append(.init(sessionID: UUID(), client: nil,
                        id: String(index), method: "tools/call", tool: "vault_list", status: "completed",
                        message: String(repeating: "x", count: 20_000)))
                }
            }
            try await group.waitForAll()
        }
        let entries = try fixture.entries()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertLessThan(entries.count, 100)
        XCTAssertEqual(Set(entries.compactMap { $0["id"] as? String }).count, entries.count)
        XCTAssertTrue(entries.allSatisfy { ($0["message"] as? String)?.count == 20_000 })
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
    }

    func testChangingMaximumImmediatelyPrunesAndOtherWritersUseNewLimit() async throws {
        let fixture = Fixture(maximumMB: 4)
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        let other = MCPAccessLog(fileURL: fixture.file, defaults: UserDefaults(suiteName: fixture.suite)!)
        for index in 0..<8 {
            try await log.append(.init(sessionID: UUID(), client: nil, id: String(index), method: "tools/call",
                                       tool: "vault_list", status: "completed", message: String(repeating: "a", count: 300_000)))
        }
        XCTAssertGreaterThan(try fixture.totalBytes(), 1_000_000)
        try await log.setMaximumMB(1)
        XCTAssertEqual(MCPAccessLog.maximumMB(in: fixture.defaults), 1)
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, ["6", "7"])
        for index in 8..<10 {
            try await other.append(.init(sessionID: UUID(), client: nil, id: String(index), method: "tools/call",
                                         tool: "vault_list", status: "completed", message: String(repeating: "b", count: 200_000)))
            XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
        }
        let restarted = MCPAccessLog(fileURL: fixture.file, defaults: UserDefaults(suiteName: fixture.suite)!)
        try await restarted.prepare()
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, ["8", "9"])
    }

    func testPreparePrunesPreviouslyUnboundedLog() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data(repeating: 120, count: 2_000_000).write(to: fixture.file)
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        try await log.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try fixture.totalBytes(), 0)
    }

    func testLargeEntryGetsOwnGenerationAndOversizedEntryFailsWithoutMutation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        for id in ["old", "new"] {
            try await log.append(.init(sessionID: UUID(), client: nil, id: id, method: "tools/call",
                                       tool: "vault_list", status: "completed", message: String(repeating: "x", count: 600_000)))
        }
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, ["new"])
        let before = try Data(contentsOf: fixture.file)
        do {
            try await log.append(.init(sessionID: UUID(), client: nil, id: "oversized", method: "tools/call",
                                       tool: "vault_list", status: "completed", message: String(repeating: "x", count: 1_000_000)))
            XCTFail("An entry larger than the total budget must fail explicitly")
        } catch { XCTAssertEqual(error as? MCPAccessLogError, .oversizedEntry) }
        XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        XCTAssertLessThanOrEqual(try fixture.totalBytes(), 1_000_000)
    }

    func testTailReportsOversizedPreviewEntryAndRecoversAfterNormalAppend() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "large", method: "tools/call",
                                   tool: "vault_list", status: "completed", message: String(repeating: "x", count: 600_000)))
        do {
            _ = try await log.recentText()
            XCTFail("An oversized entry must not be shown as an empty log")
        } catch { XCTAssertEqual(error as? MCPAccessLogError, .previewEntryTooLarge) }
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, ["large"])
        try await log.append(.init(sessionID: UUID(), client: nil, id: "normal", method: "connect", tool: nil, status: "connected"))
        let text = try await log.recentText()
        XCTAssertTrue(text.contains("\"id\":\"normal\""))
        XCTAssertFalse(text.contains("\"id\":\"large\""))
        XCTAssertLessThanOrEqual(text.utf8.count, 262_144)
    }

    func testInvalidMaximumDoesNotReplaceSavedSettingOrLog() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "keep", method: "connect", tool: nil, status: "connected"))
        let before = try Data(contentsOf: fixture.file)
        for value in [0, -1, 1025] {
            do {
                try await log.setMaximumMB(value)
                XCTFail("An invalid maximum must fail explicitly")
            } catch { XCTAssertEqual(error as? MCPAccessLogError, .invalidMaximumMB) }
            XCTAssertEqual(MCPAccessLog.maximumMB(in: fixture.defaults), 1)
            XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        }
        for value in [0, 1.5, true, "1"] as [Any] {
            fixture.defaults.set(value, forKey: MCPAccessLog.maximumMBKey)
            do {
                try await log.append(.init(sessionID: UUID(), client: nil, id: "invalid", method: "connect", tool: nil, status: "connected"))
                XCTFail("An invalid persisted value must not be silently repaired")
            } catch { XCTAssertEqual(error as? MCPAccessLogError, .invalidMaximumMB) }
            XCTAssertEqual(try Data(contentsOf: fixture.file), before)
        }
        fixture.defaults.removeObject(forKey: MCPAccessLog.maximumMBKey)
        XCTAssertEqual(MCPAccessLog.maximumMB(in: fixture.defaults), 20)
    }

    func testActiveAndLockSymlinksNeverModifyTheirTargets() async throws {
        for isLock in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            let target = fixture.root.appendingPathComponent("target")
            try Data("keep target".utf8).write(to: target)
            let link = isLock ? fixture.file.appendingPathExtension("lock") : fixture.file
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
            do {
                try await log.append(.init(sessionID: UUID(), client: nil, id: nil, method: "connect", tool: nil, status: "connected"))
                XCTFail("Symbolic links must not be opened as log or lock files")
            } catch { XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain) }
            do {
                _ = try await log.recentText()
                XCTFail("Symbolic links must not be followed when displaying logs")
            } catch { XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain) }
            XCTAssertEqual(try String(contentsOf: target), "keep target")
        }
    }

    func testArchiveSymlinkIsRemovedWithoutTouchingItsTargetDuringRotation() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "old", method: "connect", tool: nil,
                                   status: "connected", message: String(repeating: "x", count: 200_000)))
        let target = fixture.root.appendingPathComponent("target")
        try Data("keep target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.file.appendingPathExtension("3"), withDestinationURL: target)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "new", method: "connect", tool: nil,
                                   status: "connected", message: String(repeating: "x", count: 200_000)))
        XCTAssertEqual(try String(contentsOf: target), "keep target")
        XCTAssertEqual(try fixture.entries().compactMap { $0["id"] as? String }, ["old", "new"])
    }

    func testFIFOLogAndLockFailWithoutBlocking() async throws {
        for isLock in [false, true] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            let fifo = isLock ? fixture.file.appendingPathExtension("lock") : fixture.file
            XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
            let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
            do {
                try await log.prepare()
                XCTFail("A FIFO is not a valid log or lock file")
            } catch { XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain) }
        }
    }

    func testTailRefreshesAfterReplacementWithSameSizeAndModificationDate() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let log = MCPAccessLog(fileURL: fixture.file, defaults: fixture.defaults)
        try await log.append(.init(sessionID: UUID(), client: nil, id: "old", method: "connect", tool: nil, status: "connected"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.file.path)
        let old = try await log.recentText()
        XCTAssertTrue(old.contains("\"id\":\"old\""))
        try FileManager.default.moveItem(at: fixture.file, to: fixture.root.appendingPathComponent("replaced.log"))
        let replacement = old.replacingOccurrences(of: "\"id\":\"old\"", with: "\"id\":\"new\"")
        try Data(replacement.utf8).write(to: fixture.file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.file.path)
        let updated = try await log.recentText()
        XCTAssertTrue(updated.contains("\"id\":\"new\""))
        XCTAssertFalse(updated.contains("\"id\":\"old\""))
    }
}
