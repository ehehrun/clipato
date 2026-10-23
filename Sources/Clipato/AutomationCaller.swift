import Darwin
import Foundation

struct AutomationCaller: Sendable {
    struct ReadError: Sendable {
        let operation: String
        let result: Int32
        let code: Int32

        var jsonObject: [String: Any] {
            ["operation": operation, "result": result, "errno": code]
        }
    }

    struct ProcessIdentity: Sendable {
        let pid: pid_t
        var parentPID: pid_t?
        var name: String?
        var executable: String?
        var startTime: TimeInterval?
        var applicationPath: String?
        var bundleIdentifier: String?
        var appName: String?
        var bundleInfoUnavailable = false
        var errors: [ReadError] = []

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["pid": pid]
            if let parentPID { object["parentPID"] = parentPID }
            if let name { object["name"] = name }
            if let executable { object["executable"] = executable }
            if let startTime { object["startTime"] = startTime }
            if let applicationPath { object["applicationPath"] = applicationPath }
            if let bundleIdentifier { object["bundleIdentifier"] = bundleIdentifier }
            if let appName { object["appName"] = appName }
            if bundleInfoUnavailable { object["bundleInfoUnavailable"] = true }
            if !errors.isEmpty { object["errors"] = errors.map(\.jsonObject) }
            return object
        }
    }

    static let current = capture()

    let process: ProcessIdentity
    let ancestors: [ProcessIdentity]
    let ancestryLimited: Bool

    var jsonObject: [String: Any] {
        ["process": process.jsonObject, "ancestors": ancestors.map(\.jsonObject), "ancestryLimited": ancestryLimited]
    }

    static func capture(processID: pid_t = getpid()) -> AutomationCaller {
        let process = readProcess(processID)
        var ancestors: [ProcessIdentity] = []
        var parentPID = process.parentPID
        while let pid = parentPID, pid > 0, ancestors.count < 8 {
            let parent = readProcess(pid)
            ancestors.append(parent)
            parentPID = parent.parentPID
        }
        return AutomationCaller(process: process, ancestors: ancestors,
                                ancestryLimited: ancestors.count == 8 && parentPID != nil && parentPID != 0)
    }

    private static func readProcess(_ pid: pid_t) -> ProcessIdentity {
        var identity = ProcessIdentity(pid: pid)
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let informationResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, informationSize)
        if informationResult == informationSize {
            identity.parentPID = pid_t(information.pbi_ppid)
            identity.name = withUnsafeBytes(of: information.pbi_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            identity.startTime = TimeInterval(information.pbi_start_tvsec) + TimeInterval(information.pbi_start_tvusec) / 1_000_000
        } else {
            identity.errors.append(ReadError(operation: "proc_pidinfo", result: informationResult, code: errno))
        }

        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro that Swift does not import.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        errno = 0
        let pathResult = proc_pidpath(pid, &path, UInt32(path.count))
        if pathResult > 0 {
            identity.executable = String(cString: path)
            readApplication(into: &identity)
        } else {
            identity.errors.append(ReadError(operation: "proc_pidpath", result: pathResult, code: errno))
        }
        return identity
    }

    private static func readApplication(into identity: inout ProcessIdentity) {
        guard let executable = identity.executable else { return }
        var directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                identity.applicationPath = directory.path
                guard let bundle = Bundle(url: directory), let information = bundle.infoDictionary else {
                    identity.bundleInfoUnavailable = true
                    return
                }
                identity.bundleIdentifier = information["CFBundleIdentifier"] as? String
                identity.appName = information["CFBundleName"] as? String
                return
            }
            directory.deleteLastPathComponent()
        }
    }
}
