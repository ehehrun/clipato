import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static func isAuthorizationError(_ error: Error) -> Bool {
        let original = error as NSError
        return original.domain == SCStreamErrorDomain && original.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func localizedError(_ error: Error) -> Error {
        let original = error as NSError
        guard isAuthorizationError(error) else { return error }
        var userInfo = original.userInfo
        userInfo[NSUnderlyingErrorKey] = original
        userInfo[NSLocalizedDescriptionKey] = L("""
        Clipato 当前无法访问屏幕。

        如果权限开关已经打开，请完全退出 Clipato 后重新打开。刚更新本地版本时，旧授权可能关联了上一个签名身份，需要在系统设置的屏幕录制权限列表中重新添加当前应用。

        当前应用：\(Bundle.main.bundleURL.path)
        系统错误：\(original.domain)（\(original.code)）
        """)
        return NSError(domain: original.domain, code: original.code, userInfo: userInfo)
    }
}
