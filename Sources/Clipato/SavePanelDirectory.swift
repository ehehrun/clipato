import Foundation

enum SavePanelDirectory {
    private static let key = "savePanel.lastDirectory"

    static func lastDirectory(defaults: UserDefaults = .standard) -> URL? {
        defaults.url(forKey: key)
    }

    static func rememberFile(_ url: URL, defaults: UserDefaults = .standard) {
        rememberDirectory(url.deletingLastPathComponent(), defaults: defaults)
    }

    static func rememberDirectory(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url, forKey: key)
    }
}
