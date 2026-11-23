import Foundation
import XCTest
@testable import Clipato

final class AppUpdateCheckerTests: XCTestCase {
    func testRepositoryLinksPointToClipato() {
        XCTAssertEqual(AppUpdateChecker.repositoryURL.absoluteString, "https://github.com/ehehrun/clipato")
        XCTAssertEqual(AppUpdateChecker.releasesURL.absoluteString, "https://github.com/ehehrun/clipato/releases")
    }

    func testAppStoreRejectsExternalChecksBeforeSendingARequest() async throws {
        guard DistributionChannel.isAppStore else { throw XCTSkip("Run with -Xswiftc -DAPP_STORE for the store updater gate.") }
        let fixture = try makeSession(allowsAppStore: true) { _ in XCTFail("An App Store build must not contact GitHub.") }
        await assertCheckError(.appStoreUpdatesOnly, fixture: fixture)
        XCTAssertTrue(requests(for: fixture).isEmpty)
    }

    func testUnsortedTagsSelectTheHighestNumericStableVersion() async throws {
        let cases: [([String], String, String)] = [
            (["v1.9.10", "v1.9.9", "v1.10.0", "v1.2.99"], "1.9.9", "v1.10.0"),
            (["v1.2.9", "v1.2.10", "v1.2.8"], "1.2.9", "v1.2.10"),
            (["v2.0.0", "v1.99.99", "v0.99.99"], "1.99.99", "v2.0.0"),
        ]
        for (tags, installed, expected) in cases {
            let fixture = try makeSession(body: tagData(tags))
            let result = try await fixture.checker.check(currentVersion: installed)
            XCTAssertEqual(result?.name, expected)
        }
    }

    func testSameOrOlderTagsDoNotOfferAnUpdate() async throws {
        for installed in ["1.2.3", "1.2.4", "1.3.0", "2.0.0"] {
            let fixture = try makeSession(body: tagData(["v1.2.3", "v1.0.99"]))
            let result = try await fixture.checker.check(currentVersion: installed)
            XCTAssertNil(result, installed)
        }
    }

    func testNightlyPrereleaseAndUnrelatedTagsDoNotReplaceStableVersions() async throws {
        let fixture = try makeSession(body: tagData(["v99.0.0-nightly.9", "release-30.0.0", "v2.0.0-rc.1", "v1.2.4"]))
        let result = try await fixture.checker.check(currentVersion: "1.2.3")
        XCTAssertEqual(result?.name, "v1.2.4")
    }

    func testMalformedVersionNamesAreNotTreatedAsStableTags() async throws {
        let names = ["v01.0.0", "v1.0", "v1.0.0.1", "v1..0", "v1.0.-1", "v+1.0.0", "v1. 0.0",
                     "v١.0.0", "v9999999999999999999999999999.0.0", "1.9.0", "v1.0.1"]
        let fixture = try makeSession(body: tagData(names))
        let result = try await fixture.checker.check(currentVersion: "1.0.0")
        XCTAssertEqual(result?.name, "v1.0.1")
    }

    func testNoComparableStableTagIsAnErrorRatherThanUpToDate() async throws {
        for names in [[], ["v2.0.0-nightly.1", "test-tag"]] {
            let fixture = try makeSession(body: tagData(names))
            await assertCheckError(.noStableTags, fixture: fixture)
        }
    }

    func testPaginationComparesAllPagesAndKeepsRequestsOnTheFixedEndpoint() async throws {
        let first = try tagData(["v1.9.0", "v1.7.0"])
        let second = try tagData(["v1.10.0", "v1.8.0"])
        let fixture = try makeSession { connection in
            let query = URLComponents(url: connection.request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(URLQueryItem(name: "page", value: "2")) {
                connection.respond(status: 200, body: second,
                    headers: ["Link": "<https://api.github.com/repos/ehehrun/clipato/tags?per_page=100&page=1>; rel=\"prev\""])
            } else {
                connection.respond(status: 200, body: first,
                    headers: ["Link": "<https://api.github.com/repos/ehehrun/clipato/tags?per_page=100&page=2>; rel=\"next\""])
            }
        }
        let result = try await fixture.checker.check(currentVersion: "1.8.0")
        XCTAssertEqual(result?.name, "v1.10.0")
        XCTAssertEqual(requests(for: fixture).compactMap(\.url).map(\.absoluteString), [
            "https://api.github.com/repos/ehehrun/clipato/tags?per_page=100",
            "https://api.github.com/repos/ehehrun/clipato/tags?per_page=100&page=2",
        ])
    }

    func testFailureOnALaterPageDoesNotReturnAPartialResult() async throws {
        let first = try tagData(["v2.0.0"])
        let fixture = try makeSession { connection in
            if connection.request.url!.query!.contains("page=2") {
                connection.respond(status: 503, body: Data())
            } else {
                connection.respond(status: 200, body: first,
                    headers: ["Link": "<https://api.github.com/repos/ehehrun/clipato/tags?per_page=100&page=2>; rel=\"next\""])
            }
        }
        await assertCheckError(.httpStatus(503), fixture: fixture)
        XCTAssertEqual(requests(for: fixture).count, 2)
    }

    func testRequestUsesGitHubHeadersNoCredentialsAndABoundedTimeout() async throws {
        let body = try tagData(["v1.1.0"])
        let fixture = try makeSession { connection in
            let request = connection.request
            XCTAssertEqual(request.url, AppUpdateChecker.tagsURL)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Clipato")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            connection.respond(status: 200, body: body)
        }
        let result = try await fixture.checker.check(currentVersion: "1.0.0")
        XCTAssertEqual(result?.name, "v1.1.0")
    }

    func testProductionSessionDoesNotUseSharedCookiesCredentialsOrResponseCache() {
        let configuration = AppUpdateChecker.updateSession.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testEveryCheckRequestsGitHubRatherThanUsingTheOldDailyCache() async throws {
        let fixture = try makeSession(body: tagData(["v1.1.0"]))
        for _ in 0..<6 {
            let result = try await fixture.checker.check(currentVersion: "1.0.0")
            XCTAssertEqual(result?.name, "v1.1.0")
        }
        XCTAssertEqual(requests(for: fixture).count, 6)
    }

    func testHTTPAndRateLimitFailuresAreNotReportedAsNoUpdate() async throws {
        for status in [204, 301, 403, 404, 429, 500, 503] {
            let fixture = try makeSession(body: tagData(["v1.1.0"]), status: status)
            await assertCheckError(.httpStatus(status), fixture: fixture)
            XCTAssertEqual(requests(for: fixture).count, 1)
        }
    }

    func testMalformedJSONAndMissingOrWrongNameFieldsAreReported() async throws {
        for body in [Data("not JSON".utf8), Data("{}".utf8), Data("[{}]".utf8), Data("[{\"name\":3}]".utf8)] {
            let fixture = try makeSession(body: body)
            await assertCheckError(.invalidTags, fixture: fixture)
        }
    }

    func testUnexpectedResponseURLIsRejected() async throws {
        let body = try tagData(["v1.1.0"])
        let fixture = try makeSession { connection in
            connection.respond(status: 200, body: body, url: URL(string: "http://api.github.com/repos/ehehrun/clipato/tags")!)
        }
        await assertCheckError(.invalidResponse, fixture: fixture)
    }

    func testTransportFailureIsPreserved() async throws {
        let fixture = try makeSession { connection in
            connection.client!.urlProtocol(connection, didFailWithError: URLError(.notConnectedToInternet))
        }
        do {
            _ = try await fixture.checker.check(currentVersion: "1.0.0")
            XCTFail("The transport failure must reach the update UI.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testInvalidInstalledVersionDoesNotStartARequest() async throws {
        let fixture = try makeSession { _ in XCTFail("Invalid local metadata must not start a request.") }
        for version in ["invalid", "1.0", "01.0.0", "v1.0.0", "1.0.0-nightly.1"] {
            await assertCheckError(.invalidInstalledVersion, fixture: fixture, currentVersion: version)
        }
        XCTAssertTrue(requests(for: fixture).isEmpty)
    }

    func testCancellingBeforeTheRequestDoesNotContactGitHub() async throws {
        let fixture = try makeSession { _ in XCTFail("A cancelled check must not start a request.") }
        let task = Task {
            withUnsafeCurrentTask { $0!.cancel() }
            return try await fixture.checker.check(currentVersion: "1.0.0")
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled check must not complete.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertTrue(requests(for: fixture).isEmpty)
    }

    func testCancellingAnInFlightRequestPropagatesCancellation() async throws {
        let started = expectation(description: "The tag request started")
        let fixture = try makeSession { _ in started.fulfill() }
        let task = Task { try await fixture.checker.check(currentVersion: "1.0.0") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled check must not complete.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private func tagData(_ names: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: names.map {
            ["name": $0, "zipball_url": "https://api.github.com/repos/ehehrun/clipato/zipball/\($0)",
             "tarball_url": "https://api.github.com/repos/ehehrun/clipato/tarball/\($0)",
             "commit": ["sha": "1234567890abcdef", "url": "https://api.github.com/repos/ehehrun/clipato/commits/1234567890abcdef"],
             "node_id": "tag-node"] as [String: Any]
        })
    }

    private func makeSession(body: Data, status: Int = 200) throws -> UpdateFixture {
        try makeSession { $0.respond(status: status, body: body) }
    }

    private func makeSession(allowsAppStore: Bool = false, handler: @escaping (UpdateURLProtocol) -> Void) throws -> UpdateFixture {
        if DistributionChannel.isAppStore && !allowsAppStore { throw XCTSkip("External update checks are disabled in App Store builds.") }
        let id = UUID().uuidString
        UpdateURLProtocol.lock.lock()
        UpdateURLProtocol.handlers[id] = handler
        UpdateURLProtocol.requests[id] = []
        UpdateURLProtocol.lock.unlock()
        let configuration = AppUpdateChecker.updateSession.configuration
        configuration.protocolClasses = [UpdateURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Update-Test-ID": id]
        let session = URLSession(configuration: configuration)
        addTeardownBlock {
            session.invalidateAndCancel()
            UpdateURLProtocol.lock.lock()
            UpdateURLProtocol.handlers.removeValue(forKey: id)
            UpdateURLProtocol.requests.removeValue(forKey: id)
            UpdateURLProtocol.lock.unlock()
        }
        return (session, AppUpdateChecker(session: session), id)
    }

    private func requests(for fixture: UpdateFixture) -> [URLRequest] {
        UpdateURLProtocol.lock.lock()
        defer { UpdateURLProtocol.lock.unlock() }
        return UpdateURLProtocol.requests[fixture.id]!
    }

    private func assertCheckError(_ expected: AppUpdateError, fixture: UpdateFixture, currentVersion: String = "1.0.0",
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.checker.check(currentVersion: currentVersion)
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppUpdateError, expected, file: file, line: line)
        }
    }
}

private typealias UpdateFixture = (session: URLSession, checker: AppUpdateChecker, id: String)

private final class UpdateURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (UpdateURLProtocol) -> Void] = [:]
    static var requests: [String: [URLRequest]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Update-Test-ID")!
        Self.lock.lock()
        let handler = Self.handlers[id]!
        Self.requests[id]!.append(request)
        Self.lock.unlock()
        handler(self)
    }

    override func stopLoading() {}

    func respond(status: Int, body: Data, url: URL? = nil, headers: [String: String] = [:]) {
        var headers = headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: body)
        client!.urlProtocolDidFinishLoading(self)
    }
}
