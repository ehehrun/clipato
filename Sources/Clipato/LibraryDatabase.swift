import Foundation
import CSQLite

struct LibraryDatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { L("保管箱数据库：\(message)") }
}

final class LibraryDatabase {
    private let connection: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let insertSQL = "INSERT INTO images (id, filename, createdAt, width, height, source, directory, tag) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"

    init(root: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &opened,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? L("无法打开数据库 (\(status))")
            if let opened { sqlite3_close(opened) }
            throw LibraryDatabaseError(message: message)
        }
        connection = opened
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, 3_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA cache_size = -512; PRAGMA mmap_size = 0; PRAGMA synchronous = FULL; PRAGMA wal_autocheckpoint = 128")
        try execute("PRAGMA journal_mode = WAL")
        try transaction {
            let version = try integer("PRAGMA user_version")
            guard (0...6).contains(version) else {
                throw LibraryDatabaseError(message: L("此索引版本较新，请使用支持版本 \(version) 的 Clipato。"))
            }
            if version == 0 {
                try execute("""
                    CREATE TABLE images (
                        id TEXT PRIMARY KEY NOT NULL,
                        filename TEXT NOT NULL,
                        createdAt REAL NOT NULL,
                        width INTEGER NOT NULL CHECK (width > 0),
                        height INTEGER NOT NULL CHECK (height > 0),
                        source TEXT NOT NULL,
                        directory TEXT,
                        tag TEXT CHECK (tag IN ('red', 'orange', 'yellow', 'green', 'blue', 'purple', 'gray'))
                    )
                    """)
                let legacy = root.appendingPathComponent("images.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let images = try decoder.decode([VaultImage].self, from: Data(contentsOf: legacy))
                    // 保留原索引作为迁移备份；按原数组顺序迁移，不能用日期重排同秒截图。
                    try statement(Self.insertSQL) { statement in
                        for image in images.reversed() {
                            try insert(image, using: statement)
                            sqlite3_reset(statement)
                            sqlite3_clear_bindings(statement)
                        }
                    }
                }
                try execute("PRAGMA user_version = 1")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS storagePolicy (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    maximumBytes INTEGER CHECK (maximumBytes > 0),
                    automaticallyRemoveOldestImages INTEGER NOT NULL CHECK (automaticallyRemoveOldestImages IN (0, 1)),
                    protectTaggedImages INTEGER NOT NULL CHECK (protectTaggedImages IN (0, 1)),
                    keepRecentDays INTEGER NOT NULL CHECK (keepRecentDays >= 0)
                );
                INSERT OR IGNORE INTO storagePolicy (id, maximumBytes, automaticallyRemoveOldestImages, protectTaggedImages, keepRecentDays)
                VALUES (1, NULL, 0, 1, 7)
                """)
            if version < 2 {
                try execute("""
                    CREATE TABLE collections (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                        parentID TEXT REFERENCES collections(id) ON DELETE CASCADE,
                        position INTEGER NOT NULL CHECK (position >= 0),
                        CHECK (parentID IS NULL OR parentID != id)
                    );
                    CREATE INDEX collections_parent ON collections(parentID, position);
                    CREATE TABLE collectionMembers (
                        collectionID TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                        imageID TEXT REFERENCES images(id) ON DELETE CASCADE,
                        sessionID TEXT,
                        videoURL TEXT,
                        CHECK ((imageID IS NOT NULL) + (sessionID IS NOT NULL) + (videoURL IS NOT NULL) = 1)
                    );
                    CREATE UNIQUE INDEX collection_images ON collectionMembers(collectionID, imageID) WHERE imageID IS NOT NULL;
                    CREATE UNIQUE INDEX collection_sessions ON collectionMembers(collectionID, sessionID) WHERE sessionID IS NOT NULL;
                    CREATE UNIQUE INDEX collection_videos ON collectionMembers(collectionID, videoURL) WHERE videoURL IS NOT NULL;
                    CREATE INDEX collection_image_reference ON collectionMembers(imageID) WHERE imageID IS NOT NULL;
                    PRAGMA user_version = 2
                    """)
            }
            if version < 5 {
                // 旧层级迁移也读取收藏夹，因此须先补齐颜色列，再按原顺序升级。
                try execute("ALTER TABLE collections ADD COLUMN color TEXT CHECK (color IN ('red', 'orange', 'yellow', 'green', 'blue', 'purple', 'gray'))")
            }
            if version < 3 {
                let collections = try readCollections()
                let children = Dictionary(grouping: collections, by: \.parentID)
                var pending = Array((children[nil] ?? []).reversed())
                var ordered: [AssetCollection] = []
                while let collection = pending.popLast() {
                    ordered.append(collection)
                    pending.append(contentsOf: (children[collection.id] ?? []).reversed())
                }
                guard ordered.count == collections.count else {
                    throw LibraryDatabaseError(message: L("收藏夹层级无效，升级未修改原索引。"))
                }
                try updateCollectionPositions(ordered, parentID: nil)
                try execute("""
                    ALTER TABLE storagePolicy ADD COLUMN protectCollectedImages INTEGER NOT NULL DEFAULT 1 CHECK (protectCollectedImages IN (0, 1));
                    CREATE TRIGGER collections_single_level_insert BEFORE INSERT ON collections
                    WHEN NEW.parentID IS NOT NULL BEGIN SELECT RAISE(ABORT, '收藏夹仅支持一级'); END;
                    CREATE TRIGGER collections_single_level_update BEFORE UPDATE OF parentID ON collections
                    WHEN NEW.parentID IS NOT NULL BEGIN SELECT RAISE(ABORT, '收藏夹仅支持一级'); END;
                    PRAGMA user_version = 3
                    """)
            }
            if version < 4 {
                try execute("""
                    CREATE TABLE operationHistory (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        imageID TEXT REFERENCES images(id) ON DELETE SET NULL
                    );
                    INSERT INTO operationHistory (id, imageID)
                    VALUES (1, (SELECT id FROM images ORDER BY rowid DESC LIMIT 1));
                    CREATE TRIGGER images_remember_recent AFTER INSERT ON images
                    BEGIN UPDATE operationHistory SET imageID = NEW.id WHERE id = 1; END;
                    PRAGMA user_version = 4
                    """)
            }
            if version < 5 { try execute("PRAGMA user_version = 5") }
            if version < 6 {
                try execute("DROP TRIGGER images_remember_recent; PRAGMA user_version = 6")
            }
        }
    }

    deinit { sqlite3_close(connection) }

    func dataVersion() throws -> Int64 { try integer("PRAGMA data_version") }

    func collectionState() throws -> ([AssetCollection], [UUID: Set<CollectionAsset>]) {
        // 一条查询读取目录及关系，避免另一个进程写入时出现不同版本的树与内容。
        try statement("""
            SELECT c.id, c.name, c.parentID, c.position, c.color, m.imageID, m.sessionID, m.videoURL
            FROM collections c LEFT JOIN collectionMembers m ON c.id = m.collectionID
            ORDER BY c.parentID, c.position, c.id
            """) { statement in
            var collections: [AssetCollection] = []
            var members: [UUID: Set<CollectionAsset>] = [:]
            while try step(statement) == SQLITE_ROW {
                let collection = try readCollection(statement)
                if members[collection.id] == nil {
                    collections.append(collection)
                    members[collection.id] = []
                }
                let asset: CollectionAsset?
                if sqlite3_column_type(statement, 5) != SQLITE_NULL {
                    asset = .image(try uuid(statement, at: 5))
                } else if sqlite3_column_type(statement, 6) != SQLITE_NULL {
                    asset = .session(try uuid(statement, at: 6))
                } else if sqlite3_column_type(statement, 7) != SQLITE_NULL {
                    guard let url = URL(string: try text(statement, at: 7)), url.isFileURL else {
                        throw LibraryDatabaseError(message: L("收藏视频位置无效。"))
                    }
                    asset = .video(url)
                } else { asset = nil }
                if let asset { members[collection.id]!.insert(asset) }
            }
            return (collections, members)
        }
    }

    func clearCollections() throws {
        try transaction { try execute("DELETE FROM collections") }
    }

    func createCollection(name: String, parentID: UUID?) throws -> AssetCollection {
        guard parentID == nil else { throw CollectionError.singleLevelOnly }
        let name = try collectionName(name)
        return try transaction {
            let collections = try readCollections()
            let position = collections.count
            let collection = AssetCollection(id: UUID(), name: name, parentID: parentID, position: position)
            try statement("INSERT INTO collections (id, name, parentID, position) VALUES (?, ?, ?, ?)") { statement in
                try bind(collection.id.uuidString, to: statement, at: 1)
                try bind(name, to: statement, at: 2)
                try bind(parentID?.uuidString, to: statement, at: 3)
                try check(sqlite3_bind_int64(statement, 4, Int64(position)))
                try step(statement)
            }
            return collection
        }
    }

    func renameCollection(_ id: UUID, name: String) throws {
        let name = try collectionName(name)
        try statement("UPDATE collections SET name = ? WHERE id = ?") { statement in
            try bind(name, to: statement, at: 1)
            try bind(id.uuidString, to: statement, at: 2)
            try step(statement)
            guard sqlite3_changes(connection) == 1 else { throw CollectionError.missingCollection }
        }
    }

    func setCollectionColor(_ id: UUID, color: AssetTag?) throws {
        try statement("UPDATE collections SET color = ? WHERE id = ?") { statement in
            try bind(color?.rawValue, to: statement, at: 1)
            try bind(id.uuidString, to: statement, at: 2)
            try step(statement)
            guard sqlite3_changes(connection) == 1 else { throw CollectionError.missingCollection }
        }
    }

    func deleteCollection(_ id: UUID) throws {
        try transaction {
            let collections = try readCollections()
            guard let collection = collections.first(where: { $0.id == id }) else { throw CollectionError.missingCollection }
            try statement("DELETE FROM collections WHERE id = ?") { statement in
                try bind(id.uuidString, to: statement, at: 1)
                try step(statement)
            }
            try updateCollectionPositions(collections.filter { $0.parentID == collection.parentID && $0.id != id }, parentID: collection.parentID)
        }
    }

    func moveCollection(_ id: UUID, toParent parentID: UUID?, before: UUID?) throws {
        guard parentID == nil else { throw CollectionError.singleLevelOnly }
        try transaction {
            let collections = try readCollections()
            guard let moving = collections.first(where: { $0.id == id }) else { throw CollectionError.missingCollection }
            if before == id { return }
            var siblings = collections.filter { $0.id != id }
            let index: Int
            if let before {
                guard let found = siblings.firstIndex(where: { $0.id == before }) else { throw CollectionError.invalidSibling }
                index = found
            } else { index = siblings.count }
            siblings.insert(moving, at: index)
            try updateCollectionPositions(siblings, parentID: nil)
        }
    }

    func addToCollection(_ id: UUID, assets: Set<CollectionAsset>) throws {
        try transaction {
            try requireCollection(id)
            try insertCollectionAssets(assets, collectionID: id)
        }
    }

    private func insertCollectionAssets(_ assets: Set<CollectionAsset>, collectionID: UUID) throws {
        try statement("INSERT INTO collectionMembers (collectionID, imageID, sessionID, videoURL) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING") { statement in
            for asset in assets {
                try bind(collectionID.uuidString, to: statement, at: 1)
                try bind(asset, to: statement, at: 2)
                try step(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    func removeFromCollection(_ id: UUID, assets: Set<CollectionAsset>) throws {
        try transaction {
            try requireCollection(id)
            try removeCollectionAssets(assets, collectionID: id)
        }
    }

    func removeCollectionAsset(_ asset: CollectionAsset) throws {
        try removeCollectionAssets([asset], collectionID: nil)
    }

    func isCollectedImage(_ id: UUID) throws -> Bool {
        try statement("SELECT EXISTS(SELECT 1 FROM collectionMembers WHERE imageID = ?)") { statement in
            try bind(id.uuidString, to: statement, at: 1)
            guard try step(statement) == SQLITE_ROW else { throw LibraryDatabaseError(message: L("无法读取图片收藏状态。")) }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func removeCollectionAssets(_ assets: Set<CollectionAsset>, collectionID: UUID?) throws {
        let condition = collectionID == nil ? "" : "collectionID = ? AND "
        try statement("DELETE FROM collectionMembers WHERE \(condition)(imageID IS ? AND sessionID IS ? AND videoURL IS ?)") { statement in
            for asset in assets {
                if let collectionID { try bind(collectionID.uuidString, to: statement, at: 1) }
                try bind(asset, to: statement, at: collectionID == nil ? 1 : 2)
                try step(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    private func bind(_ asset: CollectionAsset, to statement: OpaquePointer, at index: Int32) throws {
        for offset in Int32(0)...Int32(2) { try check(sqlite3_bind_null(statement, index + offset)) }
        switch asset {
        case .image(let id): try bind(id.uuidString, to: statement, at: index)
        case .session(let id): try bind(id.uuidString, to: statement, at: index + 1)
        case .video(let url):
            guard url.isFileURL else { throw CollectionError.missingAsset }
            try bind(url.absoluteString, to: statement, at: index + 2)
        }
    }

    private func readCollections() throws -> [AssetCollection] {
        try statement("SELECT id, name, parentID, position, color FROM collections ORDER BY parentID, position, id") { statement in
            var result: [AssetCollection] = []
            while try step(statement) == SQLITE_ROW { result.append(try readCollection(statement)) }
            return result
        }
    }

    private func readCollection(_ statement: OpaquePointer) throws -> AssetCollection {
        let color: AssetTag?
        if sqlite3_column_type(statement, 4) == SQLITE_NULL { color = nil }
        else {
            guard let value = AssetTag(rawValue: try text(statement, at: 4)) else {
                throw LibraryDatabaseError(message: L("收藏夹颜色无效，索引未被修改。"))
            }
            color = value
        }
        return AssetCollection(id: try uuid(statement, at: 0), name: try text(statement, at: 1),
                        parentID: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : try uuid(statement, at: 2),
                        position: Int(sqlite3_column_int64(statement, 3)), color: color)
    }

    private func uuid(_ statement: OpaquePointer, at index: Int32) throws -> UUID {
        guard let id = UUID(uuidString: try text(statement, at: index)) else {
            throw LibraryDatabaseError(message: L("收藏夹索引包含无效 ID。"))
        }
        return id
    }

    private func collectionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CollectionError.invalidName }
        return trimmed
    }

    private func requireCollection(_ id: UUID) throws {
        try statement("SELECT 1 FROM collections WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, at: 1)
            guard try step(statement) == SQLITE_ROW else { throw CollectionError.missingCollection }
        }
    }

    private func updateCollectionPositions(_ collections: [AssetCollection], parentID: UUID?) throws {
        try statement("UPDATE collections SET parentID = ?, position = ? WHERE id = ?") { statement in
            for (position, collection) in collections.enumerated() {
                try bind(parentID?.uuidString, to: statement, at: 1)
                try check(sqlite3_bind_int64(statement, 2, Int64(position)))
                try bind(collection.id.uuidString, to: statement, at: 3)
                try step(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
        }
    }

    func images() throws -> [VaultImage] {
        try statement("SELECT id, filename, createdAt, width, height, source, directory, tag FROM images ORDER BY rowid DESC") { statement in
            var images: [VaultImage] = []
            while try step(statement) == SQLITE_ROW {
                images.append(try readImage(statement))
            }
            return images
        }
    }

    func image(_ id: UUID) throws -> VaultImage? {
        try statement("SELECT id, filename, createdAt, width, height, source, directory, tag FROM images WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, at: 1)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return try readImage(statement)
        }
    }

    func recentImage() throws -> VaultImage? {
        try statement("""
            SELECT i.id, i.filename, i.createdAt, i.width, i.height, i.source, i.directory, i.tag
            FROM operationHistory h JOIN images i ON i.id = h.imageID WHERE h.id = 1
            """) { statement in
            guard try step(statement) == SQLITE_ROW else { return nil }
            return try readImage(statement)
        }
    }

    func rememberImage(_ id: UUID) throws {
        try statement("UPDATE operationHistory SET imageID = ? WHERE id = 1") { statement in
            try bind(id.uuidString, to: statement, at: 1)
            try step(statement)
            guard sqlite3_changes(connection) == 1 else {
                throw LibraryDatabaseError(message: L("操作记忆记录缺失。"))
            }
        }
    }

    func clearOperationHistory() throws {
        try execute("UPDATE operationHistory SET imageID = NULL WHERE id = 1")
        guard sqlite3_changes(connection) == 1 else {
            throw LibraryDatabaseError(message: L("操作记忆记录缺失。"))
        }
    }

    private func readImage(_ statement: OpaquePointer) throws -> VaultImage {
        guard let id = UUID(uuidString: try text(statement, at: 0)) else {
            throw LibraryDatabaseError(message: L("图片 ID 无效，索引未被修改。"))
        }
        let directory: URL?
        if sqlite3_column_type(statement, 6) == SQLITE_NULL { directory = nil }
        else {
            guard let url = URL(string: try text(statement, at: 6)), url.isFileURL else {
                throw LibraryDatabaseError(message: L("图片保存位置无效，索引未被修改。"))
            }
            directory = url
        }
        let tag: AssetTag?
        if sqlite3_column_type(statement, 7) == SQLITE_NULL { tag = nil }
        else {
            guard let value = AssetTag(rawValue: try text(statement, at: 7)) else {
                throw LibraryDatabaseError(message: L("图片标签无效，索引未被修改。"))
            }
            tag = value
        }
        return VaultImage(id: id, filename: try text(statement, at: 1),
                                 createdAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                                 width: Int(sqlite3_column_int64(statement, 3)), height: Int(sqlite3_column_int64(statement, 4)),
                                 source: try text(statement, at: 5), directory: directory, tag: tag)
    }

    func storagePolicy() throws -> LibraryStoragePolicy {
        try statement("SELECT maximumBytes, automaticallyRemoveOldestImages, protectTaggedImages, keepRecentDays, protectCollectedImages FROM storagePolicy WHERE id = 1") { statement in
            guard try step(statement) == SQLITE_ROW else {
                throw LibraryDatabaseError(message: L("容量设置记录缺失。"))
            }
            var policy = LibraryStoragePolicy(
                maximumBytes: sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0),
                automaticallyRemoveOldestImages: sqlite3_column_int(statement, 1) == 1,
                protectTaggedImages: sqlite3_column_int(statement, 2) == 1,
                keepRecentDays: Int(sqlite3_column_int64(statement, 3)))
            policy.protectCollectedImages = sqlite3_column_int(statement, 4) == 1
            try policy.validate()
            return policy
        }
    }

    func updateStoragePolicy(_ policy: LibraryStoragePolicy) throws {
        try policy.validate()
        try statement("UPDATE storagePolicy SET maximumBytes = ?, automaticallyRemoveOldestImages = ?, protectTaggedImages = ?, keepRecentDays = ?, protectCollectedImages = ? WHERE id = 1") { statement in
            if let maximum = policy.maximumBytes { try check(sqlite3_bind_int64(statement, 1, maximum)) }
            else { try check(sqlite3_bind_null(statement, 1)) }
            try check(sqlite3_bind_int(statement, 2, policy.automaticallyRemoveOldestImages ? 1 : 0))
            try check(sqlite3_bind_int(statement, 3, policy.protectTaggedImages ? 1 : 0))
            try check(sqlite3_bind_int64(statement, 4, Int64(policy.keepRecentDays)))
            try check(sqlite3_bind_int(statement, 5, policy.protectCollectedImages ? 1 : 0))
            try step(statement)
            guard sqlite3_changes(connection) == 1 else { throw LibraryDatabaseError(message: L("容量设置记录缺失。")) }
        }
    }

    func insert(_ image: VaultImage, collectionID: UUID? = nil, remember: Bool = true) throws {
        try transaction {
            if let collectionID { try requireCollection(collectionID) }
            try statement(Self.insertSQL) { try insert(image, using: $0) }
            if let collectionID {
                try insertCollectionAssets([.image(image.id)], collectionID: collectionID)
            }
            if remember { try rememberImage(image.id) }
        }
    }

    func insert(_ images: [VaultImage], remember: Bool = true) throws {
        try transaction {
            try statement(Self.insertSQL) { statement in
                for image in images {
                    try Task.checkCancellation()
                    try insert(image, using: statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
            try Task.checkCancellation()
            if remember, let last = images.last { try rememberImage(last.id) }
        }
    }

    func rename(_ id: UUID, to filename: String) throws {
        try statement("UPDATE images SET filename = ? WHERE id = ?") { statement in
            try bind(filename, to: statement, at: 1)
            try bind(id.uuidString, to: statement, at: 2)
            try step(statement)
        }
    }

    func batchRename(_ renames: [(CollectionAsset, URL)]) throws {
        try transaction {
            var videoRenames: [(URL, URL, URL)] = []
            try statement("UPDATE images SET filename = ? WHERE id = ?") { statement in
                for (asset, destination) in renames {
                    switch asset {
                    case .image(let id):
                        try bind(destination.lastPathComponent, to: statement, at: 1)
                        try bind(id.uuidString, to: statement, at: 2)
                        try step(statement)
                        guard sqlite3_changes(connection) == 1 else { throw CollectionError.missingAsset }
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                    case .video(let source):
                        videoRenames.append((source, source.deletingLastPathComponent().appendingPathComponent(".clipato-rename-\(UUID().uuidString)"), destination))
                    case .session: throw BatchRenameError.unsupportedSelection
                    }
                }
            }
            // Temporary references also let a batch exchange names without colliding in a collection.
            try statement("UPDATE collectionMembers SET videoURL = ? WHERE videoURL = ?") { statement in
                for (source, temporary, _) in videoRenames {
                    try bind(temporary.absoluteString, to: statement, at: 1)
                    try bind(source.absoluteString, to: statement, at: 2)
                    try step(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
                for (_, temporary, destination) in videoRenames {
                    try bind(destination.absoluteString, to: statement, at: 1)
                    try bind(temporary.absoluteString, to: statement, at: 2)
                    try step(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }
    }

    func delete(_ id: UUID) throws {
        try statement("DELETE FROM images WHERE id = ?") { statement in
            try bind(id.uuidString, to: statement, at: 1)
            try step(statement)
        }
    }

    func setTag(_ tag: AssetTag?, for ids: [UUID]) throws {
        try transaction {
            try statement("UPDATE images SET tag = ? WHERE id = ?") { statement in
                for id in ids {
                    try bind(tag?.rawValue, to: statement, at: 1)
                    try bind(id.uuidString, to: statement, at: 2)
                    try step(statement)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
        }
    }

    private func insert(_ image: VaultImage, using statement: OpaquePointer) throws {
        if let directory = image.directory, !directory.isFileURL {
            throw LibraryDatabaseError(message: L("图片保存位置无效，索引未被修改。"))
        }
        try bind(image.id.uuidString, to: statement, at: 1)
        try bind(image.filename, to: statement, at: 2)
        try check(sqlite3_bind_double(statement, 3, image.createdAt.timeIntervalSinceReferenceDate))
        try check(sqlite3_bind_int64(statement, 4, Int64(image.width)))
        try check(sqlite3_bind_int64(statement, 5, Int64(image.height)))
        try bind(image.source, to: statement, at: 6)
        try bind(image.directory?.absoluteString, to: statement, at: 7)
        try bind(image.tag?.rawValue, to: statement, at: 8)
        try step(statement)
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            let original = error
            do { try execute("ROLLBACK") }
            catch { throw LibraryDatabaseError(message: L("\(original.localizedDescription)；回滚失败：\(error.localizedDescription)")) }
            throw original
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(connection, sql, nil, nil, nil))
    }

    private func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { statement in
            guard try step(statement) == SQLITE_ROW else {
                throw LibraryDatabaseError(message: L("无法读取数据库状态。"))
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func statement<T>(_ sql: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        return try action(statement!)
    }

    @discardableResult
    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw LibraryDatabaseError(message: String(cString: sqlite3_errmsg(connection)))
        }
        return result
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        if let value {
            try check(sqlite3_bind_text(statement, index, value, Int32(value.utf8.count), Self.transient))
        } else { try check(sqlite3_bind_null(statement, index)) }
    }

    private func text(_ statement: OpaquePointer, at column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column),
              let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else {
            throw LibraryDatabaseError(message: L("索引包含无效文字，索引未被修改。"))
        }
        return value
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw LibraryDatabaseError(message: String(cString: sqlite3_errmsg(connection)))
        }
    }
}
