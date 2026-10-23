import Foundation
import CSQLite
import XCTest
@testable import Clipato

final class LibraryDatabaseTests: XCTestCase {
    func testLegacyMigrationPreservesOrderFieldsAndOriginalBackupAcrossReopens() throws {
        let root = try temporaryDirectory()
        let first = item(filename: "中文 ' \".png", date: Date(timeIntervalSince1970: 1_700_000_000),
                         directory: root.appendingPathComponent("外部 图片"), tag: .purple)
        let second = item(filename: "older.png", date: first.createdAt, tag: nil)
        let legacy = root.appendingPathComponent("images.json")
        let bytes = try encode([second, first])
        try bytes.write(to: legacy)

        var database: LibraryDatabase? = try LibraryDatabase(root: root)
        XCTAssertEqual(try database!.images(), [second, first])
        try database!.rename(second.id, to: "new name.png")
        database = nil
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        let reopened = try LibraryDatabase(root: root)
        XCTAssertEqual(try reopened.images().map(\.id), [second.id, first.id])
        XCTAssertEqual(try reopened.images().first?.filename, "new name.png")
        XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 6)
        XCTAssertEqual(try scalar("PRAGMA integrity_check = 1", root: root, text: true), "ok")
    }

    func testFailedMigrationIsAtomicAndCanBeRetriedAfterRepairingLegacyFile() throws {
        let root = try temporaryDirectory()
        let image = item(filename: "duplicate.png")
        let legacy = root.appendingPathComponent("images.json")
        let corrupt = try encode([image, image])
        try corrupt.write(to: legacy)

        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
        XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'images'", root: root), 0)
        try encode([image]).write(to: legacy)
        XCTAssertEqual(try LibraryDatabase(root: root).images().map(\.id), [image.id])
    }

    func testCorruptSQLiteDoesNotFallBackToOldJSONOrReplaceDatabase() throws {
        let root = try temporaryDirectory()
        try encode([item(filename: "old.png")]).write(to: root.appendingPathComponent("images.json"))
        let file = root.appendingPathComponent("library.sqlite")
        let bytes = Data("This is a damaged database".utf8)
        try bytes.write(to: file)

        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testNonFileLegacyDirectoryRollsBackMigrationAndAllowsRepair() throws {
        let root = try temporaryDirectory()
        var invalid = item(filename: "invalid.png", directory: URL(string: "https://example.com/Images")!)
        let valid = item(filename: "valid.png")
        let legacy = root.appendingPathComponent("images.json")
        let bytes = try encode([invalid, valid])
        try bytes.write(to: legacy)

        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 0)
        XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'images'", root: root), 0)

        invalid.directory = root.appendingPathComponent("Images")
        try encode([invalid, valid]).write(to: legacy)
        let restored = try LibraryDatabase(root: root).images()
        XCTAssertEqual(restored.map(\.id), [invalid.id, valid.id])
        XCTAssertEqual(restored.first?.directory, invalid.directory)
        XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 6)
    }

    func testExternalWritesAdvanceDataVersionAndPersistWithoutLosingOtherRows() throws {
        let root = try temporaryDirectory()
        let first = try LibraryDatabase(root: root)
        let second = try LibraryDatabase(root: root)
        let image = item(filename: "first.png")
        let other = item(filename: "second.png")
        let version = try first.dataVersion()
        try first.insert(image)
        XCTAssertEqual(try first.dataVersion(), version)
        try second.insert(other)
        XCTAssertNotEqual(try first.dataVersion(), version)
        try first.setTag(.green, for: [image.id])
        try second.rename(other.id, to: "renamed.png")

        let restored = try LibraryDatabase(root: root).images()
        XCTAssertEqual(restored.map(\.id), [other.id, image.id])
        XCTAssertEqual(restored[0].filename, "renamed.png")
        XCTAssertEqual(restored[1].tag, .green)
        XCTAssertEqual(restored[1].createdAt, image.createdAt)
    }

    func testMultipleConnectionsCanWriteConcurrently() async throws {
        let root = try temporaryDirectory()
        _ = try LibraryDatabase(root: root)
        let rows = (0..<4).map { worker in (0..<40).map { item(filename: "\(worker)-\($0).png") } }
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for items in rows {
                tasks.addTask {
                    let database = try LibraryDatabase(root: root)
                    for item in items { try database.insert(item) }
                }
            }
            try await tasks.waitForAll()
        }
        let restored = try LibraryDatabase(root: root).images()
        XCTAssertEqual(restored.count, 160)
        XCTAssertEqual(Set(restored.map(\.id)), Set(rows.flatMap { $0 }.map(\.id)))
        XCTAssertEqual(try scalar("PRAGMA integrity_check = 1", root: root, text: true), "ok")
    }

    func testWriterWaitsForAnotherConnectionsTransactionThenCommits() async throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let image = item(filename: "waits.png")
        let started = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            started.signal()
            try database.insert(image)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sqlite3_exec(blocker, "COMMIT", nil, nil, nil), SQLITE_OK)
        try await writer.value
        XCTAssertEqual(try LibraryDatabase(root: root).images().map(\.id), [image.id])
    }

    func testNewerSchemaIsRejectedWithoutOverwritingItsVersion() throws {
        let root = try temporaryDirectory()
        _ = try LibraryDatabase(root: root)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 99)
    }

    func testVersionThreeMigrationSeedsRecentImageOnceByInsertionOrder() throws {
        let root = try temporaryDirectory()
        let first = item(filename: "first.png", date: Date(timeIntervalSince1970: 2_000_000_000))
        let second = item(filename: "last-inserted.png", date: Date(timeIntervalSince1970: 1_000_000_000))
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(first)
            try database.insert(second)
        }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, """
            DROP TABLE operationHistory;
            ALTER TABLE collections DROP COLUMN color;
            PRAGMA user_version = 3
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

        do {
            let migrated = try LibraryDatabase(root: root)
            XCTAssertEqual(try migrated.recentImage(), second)
            XCTAssertEqual(try migrated.images(), [second, first])
            XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 6)
            try migrated.clearOperationHistory()
        }
        let reopened = try LibraryDatabase(root: root)
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(try reopened.images(), [second, first])
        XCTAssertEqual(try scalar("SELECT count(*) FROM operationHistory", root: root), 1)
        XCTAssertEqual(try scalar("PRAGMA integrity_check = 1", root: root, text: true), "ok")
    }

    func testImageInsertTransactionRollbackPreservesRecentImageAndClearedState() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let original = item(filename: "original.png")
        try database.insert(original)
        for cleared in [false, true] {
            if cleared { try database.clearOperationHistory() }
            let next = item(filename: "would-be-recent.png")
            let invalid = VaultImage(id: UUID(), filename: "invalid.png", createdAt: Date(),
                                     width: 0, height: 2, source: "导入")

            XCTAssertThrowsError(try database.insert([next, invalid])) { error in
                XCTAssertTrue(error.localizedDescription.contains("CHECK constraint failed"))
            }

            XCTAssertEqual(try database.images(), [original])
            XCTAssertEqual(try database.recentImage(), cleared ? nil : original)
            let reopened = try LibraryDatabase(root: root)
            XCTAssertEqual(try reopened.recentImage(), cleared ? nil : original)
            XCTAssertEqual(try reopened.images(), [original])
        }
    }

    func testVersionFiveMigrationRemovesAutomaticHistoryWithoutChangingTheExistingChoice() throws {
        for cleared in [false, true] {
            let root = try temporaryDirectory()
            let original = item(filename: "remembered.png")
            do {
                let database = try LibraryDatabase(root: root)
                try database.insert(original)
                if cleared { try database.clearOperationHistory() }
            }
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(connection, """
                CREATE TRIGGER images_remember_recent AFTER INSERT ON images
                BEGIN UPDATE operationHistory SET imageID = NEW.id WHERE id = 1; END;
                PRAGMA user_version = 5
                """, nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

            let migrated = try LibraryDatabase(root: root)
            let single = item(filename: "private-single.png")
            let batch = [item(filename: "private-first.png"), item(filename: "private-last.png")]
            try migrated.insert(single, remember: false)
            try migrated.insert(batch, remember: false)

            XCTAssertEqual(try scalar("PRAGMA user_version", root: root), 6)
            XCTAssertEqual(try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'images_remember_recent'", root: root), 0)
            XCTAssertEqual(try migrated.recentImage(), cleared ? nil : original)
            XCTAssertEqual(try migrated.images(), Array(batch.reversed()) + [single, original])
            let reopened = try LibraryDatabase(root: root)
            XCTAssertEqual(try reopened.recentImage(), cleared ? nil : original)
            let fresh = item(filename: "normal.png")
            try reopened.insert(fresh)
            XCTAssertEqual(try reopened.recentImage(), fresh)
        }
    }

    func testHistoryWriteFailureRollsBackSingleCollectionAndBatchInserts() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let original = item(filename: "original.png")
        try database.insert(original)
        let collection = try database.createCollection(name: "Existing", parentID: nil)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TRIGGER reject_history BEFORE UPDATE ON operationHistory
            BEGIN SELECT RAISE(ABORT, 'history write rejected'); END
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(connection), SQLITE_OK)

        XCTAssertThrowsError(try database.insert(item(filename: "single.png")))
        XCTAssertThrowsError(try database.insert(item(filename: "collected.png"), collectionID: collection.id))
        XCTAssertThrowsError(try database.insert([item(filename: "first.png"), item(filename: "last.png")]))

        XCTAssertEqual(try database.images(), [original])
        XCTAssertEqual(try database.recentImage(), original)
        XCTAssertEqual(try database.collectionState().1[collection.id], [])
        XCTAssertEqual(try LibraryDatabase(root: root).images(), [original])
    }

    func testRememberingMissingImageFailsWithoutReplacingTheExistingReference() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let original = item(filename: "original.png")
        try database.insert(original)

        XCTAssertThrowsError(try database.rememberImage(UUID())) { error in
            XCTAssertTrue(error.localizedDescription.contains("FOREIGN KEY constraint failed"))
        }

        XCTAssertEqual(try database.recentImage(), original)
        XCTAssertEqual(try database.images(), [original])
    }

    private func item(filename: String, date: Date = Date(), directory: URL? = nil, tag: AssetTag? = nil) -> VaultImage {
        VaultImage(id: UUID(), filename: filename, createdAt: date, width: 320, height: 180,
                   source: "导入", directory: directory, tag: tag)
    }

    private func encode(_ images: [VaultImage]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(images)
    }

    private func scalar(_ sql: String, root: URL) throws -> Int64 {
        Int64(try scalar(sql, root: root, text: true))!
    }

    private func scalar(_ sql: String, root: URL, text: Bool) throws -> String {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-SQLiteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
