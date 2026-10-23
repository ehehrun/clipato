import CoreFoundation
import CoreGraphics
import ClipatoCore
import Darwin
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class MCPServerTests: XCTestCase {
    func testToolThatFinalizesAfterCancellationIsLoggedAsCompletedWithoutSendingALateResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditFinalized-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        let started = expectation(description: "Tool started")
        let finalized = expectation(description: "Tool finalized after cancellation")
        let client = try Client(callTool: { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(20)) }
            catch is CancellationError { finalized.fulfill() }
            return ["saved": true]
        }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/call", params: ["name": "test_tool"]))
        await fulfillment(of: [started], timeout: 3)
        try await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]])
        await fulfillment(of: [finalized], timeout: 3)
        try await client.send(Client.modern(id: 2, method: "ping"))
        _ = try await client.object(2, key: "result")
        try await client.finish()
        XCTAssertFalse(client.messages.contains { $0["id"] as? Int == 1 })
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.contains("\"status\":\"completed\""))
        XCTAssertFalse(text.contains("\"status\":\"cancelled\""))
    }

    func testLogFailurePreventsServerStartingBeforeToolWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditFailure-\(UUID())")
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var called = false
        let server = MCPServer(library: root.appendingPathComponent("unused-vault"), isEnabled: { true }, callTool: { _, _, _ in
            called = true
            return [:]
        }, accessLog: makeAccessLog(root.appendingPathComponent("access.log")))
        do {
            try await server.run(input: .nullDevice, output: .nullDevice)
            XCTFail("An unavailable audit log must stop execution")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertFalse(called)
    }

    func testLogFailureAfterToolCompletionReturnsItsRealResultWithAnExplicitWarning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditCompletion-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        let client = try Client(callTool: { _, _, _ in
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            return ["count": 3]
        }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/call", params: ["name": "test_tool"]))
        let result = try await client.object(1, key: "result")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Int])?["count"], 3)
        let content = try XCTUnwrap(result["content"] as? [[String: String]])
        XCTAssertTrue(content.contains { $0["text"]?.contains("Operation completed, but the access log could not be written") == true })
        try await client.finish()
    }

    func testAccessLogPreservesOriginalParametersOnceAndDoesNotRecordReturnedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-Audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        let client = try Client(callTool: { _, _, _ in ["resultOnly": "do-not-log-return-payload"] }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        let initialize = Client.initialize(id: 1, version: "2025-11-25")
        try await client.send(initialize)
        _ = try await client.response(1)
        try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let arguments: [String: Any] = [
            "files": ["/tmp/中文\n图片.png", "/tmp/日本語.jpg"], "quality": 87,
            "threshold": 0.025, "overwrite": true, "nullable": NSNull(), "flags": [true, false],
            "crop": ["x": 0, "y": 12, "width": 512, "height": 512],
            "sizes": [["width": 1280, "height": 720, "mode": "fit"], ["width": 640, "height": 480, "mode": "crop"]]
        ]
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "test_tool", "arguments": arguments]]
        try await client.send(request)
        let result = try await client.object(2, key: "result")
        XCTAssertEqual((result["structuredContent"] as? [String: String])?["resultOnly"], "do-not-log-return-payload")
        try await client.finish()
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("do-not-log-return-payload"))
        let entries = try logEntries(file)
        let received = try XCTUnwrap(entries.first { $0["id"] as? String == "2" && $0["status"] as? String == "received" })
        let params = try XCTUnwrap(received["params"] as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: params).isEqual(to: request["params"] as! [String: Any]))
        let recorded = try XCTUnwrap(params["arguments"] as? [String: Any])
        XCTAssertTrue(recorded["nullable"] is NSNull)
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(recorded["overwrite"] as? NSNumber)), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(recorded["quality"] as? NSNumber)), CFBooleanGetTypeID())
        let flags = try XCTUnwrap(recorded["flags"] as? [NSNumber])
        XCTAssertTrue(flags.allSatisfy { CFGetTypeID($0) == CFBooleanGetTypeID() })
        XCTAssertEqual(flags.map(\.boolValue), [true, false])
        let initialized = try XCTUnwrap(entries.first { $0["id"] as? String == "1" && $0["status"] as? String == "received" })
        XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(initialized["params"] as? [String: Any])).isEqual(to: initialize["params"] as! [String: Any]))
        let completed = try XCTUnwrap(entries.first { $0["id"] as? String == "2" && $0["status"] as? String == "completed" })
        XCTAssertEqual(completed["tool"] as? String, "test_tool")
        XCTAssertEqual((completed["client"] as? [String: String])?["name"], "ClipatoTests")
        XCTAssertEqual(completed["transport"] as? String, "mcp")
        let caller = try XCTUnwrap(completed["caller"] as? [String: Any])
        XCTAssertEqual((caller["process"] as? [String: Any])?["pid"] as? Int32, getpid())
        XCTAssertFalse(try XCTUnwrap(caller["ancestors"] as? [[String: Any]]).isEmpty)
        XCTAssertNotNil(completed["durationMs"] as? Int)
        XCTAssertEqual(completed["sessionID"] as? String, received["sessionID"] as? String)
        XCTAssertEqual(entries.filter { $0["id"] as? String == "2" && $0["params"] != nil }.count, 1)
        XCTAssertTrue(entries.filter { $0["status"] as? String != "received" }.allSatisfy { $0["params"] == nil })
        let notification = try XCTUnwrap(entries.first { $0["method"] as? String == "notifications/initialized" })
        XCTAssertNil(notification["params"], "An absent params field must not become an invented empty object")
    }

    func testRejectedAndFailedCallsKeepTheirOriginalReceivedParameters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditRejected-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        var enabled = true
        var calls = 0
        let client = try Client(isEnabled: { enabled }, callTool: { _, _, _ in
            calls += 1
            throw NSError(domain: "MCPServerTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing input image"])
        }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        let unknown = Client.modern(id: 1, method: "tools/call", params: ["name": "missing_tool", "arguments": ["files": ["/tmp/unknown.png"]]])
        try await client.send(unknown)
        try await assertError(client, id: 1, code: -32602)
        enabled = false
        let disabled = Client.modern(id: 2, method: "tools/call", params: ["name": "test_tool", "arguments": ["overwrite": false]])
        try await client.send(disabled)
        try await assertError(client, id: 2, code: -31000)
        enabled = true
        let invalid = Client.modern(id: 3, method: "tools/call", params: ["name": "test_tool", "arguments": ["invalid array"]])
        try await client.send(invalid)
        try await assertError(client, id: 3, code: -32602)
        let failed = Client.modern(id: 4, method: "tools/call", params: ["name": "test_tool", "arguments": ["files": ["/tmp/missing.png"]]])
        try await client.send(failed)
        let result = try await client.object(4, key: "result")
        XCTAssertEqual(result["isError"] as? Bool, true)
        try await client.send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["not an object"]])
        try await assertError(client, id: 5, code: -32602)
        try await client.finish()
        XCTAssertEqual(calls, 1)
        let entries = try logEntries(file)
        for (index, request) in [unknown, disabled, invalid, failed].enumerated() {
            let id = String(index + 1)
            let received = try XCTUnwrap(entries.first { $0["id"] as? String == id && $0["status"] as? String == "received" })
            XCTAssertTrue(NSDictionary(dictionary: try XCTUnwrap(received["params"] as? [String: Any])).isEqual(to: request["params"] as! [String: Any]))
            let final = try XCTUnwrap(entries.first { $0["id"] as? String == id && $0["status"] as? String == (index == 3 ? "failed" : "rejected") })
            XCTAssertEqual(final["sessionID"] as? String, received["sessionID"] as? String)
            XCTAssertEqual(final["method"] as? String, "tools/call")
            XCTAssertNil(final["params"])
        }
        let invalidParams = try XCTUnwrap(entries.first { $0["id"] as? String == "5" && $0["status"] as? String == "rejected" })
        XCTAssertEqual(invalidParams["method"] as? String, "tools/call")
        XCTAssertNil(invalidParams["params"])
        XCTAssertFalse(entries.contains { $0["id"] as? String == "5" && $0["status"] as? String == "received" })
    }

    func testRequestLargerThanLogCapacityIsExplicitlyRejectedWithoutDisconnecting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditOversized-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        var calls = 0
        let client = try Client(callTool: { _, _, _ in calls += 1; return [:] }, accessLog: makeAccessLog(file, maximumMB: 1))
        addTeardownBlock { try await client.finish() }
        let marker = "parameter-must-not-be-truncated-"
        let request = Client.modern(id: 1, method: "tools/call", params: ["name": "test_tool", "arguments": ["files": ["/tmp/" + marker + String(repeating: "x", count: 1_040_000)]]])
        let frame = try Client.data(request)
        XCTAssertGreaterThan(frame.count, 1_000_000)
        XCTAssertLessThanOrEqual(frame.count, MCPServer.maximumMessageBytes)
        try await client.write(frame + Data([10]))
        let failure = try await client.object(1, key: "error")
        XCTAssertEqual(failure["code"] as? Int, -32603)
        let message = try XCTUnwrap(failure["message"] as? String)
        XCTAssertEqual(message, L("请求日志超过容量上限，参数未保存，操作未执行。请增大日志容量或缩小请求。"))
        try await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled",
                               "params": ["requestId": 1, "reason": marker + String(repeating: "y", count: 1_040_000)]])
        try await client.send(Client.modern(id: 2, method: "ping"))
        _ = try await client.object(2, key: "result")
        try await client.finish()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(client.messages.count, 2, "Rejected notifications must not generate responses")
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains(marker))
        let entries = try logEntries(file)
        let rejected = entries.filter { $0["method"] as? String == "transport" && $0["status"] as? String == "rejected" }
        XCTAssertEqual(rejected.count, 2)
        for entry in rejected {
            XCTAssertEqual(Set(entry.keys), ["timestamp", "sessionID", "method", "status", "message"])
            XCTAssertEqual(entry["message"] as? String, message)
        }
        XCTAssertFalse(entries.contains { $0["id"] as? String == "1" && ["received", "started", "completed"].contains($0["status"] as? String ?? "") })
        let bytes = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber
        XCTAssertLessThanOrEqual(bytes.intValue, 1_000_000)
    }

    func testOversizedProtocolFieldsCannotEnlargeRejectionLogsOrPoisonTheClient() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditOversizedFields-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        var calls = 0
        let client = try Client(callTool: { _, _, _ in calls += 1; return [:] }, accessLog: makeAccessLog(file, maximumMB: 1))
        addTeardownBlock { try await client.finish() }
        let oversized = "oversized-protocol-field-" + String(repeating: "x", count: 1_040_000)
        var largeID = Client.modern(id: 2, method: "ping")
        largeID["id"] = oversized
        var largeClient = Client.modern(id: 4, method: "ping")
        var metadata = (largeClient["params"] as! [String: Any])["_meta"] as! [String: Any]
        metadata["io.modelcontextprotocol/clientInfo"] = ["name": oversized, "version": "1"]
        largeClient["params"] = ["_meta": metadata]
        let requests = [
            Client.modern(id: 1, method: "tools/call", params: ["name": oversized]),
            largeID,
            Client.modern(id: 3, method: oversized),
            largeClient
        ]
        let message = L("请求日志超过容量上限，参数未保存，操作未执行。请增大日志容量或缩小请求。")
        for (index, request) in requests.enumerated() {
            let frame = try Client.data(request)
            XCTAssertGreaterThan(frame.count, 1_000_000)
            XCTAssertLessThanOrEqual(frame.count, MCPServer.maximumMessageBytes)
            let count = client.messages.count
            try await client.write(frame + Data([10]))
            await client.waitForCount(count + 1)
            let response = try XCTUnwrap(client.messages.last)
            let failure = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(failure["code"] as? Int, -32603)
            XCTAssertEqual(failure["message"] as? String, message)
            if let id = request["id"] as? String {
                XCTAssertTrue(response["id"] as? String == id, "The original string ID must be returned unchanged")
            } else {
                XCTAssertEqual(response["id"] as? Int, request["id"] as? Int)
            }
            try await client.send(Client.modern(id: 100 + index, method: "ping"))
            _ = try await client.object(100 + index, key: "result")
        }
        try await client.finish()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(client.messages.count, 8)
        let entries = try logEntries(file)
        let rejected = entries.filter { $0["status"] as? String == "rejected" }
        XCTAssertEqual(rejected.count, 4)
        for entry in rejected {
            XCTAssertEqual(Set(entry.keys), ["timestamp", "sessionID", "method", "status", "message"])
            XCTAssertEqual(entry["method"] as? String, "transport")
            XCTAssertEqual(entry["message"] as? String, message)
        }
        XCTAssertTrue(entries.allSatisfy { $0["client"] == nil }, "Rejected client metadata must not affect later pings")
        XCTAssertFalse(try String(contentsOf: file).contains("oversized-protocol-field-"))
    }

    func testLargeUnknownNamesAndMethodsReturnTheirProtocolErrorsWithinLogBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditUnknownFields-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let largeName = String(repeating: "n", count: 400_000)
        let largeMethod = String(repeating: "m", count: 600_000)
        let cases: [([String: Any], Int, String)] = [
            (Client.modern(id: 1, method: "tools/call", params: ["name": largeName]), -32602, "Unknown tool"),
            (Client.modern(id: 1, method: largeMethod), -32601, "Method not found")
        ]
        for (index, testCase) in cases.enumerated() {
            let file = root.appendingPathComponent("access-\(index).log")
            let client = try Client(accessLog: makeAccessLog(file, maximumMB: 1))
            addTeardownBlock { try await client.finish() }
            try await client.send(testCase.0)
            let failure = try await client.object(1, key: "error")
            XCTAssertEqual(failure["code"] as? Int, testCase.1)
            XCTAssertEqual(failure["message"] as? String, testCase.2)
            try await client.send(Client.modern(id: 2, method: "ping"))
            _ = try await client.object(2, key: "result")
            try await client.finish()
            let entries = try logEntries(file)
            let rejected = try XCTUnwrap(entries.first { $0["id"] as? String == "1" && $0["status"] as? String == "rejected" })
            XCTAssertEqual(rejected["message"] as? String, testCase.2)
            XCTAssertFalse(entries.contains { $0["method"] as? String == "transport" && $0["status"] as? String == "rejected" })
            let files = [file] + (1...3).map { file.appendingPathExtension(String($0)) }
            let bytes = try files.reduce(0) { total, url in
                guard FileManager.default.fileExists(atPath: url.path) else { return total }
                return total + (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
            }
            XCTAssertLessThanOrEqual(bytes, 1_000_000)
        }
    }

    func testLegacyLifecycleAndFragmentedMultipleMessages() async throws {
        let client = try Client()
        addTeardownBlock { try await client.finish() }
        let initialize = try Client.data(Client.initialize(id: 1, version: "2025-06-18"))
        try await client.write(initialize.prefix(17))
        try await client.write(initialize.dropFirst(17) + Data([10]))
        let initialization = try await client.response(1)
        XCTAssertEqual((initialization["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(((initialization["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "Clipato")
        XCTAssertEqual(((initialization["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["version"] as? String, AppVersion.number)
        XCTAssertNil((initialization["result"] as? [String: Any])?["resultType"])

        try await client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        try await assertError(client, id: 2, code: -32602)
        let ready: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]
        try await client.write(Client.data(ready) + Data([10]) + Client.data(list) + Data([13, 10]))
        let tools = (try await client.response(3)["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.first?["name"] as? String, "test_tool")
        try await client.send(Client.initialize(id: 4, version: "2025-11-25"))
        try await assertError(client, id: 4, code: -32600)
        try await client.finish()
        XCTAssertEqual(client.messages.count, 4)
    }

    func testModernDiscoveryAndIndependentRequestMetadata() async throws {
        let client = try Client(callTool: { _, arguments, library in
            XCTAssertEqual(library.lastPathComponent, "mcp-test-library")
            return ["name": arguments["name"]!, "paths": ["/tmp/图片.png"]]
        })
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "server/discover"))
        let discovery = try await client.object(1, key: "result")
        XCTAssertEqual(discovery["supportedVersions"] as? [String], MCPServer.supportedVersions)
        XCTAssertEqual(discovery["resultType"] as? String, "complete")
        XCTAssertEqual(discovery["ttlMs"] as? Int, 0)
        XCTAssertEqual(discovery["cacheScope"] as? String, "private")
        XCTAssertEqual(((discovery["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String, "Clipato")
        XCTAssertEqual(((discovery["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["version"] as? String, AppVersion.number)
        XCTAssertEqual((discovery["capabilities"] as? [String: Any])?.count, 1)

        try await client.send(Client.modern(id: 2, method: "tools/call", params: ["name": "test_tool", "arguments": ["name": "中文\n文件"]]))
        let result = try await client.object(2, key: "result")
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["name"] as? String, "中文\n文件")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let textResult = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(textResult["paths"] as? [String], ["/tmp/图片.png"])
        XCTAssertEqual(result["isError"] as? Bool, false)

        try await client.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        try await assertError(client, id: 3, code: -32602)
        try await client.send(Client.modern(id: 4, method: "tools/list", version: "2100-01-01"))
        let unsupported = try await client.object(4, key: "error")
        XCTAssertEqual(unsupported["code"] as? Int, -32022)
        XCTAssertEqual((unsupported["data"] as? [String: Any])?["supported"] as? [String], MCPServer.supportedVersions)
        try await client.send(["jsonrpc": "2.0", "id": 5, "method": "ping", "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]])
        try await assertError(client, id: 5, code: -32602)
        try await client.finish()
    }

    func testProductionRegistryConvertsARealImageOverThePipe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.MCPPipe.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 128,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        let source = root.appendingPathComponent("original.png")
        let original = try ImageFormatStep.execute(image: XCTUnwrap(context.makeImage()), format: .png)
        try original.write(to: source)
        let library = root.appendingPathComponent("Library")
        let output = root.appendingPathComponent("converted")
        let client = try Client(library: library, definitions: nil, callTool: nil)
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/list"))
        let list = try await client.object(1, key: "result")
        let tools = try XCTUnwrap(list["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["name"] as? String == "image_convert" })
        XCTAssertEqual(list["ttlMs"] as? Int, 0)
        XCTAssertEqual(list["cacheScope"] as? String, "private")
        try await client.send(Client.modern(id: 2, method: "tools/call", params: [
            "name": "image_convert", "arguments": ["files": [source.path], "output": output.path,
                                                      "format": "jpeg", "quality": 87]
        ]))
        let result = try await client.object(2, key: "result")
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let paths = try XCTUnwrap(structured["files"] as? [String])
        XCTAssertEqual(paths.count, 1)
        let converted = URL(fileURLWithPath: try XCTUnwrap(paths.first))
        XCTAssertEqual(converted.deletingLastPathComponent().path, output.path)
        let convertedSource = try XCTUnwrap(CGImageSourceCreateWithURL(converted as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(convertedSource) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(convertedSource, 0, nil))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 20)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let textResult = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(textResult["files"] as? [String], paths)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        try await client.finish()
    }

    func testMalformedUnknownAndToolErrorsRemainProtocolMessages() async throws {
        let client = try Client(callTool: { _, _, _ in
            throw NSError(domain: "MCPServerTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "The source file does not exist"])
        })
        try await client.write(Data("not JSON\n[]\n{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}\n".utf8))
        await client.waitForCount(3)
        XCTAssertEqual(client.messages.compactMap { ($0["error"] as? [String: Any])?["code"] as? Int }, [-32700, -32600, -32600])
        try await client.send(["jsonrpc": "2.0", "id": 4, "method": "ping", "params": []])
        try await assertError(client, id: 4, code: -32602)
        try await client.send(Client.modern(id: 5, method: "not_a_method"))
        try await assertError(client, id: 5, code: -32601)
        try await client.send(Client.modern(id: 6, method: "tools/call", params: ["name": "unknown"]))
        try await assertError(client, id: 6, code: -32602)
        try await client.send(Client.modern(id: 7, method: "tools/call", params: ["name": "test_tool", "arguments": []]))
        try await assertError(client, id: 7, code: -32602)
        try await client.send(Client.modern(id: 8, method: "tools/call", params: ["name": "test_tool"]))
        let failure = try await client.object(8, key: "result")
        XCTAssertEqual(failure["isError"] as? Bool, true)
        XCTAssertEqual((failure["content"] as? [[String: Any]])?.first?["text"] as? String, "The source file does not exist")
        try await client.finish()
    }

    func testMalformedModernMetadataNeverUsesAnInitializedLegacySession() async throws {
        let client = try Client()
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.initialize(id: 1, version: "2025-11-25"))
        let initialized = try await client.object(1, key: "result")
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-11-25")
        try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let version = "io.modelcontextprotocol/protocolVersion"
        let capabilities = "io.modelcontextprotocol/clientCapabilities"
        let malformed: [Any] = [
            [version: false, capabilities: [:]],
            [capabilities: [:]],
            [version: "2026-07-28", capabilities: []],
            [version: "2026-07-28", capabilities: [:], "io.modelcontextprotocol/clientInfo": "bad"],
            [version: "2026-07-28", capabilities: [:], "io.modelcontextprotocol/logLevel": 17],
            []
        ]
        for (index, meta) in malformed.enumerated() {
            let id = index + 2
            try await client.send(["jsonrpc": "2.0", "id": id, "method": "ping", "params": ["_meta": meta]])
            try await assertError(client, id: id, code: -32602)
        }
        let count = client.messages.count
        var invalidID = Client.modern(id: 20, method: "ping")
        invalidID["id"] = NSNull()
        try await client.send(invalidID)
        await client.waitForCount(count + 1)
        XCTAssertNil(client.messages.last?["id"], "Recognized modern malformed requests omit an unreadable ID")
        XCTAssertEqual((client.messages.last?["error"] as? [String: Any])?["code"] as? Int, -32600)

        try await client.send(["jsonrpc": "2.0", "id": 21, "method": "ping", "params": ["_meta": ["progressToken": "legacy-progress"]]])
        let legacyPing = try await client.object(21, key: "result")
        XCTAssertNil(legacyPing["resultType"], "Legacy progress metadata does not select the modern protocol")
        var stringID = Client.modern(id: 22, method: "ping")
        stringID["id"] = "string-request"
        try await client.send(stringID)
        await client.waitForCount(count + 3)
        XCTAssertEqual(client.messages.last?["id"] as? String, "string-request")
        XCTAssertEqual((client.messages.last?["result"] as? [String: Any])?["resultType"] as? String, "complete")
        try await client.finish()
    }

    func testCancellationKeepsPingResponsiveAndRejectsConcurrentOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AuditCancellation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        let started = expectation(description: "Tool started")
        let cancelled = expectation(description: "Tool cancelled")
        let client = try Client(callTool: { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { cancelled.fulfill(); throw error }
            return [:]
        }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/call", params: ["name": "test_tool"]))
        await fulfillment(of: [started], timeout: 3)
        try await client.send(Client.modern(id: 2, method: "ping"))
        _ = try await client.object(2, key: "result")
        try await client.send(Client.modern(id: 3, method: "tools/call", params: ["name": "test_tool"]))
        try await assertError(client, id: 3, code: -31001)
        try await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]])
        await fulfillment(of: [cancelled], timeout: 3)
        try await client.send(Client.modern(id: 4, method: "ping"))
        _ = try await client.object(4, key: "result")
        try await client.finish()
        XCTAssertFalse(client.messages.contains { $0["id"] as? Int == 1 }, "A cancelled request must not receive a later result or error")
        let log = try String(contentsOf: file)
        XCTAssertTrue(log.contains("\"status\":\"cancelled\""))
        let entries = try logEntries(file)
        let received = try XCTUnwrap(entries.first { $0["id"] as? String == "1" && $0["status"] as? String == "received" })
        let cancellation = try XCTUnwrap(entries.first { $0["method"] as? String == "notifications/cancelled" })
        XCTAssertEqual(cancellation["status"] as? String, "received")
        XCTAssertEqual((cancellation["params"] as? [String: Int])?["requestId"], 1)
        XCTAssertEqual(cancellation["sessionID"] as? String, received["sessionID"] as? String)
        let cancelledEntry = try XCTUnwrap(entries.first { $0["id"] as? String == "1" && $0["status"] as? String == "cancelled" })
        XCTAssertEqual(cancelledEntry["sessionID"] as? String, received["sessionID"] as? String)
        XCTAssertNil(cancelledEntry["params"])
        let busy = try XCTUnwrap(entries.first { $0["id"] as? String == "3" && $0["status"] as? String == "received" })
        XCTAssertEqual((busy["params"] as? [String: Any])?["name"] as? String, "test_tool")
        XCTAssertTrue(entries.filter { $0["status"] as? String != "received" }.allSatisfy { $0["params"] == nil })
    }

    func testEOFStopsAndAwaitsTheOutstandingOperation() async throws {
        let started = expectation(description: "Tool started")
        var cancelled = false
        let client = try Client(callTool: { _, _, _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { cancelled = Task.isCancelled; throw error }
            return [:]
        })
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/call", params: ["name": "test_tool"]))
        await fulfillment(of: [started], timeout: 3)
        try await client.finish()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(client.messages.isEmpty)
    }

    func testDisabledAtStartupAndDisabledAgainBeforeEachToolListOrCall() async throws {
        let server = MCPServer(library: URL(fileURLWithPath: "/tmp/mcp-test-library"), isEnabled: { false }, definitions: [])
        do {
            try await server.run(input: .nullDevice, output: .nullDevice)
            XCTFail("A disabled server must refuse startup")
        } catch {
            XCTAssertEqual(error.localizedDescription, MCPServerError.mcpDisabled.localizedDescription)
        }
        var enabled = true
        var calls = 0
        let client = try Client(isEnabled: { enabled }, callTool: { _, _, _ in calls += 1; return [:] })
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "tools/list"))
        _ = try await client.object(1, key: "result")
        try await client.send(Client.modern(id: 2, method: "tools/call", params: ["name": "test_tool"]))
        _ = try await client.object(2, key: "result")
        enabled = false
        try await client.send(Client.modern(id: 3, method: "tools/list"))
        try await assertError(client, id: 3, code: -31000)
        try await client.send(Client.modern(id: 4, method: "tools/call", params: ["name": "test_tool"]))
        try await assertError(client, id: 4, code: -31000)
        XCTAssertEqual(calls, 1)
        try await client.finish()
    }

    func testInitializedLegacySessionCannotListOrCallToolsAfterDisabling() async throws {
        var enabled = true
        var calls = 0
        let client = try Client(isEnabled: { enabled }, callTool: { _, _, _ in calls += 1; return [:] })
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.initialize(id: 1, version: "2025-11-25"))
        _ = try await client.object(1, key: "result")
        try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try await client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        _ = try await client.object(2, key: "result")

        enabled = false
        try await client.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        try await assertError(client, id: 3, code: -31000)
        try await client.send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "test_tool"]])
        try await assertError(client, id: 4, code: -31000)
        XCTAssertEqual(calls, 0)
        try await client.finish()
    }

    func testRevocationAfterRequestAuthorizationPreventsToolExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-RevokedBeforeExecution-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("access.log")
        var enabled = true
        var revokeAfterAuthorization = false
        var calls = 0
        let client = try Client(isEnabled: {
            let allowed = enabled
            if revokeAfterAuthorization {
                enabled = false
                revokeAfterAuthorization = false
            }
            return allowed
        }, callTool: { _, _, _ in calls += 1; return [:] }, accessLog: makeAccessLog(file))
        addTeardownBlock { try await client.finish() }
        try await client.send(Client.modern(id: 1, method: "ping"))
        _ = try await client.object(1, key: "result")

        revokeAfterAuthorization = true
        try await client.send(Client.modern(id: 2, method: "tools/call", params: ["name": "test_tool"]))
        let result = try await client.object(2, key: "result")
        XCTAssertFalse(enabled)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: String]])
        XCTAssertEqual(content.first?["text"], MCPServerError.mcpDisabled.localizedDescription)
        try await client.finish()

        let entries = try logEntries(file).filter { $0["id"] as? String == "2" }
        XCTAssertEqual(entries.map { $0["status"] as? String }, ["received", "started", "denied"])
        XCTAssertFalse(entries.contains { $0["status"] as? String == "completed" })
    }

    func testOversizedAndIncompleteFramesAreBoundedAndRecoverable() async throws {
        let client = try Client()
        addTeardownBlock { try await client.finish() }
        try await client.write(Data(repeating: 0x61, count: MCPServer.maximumMessageBytes + 1) + Data([10]))
        await client.waitForCount(1)
        XCTAssertEqual((client.messages[0]["error"] as? [String: Any])?["code"] as? Int, -32700)
        try await client.send(Client.modern(id: 1, method: "ping"))
        _ = try await client.object(1, key: "result")
        try await client.write(Data("{\"jsonrpc\":".utf8))
        try await client.finish()
        XCTAssertEqual(client.messages.count, 3)
        XCTAssertEqual((client.messages[2]["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    private func makeAccessLog(_ file: URL, maximumMB: Int = 20) -> MCPAccessLog {
        let suite = "Clipato-MCP-Server-Tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(maximumMB, forKey: MCPAccessLog.maximumMBKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return MCPAccessLog(fileURL: file, defaults: defaults)
    }

    private func logEntries(_ file: URL) throws -> [[String: Any]] {
        let files = [file] + (1...3).map { file.appendingPathExtension(String($0)) }
        return try files.reversed().flatMap { url -> [[String: Any]] in
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return try Data(contentsOf: url).split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }
    }

    private func assertError(_ client: Client, id: Int, code: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await client.errorCode(id)
        XCTAssertEqual(actual, code, file: file, line: line)
    }

    @MainActor
    private final class Client {
        let input = Pipe()
        let output = Pipe()
        var messages: [[String: Any]] = []
        private var waiters: [(Int, XCTestExpectation)] = []
        private var serverTask: Task<Void, Error>!
        private var readerTask: Task<Void, Error>!
        private var finished = false

        init(library: URL = URL(fileURLWithPath: "/tmp/mcp-test-library"),
             isEnabled: @escaping () -> Bool = { true },
             definitions: [[String: Any]]? = [["name": "test_tool", "inputSchema": ["type": "object"]]],
             callTool: ((String, [String: Any], URL) async throws -> [String: Any])? = { _, arguments, _ in arguments },
             accessLog: MCPAccessLog? = nil) throws {
            let server = MCPServer(library: library, isEnabled: isEnabled,
                                   definitions: definitions, callTool: callTool, accessLog: accessLog)
            serverTask = Task { try await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
            readerTask = Task {
                var line = Data()
                let handle = output.fileHandleForReading
                while true {
                    let chunk = try await Task.detached {
                        var data = Data(count: 65_536)
                        let count = try data.withUnsafeMutableBytes { bytes -> Int in
                            while true {
                                let count = Darwin.read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
                                if count >= 0 { return count }
                                let code = errno
                                if code != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                            }
                        }
                        data.count = count
                        return data
                    }.value
                    if chunk.isEmpty { break }
                    for byte in chunk {
                        if byte == 10 {
                            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
                            messages.append(message)
                            line.removeAll(keepingCapacity: true)
                            for (count, waiter) in waiters where messages.count >= count { waiter.fulfill() }
                            waiters.removeAll { messages.count >= $0.0 }
                        } else { line.append(byte) }
                    }
                }
                XCTAssertTrue(line.isEmpty, "Every server response must end with a newline")
            }
        }

        func write(_ data: Data) async throws {
            let handle = input.fileHandleForWriting
            try await Task.detached { try handle.write(contentsOf: data) }.value
        }

        func send(_ message: [String: Any]) async throws { try await write(Self.data(message) + Data([10])) }

        func response(_ id: Int) async throws -> [String: Any] {
            while true {
                if let message = messages.first(where: { $0["id"] as? Int == id }) { return message }
                let count = messages.count
                await waitForCount(count + 1)
                guard messages.count > count else { throw NSError(domain: "MCPServerTests", code: 1) }
            }
        }

        func object(_ id: Int, key: String) async throws -> [String: Any] {
            let message = try await response(id)
            return try XCTUnwrap(message[key] as? [String: Any])
        }

        func errorCode(_ id: Int) async throws -> Int? {
            let message = try await response(id)
            return (message["error"] as? [String: Any])?["code"] as? Int
        }

        func waitForCount(_ count: Int) async {
            guard messages.count < count else { return }
            let waiter = XCTestExpectation(description: "Read \(count) MCP responses")
            waiters.append((count, waiter))
            _ = await XCTWaiter.fulfillment(of: [waiter], timeout: 5)
            XCTAssertGreaterThanOrEqual(messages.count, count)
        }

        func finish() async throws {
            guard !finished else { return }
            finished = true
            try input.fileHandleForWriting.close()
            let serverResult = await serverTask.result
            try output.fileHandleForWriting.close()
            let readerResult = await readerTask.result
            try input.fileHandleForReading.close()
            try output.fileHandleForReading.close()
            serverTask = nil
            readerTask = nil
            try serverResult.get()
            try readerResult.get()
        }

        static func data(_ message: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        static func initialize(id: Int, version: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "ClipatoTests", "version": "1"]]]
        }

        static func modern(id: Int, method: String, params: [String: Any] = [:], version: String = "2026-07-28") -> [String: Any] {
            var params = params
            params["_meta"] = ["io.modelcontextprotocol/protocolVersion": version, "io.modelcontextprotocol/clientCapabilities": [:]]
            return ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        }
    }
}
