import Darwin
import Foundation
import XCTest
@testable import Clipato

final class ExternalImageRenameTests: XCTestCase {
    func testNumberingFollowsInputOrderAndPreservesExtensions() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.png", contents: "first", in: directory)
        let second = try file("second.JPG", contents: "second", in: directory)

        let renamed = try BatchRenameStep.execute(urls: [second, first],
            rule: BatchRenameRule(prefix: "Photo_", start: 7, increment: 2, digits: 3))

        XCTAssertEqual(renamed.map(\.lastPathComponent), ["Photo_007.JPG", "Photo_009.png"])
        XCTAssertEqual(try Data(contentsOf: renamed[0]), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: renamed[1]), Data("first".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(renamed.map(\.lastPathComponent)))
    }

    func testSelectedNamesCanBeExchangedWithoutLosingEitherFile() throws {
        let directory = try temporaryDirectory()
        let first = try file("Frame_01.png", contents: "first", in: directory)
        let second = try file("Frame_02.png", contents: "second", in: directory)

        let renamed = try BatchRenameStep.execute(urls: [second, first],
            rule: BatchRenameRule(prefix: "Frame_", start: 1, increment: 1, digits: 2))

        XCTAssertEqual(renamed, [first, second])
        XCTAssertEqual(try Data(contentsOf: first), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testUnselectedDestinationIsNeverOverwrittenAndPreventsAllChanges() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.png", contents: "first", in: directory)
        let second = try file("second.png", contents: "second", in: directory)
        let occupied = try file("Frame_002.png", contents: "unselected", in: directory)

        XCTAssertThrowsError(try BatchRenameStep.execute(urls: [first, second], rule: BatchRenameRule())) { error in
            guard case BatchRenameError.existingFile(let url) = error else { return XCTFail("Expected existing-file error, got \(error)") }
            XCTAssertEqual(url, occupied)
        }

        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: occupied), Data("unselected".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testFailureToStageAnotherDirectoryRollsBackTheFirstFile() throws {
        guard geteuid() != 0 else { throw XCTSkip("Directory permissions do not restrict root.") }
        let directory = try temporaryDirectory()
        let first = try file("first.png", contents: "first", in: directory)
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let second = try file("second.png", contents: "second", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        addTeardownBlock { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try BatchRenameStep.execute(urls: [first, second], rule: BatchRenameRule()))

        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["first.png", "locked"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), ["second.png"])
    }

    func testDuplicateFilesystemIdentityAndSymbolicLinksAreRejectedBeforeChanges() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.png", contents: "first", in: directory)
        let linked = directory.appendingPathComponent("linked.png")
        try FileManager.default.linkItem(at: first, to: linked)
        XCTAssertThrowsError(try BatchRenameStep.execute(urls: [first, linked], rule: BatchRenameRule()))

        let symbolic = directory.appendingPathComponent("symbolic.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: first)
        XCTAssertThrowsError(try BatchRenameStep.execute(urls: [first, symbolic], rule: BatchRenameRule()))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 3)
    }

    func testMissingInputDoesNotMoveTheOtherFiles() throws {
        let directory = try temporaryDirectory()
        let first = try file("first.png", contents: "first", in: directory)
        let missing = directory.appendingPathComponent("missing.png")

        XCTAssertThrowsError(try BatchRenameStep.execute(urls: [first, missing], rule: BatchRenameRule()))

        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["first.png"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ExternalRename.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func file(_ name: String, contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
