import Foundation

struct LibraryStoragePolicy: Equatable {
    var maximumBytes: Int64? = nil
    var automaticallyRemoveOldestImages = false
    var protectTaggedImages = true
    var protectCollectedImages = true
    var keepRecentDays = 7

    func validate() throws {
        if let maximumBytes, maximumBytes <= 0 { throw LibraryStoragePolicyError.invalidCapacity }
        if keepRecentDays < 0 { throw LibraryStoragePolicyError.invalidRecentDays }
    }
}

enum LibraryStoragePolicyError: LocalizedError {
    case invalidCapacity
    case invalidRecentDays

    var errorDescription: String? {
        switch self {
        case .invalidCapacity: return L("保管箱容量上限必须大于 0。")
        case .invalidRecentDays: return L("保留天数不能小于 0。")
        }
    }
}
