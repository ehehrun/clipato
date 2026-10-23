import CryptoKit
import Darwin
import Foundation

public struct DuplicateFileGroup: Sendable {
    public let urls: [URL]
    public let fileSize: Int64
    public let sha256: String

    public init(urls: [URL], fileSize: Int64, sha256: String) {
        self.urls = urls
        self.fileSize = fileSize
        self.sha256 = sha256
    }
}

public enum FileDuplicateError: LocalizedError {
    case notRegularFile(URL)
    case fileChanged(URL)
    case readAndCloseFailed(Error, Error)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let url): return "不是可读取的普通文件：\(url.path)"
        case .fileChanged(let url): return "检查期间文件已发生变化，请重新检查：\(url.path)"
        case .readAndCloseFailed(let read, let close): return "\(read.localizedDescription)；关闭文件失败：\(close.localizedDescription)"
        }
    }
}

public enum FileDuplicateStep {
    public static func execute(urls: [URL], progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [DuplicateFileGroup] {
        var seenURLs: Set<URL> = []
        var identities: [dev_t: Set<ino_t>] = [:]
        var files: [(url: URL, info: stat)] = []
        for url in urls {
            try Task.checkCancellation()
            guard seenURLs.insert(url).inserted else { continue }
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url]) }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixError(url) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw FileDuplicateError.notRegularFile(url) }
            // Aliases and hard links to one physical file are one input, not another copy to remove.
            guard identities[info.st_dev, default: []].insert(info.st_ino).inserted else { continue }
            files.append((url, info))
        }
        try Task.checkCancellation()
        let total = files.count
        var completed = 0
        progress(completed, total)
        let sizeGroups = Dictionary(grouping: files.indices, by: { files[$0].info.st_size })
            .values.sorted { $0[0] < $1[0] }
        var matches: [(index: Int, group: DuplicateFileGroup)] = []
        var buffer: [UInt8] = []
        for sizeGroup in sizeGroups {
            try Task.checkCancellation()
            if sizeGroup.count == 1 {
                completed += 1
                progress(completed, total)
                continue
            }
            if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: 1_048_576) }
            var samples: [SHA256Digest: [Int]] = [:]
            for index in sizeGroup {
                try Task.checkCancellation()
                let sample = try hash(files[index], sampleOnly: true, buffer: &buffer)
                samples[sample, default: []].append(index)
            }
            for sampleGroup in samples.values.sorted(by: { $0[0] < $1[0] }) {
                try Task.checkCancellation()
                if sampleGroup.count == 1 {
                    completed += 1
                    progress(completed, total)
                    continue
                }
                var hashes: [SHA256Digest: [Int]] = [:]
                for index in sampleGroup {
                    try Task.checkCancellation()
                    let digest = try hash(files[index], sampleOnly: false, buffer: &buffer)
                    hashes[digest, default: []].append(index)
                    completed += 1
                    progress(completed, total)
                }
                for (digest, indices) in hashes where indices.count > 1 {
                    let group = DuplicateFileGroup(urls: indices.map { files[$0].url }, fileSize: files[indices[0]].info.st_size,
                                                   sha256: hexadecimal(digest))
                    matches.append((indices[0], group))
                }
            }
        }
        try validatePaths(files)
        return matches.sorted { $0.index < $1.index }.map(\.group)
    }

    public static func verify(groups: [DuplicateFileGroup]) throws {
        try Task.checkCancellation()
        var buffer: [UInt8] = []
        var verified: [(url: URL, info: stat)] = []
        for group in groups {
            for url in group.urls {
                try Task.checkCancellation()
                guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url]) }
                var info = stat()
                if lstat(url.path, &info) != 0 {
                    if errno == ENOENT { throw FileDuplicateError.fileChanged(url) }
                    throw posixError(url)
                }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size == group.fileSize else { throw FileDuplicateError.fileChanged(url) }
                if buffer.isEmpty { buffer = [UInt8](repeating: 0, count: 1_048_576) }
                let file = (url: url, info: info)
                let digest = try hash(file, sampleOnly: false, buffer: &buffer)
                guard hexadecimal(digest) == group.sha256 else { throw FileDuplicateError.fileChanged(url) }
                verified.append(file)
            }
        }
        try validatePaths(verified)
    }

    public static func sha256(at url: URL) throws -> String {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url]) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixError(url) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileDuplicateError.notRegularFile(url) }
        let file = (url: url, info: info)
        var buffer = [UInt8](repeating: 0, count: Int(min(1_048_576, max(1, info.st_size))))
        let digest = try hash(file, sampleOnly: false, buffer: &buffer)
        try validatePaths([file])
        return hexadecimal(digest)
    }

    private static func validatePaths(_ files: [(url: URL, info: stat)]) throws {
        for file in files {
            try Task.checkCancellation()
            var current = stat()
            if lstat(file.url.path, &current) != 0 {
                if errno == ENOENT { throw FileDuplicateError.fileChanged(file.url) }
                throw posixError(file.url)
            }
            try requireUnchanged(current, file: file)
        }
        try Task.checkCancellation()
    }

    private static func hexadecimal(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ file: (url: URL, info: stat), sampleOnly: Bool, buffer: inout [UInt8]) throws -> SHA256Digest {
        let descriptor = open(file.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { throw FileDuplicateError.fileChanged(file.url) }
            throw posixError(file.url)
        }
        let result: Result<SHA256Digest, Error>
        do {
            var current = stat()
            guard fstat(descriptor, &current) == 0 else { throw posixError(file.url) }
            try requireUnchanged(current, file: file)
            var hasher = SHA256()
            let size = file.info.st_size
            let ranges: [(offset: Int64, count: Int64)]
            if sampleOnly {
                let head = min(size, 4_096)
                let tail = max(head, size - 4_096)
                ranges = [(0, head), (tail, size - tail)]
            } else {
                ranges = [(0, size)]
            }
            let capacity = Int64(buffer.count)
            for range in ranges {
                var readBytes: Int64 = 0
                while readBytes < range.count {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                        let requested = Int(min(capacity, range.count - readBytes))
                        let count = pread(descriptor, bytes.baseAddress!, requested, range.offset + readBytes)
                        if count > 0 {
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress!, count: count))
                        }
                        return count
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw posixError(file.url)
                    }
                    guard count > 0 else { throw FileDuplicateError.fileChanged(file.url) }
                    readBytes += Int64(count)
                }
            }
            guard fstat(descriptor, &current) == 0 else { throw posixError(file.url) }
            try requireUnchanged(current, file: file)
            result = .success(hasher.finalize())
        } catch {
            result = .failure(error)
        }
        if close(descriptor) != 0 {
            let closing = posixError(file.url)
            if case .failure(let reading) = result { throw FileDuplicateError.readAndCloseFailed(reading, closing) }
            throw closing
        }
        return try result.get()
    }

    private static func requireUnchanged(_ current: stat, file: (url: URL, info: stat)) throws {
        let original = file.info
        guard current.st_dev == original.st_dev, current.st_ino == original.st_ino, current.st_size == original.st_size,
              current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw FileDuplicateError.fileChanged(file.url)
        }
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
