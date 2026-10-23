import Foundation

enum AssetFileInfo: Equatable {
    case size(Int64)
    case unavailable(String)

    var byteCount: Int64? {
        if case .size(let bytes) = self { return bytes }
        return nil
    }

    var label: String {
        switch self {
        case .size(let bytes): return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .unavailable: return L("大小不可用")
        }
    }

    var help: String {
        switch self {
        case .size(let bytes): return L("\(bytes.formatted()) 字节")
        case .unavailable(let message): return message
        }
    }
}

func remappingAssetMetadata<Value>(_ cache: [URL: Value], renames: [URL: URL]) -> [URL: Value] {
    guard !renames.isEmpty else { return cache }
    var updated = cache
    for source in renames.keys { updated.removeValue(forKey: source) }
    for (source, destination) in renames { updated[destination] = cache[source] }
    return updated
}

func renamedImageURLs(previous: [VaultImage], current: [VaultImage], imageURL: (VaultImage) -> URL) -> [URL: URL] {
    let previousURLs = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, imageURL($0)) })
    var renames: [URL: URL] = [:]
    for image in current {
        guard let source = previousURLs[image.id] else { continue }
        let destination = imageURL(image)
        if source != destination { renames[source] = destination }
    }
    return renames
}

actor AssetFileInfoLoader {
    private var cache: [URL: AssetFileInfo] = [:]
    private(set) var creationDates: [URL: Date] = [:]
    private var creationDatesLoaded: Set<URL> = []

    func load(_ urls: [URL], includingCreationDates: Bool = false) throws -> [URL: AssetFileInfo] {
        let retained = Set(urls)
        cache = cache.filter { retained.contains($0.key) }
        creationDates = creationDates.filter { retained.contains($0.key) }
        creationDatesLoaded.formIntersection(retained)
        for url in urls {
            try Task.checkCancellation()
            if cache[url] == nil {
                do { cache[url] = .size(try Self.byteCount(at: url)) }
                catch is CancellationError { throw CancellationError() }
                catch { cache[url] = .unavailable(error.localizedDescription) }
            }
            if includingCreationDates && !creationDatesLoaded.contains(url) {
                do {
                    var resourceURL = url
                    resourceURL.removeAllCachedResourceValues()
                    creationDates[url] = try resourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate
                    creationDatesLoaded.insert(url)
                } catch {
                    cache[url] = .unavailable(error.localizedDescription)
                }
            }
        }
        return cache
    }

    func invalidate(_ urls: [URL]) {
        for url in urls {
            cache.removeValue(forKey: url)
            creationDates.removeValue(forKey: url)
            creationDatesLoaded.remove(url)
        }
    }

    nonisolated static func byteCount(at url: URL) throws -> Int64 {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            var total: Int64 = 0
            for child in children {
                try Task.checkCancellation()
                // Session contents count once; a symlink must not traverse outside the recording.
                if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
                total += try byteCount(at: child)
            }
            return total
        }
        guard let size = values.fileSize else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return Int64(size)
    }
}

enum AssetSortOrder: String, CaseIterable, Identifiable {
    case newest, oldest, sizeDescending, sizeAscending, nameAscending, nameDescending

    var id: Self { self }
    var isAscending: Bool { self == .oldest || self == .sizeAscending || self == .nameAscending }
    var isSize: Bool { self == .sizeDescending || self == .sizeAscending }
    var isName: Bool { self == .nameAscending || self == .nameDescending }
    var title: String {
        switch self {
        case .newest: return L("时间：倒序")
        case .oldest: return L("时间：正序")
        case .sizeDescending: return L("大小：倒序")
        case .sizeAscending: return L("大小：正序")
        case .nameAscending: return L("名称：正序")
        case .nameDescending: return L("名称：倒序")
        }
    }

    func sorted<Item>(_ items: [Item], date: (Item) -> Date?, size: (Item) -> Int64?, name: (Item) -> String) -> [Item] {
        return items.enumerated().sorted { lhs, rhs in
            if isName {
                let comparison = name(lhs.element).localizedStandardCompare(name(rhs.element))
                if comparison == .orderedSame { return lhs.offset < rhs.offset }
                return isAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            } else if isSize {
                switch (size(lhs.element), size(rhs.element)) {
                case let (left?, right?) where left != right:
                    return isAscending ? left < right : left > right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.offset < rhs.offset
                }
            } else {
                switch (date(lhs.element), date(rhs.element)) {
                case let (left?, right?) where left != right:
                    return isAscending ? left < right : left > right
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
        }.map(\.element)
    }
}
