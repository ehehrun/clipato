import Foundation
import CoreFoundation
import Darwin

/// Local MCP transport. Tool work is serialized while the input loop can still handle ping and cancellation.
@MainActor
final class MCPServer {
    static let supportedVersions = ["2026-07-28", "2025-11-25", "2025-06-18"]
    static let maximumMessageBytes = 1_048_576

    private enum LegacyState {
        case new, waiting, ready
    }

    private struct Operation {
        let id: Any
        let token: UUID
        let task: Task<Void, Never>
    }

    private let library: URL
    private let isEnabled: () -> Bool
    private let definitions: [[String: Any]]
    private let callTool: (String, [String: Any], URL) async throws -> [String: Any]
    private let accessLog: MCPAccessLog?
    private let caller: [String: Any]?
    private let sessionID = UUID()
    private var clientInfo: [String: String]?
    private var requestMethod = "transport"
    private var requestTool: String?
    private var legacyState = LegacyState.new
    private var operation: Operation?
    private var output: MCPOutput?
    private var outputError: Error?

    init(library: URL, isEnabled: @escaping () -> Bool = { MCPSettings.isServerEnabled },
         definitions: [[String: Any]]? = nil,
         callTool: ((String, [String: Any], URL) async throws -> [String: Any])? = nil,
         accessLog: MCPAccessLog? = nil) {
        self.library = library
        self.isEnabled = isEnabled
        self.definitions = definitions ?? MCPTools.definitions
        self.callTool = callTool ?? { try await MCPTools.call(name: $0, arguments: $1, library: $2) }
        self.accessLog = accessLog
        caller = accessLog == nil ? nil : AutomationCaller.current.jsonObject
    }

    func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async throws {
        guard isEnabled() else {
            try await log("denied", method: "connect", message: MCPServerError.mcpDisabled.localizedDescription)
            throw MCPServerError.mcpDisabled
        }
        try await log("connected", method: "connect")
        signal(SIGPIPE, SIG_IGN)
        self.output = MCPOutput(handle: output)
        let reader = try MCPInputReader(handle: input)
        defer { reader.cancel() }
        var line = Data()
        var oversized = false
        do {
            while let chunk = try await reader.read() {
                for byte in chunk {
                    try Task.checkCancellation()
                    if byte == 0x0A {
                        if oversized {
                            try await error(id: nil, code: -32700, message: "MCP message exceeds the 1 MiB limit")
                        } else {
                            try await receive(line)
                        }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                    } else if !oversized {
                        if line.count == Self.maximumMessageBytes {
                            line.removeAll(keepingCapacity: false)
                            oversized = true
                        } else {
                            line.append(byte)
                        }
                    }
                    if let outputError { throw outputError }
                }
            }
            await stopOperation()
            if oversized || !line.isEmpty {
                try await error(id: nil, code: -32700, message: "Incomplete MCP message at end of input")
            }
        } catch {
            await stopOperation()
            self.output = nil
            throw error
        }
        await stopOperation()
        self.output = nil
        if let outputError { throw outputError }
    }

    private func stopOperation() async {
        guard let operation else { return }
        operation.task.cancel()
        await operation.task.value
        self.operation = nil
    }

    private func receive(_ data: Data) async throws {
        requestMethod = "invalid"
        requestTool = nil
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch {
            try await self.error(id: nil, code: -32700, message: "Parse error")
            return
        }
        guard let request = value as? [String: Any] else {
            try await error(id: nil, code: -32600, message: "Invalid request")
            return
        }
        let id = request["id"]
        let requestMeta = (request["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let recognizedModern = requestMeta?["io.modelcontextprotocol/protocolVersion"] as? String == Self.supportedVersions[0]
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String,
              request["result"] == nil, request["error"] == nil else {
            try await error(id: id.flatMap { Self.validID($0) ? $0 : nil }, code: -32600,
                            message: "Invalid request", omitUnknownID: recognizedModern)
            return
        }
        if let id, !Self.validID(id) {
            try await error(id: nil, code: -32600, message: "Request ID must be a string or integer",
                            omitUnknownID: recognizedModern)
            return
        }
        requestMethod = method
        requestTool = method == "tools/call" ? (request["params"] as? [String: Any])?["name"] as? String : nil
        guard request["params"] == nil || request["params"] is [String: Any] else {
            if let id { try await error(id: id, code: -32602, message: "params must be an object") }
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        var requestClient = clientInfo
        let info = method == "initialize" ? params["clientInfo"] : requestMeta?["io.modelcontextprotocol/clientInfo"]
        if let info = info as? [String: Any], let name = info["name"] as? String, let version = info["version"] as? String {
            requestClient = ["name": name, "version": version]
        }
        if let accessLog {
            do {
                try await accessLog.append(.init(sessionID: sessionID, client: requestClient,
                                                 id: id.map { String(describing: $0) }, method: method,
                                                 tool: requestTool, status: "received", params: request["params"] as? [String: Any]))
            } catch MCPAccessLogError.oversizedEntry {
                let message = L("请求日志超过容量上限，参数未保存，操作未执行。请增大日志容量或缩小请求。")
                // Oversized protocol fields cannot be copied into the rejection record either.
                try await accessLog.append(.init(sessionID: sessionID, client: nil, id: nil,
                                                 method: "transport", tool: nil, status: "rejected", message: message))
                if let id {
                    try await send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": message]])
                }
                return
            }
        }
        clientInfo = requestClient
        guard let id else {
            if method == "notifications/initialized", legacyState == .waiting {
                legacyState = .ready
            } else if method == "notifications/cancelled", let requestID = params["requestId"],
                      let operation, Self.sameID(requestID, operation.id) {
                operation.task.cancel()
            }
            return
        }
        if let operation, Self.sameID(id, operation.id) {
            try await error(id: id, code: -32600, message: "Request ID is already in use")
            return
        }
        guard params["_meta"] == nil || params["_meta"] is [String: Any] else {
            try await error(id: id, code: -32602, message: "_meta must be an object")
            return
        }
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let hasModernMetadata = !Self.modernMetadataKeys.isDisjoint(with: meta.keys)
        if method == "initialize", !hasModernMetadata {
            try await initialize(id: id, params: params)
            return
        }
        let modern: Bool
        if hasModernMetadata {
            guard let version = meta["io.modelcontextprotocol/protocolVersion"] as? String else {
                try await error(id: id, code: -32602, message: "Missing or invalid protocol version in _meta")
                return
            }
            guard version == Self.supportedVersions[0] else {
                try await error(id: id, code: -32022, message: "Unsupported protocol version",
                                data: ["supported": Self.supportedVersions, "requested": version])
                return
            }
            guard meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
                try await error(id: id, code: -32602, message: "Missing client capabilities in _meta")
                return
            }
            if let info = meta["io.modelcontextprotocol/clientInfo"] {
                guard let info = info as? [String: Any], info["name"] is String, info["version"] is String else {
                    try await error(id: id, code: -32602, message: "clientInfo in _meta requires name and version")
                    return
                }
            }
            if let level = meta["io.modelcontextprotocol/logLevel"] {
                guard let level = level as? String,
                      ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"].contains(level) else {
                    try await error(id: id, code: -32602, message: "Invalid logLevel in _meta")
                    return
                }
            }
            modern = true
        } else if legacyState == .ready || method == "ping" && legacyState == .waiting {
            modern = false
        } else {
            try await error(id: id, code: -32602,
                            message: "Provide protocol version and client capabilities in _meta, or complete initialize")
            return
        }
        switch method {
        case "ping":
            try await result(id: id, value: [:], modern: modern)
        case "server/discover" where modern:
            try await result(id: id, value: ["supportedVersions": Self.supportedVersions,
                                            "capabilities": ["tools": [:]],
                                            "ttlMs": 0, "cacheScope": "private"], modern: true)
        case "tools/list":
            try AutomationAccess.check()
            guard isEnabled() else {
                try await error(id: id, code: -31000, message: MCPServerError.mcpDisabled.localizedDescription)
                return
            }
            if let cursor = params["cursor"], !(cursor is String) || (cursor as? String)?.isEmpty == false {
                try await error(id: id, code: -32602, message: "Invalid cursor")
                return
            }
            var value: [String: Any] = ["tools": definitions]
            if modern { value["ttlMs"] = 0; value["cacheScope"] = "private" }
            try await result(id: id, value: value, modern: modern)
        case "tools/call":
            try AutomationAccess.check()
            guard isEnabled() else {
                try await error(id: id, code: -31000, message: MCPServerError.mcpDisabled.localizedDescription)
                return
            }
            guard let name = params["name"] as? String,
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                try await error(id: id, code: -32602, message: "A tool name and object arguments are required")
                return
            }
            guard definitions.contains(where: { $0["name"] as? String == name }) else {
                try await error(id: id, code: -32602, message: "Unknown tool")
                return
            }
            guard operation == nil else {
                try await error(id: id, code: -31001, message: "Another tool is running; wait for it or cancel it first")
                return
            }
            startTool(id: id, name: name, arguments: params["arguments"] as? [String: Any] ?? [:], modern: modern)
        default:
            try await error(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initialize(id: Any, params: [String: Any]) async throws {
        guard legacyState == .new else {
            try await error(id: id, code: -32600, message: "Already initialized")
            return
        }
        guard let version = params["protocolVersion"] as? String,
              params["capabilities"] is [String: Any], let info = params["clientInfo"] as? [String: Any],
              info["name"] is String, info["version"] is String else {
            try await error(id: id, code: -32602, message: "initialize requires protocolVersion, capabilities and clientInfo")
            return
        }
        let selectedVersion = Self.supportedVersions.dropFirst().contains(version) ? version : "2025-11-25"
        legacyState = .waiting
        try await result(id: id, value: ["protocolVersion": selectedVersion,
                                        "capabilities": ["tools": [:]],
                                        "serverInfo": Self.serverInfo], modern: false)
    }

    private func startTool(id: Any, name: String, arguments: [String: Any], modern: Bool) {
        let token = UUID()
        let client = clientInfo
        let task = Task {
            let started = ContinuousClock.now
            let assets = name == "vault_trash" ? arguments["assets"] as? [String] : nil
            var completed = false
            do {
                try await log("started", method: "tools/call", id: id, tool: name, client: client, assets: assets)
                try AutomationAccess.check()
                guard isEnabled() else { throw MCPServerError.mcpDisabled }
                let value = try await callTool(name, arguments, library)
                completed = true
                let json = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                var content = [["type": "text", "text": String(decoding: json, as: UTF8.self)]]
                do {
                    try await log("completed", method: "tools/call", id: id, tool: name, client: client,
                                  duration: started.duration(to: .now), assets: assets)
                } catch {
                    content.append(["type": "text", "text": "Operation completed, but the access log could not be written: \(error.localizedDescription). Do not repeat the operation solely to repair the log."])
                }
                if !Task.isCancelled {
                    try AutomationAccess.check()
                    try await result(id: id, value: ["content": content,
                                                    "structuredContent": value, "isError": false], modern: modern)
                }
            } catch {
                var message = error.localizedDescription
                let status: String
                if completed { status = "delivery_failed" }
                else if Task.isCancelled { status = "cancelled" }
                else if error is MCPTrashAuthorizationError || error is MCPServerError { status = "denied" }
                else { status = "failed" }
                do {
                    try await log(status, method: "tools/call", id: id, tool: name, client: client,
                                  duration: started.duration(to: .now), assets: assets, message: message)
                } catch { message += "\nAccess log write failed: \(error.localizedDescription)" }
                if !Task.isCancelled {
                    do {
                        try await result(id: id, value: ["content": [["type": "text", "text": message]],
                                                        "isError": true], modern: modern)
                    } catch { outputError = error }
                }
            }
            if operation?.token == token { operation = nil }
        }
        operation = Operation(id: id, token: token, task: task)
    }

    private func log(_ status: String, method: String, id: Any? = nil, tool: String? = nil,
                     client: [String: String]? = nil, duration: Duration? = nil,
                     assets: [String]? = nil, message: String? = nil, params: [String: Any]? = nil) async throws {
        guard let accessLog else { return }
        let durationMs = duration.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
        try await accessLog.append(.init(sessionID: sessionID, client: client ?? clientInfo,
                                        id: id.map { String(describing: $0) }, method: method, tool: tool,
                                        status: status, durationMs: durationMs, assets: assets, message: message, params: params,
                                        transport: "mcp", caller: caller))
    }

    private static let serverInfo: [String: Any] = ["name": "Clipato", "version": AppVersion.number]
    private static let modernMetadataKeys: Set<String> = ["io.modelcontextprotocol/protocolVersion",
                                                        "io.modelcontextprotocol/clientCapabilities",
                                                        "io.modelcontextprotocol/clientInfo",
                                                        "io.modelcontextprotocol/logLevel"]

    private func result(id: Any, value: [String: Any], modern: Bool) async throws {
        var value = value
        if modern {
            value["resultType"] = "complete"
            value["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo]
        }
        try await send(["jsonrpc": "2.0", "id": id, "result": value])
    }

    private func error(id: Any?, code: Int, message: String, data: [String: Any]? = nil, omitUnknownID: Bool = false) async throws {
        try await log("rejected", method: requestMethod, id: id, tool: requestTool, message: message)
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        var response: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { response["id"] = id }
        else if !omitUnknownID { response["id"] = NSNull() }
        try await send(response)
    }

    private func send(_ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])
        try await output!.write(data + Data([0x0A]))
    }

    private static func validID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }

    private static func sameID(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhs = lhs as? String, let rhs = rhs as? String { return lhs == rhs }
        guard let lhs = lhs as? NSNumber, let rhs = rhs as? NSNumber,
              CFGetTypeID(lhs) != CFBooleanGetTypeID(), CFGetTypeID(rhs) != CFBooleanGetTypeID() else { return false }
        return lhs == rhs
    }
}

/// A read source avoids Foundation AsyncBytes serializing blocked reads from independent pipes.
/// All mutable state is confined to the source's serial queue.
private final class MCPInputReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.freddon.clipato.mcp.input")
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private var pending: CheckedContinuation<Data?, Error>?
    private var listening = false
    private var ended = false

    init(handle: FileHandle) throws {
        descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        let descriptor = self.descriptor
        source.setCancelHandler { Darwin.close(descriptor) }
    }

    func read() async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.ended else { continuation.resume(throwing: CancellationError()); return }
                    self.pending = continuation
                    self.listening = true
                    self.source.resume()
                }
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

    private func receive() {
        guard !ended else { return }
        source.suspend()
        listening = false
        var data = Data(count: 65_536)
        let count = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
            data.count = count
            let continuation = pending!
            pending = nil
            continuation.resume(returning: data)
        } else if count == 0 {
            finish(.success(nil))
        } else if errno == EINTR {
            listening = true
            source.resume()
        } else {
            finish(.failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno))))
        }
    }

    private func finish(_ result: Result<Data?, Error>) {
        guard !ended else { return }
        ended = true
        pending?.resume(with: result)
        pending = nil
        if !listening { source.resume() }
        source.cancel()
    }
}

private actor MCPOutput {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws {
        try Task.checkCancellation()
        try handle.write(contentsOf: data)
    }
}

enum MCPServerError: LocalizedError {
    case disabled, mcpDisabled
    var errorDescription: String? {
        switch self {
        case .disabled:
            return L("外部调用未授权或已被撤销。请关闭隐私模式，并在 Clipato「AI 终端 → 自动化接入」中开启「允许外部自动化调用」。")
        case .mcpDisabled:
            return L("MCP 服务未启用或授权已被撤销。请在 Clipato「AI 终端」中先允许外部自动化调用，再开启「启用 MCP 服务」；已有客户端需重新连接。")
        }
    }
}
