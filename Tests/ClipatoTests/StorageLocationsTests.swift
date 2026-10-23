import Foundation
import XCTest
@testable import Clipato

final class StorageLocationsTests: XCTestCase {
    func testValidationReadsWritesAndRemovesOnlyItsProbe() throws {
        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent("keep.txt")
        let bytes = Data("existing contents".utf8)
        try bytes.write(to: existing)

        try StorageLocations.validateDirectory(directory)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
    }

    func testValidationRejectsRegularFileAndMissingDirectoryWithoutCreatingThem() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let missing = directory.appendingPathComponent("missing")

        XCTAssertThrowsError(try StorageLocations.validateDirectory(file)) { error in
            guard case StorageLocationError.notDirectory(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, file)
        }
        XCTAssertThrowsError(try StorageLocations.validateDirectory(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }

    func testValidationRejectsReadOnlyDirectoryWithoutLeavingProbe() throws {
        let directory = try temporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try StorageLocations.validateDirectory(directory))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-StorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
