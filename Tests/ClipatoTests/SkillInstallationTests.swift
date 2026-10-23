import Darwin
import Foundation
import XCTest
@testable import Clipato

final class SkillInstallationTests: XCTestCase {
    func testClientDirectoriesAreResolvedInsideTheProvidedHome() throws {
        let home = try temporaryDirectory().appendingPathComponent("模拟 用户")
        XCTAssertEqual(SkillClient.codex.directory(home: home).path,
                       home.appendingPathComponent(".agents/skills/clipato").path)
        XCTAssertEqual(SkillClient.claudeCode.directory(home: home).path,
                       home.appendingPathComponent(".claude/skills/clipato").path)
    }

    func testInstallationCopiesTheCompletePackageAndSafelyForwardsArguments() throws {
        let root = try temporaryDirectory()
        let executable = try makeExecutable(in: root.appendingPathComponent("中文 空格's $(touch injected) `touch backtick-injected`"))
        let destination = SkillClient.codex.directory(home: root.appendingPathComponent("home"))
        try SkillInstallation.install(to: destination, executable: executable)

        let resource = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: "Skills", withExtension: nil))
            .appendingPathComponent("clipato")
        for path in ["SKILL.md", "references/capabilities.md", "agents/openai.yaml"] {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)),
                           try Data(contentsOf: resource.appendingPathComponent(path)), path)
        }
        let launcher = destination.appendingPathComponent("scripts/clipato")
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o755)
        let arguments = ["call", "image_convert", "--input", "中文 'job' $(touch argument-injected) `touch argument-backtick`.json", "line\nbreak", ""]
        let result = try run(launcher, arguments: arguments, in: root)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, nullSeparated([executable.path] + arguments))
        XCTAssertTrue(result.errors.isEmpty)
        for name in ["injected", "backtick-injected", "argument-injected", "argument-backtick"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
        try assertNoStagingDirectories(beside: destination)
    }

    func testExistingDirectoryIsNotReplacedWithoutExplicitReplacement() throws {
        let root = try temporaryDirectory()
        let executable = try makeExecutable(in: root.appendingPathComponent("App"))
        let destination = SkillClient.claudeCode.directory(home: root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("existing user skill".utf8).write(to: sentinel)

        XCTAssertThrowsError(try SkillInstallation.install(to: destination, executable: executable)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EEXIST))
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "existing user skill")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["keep.txt"])
        try assertNoStagingDirectories(beside: destination)
    }

    func testExplicitReplacementUpdatesTheExecutableAndRemovesOldFiles() throws {
        let root = try temporaryDirectory()
        let first = try makeExecutable(in: root.appendingPathComponent("First"))
        let second = try makeExecutable(in: root.appendingPathComponent("新 App's location"))
        let destination = SkillClient.codex.directory(home: root.appendingPathComponent("home"))
        try SkillInstallation.install(to: destination, executable: first)
        let sentinel = destination.appendingPathComponent("old.txt")
        try Data("old installation".utf8).write(to: sentinel)

        try SkillInstallation.install(to: destination, executable: second, replaceExisting: true)
        let result = try run(destination.appendingPathComponent("scripts/clipato"), arguments: ["version"], in: root)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, nullSeparated([second.path, "version"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        try assertNoStagingDirectories(beside: destination)
    }

    func testInvalidExecutableLeavesAnExistingInstallationUntouched() throws {
        let root = try temporaryDirectory()
        let executable = try makeExecutable(in: root.appendingPathComponent("Valid"))
        let destination = SkillClient.claudeCode.directory(home: root.appendingPathComponent("home"))
        try SkillInstallation.install(to: destination, executable: executable)
        let launcher = destination.appendingPathComponent("scripts/clipato")
        let original = try Data(contentsOf: launcher)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let notExecutable = root.appendingPathComponent("not-executable")
        try Data("not a program".utf8).write(to: notExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)

        for invalid in [root.appendingPathComponent("missing"), notExecutable] {
            XCTAssertThrowsError(try SkillInstallation.install(to: destination, executable: invalid, replaceExisting: true))
            XCTAssertEqual(try Data(contentsOf: launcher), original)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
            try assertNoStagingDirectories(beside: destination)
        }
        let result = try run(launcher, arguments: ["version"], in: root)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, nullSeparated([executable.path, "version"]))
    }

    func testMovingTheAppRequiresReinstallationAndThenUsesTheNewLocation() throws {
        let root = try temporaryDirectory()
        let executable = try makeExecutable(in: root.appendingPathComponent("Original App"))
        let destination = root.appendingPathComponent("exported/clipato")
        try SkillInstallation.install(to: destination, executable: executable)
        let moved = root.appendingPathComponent("移动 后's Clipato")
        try FileManager.default.moveItem(at: executable, to: moved)
        let launcher = destination.appendingPathComponent("scripts/clipato")

        let unavailable = try run(launcher, arguments: ["tools"], in: root)
        XCTAssertEqual(unavailable.status, 127)
        XCTAssertTrue(unavailable.output.isEmpty)
        XCTAssertTrue(unavailable.errors.contains(executable.path))
        XCTAssertTrue(unavailable.errors.contains("reinstall this skill"))

        try SkillInstallation.install(to: destination, executable: moved, replaceExisting: true)
        let restored = try run(launcher, arguments: ["tools", "image_resize"], in: root)
        XCTAssertEqual(restored.status, 0, restored.errors)
        XCTAssertEqual(restored.output, nullSeparated([moved.path, "tools", "image_resize"]))
        try assertNoStagingDirectories(beside: destination)
    }

    private func makeExecutable(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("Clipato")
        try "#!/bin/bash\nprintf '%s\\0' \"$0\" \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func run(_ executable: URL, arguments: [String], in directory: URL) throws -> (status: Int32, output: Data, errors: String) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: errorData, as: UTF8.self))
    }

    private func nullSeparated(_ values: [String]) -> Data {
        Data((values.joined(separator: "\0") + "\0").utf8)
    }

    private func assertNoStagingDirectories(beside destination: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".Clipato-skill-") }, file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-SkillInstallationTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
