import Darwin
import Foundation

enum SkillClient: CaseIterable {
    case codex, claudeCode

    var title: String { self == .codex ? "Codex" : "Claude Code" }

    func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(self == .codex ? ".agents/skills/clipato" : ".claude/skills/clipato", isDirectory: true)
    }
}

enum SkillInstallation {
    static func install(to destination: URL, executable: URL, replaceExisting: Bool = false,
                        bundle: Bundle = LanguageSettings.resourceBundle) throws {
        guard !DistributionChannel.isAppStore else {
            throw NSError(domain: "Clipato.SkillInstallation", code: 4, userInfo: [NSLocalizedDescriptionKey:
                L("Mac App Store 版本不支持安装或导出可执行 Skill。")])
        }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "Clipato.SkillInstallation", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("无法执行 Clipato，请从新的位置重新打开 App 后再安装 Skill：\(executable.path)")])
        }
        guard let resources = bundle.url(forResource: "Skills", withExtension: nil) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "Skills/clipato"])
        }
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".Clipato-skill-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: resources.appendingPathComponent("clipato", isDirectory: true), to: staging)
            let launcher = staging.appendingPathComponent("scripts/clipato")
            let template = try String(contentsOf: launcher, encoding: .utf8)
            let quotedPath = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try template.replacingOccurrences(of: "__CLIPATO_EXECUTABLE__", with: quotedPath)
                .write(to: launcher, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            let flags = UInt32(replaceExisting ? RENAME_SWAP : RENAME_EXCL)
            let result = staging.path.withCString { source in
                destination.path.withCString { target in renamex_np(source, target, flags) }
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
            }
        } catch {
            let installationError = error
            if manager.fileExists(atPath: staging.path) {
                do { try manager.removeItem(at: staging) }
                catch {
                    throw NSError(domain: "Clipato.SkillInstallation", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        L("Skill 安装失败：\(installationError.localizedDescription)\n临时文件清理失败：\(error.localizedDescription)\n保留位置：\(staging.path)"),
                        NSUnderlyingErrorKey: installationError])
                }
            }
            throw installationError
        }
        if replaceExisting {
            do { try manager.removeItem(at: staging) }
            catch {
                throw NSError(domain: "Clipato.SkillInstallation", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    L("Skill 已安装到 \(destination.path)，但旧文件清理失败：\(error.localizedDescription)\n保留位置：\(staging.path)"),
                    NSUnderlyingErrorKey: error])
            }
        }
    }
}
