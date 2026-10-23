import Foundation

struct UpdateRelease: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let downloadURL: URL
    let releaseNotes: String
}

actor AppUpdateChecker {
    static let shared = AppUpdateChecker()
    static let updateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    private let defaults: UserDefaults
    private let session: URLSession
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private static let requestDayKey = "updateCheck.requestDay"
    private static let requestCountKey = "updateCheck.requestCount"
    private static let cachedResultKey = "updateCheck.cachedResult"

    private struct CachedResult: Codable {
        let release: UpdateRelease
        let source: URL
        let checkedAt: Date
    }

    init(defaults: UserDefaults = .standard, session: URLSession = AppUpdateChecker.updateSession,
         calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.session = session
        self.calendar = calendar
        self.now = now
    }

    static func configuredURLs() throws -> [URL] {
        guard let url = LanguageSettings.resourceBundle.url(forResource: "UpdateSources", withExtension: "plist") else {
            throw AppUpdateError.invalidConfiguration
        }
        let addresses = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: url))
        return try addresses.map { address in
            guard let url = URL(string: address), isHTTPSURL(url) else {
                throw AppUpdateError.invalidManifestURL
            }
            return url
        }
    }

    func check(at urls: [URL], currentVersion: String = AppVersion.number,
               currentBuild: Int = AppVersion.buildNumber) async throws -> (release: UpdateRelease?, source: URL, cachedAt: Date?) {
        guard !DistributionChannel.isAppStore else { throw AppUpdateError.appStoreUpdatesOnly }
        guard !urls.isEmpty else { throw AppUpdateError.noManifestURLs }
        guard urls.allSatisfy(Self.isHTTPSURL) else { throw AppUpdateError.invalidManifestURL }
        guard let installed = Self.versionComponents(currentVersion), currentBuild >= 1 else {
            throw AppUpdateError.invalidInstalledVersion
        }
        var failures: [String] = []
        for url in urls {
            try Task.checkCancellation()
            do {
                return try await checkSource(at: url, installed: installed, currentBuild: currentBuild)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if error as? AppUpdateError == .dailyLimitReached || error as? AppUpdateError == .invalidCachedResult { throw error }
                failures.append("\(url.absoluteString)\n\(error.localizedDescription)")
            }
        }
        throw AppUpdateError.allSourcesFailed(failures)
    }

    func check(at url: URL, currentVersion: String = AppVersion.number,
               currentBuild: Int = AppVersion.buildNumber) async throws -> UpdateRelease? {
        guard !DistributionChannel.isAppStore else { throw AppUpdateError.appStoreUpdatesOnly }
        guard Self.isHTTPSURL(url) else { throw AppUpdateError.invalidManifestURL }
        guard let installed = Self.versionComponents(currentVersion), currentBuild >= 1 else {
            throw AppUpdateError.invalidInstalledVersion
        }
        return try await checkSource(at: url, installed: installed, currentBuild: currentBuild).release
    }

    private func checkSource(at url: URL, installed: [Int], currentBuild: Int) async throws
        -> (release: UpdateRelease?, source: URL, cachedAt: Date?) {
        try Task.checkCancellation()
        let release: UpdateRelease
        do {
            release = try await fetch(at: url)
        } catch AppUpdateError.dailyLimitReached {
            return try cachedResult(installed: installed, currentBuild: currentBuild)
        }
        try Task.checkCancellation()
        let newer = try Self.newerRelease(release, than: installed, currentBuild: currentBuild)
        let cached = CachedResult(release: release, source: url, checkedAt: now())
        defaults.set(try JSONEncoder().encode(cached), forKey: Self.cachedResultKey)
        return (newer, url, nil)
    }

    private func reserveRequest() -> Bool {
        let day = calendar.startOfDay(for: now())
        let count = defaults.object(forKey: Self.requestDayKey) as? Date == day
            ? defaults.integer(forKey: Self.requestCountKey) : 0
        guard count < 5 else { return false }
        // Reserve before suspension so concurrent checks and retries share the same daily budget.
        defaults.set(day, forKey: Self.requestDayKey)
        defaults.set(count + 1, forKey: Self.requestCountKey)
        return true
    }

    private func cachedResult(installed: [Int], currentBuild: Int) throws
        -> (release: UpdateRelease?, source: URL, cachedAt: Date?) {
        guard let data = defaults.data(forKey: Self.cachedResultKey) else { throw AppUpdateError.dailyLimitReached }
        do {
            let cached = try JSONDecoder().decode(CachedResult.self, from: data)
            let newer = try Self.newerRelease(cached.release, than: installed, currentBuild: currentBuild)
            return (newer, cached.source, cached.checkedAt)
        }
        catch { throw AppUpdateError.invalidCachedResult }
    }

    private func fetch(at url: URL) async throws -> UpdateRelease {
        var address = url
        while true {
            try Task.checkCancellation()
            guard reserveRequest() else { throw AppUpdateError.dailyLimitReached }
            var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request, delegate: RedirectDelegate())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  let responseURL = response.url, Self.isHTTPSURL(responseURL) else {
                throw AppUpdateError.invalidResponse
            }
            switch response.statusCode {
            case 301, 302, 303, 307, 308:
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let target = URL(string: location, relativeTo: responseURL)?.absoluteURL,
                      Self.isHTTPSURL(target) else { throw AppUpdateError.httpStatus(response.statusCode) }
                address = target
            case 200:
                do { return try JSONDecoder().decode(UpdateRelease.self, from: data) }
                catch is DecodingError { throw AppUpdateError.invalidManifest }
            default:
                throw AppUpdateError.httpStatus(response.statusCode)
            }
        }
    }

    private static func newerRelease(_ release: UpdateRelease, than installed: [Int], currentBuild: Int) throws -> UpdateRelease? {
        guard let available = versionComponents(release.version) else { throw AppUpdateError.invalidReleaseVersion }
        guard release.build >= 1 else { throw AppUpdateError.invalidReleaseBuild }
        guard isHTTPSURL(release.downloadURL) else { throw AppUpdateError.invalidDownloadURL }
        let newer = installed.lexicographicallyPrecedes(available)
            || (installed == available && currentBuild < release.build)
        return newer ? release : nil
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

    private static func isHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // Redirects are sent explicitly so every HTTP request consumes the same daily budget.
            completionHandler(nil)
        }
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case appStoreUpdatesOnly
    case noManifestURLs
    case invalidConfiguration
    case invalidManifestURL
    case allSourcesFailed([String])
    case invalidInstalledVersion
    case invalidResponse
    case httpStatus(Int)
    case invalidManifest
    case invalidReleaseVersion
    case invalidReleaseBuild
    case invalidDownloadURL
    case dailyLimitReached
    case invalidCachedResult

    var errorDescription: String? {
        switch self {
        case .appStoreUpdatesOnly: return L("此版本通过 App Store 更新，请在 App Store 中检查更新。")
        case .noManifestURLs: return L("此版本暂未配置更新服务。")
        case .invalidConfiguration: return L("应用内的更新服务配置无效。")
        case .invalidManifestURL: return L("更新配置地址必须是有效的 HTTPS 地址，且不能包含账号或密码。")
        case .allSourcesFailed(let failures):
            return L("所有更新地址均检查失败：") + "\n" + failures.joined(separator: "\n\n")
        case .invalidInstalledVersion: return L("当前应用的版本号或构建号无效。")
        case .invalidResponse: return L("更新服务器返回了无效的 HTTPS 响应。")
        case .httpStatus(let status): return L("更新服务器返回 HTTP \(status)。")
        case .invalidManifest: return L("更新配置不是有效的 JSON，或缺少必要字段。")
        case .invalidReleaseVersion: return L("更新版本号须为 major.minor.patch 格式，例如 1.0.0。")
        case .invalidReleaseBuild: return L("更新构建号必须是大于 0 的整数。")
        case .invalidDownloadURL: return L("更新下载地址必须是有效的 HTTPS 地址，且不能包含账号或密码。")
        case .dailyLimitReached: return L("今日更新请求已达 5 次，暂无成功缓存，请明天再试。")
        case .invalidCachedResult: return L("上次成功的更新检查结果无法读取。")
        }
    }
}
