import Foundation
import Darwin

enum StorageKind {
    case screenshots
    case recordings
}

struct StorageLocations: Codable, Equatable {
    var screenshotDirectory: URL?
    var recordingDirectory: URL?
    var recordingDirectories: [URL] = []

    static func validateDirectory(_ directory: URL) throws {
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw StorageLocationError.notDirectory(directory)
        }
        let manager = FileManager.default
        guard let stream = opendir(directory.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: directory.path])
        }
        guard closedir(stream) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: directory.path])
        }
        let probe = directory.appendingPathComponent(".Clipato-access-\(UUID().uuidString)")
        let bytes = Data([0x46, 0x56])
        let read: Data
        do {
            try bytes.write(to: probe, options: .withoutOverwriting)
            read = try Data(contentsOf: probe)
        }
        catch {
            if manager.fileExists(atPath: probe.path) { try manager.removeItem(at: probe) }
            throw error
        }
        try manager.removeItem(at: probe)
        guard read == bytes else { throw StorageLocationError.verificationFailed(directory) }
    }
}

enum StorageLocationError: LocalizedError {
    case notDirectory(URL)
    case verificationFailed(URL)
    case authorizationRequired(URL)
    case directoryMoved(URL, URL)
    case differentDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let directory): return L("保存位置不是文件夹：\(directory.path)")
        case .verificationFailed(let directory): return L("保存位置读写校验失败：\(directory.path)")
        case .authorizationRequired(let directory):
            return L("保存位置尚未授权，请重新选择此文件夹：\(directory.path)")
        case .directoryMoved(let directory, let resolved):
            return L("保存位置已移动，未自动更改原路径：\(directory.path)\n当前位置：\(resolved.path)")
        case .differentDirectory(let directory):
            return L("请选择原保存文件夹，以恢复访问：\(directory.path)")
        }
    }
}
