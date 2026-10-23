import Foundation

struct BatchRenameRule: Equatable {
    var prefix = "Frame_"
    var start = 1
    var increment = 1
    var digits = 3

    static func supports(_ assets: [CollectionAsset]) -> Bool {
        guard assets.count >= 2, Set(assets).count == assets.count else { return false }
        return assets.allSatisfy { if case .image = $0 { return true }; return false }
            || assets.allSatisfy { if case .video = $0 { return true }; return false }
    }

    func filenames(for urls: [URL]) throws -> [String] {
        guard start >= 0, increment > 0, (0...19).contains(digits) else { throw BatchRenameError.invalidNumbering }
        guard !prefix.contains("/"), !prefix.contains(":"), prefix.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BatchRenameError.invalidPrefix
        }
        var number = start
        var filenames: [String] = []
        filenames.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            let value = String(number)
            let stem = prefix + String(repeating: "0", count: max(0, digits - value.count)) + value
            let filename = url.pathExtension.isEmpty ? stem : stem + "." + url.pathExtension
            guard filename.utf8.count <= 255 else { throw BatchRenameError.nameTooLong(filename) }
            filenames.append(filename)
            if index < urls.count - 1 {
                let next = number.addingReportingOverflow(increment)
                guard !next.overflow else { throw BatchRenameError.numberOverflow }
                number = next.partialValue
            }
        }
        return filenames
    }
}

enum BatchRenameError: LocalizedError {
    case unsupportedSelection
    case invalidPrefix
    case invalidNumbering
    case numberOverflow
    case nameTooLong(String)
    case existingFile(URL)
    case multipleVideos(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection: return L("请至少选择两张图片或两个完整视频，不能混合类型或包含关键帧录屏。")
        case .invalidPrefix: return L("前缀不能包含 /、: 或控制字符。")
        case .invalidNumbering: return L("起始数字不能小于 0，步长必须大于 0，补零位数应为 0 到 19。")
        case .numberOverflow: return L("编号超出整数范围，请减小起始数字或步长。")
        case .nameTooLong(let filename): return L("文件名过长：\(filename)")
        case .existingFile(let url): return L("目标文件已存在，未改动任何文件：\(url.path)")
        case .multipleVideos(let directory): return L("录屏目录包含多个 MP4 文件，无法确定原视频：\(directory.path)")
        }
    }
}
