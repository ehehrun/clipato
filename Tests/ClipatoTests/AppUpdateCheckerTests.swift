import Foundation
import XCTest
@testable import Clipato

final class AppUpdateCheckerTests: XCTestCase {
    func testAppStoreRejectsExternalChecksBeforeNetworkOrLocalUpdateStateChanges() async throws {
        guard DistributionChannel.isAppStore else { throw XCTSkip("Run with -Xswiftc -DAPP_STORE for the store updater gate.") }
        let fixture = makeSession { _ in XCTFail("An App Store build must not contact external update servers.") }
        do {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
            XCTFail("The external updater must be disabled in an App Store build.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .appStoreUpdatesOnly)
        }
        do {
            _ = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
            XCTFail("The mirror-list entry point must also be disabled.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .appStoreUpdatesOnly)
        }
        XCTAssertTrue(requestedURLs(for: fixture.url).isEmpty)
        for key in ["updateCheck.requestDay", "updateCheck.requestCount", "updateCheck.cachedResult"] {
            XCTAssertNil(fixture.defaults.object(forKey: key))
        }
    }

    func testVersionComparisonUsesNumericComponentsBeforeBuildNumber() async throws {
        for (version, build, newer) in [("2.0.0", 1, true), ("1.10.0", 1, true),
                                        ("1.9.10", 1, true), ("1.9.8", 999, false),
                                        ("1.8.99", 999, false), ("0.99.99", 999, false)] {
            let fixture = makeSession(body: try manifest(["version": version, "build": build]))
            let result = try await fixture.checker.check(at: fixture.url, currentVersion: "1.9.9",
                                                         currentBuild: 10)
            XCTAssertEqual(result?.version, newer ? version : nil)
            if newer {
                XCTAssertEqual(result?.build, build)
                XCTAssertEqual(result?.downloadURL.absoluteString, "https://downloads.example/Clipato.zip")
                XCTAssertEqual(result?.releaseNotes, "修复问题。\nImproved capture.")
            }
        }
    }

    func testBuildNumberBreaksTiesOnlyForTheSameVersion() async throws {
        for build in [9, 10, 11] {
            let fixture = makeSession(body: try manifest(["version": "1.0.0", "build": build]))
            let result = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0",
                                                         currentBuild: 10)
            XCTAssertEqual(result?.build, build > 10 ? build : nil)
        }
    }

    func testRequestSkipsCachedManifestsAndHasABoundedTimeout() async throws {
        let body = try manifest()
        let fixture = makeSession { connection in
            XCTAssertEqual(connection.request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(connection.request.timeoutInterval, 15)
            XCTAssertEqual(connection.request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(connection.request.httpShouldHandleCookies)
            connection.respond(status: 200, body: body)
        }
        let release = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0",
                                                      currentBuild: 1)
        XCTAssertEqual(release?.version, "1.1.0")
    }

    func testProductionSessionDoesNotUseSharedCookiesCredentialsOrResponseCache() {
        let configuration = AppUpdateChecker.updateSession.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testManifestCookiesAreNotSentOnLaterRequests() async throws {
        let body = try manifest()
        let fixture = makeSession { connection in
            XCTAssertNil(connection.request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(connection.request.value(forHTTPHeaderField: "Authorization"))
            connection.respond(status: 200, body: body,
                               headers: ["Set-Cookie": "manifest-session=unneeded; Path=/; Secure"])
        }
        for _ in 0..<2 {
            let release = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
            XCTAssertEqual(release?.version, "1.1.0")
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, fixture.url])
    }

    func testMalformedJSONMissingFieldsAndWrongTypesAreReported() async throws {
        let bodies = [Data("not JSON".utf8), Data("{}".utf8),
                      try manifest(["build": true]), try manifest(["build": "2"]),
                      try manifest(["releaseNotes": NSNull()]), try manifest(["version": 2])]
        for body in bodies {
            let fixture = makeSession(body: body)
            await assertCheckError(.invalidManifest, fixture: fixture)
        }
    }

    func testInvalidReleaseVersionsAreRejected() async throws {
        for version in ["1.0", "1.0.0.1", "1..0", "1.0.-1", "+1.0.0", "1.0.0-beta",
                        "01.0.0", "1. 0.0", "١.0.0", "9999999999999999999999999999.0.0"] {
            let fixture = makeSession(body: try manifest(["version": version]))
            await assertCheckError(.invalidReleaseVersion, fixture: fixture)
        }
    }

    func testNonpositiveReleaseBuildsAreRejected() async throws {
        for build in [0, -1] {
            let fixture = makeSession(body: try manifest(["build": build]))
            await assertCheckError(.invalidReleaseBuild, fixture: fixture)
        }
    }

    func testDownloadURLMustBeAbsoluteHTTPSWithoutCredentials() async throws {
        for address in ["http://downloads.example/Clipato.zip", "file:///Clipato.zip", "/Clipato.zip",
                        "https://account:password@downloads.example/Clipato.zip"] {
            let fixture = makeSession(body: try manifest(["downloadURL": address]))
            await assertCheckError(.invalidDownloadURL, fixture: fixture)
        }
    }

    func testInvalidManifestURLsAreRejectedBeforeAnyRequest() async {
        let fixture = makeSession { _ in XCTFail("An invalid manifest URL must not start a request.") }
        for address in ["http://updates.example/latest.json", "file:///latest.json", "/latest.json",
                        "https://account:password@updates.example/latest.json"] {
            do {
                _ = try await fixture.checker.check(at: URL(string: address)!, currentVersion: "1.0.0",
                                                      currentBuild: 1)
                XCTFail("Expected URL validation to fail: \(address)")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .invalidManifestURL)
            }
        }
    }

    func testHTTPFailuresAreNotReportedAsNoUpdate() async throws {
        for status in [204, 301, 404, 503] {
            let fixture = makeSession(body: try manifest(), status: status)
            await assertCheckError(.httpStatus(status), fixture: fixture)
        }
    }

    func testNonHTTPSResponseIsRejected() async throws {
        let body = try manifest()
        let fixture = makeSession { connection in
            connection.respond(status: 200, body: body, url: URL(string: "http://updates.example/latest.json")!)
        }
        await assertCheckError(.invalidResponse, fixture: fixture)
    }

    func testTransportFailureIsPreserved() async {
        let fixture = makeSession { connection in
            connection.client!.urlProtocol(connection, didFailWithError: URLError(.notConnectedToInternet))
        }
        do {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("Expected the transport error.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testInvalidInstalledMetadataDoesNotStartARequest() async {
        let fixture = makeSession { _ in XCTFail("Invalid installed metadata must not start a request.") }
        for (version, build) in [("invalid", 1), ("1.0.0", 0)] {
            do {
                _ = try await fixture.checker.check(at: fixture.url, currentVersion: version,
                                                      currentBuild: build)
                XCTFail("Expected installed metadata validation to fail.")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .invalidInstalledVersion)
            }
        }
    }

    func testCancellingAnInFlightRequestPropagatesCancellation() async {
        let started = expectation(description: "The manifest request started")
        let fixture = makeSession { _ in started.fulfill() }
        let task = Task {
            try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0",
                                              currentBuild: 1)
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled update check must not complete successfully.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testUpdateSourcesAreReadFromThePackagedPropertyListInOrder() throws {
        let resource = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: "UpdateSources", withExtension: "plist"))
        let data = try Data(contentsOf: resource)
        let addresses = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String])
        let expected = try addresses.map { try XCTUnwrap(URL(string: $0)) }
        let urls = try AppUpdateChecker.configuredURLs()
        XCTAssertEqual(urls, expected)
        for url in urls {
            XCTAssertEqual(url.scheme?.lowercased(), "https", url.absoluteString)
            let host = try XCTUnwrap(url.host, url.absoluteString)
            XCTAssertFalse(host.isEmpty, url.absoluteString)
            XCTAssertNil(url.user, url.absoluteString)
            XCTAssertNil(url.password, url.absoluteString)
        }
    }

    func testMultipleSourcesRejectEmptyInputBeforeAnyRequest() async {
        let fixture = makeSession { _ in XCTFail("An empty source list must not start a request.") }
        do {
            _ = try await fixture.checker.check(at: [], currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("Expected an empty source list to fail.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .noManifestURLs)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [])
    }

    func testMultipleSourcesValidateAllURLsBeforeAnyRequest() async {
        let fixture = makeSession { _ in XCTFail("An invalid backup URL must prevent all requests.") }
        let invalid = URL(string: "http://mirror.example/latest.json")!
        do {
            _ = try await fixture.checker.check(at: [fixture.url, invalid], currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("Expected URL validation to fail before contacting the first source.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .invalidManifestURL)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [])
    }

    func testMultipleSourcesStopAfterTheFirstValidUpdate() async throws {
        let fixture = makeSession(body: try manifest())
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                     currentBuild: 1)
        XCTAssertEqual(result.release?.version, "1.1.0")
        XCTAssertEqual(result.source, fixture.url)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url])
    }

    func testMultipleSourcesStopWhenTheFirstValidManifestHasNoUpdate() async throws {
        let current = try manifest(["version": "1.0.0", "build": 1])
        let newer = try manifest()
        let fixture = makeSession { connection in
            connection.respond(status: 200, body: connection.request.url!.lastPathComponent == "latest.json"
                               ? current : newer)
        }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                     currentBuild: 1)
        XCTAssertNil(result.release)
        XCTAssertEqual(result.source, fixture.url)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url])
    }

    func testMultipleSourcesContinueAfterTransportFailuresInConfiguredOrder() async throws {
        let body = try manifest()
        for code in [URLError.Code.timedOut, .notConnectedToInternet, .cannotConnectToHost] {
            let fixture = makeSession { connection in
                if connection.request.url!.lastPathComponent == "latest.json" {
                    connection.client!.urlProtocol(connection, didFailWithError: URLError(code))
                } else {
                    connection.respond(status: 200, body: body)
                }
            }
            let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
            let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                         currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0")
            XCTAssertEqual(result.source, backup)
            XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, backup])
        }
    }

    func testMultipleSourcesContinueAfterHTTPFailures() async throws {
        let body = try manifest()
        for status in [404, 503] {
            let fixture = makeSession { connection in
                connection.respond(status: connection.request.url!.lastPathComponent == "latest.json" ? status : 200,
                                   body: body)
            }
            let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
            let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                         currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0")
            XCTAssertEqual(result.source, backup)
            XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, backup])
        }
    }

    func testMultipleSourcesContinueAfterInvalidRemoteManifests() async throws {
        let valid = try manifest()
        let invalid = [Data("not JSON".utf8), try manifest(["version": "1.0"]),
                       try manifest(["build": 0]), try manifest(["downloadURL": "http://downloads.example/Clipato.zip"])]
        for body in invalid {
            let fixture = makeSession { connection in
                connection.respond(status: 200, body: connection.request.url!.lastPathComponent == "latest.json"
                                   ? body : valid)
            }
            let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
            let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                         currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0")
            XCTAssertEqual(result.source, backup)
            XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, backup])
        }
    }

    func testMultipleSourcesReportEveryFailedURLAndItsActualError() async {
        let fixture = makeSession { connection in
            if connection.request.url!.lastPathComponent == "latest.json" {
                connection.client!.urlProtocol(connection, didFailWithError: URLError(.timedOut))
            } else {
                connection.respond(status: 503, body: Data())
            }
        }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        do {
            _ = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("Failed sources must not be reported as no update.")
        } catch {
            guard let updateError = error as? AppUpdateError,
                  case .allSourcesFailed(let failures) = updateError else {
                XCTFail("Expected all source failures, received \(error).")
                return
            }
            XCTAssertEqual(failures.count, 2)
            if failures.count == 2 {
                XCTAssertTrue(failures[0].contains(fixture.url.absoluteString))
                XCTAssertTrue(failures[0].contains(URLError(.timedOut).localizedDescription))
                XCTAssertTrue(failures[1].contains(backup.absoluteString))
                XCTAssertTrue(failures[1].contains(AppUpdateError.httpStatus(503).localizedDescription))
            }
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, backup])
    }

    func testMultipleSourcesRejectInvalidInstalledMetadataBeforeAnyRequest() async {
        let fixture = makeSession { _ in XCTFail("Invalid installed metadata must not contact any source.") }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        for (version, build) in [("invalid", 1), ("1.0.0", 0)] {
            do {
                _ = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: version,
                                                      currentBuild: build)
                XCTFail("Expected installed metadata validation to fail.")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .invalidInstalledVersion)
            }
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [])
    }

    func testCancellingTheFirstSourceDoesNotRequestTheNextSource() async throws {
        let started = expectation(description: "The first source request started")
        let body = try manifest()
        let fixture = makeSession { connection in
            if connection.request.url!.lastPathComponent == "latest.json" {
                started.fulfill()
            } else {
                connection.respond(status: 200, body: body)
            }
        }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        let task = Task {
            try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                              currentBuild: 1)
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled check must not complete or switch sources.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url])
    }

    func testCancelledTransportErrorDoesNotRequestTheNextSource() async {
        let fixture = makeSession { connection in
            connection.client!.urlProtocol(connection, didFailWithError: URLError(.cancelled))
        }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        do {
            _ = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("A cancelled request must not switch sources.")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url])
    }

    func testSixthCheckUsesLastSuccessfulManifestWithoutAnotherRequest() async throws {
        let clock = UpdateClock()
        let fixture = makeSession(body: try manifest(), now: { clock.now })
        var lastSuccessfulAt = clock.now
        for _ in 0..<5 {
            lastSuccessfulAt = clock.now
            let result = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0")
            XCTAssertEqual(result.source, fixture.url)
            XCTAssertNil(result.cachedAt)
            clock.advance(by: 10)
        }

        let result = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(result.release?.version, "1.1.0")
        XCTAssertEqual(result.source, fixture.url)
        XCTAssertEqual(result.cachedAt, lastSuccessfulAt)
        XCTAssertEqual(requestedURLs(for: fixture.url), Array(repeating: fixture.url, count: 5))
    }

    func testDailyBudgetAndSuccessfulCacheSurviveCheckerRecreation() async throws {
        let clock = UpdateClock()
        let fixture = makeSession(body: try manifest(), now: { clock.now })
        for _ in 0..<5 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        let recreated = AppUpdateChecker(defaults: fixture.defaults, session: fixture.session, now: { clock.now })
        let result = try await recreated.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(result.release?.version, "1.1.0")
        XCTAssertEqual(result.source, fixture.url)
        XCTAssertEqual(result.cachedAt, clock.now)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testDailyBudgetResetsAtLocalMidnightRatherThanAfterTwentyFourHours() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20,
                                                      hour: 23, minute: 59, second: 59))!
        let clock = UpdateClock(date)
        let fixture = makeSession(body: try manifest(), calendar: calendar, now: { clock.now })
        for _ in 0..<5 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(cached.cachedAt, date)

        clock.advance(by: 2)
        let fresh = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertNil(fresh.cachedAt)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 6)
    }

    func testFailedRequestsConsumeBudgetWithoutReplacingTheLastSuccessfulManifest() async throws {
        let clock = UpdateClock()
        let body = try manifest()
        let fixture = makeSession(now: { clock.now }) { connection in
            connection.respond(status: connection.request.url!.lastPathComponent == "latest.json" ? 200 : 503,
                               body: body)
        }
        _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        let successfulAt = clock.now
        clock.advance(by: 60)
        let failedURL = fixture.url.deletingLastPathComponent().appendingPathComponent("unavailable.json")
        for _ in 0..<4 {
            do {
                _ = try await fixture.checker.check(at: failedURL, currentVersion: "1.0.0", currentBuild: 1)
                XCTFail("An HTTP failure must remain visible while requests are available.")
            } catch {
                XCTAssertEqual(error as? AppUpdateError, .httpStatus(503))
            }
        }
        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(cached.release?.version, "1.1.0")
        XCTAssertEqual(cached.source, fixture.url)
        XCTAssertEqual(cached.cachedAt, successfulAt)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url] + Array(repeating: failedURL, count: 4))
    }

    func testExhaustedBudgetWithoutAnySuccessfulCacheReportsTheLimit() async throws {
        let fixture = makeSession(body: Data(), status: 503)
        for _ in 0..<5 {
            await assertCheckError(.httpStatus(503), fixture: fixture)
        }
        do {
            _ = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
            XCTFail("A daily limit without a successful cache must not be reported as up to date.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .dailyLimitReached)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testEachMirrorAttemptConsumesBudgetAndExhaustionStopsTheNextMirror() async throws {
        let clock = UpdateClock()
        let body = try manifest()
        let fixture = makeSession(now: { clock.now }) { connection in
            connection.respond(status: connection.request.url!.lastPathComponent == "latest.json" ? 503 : 200,
                               body: body)
        }
        let backup = fixture.url.deletingLastPathComponent().appendingPathComponent("backup.json")
        for _ in 0..<2 {
            let result = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0", currentBuild: 1)
            XCTAssertEqual(result.source, backup)
            XCTAssertNil(result.cachedAt)
        }
        let cached = try await fixture.checker.check(at: [fixture.url, backup], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(cached.release?.version, "1.1.0")
        XCTAssertEqual(cached.source, backup)
        XCTAssertEqual(cached.cachedAt, clock.now)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, backup, fixture.url, backup, fixture.url])
    }

    func testFailedMirrorsCannotExceedTheDailyLimitWithoutASuccessfulCache() async throws {
        let fixture = makeSession(body: Data(), status: 503)
        let urls = (0..<7).map {
            fixture.url.deletingLastPathComponent().appendingPathComponent("mirror-\($0).json")
        }
        do {
            _ = try await fixture.checker.check(at: urls, currentVersion: "1.0.0", currentBuild: 1)
            XCTFail("Trying all configured mirrors must still respect the daily limit.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .dailyLimitReached)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), Array(urls.prefix(5)))
    }

    func testHTTPSRedirectsConsumeBudgetAndStopBeforeARequestBeyondTheLimit() async throws {
        let clock = UpdateClock()
        let body = try manifest()
        let fixture = makeSession(now: { clock.now }) { connection in
            if connection.request.url!.lastPathComponent == "latest.json" {
                let target = connection.request.url!.deletingLastPathComponent().appendingPathComponent("redirected.json")
                connection.redirect(to: target)
            } else {
                connection.respond(status: 200, body: body)
            }
        }
        let target = fixture.url.deletingLastPathComponent().appendingPathComponent("redirected.json")
        for _ in 0..<2 {
            let result = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0")
            XCTAssertNil(result.cachedAt)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, target, fixture.url, target])

        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(cached.release?.version, "1.1.0")
        XCTAssertEqual(cached.cachedAt, clock.now)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url, target, fixture.url, target, fixture.url])
    }

    func testHTTPSRedirectStatusesResolveRelativeLocationsAgainstTheResponseURL() async throws {
        let body = try manifest()
        for status in [301, 302, 303, 307, 308] {
            let fixture = makeSession { connection in
                if connection.request.url!.lastPathComponent == "latest.json" {
                    let target = URL(string: "../releases/stable.json", relativeTo: connection.request.url!)!.absoluteURL
                    connection.redirect(to: target, status: status, location: "../releases/stable.json")
                } else {
                    connection.respond(status: 200, body: body)
                }
            }
            let entry = fixture.url.deletingLastPathComponent().appendingPathComponent("channels/latest.json")
            let target = fixture.url.deletingLastPathComponent().appendingPathComponent("releases/stable.json")
            let result = try await fixture.checker.check(at: [entry], currentVersion: "1.0.0", currentBuild: 1)
            XCTAssertEqual(result.release?.version, "1.1.0", "HTTP \(status)")
            XCTAssertEqual(result.source, entry, "HTTP \(status)")
            XCTAssertNil(result.cachedAt, "HTTP \(status)")
            XCTAssertEqual(requestedURLs(for: fixture.url), [entry, target], "HTTP \(status)")
        }
    }

    func testHTTPDowngradeRedirectIsRejectedBeforeRequestingItsTarget() async {
        let fixture = makeSession { connection in
            let target = URL(string: "http://\(connection.request.url!.host!)/insecure.json")!
            connection.redirect(to: target)
        }
        await assertCheckError(.httpStatus(302), fixture: fixture)
        XCTAssertEqual(requestedURLs(for: fixture.url), [fixture.url])
    }

    func testRedirectLoopStopsAfterFiveRequestsWithoutASuccessfulCache() async {
        let fixture = makeSession { connection in
            connection.redirect(to: connection.request.url!)
        }
        await assertCheckError(.dailyLimitReached, fixture: fixture)
        XCTAssertEqual(requestedURLs(for: fixture.url), Array(repeating: fixture.url, count: 5))
    }

    func testInvalidSuccessfulCacheIsReportedWithoutAnotherRequest() async throws {
        let fixture = makeSession(body: try manifest())
        for _ in 0..<5 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        fixture.defaults.set(Data("bad cache".utf8), forKey: "updateCheck.cachedResult")
        do {
            _ = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
            XCTFail("A damaged cached manifest must not be treated as a valid update result.")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .invalidCachedResult)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testSuccessfulUpToDateManifestIsCachedWithItsCompleteRelease() async throws {
        let clock = UpdateClock()
        let fixture = makeSession(body: try manifest(), now: { clock.now })
        for _ in 0..<5 {
            let result = try await fixture.checker.check(at: fixture.url, currentVersion: "1.1.0", currentBuild: 2)
            XCTAssertNil(result)
        }
        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.1.0", currentBuild: 2)
        XCTAssertNil(cached.release)
        XCTAssertEqual(cached.cachedAt, clock.now)
        let olderInstall = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(olderInstall.release?.version, "1.1.0")
        XCTAssertEqual(olderInstall.cachedAt, clock.now)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testCachedReleaseIsComparedAgainstTheCurrentlyInstalledVersion() async throws {
        let clock = UpdateClock()
        let fixture = makeSession(body: try manifest(), now: { clock.now })
        for _ in 0..<5 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        for (version, build) in [("1.1.0", 2), ("1.1.0", 3), ("1.2.0", 1)] {
            let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: version, currentBuild: build)
            XCTAssertNil(cached.release)
            XCTAssertEqual(cached.cachedAt, clock.now)
        }
        let earlierBuild = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.1.0", currentBuild: 1)
        XCTAssertEqual(earlierBuild.release?.build, 2)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testConcurrentChecksShareTheFiveRequestBudget() async throws {
        let fixture = makeSession(body: try manifest())
        let validResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        let result = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
                        return result.release?.version == "1.1.0"
                    } catch {
                        return (error as? AppUpdateError) == .dailyLimitReached
                    }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(validResults.count, 10)
        XCTAssertTrue(validResults.allSatisfy { $0 })
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertEqual(cached.release?.version, "1.1.0")
        XCTAssertNotNil(cached.cachedAt)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testCancellationBeforeStartingDoesNotConsumeTheDailyBudget() async throws {
        let fixture = makeSession(body: try manifest())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        do {
            _ = try await task.value
            XCTFail("A task cancelled before checking must not send a request.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url), [])
        for _ in 0..<5 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    func testCancellingAnAlreadyStartedRequestStillConsumesOneAttempt() async throws {
        let started = expectation(description: "The first request started before cancellation")
        let body = try manifest()
        let fixture = makeSession { connection in
            if self.requestedURLs(for: connection.request.url!).count == 1 {
                started.fulfill()
            } else {
                connection.respond(status: 200, body: body)
            }
        }
        let task = Task {
            try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An in-flight cancellation must propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        for _ in 0..<4 {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0", currentBuild: 1)
        }
        let cached = try await fixture.checker.check(at: [fixture.url], currentVersion: "1.0.0", currentBuild: 1)
        XCTAssertNotNil(cached.cachedAt)
        XCTAssertEqual(requestedURLs(for: fixture.url).count, 5)
    }

    private func manifest(_ fields: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = ["version": "1.1.0", "build": 2,
                                     "downloadURL": "https://downloads.example/Clipato.zip",
                                     "releaseNotes": "修复问题。\nImproved capture."]
        values.merge(fields) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: values)
    }

    private func makeSession(body: Data, status: Int = 200,
                             calendar: Calendar = .autoupdatingCurrent,
                             now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }) -> UpdateFixture {
        makeSession(calendar: calendar, now: now) { $0.respond(status: status, body: body) }
    }

    private func makeSession(calendar: Calendar = .autoupdatingCurrent,
                             now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) },
                             handler: @escaping (UpdateURLProtocol) -> Void) -> UpdateFixture {
        let host = "\(UUID().uuidString.lowercased()).updates.example"
        let url = URL(string: "https://\(host)/latest.json")!
        UpdateURLProtocol.lock.lock()
        UpdateURLProtocol.handlers[host] = handler
        UpdateURLProtocol.requests[host] = []
        UpdateURLProtocol.lock.unlock()
        let configuration = AppUpdateChecker.updateSession.configuration
        configuration.protocolClasses = [UpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName = "ClipatoUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let checker = AppUpdateChecker(defaults: defaults, session: session, calendar: calendar, now: now)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            session.invalidateAndCancel()
            UpdateURLProtocol.lock.lock()
            UpdateURLProtocol.handlers.removeValue(forKey: host)
            UpdateURLProtocol.requests.removeValue(forKey: host)
            UpdateURLProtocol.lock.unlock()
        }
        return (session, url, checker, defaults)
    }

    private func requestedURLs(for url: URL) -> [URL] {
        UpdateURLProtocol.lock.lock()
        defer { UpdateURLProtocol.lock.unlock() }
        return UpdateURLProtocol.requests[url.host!]!
    }

    private func assertCheckError(_ expected: AppUpdateError, fixture: UpdateFixture,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await fixture.checker.check(at: fixture.url, currentVersion: "1.0.0",
                                                  currentBuild: 1)
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppUpdateError, expected, file: file, line: line)
        }
    }
}

private typealias UpdateFixture = (session: URLSession, url: URL, checker: AppUpdateChecker, defaults: UserDefaults)

private final class UpdateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value.addTimeInterval(interval)
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handlers: [String: (UpdateURLProtocol) -> Void] = [:]
    static var requests: [String: [URL]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.url!.host!]!
        Self.requests[request.url!.host!]!.append(request.url!)
        Self.lock.unlock()
        handler(self)
    }

    override func stopLoading() {}

    func redirect(to url: URL, status: Int = 302, location: String? = nil) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Location": location ?? url.absoluteString])!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        client!.urlProtocolDidFinishLoading(self)
    }

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
