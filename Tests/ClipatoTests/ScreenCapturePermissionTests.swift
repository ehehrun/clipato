import ScreenCaptureKit
import XCTest
@testable import Clipato

final class ScreenCapturePermissionTests: XCTestCase {
    func testDenialKeepsSystemErrorAndIdentifiesCurrentApplication() {
        let cause = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let original = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue,
                               userInfo: [NSUnderlyingErrorKey: cause, "diagnostic": "original"])
        let reported = ScreenCapturePermission.localizedError(original) as NSError
        XCTAssertEqual(reported.domain, original.domain)
        XCTAssertEqual(reported.code, original.code)
        XCTAssertEqual(reported.userInfo["diagnostic"] as? String, "original")
        XCTAssertTrue(reported.userInfo[NSUnderlyingErrorKey] as? NSError === original)
        XCTAssertTrue(reported.localizedDescription.contains(Bundle.main.bundleURL.path))
        XCTAssertEqual(reported.localizedDescription, L("""
        Clipato 当前无法访问屏幕。

        如果权限开关已经打开，请完全退出 Clipato 后重新打开。刚更新本地版本时，旧授权可能关联了上一个签名身份，需要在系统设置的屏幕录制权限列表中重新添加当前应用。

        当前应用：\(Bundle.main.bundleURL.path)
        系统错误：\(original.domain)（\(original.code)）
        """))
    }

    func testUnrelatedCaptureAndFilesystemErrorsAreNotReclassified() {
        for original in [NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue),
                         NSError(domain: NSPOSIXErrorDomain, code: 13)] {
            XCTAssertTrue(ScreenCapturePermission.localizedError(original) as NSError === original)
        }
    }
}
