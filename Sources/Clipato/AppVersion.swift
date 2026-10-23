import Foundation

enum AppVersion {
    static let number = metadata.CFBundleShortVersionString
    static let build = metadata.CFBundleVersion
    static let buildNumber = Int(build)!
    static var displayName: String { "Clipato \(number) (\(build))" }

    private struct Metadata: Decodable {
        let CFBundleShortVersionString: String
        let CFBundleVersion: String
    }

    private static let metadata: Metadata = {
        let url = LanguageSettings.resourceBundle.url(forResource: "Version", withExtension: "plist")!
        return try! PropertyListDecoder().decode(Metadata.self, from: Data(contentsOf: url))
    }()
}
