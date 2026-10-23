import Foundation

enum CaptureNamingKind: String, CaseIterable {
    case screenshot, recording

    var templateKey: String { "captureNaming.\(rawValue).template" }
    fileprivate var counterKey: String { "captureNaming.\(rawValue).index" }
    var defaultTemplate: String {
        switch self {
        case .screenshot: return "截图 {date} {time}_{index}"
        case .recording: return "录屏 {date} {time}_{index}"
        }
    }
}

struct CaptureNamingRule: Equatable {
    let template: String

    private enum Part {
        case literal(String), date, time, index(Int)
    }

    private func parts() throws -> [Part] {
        var result: [Part] = []
        var literal = ""
        var position = template.startIndex
        while position < template.endIndex {
            let character = template[position]
            if character == "{" {
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                guard let end = template[position...].firstIndex(of: "}") else { throw CaptureNamingError.invalidTemplate }
                let token = String(template[template.index(after: position)..<end])
                switch token {
                case "date": result.append(.date)
                case "time": result.append(.time)
                case "index": result.append(.index(3))
                default:
                    guard token.hasPrefix("index:"), let digits = Int(token.dropFirst(6)),
                          (1...12).contains(digits), String(digits) == token.dropFirst(6) else {
                        throw CaptureNamingError.invalidTemplate
                    }
                    result.append(.index(digits))
                }
                position = template.index(after: end)
            } else {
                guard character != "}" else { throw CaptureNamingError.invalidTemplate }
                literal.append(character)
                position = template.index(after: position)
            }
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }

    fileprivate var usesIndex: Bool {
        get throws { try parts().contains { if case .index = $0 { return true }; return false } }
    }

    func filename(extension fileExtension: String, date: Date = Date(), index: Int, timeZone: TimeZone = .current) throws -> String {
        guard index > 0 else { throw CaptureNamingError.invalidIndex }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        var stem = ""
        for part in try parts() {
            switch part {
            case .literal(let value): stem += value
            case .date:
                formatter.dateFormat = "yyyy-MM-dd"
                stem += formatter.string(from: date)
            case .time:
                formatter.dateFormat = "HH.mm.ss"
                stem += formatter.string(from: date)
            case .index(let digits):
                let number = String(index)
                stem += String(repeating: "0", count: max(0, digits - number.count)) + number
            }
        }
        let filename = stem + "." + fileExtension
        guard !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !stem.hasPrefix("."),
              !fileExtension.isEmpty, !fileExtension.contains("."),
              !filename.contains("/"), !filename.contains(":"),
              filename.rangeOfCharacter(from: .controlCharacters) == nil,
              filename.utf8.count <= 255 else { throw CaptureNamingError.invalidFilename }
        return filename
    }
}

// GUI captures reserve numbers on the main actor; CLI/MCP keep their explicit output names.
@MainActor
struct CaptureFileNaming {
    static func rule(for kind: CaptureNamingKind, defaults: UserDefaults = .standard) throws -> CaptureNamingRule {
        guard let stored = defaults.object(forKey: kind.templateKey) else {
            return CaptureNamingRule(template: kind.defaultTemplate)
        }
        guard let template = stored as? String else { throw CaptureNamingError.invalidSettings }
        return CaptureNamingRule(template: template)
    }

    static func nextIndex(for kind: CaptureNamingKind, defaults: UserDefaults = .standard) throws -> Int {
        guard let stored = defaults.object(forKey: kind.counterKey) else { return 1 }
        guard let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let index = stored as? Int, index >= 0 else { throw CaptureNamingError.invalidSettings }
        let next = index.addingReportingOverflow(1)
        guard !next.overflow else { throw CaptureNamingError.invalidIndex }
        return next.partialValue
    }

    static func save(screenshot: String, recording: String, defaults: UserDefaults = .standard) throws {
        _ = try CaptureNamingRule(template: screenshot).filename(extension: "png", index: 1)
        _ = try CaptureNamingRule(template: recording).filename(extension: "mp4", index: 1)
        defaults.set(screenshot, forKey: CaptureNamingKind.screenshot.templateKey)
        defaults.set(recording, forKey: CaptureNamingKind.recording.templateKey)
    }

    static func nextFilename(for kind: CaptureNamingKind, extension fileExtension: String,
                             date: Date = Date(), defaults: UserDefaults = .standard) throws -> String {
        let rule = try rule(for: kind, defaults: defaults)
        let usesIndex = try rule.usesIndex
        let index = usesIndex ? try nextIndex(for: kind, defaults: defaults) : 1
        let filename = try rule.filename(extension: fileExtension, date: date, index: index)
        // Reservations survive failures/cancellation; reusing a number could duplicate an exported name.
        if usesIndex { defaults.set(index, forKey: kind.counterKey) }
        return filename
    }
}

enum CaptureNamingError: LocalizedError {
    case invalidTemplate, invalidFilename, invalidIndex, invalidSettings

    var errorDescription: String? {
        switch self {
        case .invalidTemplate: return L("命名规则仅支持 {date}、{time}、{index} 或 {index:1} 至 {index:12}。")
        case .invalidFilename: return L("文件名不能为空、以点开头，或包含 /、:、控制字符；含扩展名最长 255 字节。")
        case .invalidIndex: return L("自动命名编号超出有效范围。")
        case .invalidSettings: return L("自动命名设置损坏，请检查本地设置。")
        }
    }
}
