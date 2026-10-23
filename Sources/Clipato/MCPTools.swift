import Foundation
import CoreFoundation

enum MCPError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        }
    }
}

struct MCPInput {
    let values: [String: Any]

    init(_ values: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MCPError.invalidArguments("Unknown arguments: \(unknown.sorted().joined(separator: ", "))")
        }
        self.values = values
    }

    func string(_ key: String, default defaultValue: String? = nil) throws -> String {
        if let value = try optionalString(key) { return value }
        if let defaultValue { return defaultValue }
        throw MCPError.invalidArguments("\(key) is required.")
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let value = value as? String else {
            throw MCPError.invalidArguments("\(key) must be a string.")
        }
        return value
    }

    func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = values[key] else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.decimalValue == Decimal(number.int64Value),
              range.contains(number.intValue) else {
            throw MCPError.invalidArguments("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound).")
        }
        return number.intValue
    }

    func double(_ key: String, default defaultValue: Double, range: ClosedRange<Double>) throws -> Double {
        guard let value = values[key] else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, range.contains(number.doubleValue) else {
            throw MCPError.invalidArguments("\(key) must be a number in \(range.lowerBound)...\(range.upperBound).")
        }
        return number.doubleValue
    }

    func bool(_ key: String, default defaultValue: Bool = false) throws -> Bool {
        guard let value = values[key] else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw MCPError.invalidArguments("\(key) must be a boolean.")
        }
        return number.boolValue
    }

    func strings(_ key: String, minimum: Int = 1, maximum: Int = 4_096) throws -> [String] {
        guard let values = values[key] as? [String], (minimum...maximum).contains(values.count) else {
            throw MCPError.invalidArguments("\(key) must contain \(minimum)...\(maximum) strings.")
        }
        return values
    }

    func paths(_ key: String = "files", minimum: Int = 1, maximum: Int = 4_096) throws -> [URL] {
        try strings(key, minimum: minimum, maximum: maximum).map(Self.fileURL)
    }

    func path(_ key: String) throws -> URL { try Self.fileURL(string(key)) }

    static func fileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw MCPError.invalidArguments("Use an absolute file path: \(path)")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func object(_ key: String) throws -> [String: Any]? {
        guard let value = values[key] else { return nil }
        guard let object = value as? [String: Any] else {
            throw MCPError.invalidArguments("\(key) must be an object.")
        }
        return object
    }
}

enum MCPTool {
    static func define(_ name: String, _ description: String, properties: [String: Any],
                       required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required,
                         "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
    }

    static func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
}

@MainActor
enum MCPTools {
    static let definitions = MCPAppTools.definitions + MCPImageTools.definitions

    static func call(name: String, arguments: [String: Any], library: URL) async throws -> [String: Any] {
        if MCPAppTools.definitions.contains(where: { $0["name"] as? String == name }) {
            return try await MCPAppTools.call(name: name, arguments: arguments, library: library)
        }
        return try await MCPImageTools.call(name: name, arguments: arguments, library: library)
    }
}
