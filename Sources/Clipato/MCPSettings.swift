import Foundation

enum MCPSettings {
    static let enabledKey = "mcpEnabled"
    static let allowTrashKey = "mcpAllowTrash"
    static let generationKey = "mcpAuthorizationGeneration"
    static let serverEnabledKey = "mcpServerEnabled"
    static let serverGenerationKey = "mcpServerAuthorizationGeneration"
    static let authorizationDidChange = Notification.Name("dev.freddon.clipato.automation-authorization-changed")

    static var isEnabled: Bool { isEnabled(in: .standard) }
    static var isServerEnabled: Bool { isServerEnabled(in: .standard) }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard !DistributionChannel.isAppStore else { return false }
        // External processes read the GUI's latest choice before accepting another operation.
        defaults.synchronize()
        return defaults.bool(forKey: enabledKey) && !defaults.bool(forKey: "privacyMode")
    }

    static func isServerEnabled(in defaults: UserDefaults) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: serverEnabledKey)
    }

    static func allowsTrash(in defaults: UserDefaults = .standard) -> Bool {
        isEnabled(in: defaults) && defaults.bool(forKey: allowTrashKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        guard !DistributionChannel.isAppStore else { return }
        let enabled = enabled && !defaults.bool(forKey: "privacyMode")
        // Revocation survives a rapid off/on toggle; an old process must acquire a new authorization.
        if !enabled {
            defaults.set(UUID().uuidString, forKey: generationKey)
            defaults.set(false, forKey: serverEnabledKey)
            defaults.set(UUID().uuidString, forKey: serverGenerationKey)
        }
        defaults.set(enabled, forKey: enabledKey)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(authorizationDidChange, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }

    static func setServerEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        guard !DistributionChannel.isAppStore else { return }
        let enabled = enabled && isEnabled(in: defaults)
        if !enabled { defaults.set(UUID().uuidString, forKey: serverGenerationKey) }
        defaults.set(enabled, forKey: serverEnabledKey)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(authorizationDidChange, object: nil,
                                                                      userInfo: nil, deliverImmediately: true)
    }

    static func configuration(executable: URL) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["clipato": ["command": executable.path, "args": ["mcp"]]]
        ], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
