import AppKit
import CoreFoundation
import Darwin
import Foundation

actor MCPAccessLog {
    struct Entry {
        var timestamp = Date()
        let sessionID: UUID
        let client: [String: String]?
        let id: String?
        let method: String
        let tool: String?
        let status: String
        var durationMs: Int? = nil
        var assets: [String]? = nil
        var message: String? = nil
        var params: [String: Any]? = nil
        var transport: String? = nil
        var caller: [String: Any]? = nil
        var exitCode: Int32? = nil
    }

    nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clipato/mcp-access.log")
    nonisolated static let maximumMBKey = "mcpAccessLogMaximumMB"
    nonisolated static let defaultMaximumMB = 20
    static let shared = MCPAccessLog(fileURL: fileURL)
    private let url: URL
    private let defaults: UserDefaults
    private var cachedSnapshot: Snapshot?
    private var cachedText = ""

    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int

        init(_ information: stat) {
            device = information.st_dev
            inode = information.st_ino
            size = information.st_size
            seconds = information.st_mtimespec.tv_sec
            nanoseconds = information.st_mtimespec.tv_nsec
        }
    }

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        url = fileURL
        self.defaults = defaults
    }

    nonisolated static func maximumMB(in defaults: UserDefaults = .standard) -> Int {
        defaults.synchronize()
        return defaults.object(forKey: maximumMBKey) == nil ? defaultMaximumMB : defaults.integer(forKey: maximumMBKey)
    }

    func setMaximumMB(_ value: Int) throws {
        let maximumBytes = try bytes(for: value)
        try withLock {
            try enforceLimit(maximumBytes, incoming: 0)
            let descriptor = try openRegularFile(url, flags: O_CREAT | O_WRONLY | O_APPEND)
            Darwin.close(descriptor)
            defaults.set(value, forKey: Self.maximumMBKey)
            defaults.synchronize()
        }
    }

    func prepare() throws {
        try withLock {
            try enforceLimit(configuredMaximumBytes(), incoming: 0)
            let descriptor = try openRegularFile(url, flags: O_CREAT | O_WRONLY | O_APPEND)
            Darwin.close(descriptor)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // The lock must survive renaming the active file, including across MCP processes.
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = try openRegularFile(lockURL, flags: O_CREAT | O_RDWR)
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw fileError(lockURL) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func openRegularFile(_ file: URL, flags: Int32) throws -> Int32 {
        let descriptor = open(file.path, flags | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw fileError(file) }
        do { _ = try regularStatus(descriptor, at: file) }
        catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func regularStatus(_ descriptor: Int32, at file: URL) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw fileError(file) }
        guard information.st_mode & S_IFMT == S_IFREG else { throw fileError(file, code: EINVAL) }
        return information
    }

    private func configuredMaximumBytes() throws -> UInt64 {
        let value = Self.maximumMB(in: defaults)
        if let object = defaults.object(forKey: Self.maximumMBKey) {
            guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(value) else { throw MCPAccessLogError.invalidMaximumMB }
        }
        return try bytes(for: value)
    }

    private func bytes(for value: Int) throws -> UInt64 {
        guard (1...1024).contains(value) else { throw MCPAccessLogError.invalidMaximumMB }
        return UInt64(value) * 1_000_000
    }

    private func archive(_ generation: Int) -> URL { url.appendingPathExtension(String(generation)) }

    private func size(at file: URL) throws -> UInt64 {
        var information = stat()
        if lstat(file.path, &information) != 0 {
            if errno == ENOENT { return 0 }
            throw fileError(file)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw fileError(file, code: information.st_mode & S_IFMT == S_IFLNK ? ELOOP : EINVAL)
        }
        return UInt64(information.st_size)
    }

    private func remove(_ file: URL) throws {
        if unlink(file.path) != 0, errno != ENOENT { throw fileError(file) }
    }

    private func move(_ source: URL, to destination: URL) throws {
        if rename(source.path, destination.path) != 0, errno != ENOENT { throw fileError(source) }
    }

    private func enforceLimit(_ maximumBytes: UInt64, incoming: UInt64) throws {
        guard incoming <= maximumBytes else { throw MCPAccessLogError.oversizedEntry }
        let activeSize = try size(at: url)
        if activeSize > 0, activeSize + incoming > maximumBytes / 4 {
            try remove(archive(3))
            for generation in stride(from: 2, through: 1, by: -1) {
                try move(archive(generation), to: archive(generation + 1))
            }
            try move(url, to: archive(1))
            cachedSnapshot = nil
        }
        var total = try size(at: url)
        for generation in 1...3 { total += try size(at: archive(generation)) }
        for generation in stride(from: 3, through: 1, by: -1) where total + incoming > maximumBytes {
            let file = archive(generation)
            let fileSize = try size(at: file)
            try remove(file)
            total -= fileSize
        }
    }

    private func fileError(_ file: URL, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: file.path])
    }

    func append(_ entry: Entry) throws {
        var record: [String: Any] = ["timestamp": entry.timestamp.ISO8601Format(),
                                     "sessionID": entry.sessionID.uuidString,
                                     "method": entry.method, "status": entry.status]
        if let client = entry.client { record["client"] = client }
        if let id = entry.id { record["id"] = id }
        if let tool = entry.tool { record["tool"] = tool }
        if let durationMs = entry.durationMs { record["durationMs"] = durationMs }
        if let assets = entry.assets { record["assets"] = assets }
        if let message = entry.message { record["message"] = message }
        if let params = entry.params { record["params"] = params }
        if let transport = entry.transport { record["transport"] = transport }
        if let caller = entry.caller { record["caller"] = caller }
        if let exitCode = entry.exitCode { record["exitCode"] = exitCode }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
        try withLock {
            try enforceLimit(configuredMaximumBytes(), incoming: UInt64(data.count))
            let descriptor = try openRegularFile(url, flags: O_CREAT | O_WRONLY | O_APPEND)
            defer { Darwin.close(descriptor) }
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        }
    }

    func recentText() throws -> String {
        try withLock {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                if errno == ENOENT {
                    cachedSnapshot = nil
                    cachedText = ""
                    return ""
                }
                throw fileError(url)
            }
            defer { Darwin.close(descriptor) }
            let snapshot = Snapshot(try regularStatus(descriptor, at: url))
            if cachedSnapshot == snapshot { return cachedText }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let size = UInt64(snapshot.size)
            let offset = size > 262_144 ? size - 262_144 : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: 262_144) ?? Data()
            if offset > 0 {
                if let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
                else { data.removeAll() }
                guard !data.isEmpty else { throw MCPAccessLogError.previewEntryTooLarge }
            }
            cachedText = String(decoding: data, as: UTF8.self)
            cachedSnapshot = snapshot
            return cachedText
        }
    }

    nonisolated static var tailCommand: String { tailCommand(for: fileURL) }

    nonisolated static func tailCommand(for url: URL) -> String {
        "tail -F -- '" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    static func copyTailCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tailCommand, forType: .string)
    }
}

enum MCPAccessLogError: LocalizedError, Equatable {
    case invalidMaximumMB
    case oversizedEntry
    case previewEntryTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidMaximumMB: return L("日志容量须为 1–1024 MB 的整数。")
        case .oversizedEntry: return L("单条访问日志超过日志总容量上限。")
        case .previewEntryTooLarge: return L("当前日志条目超过预览范围，请使用 tail -F 查看。")
        }
    }
}
