import Foundation
import XCTest
@testable import Clipato

final class AutomationAccessTests: XCTestCase {
    func testDistributedRevocationCancelsAnAwaitingTaskWithoutAnAppRunLoop() async throws {
        let defaults = try makeDefaults()
        let access = AutomationAccess(defaults: defaults)
        let worker = Task.detached {
            do {
                try await Task.sleep(for: .seconds(3))
                return false
            } catch is CancellationError {
                return true
            }
        }
        defer { worker.cancel() }
        let observer = access.observeRevocation { worker.cancel() }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        await Task.detached { MCPSettings.setEnabled(false, in: defaults) }.value
        let cancelled = try await worker.value
        XCTAssertTrue(cancelled, "A real distributed notification must cancel an idle async task without pumping an AppKit run loop")
        XCTAssertFalse(access.isAllowed)
    }

    func testReenablingRequiresANewLease() throws {
        let defaults = try makeDefaults()
        let original = AutomationAccess(defaults: defaults)
        XCTAssertTrue(original.isAllowed)
        try AutomationAccess.$current.withValue(original) { try AutomationAccess.check() }

        MCPSettings.setEnabled(false, in: defaults)
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(original.isAllowed)
        MCPSettings.setEnabled(true, in: defaults)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(original.isAllowed)
        try AutomationAccess.$current.withValue(original) {
            XCTAssertThrowsError(try AutomationAccess.check()) { error in
                XCTAssertTrue(error is MCPServerError)
            }
        }

        let renewed = AutomationAccess(defaults: defaults)
        XCTAssertTrue(renewed.isAllowed)
        try AutomationAccess.$current.withValue(renewed) { try AutomationAccess.check() }
    }

    func testPrivacyModeRefusesEnablingAndRevokesTheExistingLease() throws {
        let defaults = try makeDefaults()
        let original = AutomationAccess(defaults: defaults)
        defaults.set(true, forKey: "privacyMode")
        MCPSettings.setEnabled(true, in: defaults)
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(original.isAllowed)

        defaults.set(false, forKey: "privacyMode")
        MCPSettings.setEnabled(true, in: defaults)
        XCTAssertTrue(AutomationAccess(defaults: defaults).isAllowed)
        XCTAssertFalse(original.isAllowed)
    }

    func testNoLeaseLeavesSharedGUIOperationsAvailableWhenAutomationIsDisabled() throws {
        let defaults = try makeDefaults(enabled: false)
        let disabled = AutomationAccess(defaults: defaults)
        try AutomationAccess.$current.withValue(disabled) {
            XCTAssertThrowsError(try AutomationAccess.check())
            try AutomationAccess.$current.withValue(nil) {
                XCTAssertNil(AutomationAccess.current)
                XCTAssertNoThrow(try AutomationAccess.check())
            }
            XCTAssertTrue(AutomationAccess.current === disabled)
            XCTAssertThrowsError(try AutomationAccess.check())
        }
    }

    func testDetachedWorkerRetainsItsLeaseAndRejectsRevocation() async throws {
        nonisolated(unsafe) let defaults = try makeDefaults()
        let access = AutomationAccess(defaults: defaults)
        let worker = AutomationAccess.$current.withValue(access) {
            AutomationAccess.detached {
                XCTAssertTrue(AutomationAccess.current === access)
                try AutomationAccess.check()
                MCPSettings.setEnabled(false, in: defaults)
                try AutomationAccess.check()
            }
        }
        do {
            try await worker.value
            XCTFail("A detached worker must retain its lease and reject work after revocation")
        } catch {
            XCTAssertTrue(error is MCPServerError)
        }
    }

    private func makeDefaults(enabled: Bool = true) throws -> UserDefaults {
        let domain = "Clipato.AutomationAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
        MCPSettings.setEnabled(enabled, in: defaults)
        return defaults
    }
}
