import AppKit
import Combine
import ScreenCaptureKit
import XCTest
@testable import Clipato

@MainActor
final class CapturePermissionPresentationTests: XCTestCase {
    func testAuthorizationFailureOpensSettingsWithoutPublishingAModalError() throws {
        let model = try makeModel()
        model.section = .imageProcessing
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let error = ScreenCapturePermission.localizedError(denied)
        var modalMessages: [String?] = []
        var permissionRequests = 0
        let errors = model.$errorMessage.dropFirst().sink { modalMessages.append($0) }
        let requests = NotificationCenter.default.publisher(for: .clipatoShowScreenCapturePermissions, object: model)
            .sink { _ in
                XCTAssertEqual(model.section, .security)
                XCTAssertEqual(model.screenCapturePermissionError, error.localizedDescription)
                permissionRequests += 1
            }
        defer { errors.cancel(); requests.cancel() }

        model.reportCaptureError(error, message: error.localizedDescription)
        model.reportCaptureError(error, message: error.localizedDescription)

        XCTAssertEqual(permissionRequests, 2)
        XCTAssertTrue(modalMessages.isEmpty, "Even a transient modal error would create the second permission dialog")
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.capturing)
        XCTAssertFalse(model.recordingBusy)
        XCTAssertTrue(try XCTUnwrap(model.library).images.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.screenCapturePermissionError).contains(Bundle.main.bundleURL.path))
    }

    func testUnrelatedAndCompositeFailuresKeepTheirNormalErrorPresentation() throws {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let failures = [
            NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue),
            NSError(domain: NSPOSIXErrorDomain, code: denied.code),
            NSError(domain: "Clipato", code: 1, userInfo: [NSUnderlyingErrorKey: denied])
        ]
        for error in failures {
            let model = try makeModel()
            model.section = .appearance
            var permissionRequests = 0
            let requests = NotificationCenter.default.publisher(for: .clipatoShowScreenCapturePermissions, object: model)
                .sink { _ in permissionRequests += 1 }
            defer { requests.cancel() }

            model.reportCaptureError(error, message: error.localizedDescription)

            XCTAssertEqual(model.errorMessage, error.localizedDescription)
            XCTAssertNil(model.screenCapturePermissionError)
            XCTAssertEqual(model.section, .appearance)
            XCTAssertEqual(permissionRequests, 0)
        }
    }

    func testPermissionGuidancePreservesAnIndependentCleanupFailure() throws {
        let model = try makeModel()
        model.errorMessage = "Temporary screenshot cleanup failed"
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)

        model.reportCaptureError(denied, message: denied.localizedDescription)

        XCTAssertEqual(model.errorMessage, "Temporary screenshot cleanup failed")
        XCTAssertEqual(model.screenCapturePermissionError, denied.localizedDescription)
        XCTAssertEqual(model.section, .security)
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.CapturePermissionPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        XCTAssertNil(model.errorMessage)
        return model
    }
}
