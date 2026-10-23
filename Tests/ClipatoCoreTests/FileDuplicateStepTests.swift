import Foundation
import os
import XCTest
@testable import ClipatoCore

final class FileDuplicateStepTests: XCTestCase {
    func testExactDuplicatesIgnoreNamesAndModificationDatesAndKeepInputOrder() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "old-image.png", in: directory)
        let second = try write(Data("abc".utf8), named: "new-video.mp4", in: directory)
        let third = try write(Data("other duplicate".utf8), named: "third.bin", in: directory)
        let fourth = try write(Data("other duplicate".utf8), named: "fourth.bin", in: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: second.path)

        let groups = try FileDuplicateStep.execute(urls: [fourth, second, third, first])

        XCTAssertEqual(groups.map(\.urls), [[fourth, third], [second, first]])
        XCTAssertEqual(groups.map(\.fileSize), [15, 3])
        XCTAssertEqual(groups[1].sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try Data(contentsOf: first), Data("abc".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
    }

    func testMatchingHeadersTailsAndSizeDoNotHideDifferentMiddleBytes() throws {
        let directory = try temporaryDirectory()
        let contents = Data(repeating: 0x47, count: 3 * 1024 * 1024)
        var different = contents
        different[different.count / 2] = 0x48
        let first = try write(contents, named: "first.mp4", in: directory)
        let second = try write(different, named: "second.mp4", in: directory)

        XCTAssertTrue(try FileDuplicateStep.execute(urls: [first, second]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: first), contents)
        XCTAssertEqual(try Data(contentsOf: second), different)
    }

    func testDifferentSizesAndDifferentSampleBytesAreNotDuplicates() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data(repeating: 1, count: 12_000), named: "first.png", in: directory)
        let second = try write(Data(repeating: 1, count: 12_001), named: "second.png", in: directory)
        let third = try write(Data(repeating: 2, count: 12_000), named: "third.png", in: directory)

        XCTAssertTrue(try FileDuplicateStep.execute(urls: [first, second, third]).isEmpty)
    }

    func testLargeDuplicateFilesHashEveryChunkAndReportCompletion() throws {
        let directory = try temporaryDirectory()
        let contents = Data(repeating: 0x5a, count: 3 * 1024 * 1024 + 37)
        let first = try write(contents, named: "first.mp4", in: directory)
        let second = try write(contents, named: "second.mp4", in: directory)
        let progress = OSAllocatedUnfairLock(initialState: [(Int, Int)]())

        let groups = try FileDuplicateStep.execute(urls: [first, second]) { completed, total in
            progress.withLock { $0.append((completed, total)) }
        }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.urls, [first, second])
        XCTAssertEqual(groups.first?.fileSize, Int64(contents.count))
        XCTAssertEqual(groups.first?.sha256, "7c521dcf0fb321936480fa9a9c973fb5c93842c7fa306eeb5cfbf0eb23ec96d9")
        let calls = progress.withLock { $0 }
        XCTAssertEqual(calls.first?.0, 0)
        XCTAssertEqual(calls.last?.0, 2)
        XCTAssertTrue(calls.allSatisfy { $0.1 == 2 })
        XCTAssertEqual(calls.map(\.0), calls.map(\.0).sorted())
    }

    func testRepeatedURLsAndHardLinksDoNotCreateAnotherCopy() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("same file bytes".utf8), named: "first.png", in: directory)
        let alias = directory.appendingPathComponent("hard-link.png")
        try FileManager.default.linkItem(at: first, to: alias)
        let second = try write(Data("same file bytes".utf8), named: "second.png", in: directory)

        let groups = try FileDuplicateStep.execute(urls: [first, first, alias, second, second])

        XCTAssertEqual(groups.map(\.urls), [[first, second]])
        XCTAssertTrue(try FileDuplicateStep.execute(urls: [first, first, alias]).isEmpty)
    }

    func testEmptyInputsAndEmptyFilesHaveDeterministicResults() throws {
        XCTAssertTrue(try FileDuplicateStep.execute(urls: []).isEmpty)
        let directory = try temporaryDirectory()
        let first = try write(Data(), named: "first.png", in: directory)
        let second = try write(Data(), named: "second.png", in: directory)

        let groups = try FileDuplicateStep.execute(urls: [first, second])

        XCTAssertEqual(groups.map(\.urls), [[first, second]])
        XCTAssertEqual(groups.first?.fileSize, 0)
        XCTAssertEqual(groups.first?.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testMissingFilesDirectoriesAndSymbolicLinksFailWithoutPartialResults() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "first.png", in: directory)
        let second = try write(Data("abc".utf8), named: "second.png", in: directory)
        let missing = directory.appendingPathComponent("missing.mp4")
        XCTAssertThrowsError(try FileDuplicateStep.execute(urls: [first, second, missing])) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        }
        XCTAssertThrowsError(try FileDuplicateStep.execute(urls: [first, directory]))
        let link = directory.appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        XCTAssertThrowsError(try FileDuplicateStep.execute(urls: [first, link]))
        XCTAssertEqual(try Data(contentsOf: first), Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("abc".utf8))
    }

    func testPrecancelledTaskAndCancellationDuringProgressReturnNoGroups() async throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "first.png", in: directory)
        let second = try write(Data("abc".utf8), named: "second.png", in: directory)
        for cancelBeforeStarting in [true, false] {
            let task = Task.detached {
                if cancelBeforeStarting { withUnsafeCurrentTask { $0?.cancel() } }
                return try FileDuplicateStep.execute(urls: [first, second]) { completed, _ in
                    if !cancelBeforeStarting && completed > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled detection returned groups")
            } catch is CancellationError { }
        }
    }

    func testFileChangedBetweenFilteringAndHashingFailsExplicitly() throws {
        let directory = try temporaryDirectory()
        let singleton = try write(Data([1]), named: "singleton.png", in: directory)
        let first = try write(Data(repeating: 0x41, count: 16_000), named: "first.png", in: directory)
        let second = try write(Data(repeating: 0x41, count: 16_000), named: "second.png", in: directory)
        let mutation = OSAllocatedUnfairLock(initialState: Result<Void, Error>?.none)

        XCTAssertThrowsError(try FileDuplicateStep.execute(urls: [singleton, first, second]) { completed, _ in
            guard completed == 1 else { return }
            do {
                try Data([2]).write(to: first, options: .atomic)
                mutation.withLock { $0 = .success(()) }
            } catch { mutation.withLock { $0 = .failure(error) } }
        }) { error in
            guard case FileDuplicateError.fileChanged(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, first)
        }
        try XCTUnwrap(mutation.withLock { $0 }).get()
        XCTAssertEqual(try Data(contentsOf: second).count, 16_000)
    }

    func testVerificationHashesMiddleBytesEvenWhenSizeAndModificationDateArePreserved() throws {
        let directory = try temporaryDirectory()
        let contents = Data(repeating: 0x47, count: 3 * 1024 * 1024)
        let first = try write(contents, named: "first.mp4", in: directory)
        let second = try write(contents, named: "second.mp4", in: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: second.path)
        let groups = try FileDuplicateStep.execute(urls: [first, second])
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: second)
        try handle.seek(toOffset: UInt64(contents.count / 2))
        try handle.write(contentsOf: Data([0x48]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: second.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.path)[.size] as? NSNumber, NSNumber(value: contents.count))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date, originalDate)

        XCTAssertThrowsError(try FileDuplicateStep.verify(groups: groups)) { error in
            guard case FileDuplicateError.fileChanged(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, second)
        }
    }

    func testVerificationRejectsAChangedKeeperWhenOtherCopiesAreStillUnchanged() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "keeper.png", in: directory)
        let second = try write(Data("abc".utf8), named: "copy.png", in: directory)
        let groups = try FileDuplicateStep.execute(urls: [first, second])
        try Data("xyz".utf8).write(to: first)

        XCTAssertThrowsError(try FileDuplicateStep.verify(groups: groups)) { error in
            guard case FileDuplicateError.fileChanged(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, first)
        }
        XCTAssertEqual(try Data(contentsOf: second), Data("abc".utf8))
    }

    func testVerificationChecksTheChecksumWhenOnlyOneGroupMemberRemains() throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "keeper.png", in: directory)
        let second = try write(Data("abc".utf8), named: "copy.png", in: directory)
        let group = try XCTUnwrap(try FileDuplicateStep.execute(urls: [first, second]).first)
        try FileManager.default.removeItem(at: second)
        let remaining = DuplicateFileGroup(urls: [first], fileSize: group.fileSize, sha256: group.sha256)
        try FileDuplicateStep.verify(groups: [remaining])
        try Data("abd".utf8).write(to: first)

        XCTAssertThrowsError(try FileDuplicateStep.verify(groups: [remaining])) { error in
            guard case FileDuplicateError.fileChanged(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, first)
        }
    }

    func testVerificationHonorsCancellationAndReportsAnUnexpectedlyMissingMember() async throws {
        let directory = try temporaryDirectory()
        let first = try write(Data("abc".utf8), named: "first.png", in: directory)
        let second = try write(Data("abc".utf8), named: "second.png", in: directory)
        let groups = try FileDuplicateStep.execute(urls: [first, second])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try FileDuplicateStep.verify(groups: groups)
        }
        do {
            try await task.value
            XCTFail("Cancelled verification succeeded")
        } catch is CancellationError { }
        try FileManager.default.removeItem(at: second)

        XCTAssertThrowsError(try FileDuplicateStep.verify(groups: groups)) { error in
            guard case FileDuplicateError.fileChanged(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, second)
        }
    }

    func testStandaloneHashUsesKnownSHA256ForAFileAndAnEmptyFile() throws {
        let directory = try temporaryDirectory()
        let file = try write(Data("abc".utf8), named: "image.png", in: directory)
        let empty = try write(Data(), named: "empty.png", in: directory)

        XCTAssertEqual(try FileDuplicateStep.sha256(at: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileDuplicateStep.sha256(at: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    }

    func testStandaloneHashRejectsMissingFilesDirectoriesAndSymbolicLinks() throws {
        let directory = try temporaryDirectory()
        let file = try write(Data("abc".utf8), named: "image.png", in: directory)
        let missing = directory.appendingPathComponent("missing.png")
        XCTAssertThrowsError(try FileDuplicateStep.sha256(at: missing)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        }
        XCTAssertThrowsError(try FileDuplicateStep.sha256(at: directory)) { error in
            guard case FileDuplicateError.notRegularFile(let url) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(url, directory)
        }
        let link = directory.appendingPathComponent("symlink.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try FileDuplicateStep.sha256(at: link))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-FileDuplicates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(_ bytes: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
