import AppKit
import CSQLite
import XCTest
@testable import Clipato

final class CollectionDatabaseTests: XCTestCase {
    func testVersionOneMigrationKeepsImagesAndPolicy() throws {
        let root = try temporaryDirectory()
        let item = image()
        let policy = LibraryStoragePolicy(maximumBytes: 4096, automaticallyRemoveOldestImages: true, protectTaggedImages: false, keepRecentDays: 3)
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(item)
            try database.updateStoragePolicy(policy)
        }
        try execute("DROP TABLE operationHistory; DROP TABLE collectionMembers; DROP TABLE collections; ALTER TABLE storagePolicy DROP COLUMN protectCollectedImages; PRAGMA user_version = 1", root: root)

        let database = try LibraryDatabase(root: root)
        XCTAssertEqual(try database.images(), [item])
        XCTAssertEqual(try database.storagePolicy(), policy)
        let folder = try database.createCollection(name: "工作", parentID: nil)
        try database.addToCollection(folder.id, assets: [.image(item.id)])
        let state = try LibraryDatabase(root: root).collectionState()
        XCTAssertEqual(state.0, [folder])
        XCTAssertEqual(state.1, [folder.id: [.image(item.id)]])
    }

    func testVersionOneMigrationFailureRollsBackCreatedTablesAndCanBeRetried() throws {
        let root = try temporaryDirectory()
        let item = image()
        let policy = LibraryStoragePolicy(maximumBytes: 4096, automaticallyRemoveOldestImages: false, protectTaggedImages: true, keepRecentDays: 5)
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(item)
            try database.updateStoragePolicy(policy)
        }
        // 索引名冲突发生于新目录表、关联表创建之后，验证 DDL 与版本一起回滚。
        try execute("DROP TABLE operationHistory; DROP TABLE collectionMembers; DROP TABLE collections; ALTER TABLE storagePolicy DROP COLUMN protectCollectedImages; CREATE INDEX collection_images ON images(filename); PRAGMA user_version = 1", root: root)
        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 1)
        XCTAssertEqual(try integer("SELECT count(*) FROM sqlite_master WHERE name IN ('collections', 'collectionMembers')", root: root), 0)
        XCTAssertEqual(try integer("SELECT count(*) FROM images", root: root), 1)
        XCTAssertEqual(try integer("SELECT keepRecentDays FROM storagePolicy WHERE id = 1", root: root), 5)

        try execute("DROP INDEX collection_images", root: root)
        let restored = try LibraryDatabase(root: root)
        XCTAssertEqual(try restored.images(), [item])
        XCTAssertEqual(try restored.storagePolicy(), policy)
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 6)
    }

    func testVersionTwoTreeIsPromotedInPreorderWithoutChangingNamesIDsMembersOrMedia() throws {
        let root = try temporaryDirectory()
        let item = image()
        let video = root.appendingPathComponent("recording.mp4")
        let bytes = Data("original recording bytes".utf8)
        try bytes.write(to: video)
        let assets: Set<CollectionAsset> = [.image(item.id), .session(UUID()), .video(video)]
        var folders: [AssetCollection] = []
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(item)
            for name in ["工作", "灵感", "项目 B", "项目 A", "待拼图"] {
                let folder = try database.createCollection(name: name, parentID: nil)
                folders.append(folder)
                try database.addToCollection(folder.id, assets: assets)
            }
        }
        try makeVersionTwo(root: root)
        try execute("""
            UPDATE collections SET parentID = '\(folders[0].id)', position = 1 WHERE id = '\(folders[2].id)';
            UPDATE collections SET parentID = '\(folders[0].id)', position = 0 WHERE id = '\(folders[3].id)';
            UPDATE collections SET parentID = '\(folders[3].id)', position = 0 WHERE id = '\(folders[4].id)'
            """, root: root)
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 2)
        XCTAssertEqual(try integer("SELECT count(*) FROM collections WHERE parentID IS NOT NULL", root: root), 3)

        let migrated = try LibraryDatabase(root: root)
        let (collections, members) = try migrated.collectionState()
        let expected = [folders[0], folders[3], folders[4], folders[2], folders[1]]
        XCTAssertEqual(collections.map(\.id), expected.map(\.id))
        XCTAssertEqual(collections.map(\.name), expected.map(\.name))
        XCTAssertEqual(collections.map(\.position), Array(0..<5))
        XCTAssertTrue(collections.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(members, Dictionary(uniqueKeysWithValues: folders.map { ($0.id, assets) }))
        XCTAssertEqual(try migrated.images(), [item])
        XCTAssertEqual(try Data(contentsOf: video), bytes)
        XCTAssertTrue(try migrated.storagePolicy().protectCollectedImages)
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 6)
        XCTAssertEqual(try LibraryDatabase(root: root).collectionState().0, collections)
    }

    func testSingleLevelConstraintRejectsAPIsAndRawSQLiteWithoutChangingData() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let first = try database.createCollection(name: "工作", parentID: nil)
        let second = try database.createCollection(name: "项目", parentID: nil)
        let before = try database.collectionState()
        XCTAssertThrowsError(try database.createCollection(name: "子目录", parentID: first.id)) { error in
            guard case CollectionError.singleLevelOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertThrowsError(try database.moveCollection(second.id, toParent: first.id, before: nil)) { error in
            guard case CollectionError.singleLevelOnly = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try expectSQLFailure("INSERT INTO collections (id, name, parentID, position) VALUES ('\(UUID())', '子目录', '\(first.id)', 0)", root: root)
        try expectSQLFailure("UPDATE collections SET parentID = '\(first.id)' WHERE id = '\(second.id)'", root: root)
        let after = try database.collectionState()
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    func testCollectionColorsPersistAcrossReopensWithoutChangingNamesOrderOrMembers() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        var first = try database.createCollection(name: "工作", parentID: nil)
        let second = try database.createCollection(name: "灵感", parentID: nil)
        let assets: Set<CollectionAsset> = [.image(item.id), .session(UUID()), .video(root.appendingPathComponent("recording.mp4"))]
        try database.addToCollection(first.id, assets: assets)

        for color in AssetTag.allCases {
            try database.setCollectionColor(first.id, color: color)
            first.color = color
            let state = try LibraryDatabase(root: root).collectionState()
            XCTAssertEqual(state.0, [first, second])
            XCTAssertEqual(state.1, [first.id: assets, second.id: []])
            XCTAssertEqual(try database.images(), [item])
        }

        try database.renameCollection(first.id, name: "素材")
        try database.moveCollection(first.id, toParent: nil, before: nil)
        let reordered = try LibraryDatabase(root: root).collectionState().0
        XCTAssertEqual(reordered.map(\.id), [second.id, first.id])
        XCTAssertEqual(reordered.last?.name, "素材")
        XCTAssertEqual(reordered.last?.color, .gray)
        try database.setCollectionColor(first.id, color: nil)
        XCTAssertNil(try LibraryDatabase(root: root).collectionState().0.last?.color)
    }

    func testVersionFourMigrationPreservesCollectionsMembersMediaPolicyAndHistory() throws {
        let root = try temporaryDirectory()
        let item = image()
        let video = root.appendingPathComponent("recording.mp4")
        let bytes = Data("recording source".utf8)
        try bytes.write(to: video)
        let assets: Set<CollectionAsset> = [.image(item.id), .session(UUID()), .video(video)]
        let policy = LibraryStoragePolicy(maximumBytes: 8192, automaticallyRemoveOldestImages: true,
                                          protectTaggedImages: false, keepRecentDays: 2)
        let expected: [AssetCollection]
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(item)
            try database.updateStoragePolicy(policy)
            let first = try database.createCollection(name: "工作", parentID: nil)
            let second = try database.createCollection(name: "灵感", parentID: nil)
            try database.addToCollection(first.id, assets: assets)
            try database.moveCollection(second.id, toParent: nil, before: first.id)
            expected = try database.collectionState().0
            try database.clearOperationHistory()
        }
        try execute("""
            ALTER TABLE collections DROP COLUMN color;
            CREATE TRIGGER images_remember_recent AFTER INSERT ON images
            BEGIN UPDATE operationHistory SET imageID = NEW.id WHERE id = 1; END;
            PRAGMA user_version = 4
            """, root: root)

        let migrated = try LibraryDatabase(root: root)
        let state = try migrated.collectionState()
        XCTAssertEqual(state.0, expected)
        XCTAssertTrue(state.0.allSatisfy { $0.color == nil })
        XCTAssertEqual(state.1, [expected[0].id: [], expected[1].id: assets])
        XCTAssertEqual(try migrated.images(), [item])
        XCTAssertEqual(try Data(contentsOf: video), bytes)
        XCTAssertEqual(try migrated.storagePolicy(), policy)
        XCTAssertNil(try migrated.recentImage())
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 6)
        try migrated.setCollectionColor(expected[0].id, color: .blue)
        XCTAssertEqual(try LibraryDatabase(root: root).collectionState().0.first?.color, .blue)
    }

    func testCollectionColorRejectsInvalidSQLiteAndMissingCollectionWithoutChangingState() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let folder = try database.createCollection(name: "工作", parentID: nil)
        try database.setCollectionColor(folder.id, color: .green)
        let before = try database.collectionState()
        try expectSQLFailure("UPDATE collections SET color = 'pink' WHERE id = '\(folder.id)'", root: root,
                             message: "CHECK constraint failed")
        for color in [AssetTag.red, nil] {
            XCTAssertThrowsError(try database.setCollectionColor(UUID(), color: color)) { error in
                guard case CollectionError.missingCollection = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertEqual(try database.collectionState().0, before.0)
        XCTAssertEqual(try database.collectionState().1, before.1)

        try execute("PRAGMA ignore_check_constraints = ON; UPDATE collections SET color = 'pink' WHERE id = '\(folder.id)'", root: root)
        XCTAssertThrowsError(try database.collectionState()) { error in
            guard let error = error as? LibraryDatabaseError else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(error.message, L("收藏夹颜色无效，索引未被修改。"))
        }
        try database.setCollectionColor(folder.id, color: .purple)
        XCTAssertEqual(try database.collectionState().0.first?.color, .purple)
    }

    func testLegacyCollectionJSONKeepsOriginalFieldsAndDecodesOptionalColor() throws {
        let id = UUID()
        let legacy = Data("{\"id\":\"\(id)\",\"name\":\"工作\",\"parentID\":null,\"position\":3}".utf8)
        var folder = try JSONDecoder().decode(AssetCollection.self, from: legacy)
        XCTAssertEqual(folder, AssetCollection(id: id, name: "工作", parentID: nil, position: 3))
        XCTAssertNil(folder.color)
        folder.color = .purple
        let encoded = try JSONEncoder().encode(folder)
        XCTAssertEqual(try JSONDecoder().decode(AssetCollection.self, from: encoded), folder)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "name", "parentID", "position", "color"])
        XCTAssertEqual(object["color"] as? String, "purple")
        let invalid = Data("{\"id\":\"\(id)\",\"name\":\"工作\",\"parentID\":null,\"position\":3,\"color\":\"pink\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AssetCollection.self, from: invalid))
    }

    func testVersionThreeFailureRestoresOriginalHierarchyAndPolicyBeforeRetry() throws {
        let root = try temporaryDirectory()
        let item = image()
        let parentID: UUID
        let childID: UUID
        do {
            let database = try LibraryDatabase(root: root)
            try database.insert(item)
            parentID = try database.createCollection(name: "工作", parentID: nil).id
            childID = try database.createCollection(name: "项目", parentID: nil).id
            try database.addToCollection(childID, assets: [.image(item.id)])
        }
        try makeVersionTwo(root: root)
        try execute("""
            UPDATE collections SET parentID = '\(parentID)', position = 0 WHERE id = '\(childID)';
            CREATE TRIGGER collections_single_level_insert BEFORE DELETE ON images BEGIN SELECT 1; END
            """, root: root)

        XCTAssertThrowsError(try LibraryDatabase(root: root))
        XCTAssertEqual(try integer("PRAGMA user_version", root: root), 2)
        XCTAssertEqual(try integer("SELECT count(*) FROM collections WHERE id = '\(childID)' AND parentID = '\(parentID)' AND position = 0", root: root), 1)
        XCTAssertEqual(try integer("SELECT count(*) FROM collectionMembers WHERE collectionID = '\(childID)' AND imageID = '\(item.id)'", root: root), 1)
        XCTAssertEqual(try integer("SELECT count(*) FROM pragma_table_info('storagePolicy') WHERE name = 'protectCollectedImages'", root: root), 0)
        XCTAssertEqual(try integer("SELECT count(*) FROM pragma_table_info('collections') WHERE name = 'color'", root: root), 0)

        try execute("DROP TRIGGER collections_single_level_insert", root: root)
        let migrated = try LibraryDatabase(root: root)
        let state = try migrated.collectionState()
        XCTAssertEqual(state.0.map(\.id), [parentID, childID])
        XCTAssertTrue(state.0.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(state.1[childID], [.image(item.id)])
        XCTAssertEqual(try migrated.images(), [item])
        XCTAssertTrue(try migrated.storagePolicy().protectCollectedImages)
    }

    func testCollectedImageProtectionPersistsAcrossVersionThreeReopens() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        var policy = try database.storagePolicy()
        XCTAssertTrue(policy.protectCollectedImages)
        policy.maximumBytes = 8192
        policy.protectCollectedImages = false
        try database.updateStoragePolicy(policy)
        XCTAssertEqual(try LibraryDatabase(root: root).storagePolicy(), policy)
    }

    func testMixedAssetsPersistWithoutDuplicatingMembership() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        let first = try database.createCollection(name: "工作", parentID: nil)
        let second = try database.createCollection(name: "素材", parentID: nil)
        let assets: Set<CollectionAsset> = [.image(item.id), .session(UUID()), .video(root.appendingPathComponent("recording.mp4"))]
        try database.addToCollection(first.id, assets: assets)
        try database.addToCollection(first.id, assets: assets)
        try database.addToCollection(second.id, assets: assets)
        try database.renameCollection(first.id, name: "  项目 A  ")

        let state = try LibraryDatabase(root: root).collectionState()
        XCTAssertEqual(state.1[first.id], assets)
        XCTAssertEqual(state.1[second.id], assets)
        XCTAssertEqual(state.0.first?.name, "项目 A")
        XCTAssertEqual(try database.images(), [item])
    }

    func testDeletingFolderKeepsMediaAndOtherCollections() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        let parent = try database.createCollection(name: "工作", parentID: nil)
        let other = try database.createCollection(name: "灵感", parentID: nil)
        for folder in [parent, other] { try database.addToCollection(folder.id, assets: [.image(item.id)]) }

        try database.deleteCollection(parent.id)

        let state = try database.collectionState()
        XCTAssertEqual(state.0.map(\.id), [other.id])
        XCTAssertEqual(state.0.first?.position, 0)
        XCTAssertEqual(state.1, [other.id: [.image(item.id)]])
        XCTAssertEqual(try database.images(), [item])
    }

    func testReorderAndMoveMaintainContiguousSiblingPositions() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let first = try database.createCollection(name: "A", parentID: nil)
        let second = try database.createCollection(name: "B", parentID: nil)
        let third = try database.createCollection(name: "C", parentID: nil)
        try database.moveCollection(third.id, toParent: nil, before: first.id)
        XCTAssertEqual(try database.collectionState().0.filter { $0.parentID == nil }.map(\.id), [third.id, first.id, second.id])
        try database.moveCollection(first.id, toParent: nil, before: nil)
        let state = try database.collectionState().0
        XCTAssertEqual(state.map(\.id), [third.id, second.id, first.id])
        XCTAssertEqual(state.map(\.position), [0, 1, 2])
        XCTAssertTrue(state.allSatisfy { $0.parentID == nil })
    }

    func testInvalidFolderOperationsLeaveTreeUnchanged() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let parent = try database.createCollection(name: "工作", parentID: nil)
        let child = try database.createCollection(name: "项目", parentID: nil)
        let before = try database.collectionState().0
        XCTAssertThrowsError(try database.moveCollection(parent.id, toParent: child.id, before: nil))
        XCTAssertThrowsError(try database.moveCollection(parent.id, toParent: parent.id, before: nil))
        XCTAssertThrowsError(try database.moveCollection(child.id, toParent: UUID(), before: nil))
        XCTAssertThrowsError(try database.moveCollection(child.id, toParent: nil, before: UUID()))
        XCTAssertThrowsError(try database.createCollection(name: "   \n", parentID: nil))
        XCTAssertThrowsError(try database.renameCollection(parent.id, name: "  "))
        XCTAssertThrowsError(try database.createCollection(name: "失效", parentID: UUID()))
        XCTAssertThrowsError(try database.renameCollection(UUID(), name: "失效"))
        XCTAssertThrowsError(try database.deleteCollection(UUID()))
        XCTAssertEqual(try database.collectionState().0, before)
    }

    func testRemovingMediaCleansEveryReferenceButKeepsFolders() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        let first = try database.createCollection(name: "A", parentID: nil)
        let second = try database.createCollection(name: "B", parentID: nil)
        let session = CollectionAsset.session(UUID())
        let video = CollectionAsset.video(root.appendingPathComponent("recording.mp4"))
        for folder in [first, second] { try database.addToCollection(folder.id, assets: [.image(item.id), session, video]) }
        try database.delete(item.id)
        XCTAssertEqual(try database.collectionState().1[first.id], [session, video])
        try database.removeCollectionAsset(session)
        try database.removeCollectionAsset(video)
        let state = try database.collectionState()
        XCTAssertEqual(state.0, [first, second])
        XCTAssertEqual(state.1, [first.id: [], second.id: []])
    }

    func testInvalidBatchMembershipAndDeletedDestinationRollbackCompletely() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        let folder = try database.createCollection(name: "拼图", parentID: nil)
        XCTAssertThrowsError(try database.addToCollection(folder.id, assets: [.image(item.id), .image(UUID())]))
        XCTAssertEqual(try database.collectionState().1[folder.id], [])
        try database.deleteCollection(folder.id)
        let result = image()
        XCTAssertThrowsError(try database.insert(result, collectionID: folder.id))
        XCTAssertNil(try database.image(result.id))
        XCTAssertEqual(try database.images(), [item])
    }

    func testResultImageAndMembershipCommitInOneTransaction() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let folder = try database.createCollection(name: "拼图", parentID: nil)
        let item = image()
        try execute("CREATE TRIGGER reject_member BEFORE INSERT ON collectionMembers BEGIN SELECT RAISE(ABORT, 'test failure'); END", root: root)
        XCTAssertThrowsError(try database.insert(item, collectionID: folder.id))
        XCTAssertNil(try database.image(item.id))
        XCTAssertEqual(try database.collectionState().1[folder.id], [])
        try execute("DROP TRIGGER reject_member", root: root)
        try database.insert(item, collectionID: folder.id)
        XCTAssertEqual(try database.image(item.id), item)
        XCTAssertEqual(try database.collectionState().1[folder.id], [.image(item.id)])
    }

    func testRemovalIsScopedToCurrentCollection() throws {
        let root = try temporaryDirectory()
        let database = try LibraryDatabase(root: root)
        let item = image()
        try database.insert(item)
        let first = try database.createCollection(name: "A", parentID: nil)
        let second = try database.createCollection(name: "B", parentID: nil)
        for folder in [first, second] { try database.addToCollection(folder.id, assets: [.image(item.id)]) }
        try database.removeFromCollection(first.id, assets: [.image(item.id)])
        XCTAssertEqual(try database.collectionState().1[first.id], [])
        XCTAssertEqual(try database.collectionState().1[second.id], [.image(item.id)])
        XCTAssertEqual(try database.images(), [item])
        XCTAssertThrowsError(try database.removeFromCollection(UUID(), assets: [.image(item.id)]))
    }

    private func image() -> VaultImage {
        VaultImage(id: UUID(), filename: "fixture.png", createdAt: Date(timeIntervalSince1970: 1_700_000_000), width: 2, height: 2, source: "拼图", tag: .orange)
    }

    private func execute(_ sql: String, root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func makeVersionTwo(root: URL) throws {
        try execute("""
            DROP TRIGGER collections_single_level_insert;
            DROP TRIGGER collections_single_level_update;
            DROP TABLE operationHistory;
            ALTER TABLE collections DROP COLUMN color;
            ALTER TABLE storagePolicy DROP COLUMN protectCollectedImages;
            PRAGMA user_version = 2
            """, root: root)
    }

    private func expectSQLFailure(_ sql: String, root: URL, message: String = "收藏夹仅支持一级") throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertNotEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(String(cString: sqlite3_errmsg(database)).contains(message))
    }

    private func integer(_ sql: String, root: URL) throws -> Int64 {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CollectionDatabaseTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}

@MainActor
final class CollectionStoreTests: XCTestCase {
    func testCollectionColorPublishesReloadsAcrossClientsAndPreservesMedia() async throws {
        let root = try temporaryDirectory()
        let first = try LibraryStore(root: root)
        let second = try LibraryStore(root: root)
        let item = try first.addImage(fixture(), source: "截图")
        let folder = try first.createCollection(name: "工作")
        try first.addToCollection(folder.id, assets: [.image(item.id)])
        let bytes = try Data(contentsOf: first.imageURL(item))
        try first.setCollectionColor(folder.id, color: .blue)
        XCTAssertEqual(first.collections.first?.color, .blue)
        try second.reloadImages()
        XCTAssertEqual(second.collections, first.collections)
        XCTAssertEqual(second.collectionMembers, first.collectionMembers)

        try second.setCollectionColor(folder.id, color: .orange)
        try first.reloadImages()
        XCTAssertEqual(first.collections.first?.color, .orange)
        try first.setCollectionColor(folder.id, color: nil)
        try second.reloadImages()
        XCTAssertNil(second.collections.first?.color)
        XCTAssertEqual(first.images, [item])
        XCTAssertEqual(try Data(contentsOf: first.imageURL(item)), bytes)
        XCTAssertEqual(first.collectionMembers[folder.id], [.image(item.id)])
        await first.cancelStorageWorkAndWait()
        await second.cancelStorageWorkAndWait()
    }

    func testMissingCollectionColorChangeDoesNotPublishAFalseSuccess() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let folder = try library.createCollection(name: "工作")
        try library.setCollectionColor(folder.id, color: .green)
        try LibraryDatabase(root: root).deleteCollection(folder.id)

        XCTAssertThrowsError(try library.setCollectionColor(folder.id, color: .red)) { error in
            guard case CollectionError.missingCollection = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(library.collections.first?.color, .green)
        try library.reloadImages()
        XCTAssertTrue(library.collections.isEmpty)
        await library.cancelStorageWorkAndWait()
    }

    func testPublishedCollectionsAndReferencesReloadAcrossClients() async throws {
        let root = try temporaryDirectory()
        let first = try LibraryStore(root: root)
        let second = try LibraryStore(root: root)
        let item = try first.addImage(fixture(), source: "截图")
        let folder = try first.createCollection(name: "工作")
        try first.addToCollection(folder.id, assets: [.image(item.id)])
        try second.reloadImages()
        XCTAssertEqual(second.collections, first.collections)
        XCTAssertEqual(second.collectionMembers, first.collectionMembers)
        try second.renameCollection(folder.id, name: "素材")
        try first.reloadImages()
        XCTAssertEqual(first.collections.first?.name, "素材")
        try LibraryDatabase(root: root).delete(item.id)
        try first.reloadImages()
        XCTAssertTrue(first.images.isEmpty)
        XCTAssertEqual(first.collectionMembers[folder.id], [])
        await first.cancelStorageWorkAndWait()
        await second.cancelStorageWorkAndWait()
    }

    func testCollectionViewsAndFolderDeletionNeverMoveOrDuplicateMedia() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let folder = try library.createCollection(name: "工作")
        let child = try library.createCollection(name: "项目")
        let first = try library.addImage(fixture(), source: "截图", collectionID: folder.id)
        let second = try library.addImage(fixture(), source: "拼图", collectionID: child.id)
        let firstBytes = try Data(contentsOf: library.imageURL(first))
        let secondBytes = try Data(contentsOf: library.imageURL(second))
        XCTAssertEqual(library.assets(in: folder.id), [.image(first.id)])
        XCTAssertEqual(library.assets(in: child.id), [.image(second.id)])
        try library.deleteCollection(folder.id)
        XCTAssertEqual(library.collections.map(\.id), [child.id])
        XCTAssertEqual(library.images.count, 2)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(first)), firstBytes)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(second)), secondBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).count, 2)
        await library.cancelStorageWorkAndWait()
    }

    func testDeletedDestinationDoesNotLeaveResultFileOrIndexEntry() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let folder = try library.createCollection(name: "待拼图")
        try LibraryDatabase(root: root).deleteCollection(folder.id)
        XCTAssertThrowsError(try library.addImage(fixture(), source: "拼图", collectionID: folder.id))
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try LibraryDatabase(root: root).images().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).isEmpty)
        await library.cancelStorageWorkAndWait()
    }

    func testUnknownAssetsFailWithoutAddingValidItemsFromSameBatch() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let folder = try library.createCollection(name: "素材")
        let item = try library.addImage(fixture(), source: "截图")
        for unknown in [CollectionAsset.image(UUID()), .session(UUID()), .video(root.appendingPathComponent("missing.mp4"))] {
            XCTAssertThrowsError(try library.addToCollection(folder.id, assets: [.image(item.id), unknown]))
            XCTAssertEqual(library.collectionMembers[folder.id], [])
        }
        await library.cancelStorageWorkAndWait()
    }

    func testMixedRecordingReferencesSurviveOfflineVolume() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try library.setStorageDirectory(external, for: .recordings)
        let directory = external.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("published video".utf8).write(to: directory.appendingPathComponent("recording.mp4"))
        try library.reloadSessions()
        let video = try XCTUnwrap(library.videos.first)
        let first = try library.createCollection(name: "A")
        let second = try library.createCollection(name: "B")
        try library.addToCollection(first.id, assets: [.video(video)])
        let offline = root.appendingPathComponent("Offline")
        try FileManager.default.moveItem(at: external, to: offline)
        try library.addToCollection(second.id, assets: [.video(video)])
        XCTAssertFalse(library.recordingReadErrors.isEmpty)
        XCTAssertEqual(library.collectionMembers[first.id], [.video(video)])
        XCTAssertEqual(library.collectionMembers[second.id], [.video(video)])
        await library.cancelStorageWorkAndWait()
    }

    func testFailedSessionReferenceDeleteRestoresTrashedRecordingAndPublishedState() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibraryWithTrash(in: directory)
        let recording = library.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: false)
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 1, sampleRate: 1, threshold: 0.025,
                                        width: 2, height: 2, frames: [.init(file: "frame.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: recording.appendingPathComponent("manifest.json"))
        try LibraryStore.writePNG(fixture(), to: recording.appendingPathComponent("frame.png"))
        let frameBytes = try Data(contentsOf: recording.appendingPathComponent("frame.png"))
        try LibraryStore.writeRecordingTag(.green, to: recording)
        try library.reloadSessions()
        let session = try XCTUnwrap(library.sessions.first)
        let folder = try library.createCollection(name: "录屏")
        try library.addToCollection(folder.id, assets: [.session(session.id)])
        await library.cancelStorageWorkAndWait()
        try rejectMemberDeletion(in: library.root)

        XCTAssertThrowsError(try library.deleteSession(session)) { error in
            XCTAssertTrue(error.localizedDescription.contains("member deletion denied"))
        }

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("trash-invocation"), encoding: .utf8), recording.path)
        XCTAssertEqual(try Data(contentsOf: recording.appendingPathComponent("manifest.json")), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: recording.appendingPathComponent("frame.png")), frameBytes)
        XCTAssertEqual(library.sessions.map(\.id), [session.id])
        XCTAssertEqual(library.recordingTags[recording], .green)
        XCTAssertEqual(library.collectionMembers[folder.id], [.session(session.id)])
        XCTAssertEqual(try LibraryDatabase(root: library.root).collectionState().1[folder.id], [.session(session.id)])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        await library.cancelStorageWorkAndWait()
    }

    func testFailedVideoReferenceDeleteRestoresTrashedRecordingAndPublishedState() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibraryWithTrash(in: directory)
        let recording = library.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: false)
        let video = recording.appendingPathComponent("recording.mp4")
        let videoBytes = Data("published recording".utf8)
        try videoBytes.write(to: video)
        try LibraryStore.writeRecordingTag(.orange, to: recording)
        try library.reloadSessions()
        let folder = try library.createCollection(name: "录屏")
        try library.addToCollection(folder.id, assets: [.video(video)])
        await library.cancelStorageWorkAndWait()
        try rejectMemberDeletion(in: library.root)

        XCTAssertThrowsError(try library.deleteVideo(video)) { error in
            XCTAssertTrue(error.localizedDescription.contains("member deletion denied"))
        }

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("trash-invocation"), encoding: .utf8), recording.path)
        XCTAssertEqual(try Data(contentsOf: video), videoBytes)
        XCTAssertEqual(library.videos, [video])
        XCTAssertEqual(library.recordingTags[recording], .orange)
        XCTAssertEqual(library.collectionMembers[folder.id], [.video(video)])
        XCTAssertEqual(try LibraryDatabase(root: library.root).collectionState().1[folder.id], [.video(video)])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Trash").path).isEmpty)
        await library.cancelStorageWorkAndWait()
    }

    func testAutomaticCapacityCleanupUpdatesPublishedAndPersistedMemberships() async throws {
        let directory = try temporaryDirectory()
        let library = try makeLibraryWithTrash(in: directory)
        let item = VaultImage(id: UUID(), filename: "old.png", createdAt: Date().addingTimeInterval(-60 * 86_400),
                              width: 2, height: 2, source: "截图")
        let imageURL = library.imageURL(item)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: false)
        try LibraryStore.writePNG(fixture(), to: imageURL)
        let original = try Data(contentsOf: imageURL)
        try LibraryDatabase(root: library.root).insert(item)
        try library.reloadImages()
        let folder = try library.createCollection(name: "历史")
        try library.addToCollection(folder.id, assets: [.image(item.id)])
        var policy = LibraryStoragePolicy(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                          protectTaggedImages: false, keepRecentDays: 0)
        policy.protectCollectedImages = false
        try library.updateStoragePolicy(policy)

        await library.refreshStorageUsage()

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(library.collections, [folder])
        XCTAssertEqual(library.collectionMembers[folder.id], [])
        XCTAssertEqual(try LibraryDatabase(root: library.root).collectionState().1[folder.id], [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Trash").appendingPathComponent(item.id.uuidString).appendingPathComponent(item.filename)), original)
        XCTAssertEqual(library.storageUsage?.mediaBytes, 0)
        XCTAssertNil(library.storageUsageError)
        await library.cancelStorageWorkAndWait()
    }

    private func makeLibraryWithTrash(in directory: URL) throws -> LibraryStore {
        let root = directory.appendingPathComponent("Vault")
        let trash = directory.appendingPathComponent("Trash")
        let receipt = directory.appendingPathComponent("trash-invocation")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        return try LibraryStore(root: root, trashImageDirectory: { source in
            guard source.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            try Data(source.path.utf8).write(to: receipt)
            return destination
        })
    }

    private func rejectMemberDeletion(in root: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_member_delete BEFORE DELETE ON collectionMembers BEGIN SELECT RAISE(ABORT, 'member deletion denied'); END", nil, nil, nil), SQLITE_OK)
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CollectionStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
