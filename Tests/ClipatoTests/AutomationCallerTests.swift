import Darwin
import Foundation
import XCTest
@testable import Clipato

final class AutomationCallerTests: XCTestCase {
    func testCurrentProcessAndParentAreObservedFromTheSystem() throws {
        let caller = AutomationCaller.capture()
        XCTAssertEqual(caller.process.pid, getpid())
        XCTAssertEqual(caller.process.parentPID, getppid())
        XCTAssertTrue(caller.process.errors.isEmpty)
        XCTAssertFalse(try XCTUnwrap(caller.process.name).isEmpty)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(caller.process.executable)))
        XCTAssertLessThanOrEqual(try XCTUnwrap(caller.process.startTime), Date().timeIntervalSince1970)
        let parent = try XCTUnwrap(caller.ancestors.first)
        XCTAssertEqual(parent.pid, getppid())
        XCTAssertNotNil(parent.parentPID)
        XCTAssertTrue(parent.errors.isEmpty)
        XCTAssertLessThanOrEqual(caller.ancestors.count, 8)
    }

    func testRealChildIsAttributedToItsActualParentAndExecutable() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let caller = AutomationCaller.capture(processID: child.processIdentifier)
        XCTAssertEqual(caller.process.pid, child.processIdentifier)
        XCTAssertEqual(caller.process.parentPID, getpid())
        XCTAssertEqual(caller.process.executable, "/bin/sleep")
        XCTAssertEqual(caller.ancestors.first?.pid, getpid())
        XCTAssertTrue(caller.process.errors.isEmpty)
        let data = try JSONSerialization.data(withJSONObject: caller.jsonObject)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let process = try XCTUnwrap(record["process"] as? [String: Any])
        XCTAssertEqual(process["executable"] as? String, "/bin/sleep")
        XCTAssertNil(process["arguments"])
        XCTAssertNil(process["environment"])
        XCTAssertNil(record["client"])
    }

    func testUnavailableProcessRecordsReadFailuresWithoutInventingIdentity() {
        let caller = AutomationCaller.capture(processID: -1)
        XCTAssertEqual(caller.process.pid, -1)
        XCTAssertNil(caller.process.parentPID)
        XCTAssertNil(caller.process.name)
        XCTAssertNil(caller.process.executable)
        XCTAssertNil(caller.process.startTime)
        XCTAssertEqual(caller.process.errors.map(\.operation), ["proc_pidinfo", "proc_pidpath"])
        XCTAssertTrue(caller.process.errors.allSatisfy { $0.result <= 0 })
        XCTAssertTrue(caller.process.errors.allSatisfy { $0.code != 0 })
        XCTAssertTrue(caller.ancestors.isEmpty)
        XCTAssertFalse(caller.ancestryLimited)
        XCTAssertNotNil(caller.process.jsonObject["errors"])
    }

    func testApplicationIdentityComesFromTheObservedExecutableBundle() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("Clipato-Caller-\(UUID())")
        let application = root.appendingPathComponent("Caller.app")
        let contents = application.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Caller")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let identifier = "dev.clipato.caller-test.\(UUID().uuidString)"
        let information = ["CFBundleIdentifier": identifier, "CFBundleName": "Observed Caller",
                           "CFBundleExecutable": "Caller", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let child = Process()
        child.executableURL = executable
        child.arguments = ["10"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let identity = AutomationCaller.capture(processID: child.processIdentifier).process
        XCTAssertEqual(identity.executable, executable.path)
        XCTAssertEqual(identity.applicationPath, application.path)
        XCTAssertEqual(identity.bundleIdentifier, identifier)
        XCTAssertEqual(identity.appName, "Observed Caller")
        XCTAssertFalse(identity.bundleInfoUnavailable)
    }

}
