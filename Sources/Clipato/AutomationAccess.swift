import Foundation

final class AutomationAccess: @unchecked Sendable {
    @TaskLocal static var current: AutomationAccess?

    private let defaults: UserDefaults
    private let generation: String?
    private let requiresMCP: Bool
    private let mcpGeneration: String?
    private static let notificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.freddon.clipato.automation-authorization"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.synchronize()
        generation = defaults.string(forKey: MCPSettings.generationKey)
        requiresMCP = false
        mcpGeneration = nil
    }

    init(mcpFrom access: AutomationAccess) {
        defaults = access.defaults
        generation = access.generation
        requiresMCP = true
        defaults.synchronize()
        mcpGeneration = defaults.string(forKey: MCPSettings.serverGenerationKey)
    }

    private var hasBaseAuthorization: Bool {
        MCPSettings.isEnabled(in: defaults) && defaults.string(forKey: MCPSettings.generationKey) == generation
    }

    var isAllowed: Bool {
        hasBaseAuthorization && (!requiresMCP || (defaults.bool(forKey: MCPSettings.serverEnabledKey)
                && defaults.string(forKey: MCPSettings.serverGenerationKey) == mcpGeneration))
    }

    var denial: MCPServerError { requiresMCP && hasBaseAuthorization ? .mcpDisabled : .disabled }

    static func check() throws {
        if let current, !current.isAllowed { throw current.denial }
        try Task.checkCancellation()
    }

    static func detached<Success: Sendable>(priority: TaskPriority? = nil,
                                           operation: @escaping @Sendable () async throws -> Success) -> Task<Success, Error> {
        let access = current
        return Task.detached(priority: priority) {
            try await $current.withValue(access) { try await operation() }
        }
    }

    func observeRevocation(_ cancel: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: MCPSettings.authorizationDidChange,
                                                             object: nil, queue: Self.notificationQueue) { [self] _ in
            if !isAllowed { cancel() }
        }
    }
}
