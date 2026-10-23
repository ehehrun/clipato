import Foundation
import XCTest
@testable import Clipato

final class PrivacyPolicyTests: XCTestCase {
    func testBothOfflineNoticesArePackagedAndIdentifyTheUnpublishedDraft() throws {
        for (name, draft, logs) in [
            ("PrivacyPolicy.en", "Release draft", "Turning off automation or enabling Privacy Mode does not erase existing logs"),
            ("PrivacyPolicy.zh-CN", "发布前草案", "关闭自动化或开启隐私模式不会删除已有日志")
        ] {
            let url = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: name, withExtension: "txt"))
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("Clipato"), name)
            XCTAssertTrue(text.contains(draft), name)
            XCTAssertTrue(text.contains(logs), name)
        }
    }
}
