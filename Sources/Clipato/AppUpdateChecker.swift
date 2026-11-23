import Foundation

struct UpdateRelease: Decodable, Equatable, Sendable {
    let name: String
}

actor AppUpdateChecker {
    static let shared = AppUpdateChecker()
    static let repositoryURL = URL(string: "https://github.com/ehehrun/clipato")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let tagsURL = URL(string: "https://api.github.com/repos/ehehrun/clipato/tags?per_page=100")!
    static let updateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private let session: URLSession

    init(session: URLSession = AppUpdateChecker.updateSession) {
        self.session = session
    }

    func check(currentVersion: String = AppVersion.number) async throws -> UpdateRelease? {
        guard !DistributionChannel.isAppStore else { throw AppUpdateError.appStoreUpdatesOnly }
        try Task.checkCancellation()
        guard let installed = Self.versionComponents(currentVersion) else {
            throw AppUpdateError.invalidInstalledVersion
        }
        var latest: (release: UpdateRelease, components: [Int])?
        var page = 1
        while true {
            try Task.checkCancellation()
            let url = page == 1 ? Self.tagsURL
                : Self.tagsURL.appending(queryItems: [URLQueryItem(name: "page", value: String(page))])
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpShouldHandleCookies = false
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Clipato", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request, delegate: RedirectDelegate())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == url else {
                throw AppUpdateError.invalidResponse
            }
            guard response.statusCode == 200 else { throw AppUpdateError.httpStatus(response.statusCode) }
            let tags: [UpdateRelease]
            do { tags = try JSONDecoder().decode([UpdateRelease].self, from: data) }
            catch is DecodingError { throw AppUpdateError.invalidTags }
            for tag in tags {
                guard tag.name.hasPrefix("v"), let available = Self.versionComponents(String(tag.name.dropFirst())) else { continue }
                if let latest, !latest.components.lexicographicallyPrecedes(available) { continue }
                latest = (tag, available)
            }
            guard let link = response.value(forHTTPHeaderField: "Link"),
                  link.split(separator: ",").contains(where: { $0.contains("rel=\"next\"") }) else { break }
            page += 1
        }
        guard let latest else { throw AppUpdateError.noStableTags }
        return installed.lexicographicallyPrecedes(latest.components) ? latest.release : nil
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            components.append(number)
        }
        return components
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case appStoreUpdatesOnly
    case invalidInstalledVersion
    case invalidResponse
    case httpStatus(Int)
    case invalidTags
    case noStableTags

    var errorDescription: String? {
        switch self {
        case .appStoreUpdatesOnly: return L("此版本通过 App Store 更新，请在 App Store 中检查更新。")
        case .invalidInstalledVersion: return L("当前应用的版本号无效。")
        case .invalidResponse: return L("GitHub 返回了无效的更新响应。")
        case .httpStatus(let status): return L("GitHub 返回 HTTP \(status)，请前往仓库手动检查更新。")
        case .invalidTags: return L("GitHub 标签数据无效。")
        case .noStableTags: return L("GitHub 仓库中没有可比较的正式版本标签。")
        }
    }
}
