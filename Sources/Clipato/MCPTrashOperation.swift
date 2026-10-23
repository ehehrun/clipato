import AppKit
import Darwin
import Foundation

enum MCPTrashAuthorizationError: LocalizedError, Equatable {
    case disabled, rejected, timedOut, selectionChanged

    var errorDescription: String? {
        switch self {
        case .disabled: return L("自动化移入废纸篓权限未开启。请在「AI 终端」设置中开启，随后仍需逐批确认。")
        case .rejected: return L("用户取消了移入废纸篓，未执行操作。")
        case .timedOut: return L("确认请求已超时，未执行操作。")
        case .selectionChanged: return L("待移入废纸篓的内容已变化，请重新发起请求并确认。")
        }
    }
}

@MainActor
enum MCPTrashOperation {
    struct Selection {
        let assets: [CollectionAsset]
        let images: [VaultImage]
        let sessions: [SavedSession]
        let videos: [URL]
        let names: [String]
        let collectionCount: Int
        private let signatures: [String]

        @MainActor
        init(assets: [CollectionAsset], store: LibraryStore) throws {
            var seen: Set<CollectionAsset> = []
            self.assets = assets.filter { seen.insert($0).inserted }
            var images: [VaultImage] = []
            var sessions: [SavedSession] = []
            var videos: [URL] = []
            var names: [String] = []
            var signatures: [String] = []
            for asset in self.assets {
                let url: URL
                switch asset {
                case .image(let id):
                    guard let image = store.images.first(where: { $0.id == id }) else {
                        throw MCPError.invalidArguments("Image is not in this vault: \(id)")
                    }
                    images.append(image)
                    names.append(image.filename)
                    url = store.imageURL(image)
                case .session(let id):
                    guard let session = store.sessions.first(where: { $0.id == id }) else {
                        throw MCPError.invalidArguments("Recording is not in this vault: \(id)")
                    }
                    sessions.append(session)
                    names.append(session.manifest.name ?? session.directory.lastPathComponent)
                    url = session.directory.appendingPathComponent("manifest.json")
                case .video(let path):
                    guard store.videos.contains(path) else {
                        throw MCPError.invalidArguments("Video is not in this vault: \(path.path)")
                    }
                    videos.append(path)
                    names.append(path.deletingLastPathComponent().lastPathComponent + "/" + path.lastPathComponent)
                    url = path
                }
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
                }
                guard metadata.st_mode & S_IFMT != S_IFLNK else {
                    throw MCPError.invalidArguments("Symbolic links cannot be moved to Trash through MCP: \(url.path)")
                }
                signatures.append("\(url.path):\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec)")
            }
            self.images = images
            self.sessions = sessions
            self.videos = videos
            self.names = names
            self.signatures = signatures
            let selected = Set(self.assets)
            collectionCount = store.collectionMembers.values.filter { !$0.isDisjoint(with: selected) }.count
        }

        func matches(_ other: Selection) -> Bool {
            assets == other.assets && names == other.names && signatures == other.signatures && collectionCount == other.collectionCount
        }
    }

    static func perform(assets: [CollectionAsset], store: LibraryStore,
                        isAllowed: () -> Bool = { MCPSettings.allowsTrash() },
                        confirm: (Selection) async throws -> Bool = confirm) async throws -> [String: Any] {
        guard isAllowed() else { throw MCPTrashAuthorizationError.disabled }
        let selection = try Selection(assets: assets, store: store)
        guard try await confirm(selection) else { throw MCPTrashAuthorizationError.rejected }
        try AutomationAccess.check()
        guard isAllowed() else { throw MCPTrashAuthorizationError.disabled }
        try store.reloadImages()
        try store.reloadSessions()
        guard selection.matches(try Selection(assets: selection.assets, store: store)) else {
            throw MCPTrashAuthorizationError.selectionChanged
        }
        var trashed: [CollectionAsset] = []
        do {
            for image in selection.images {
                try AutomationAccess.check()
                guard isAllowed() else { throw MCPTrashAuthorizationError.disabled }
                try store.delete([image])
                trashed.append(.image(image.id))
            }
            for session in selection.sessions {
                try AutomationAccess.check()
                guard isAllowed() else { throw MCPTrashAuthorizationError.disabled }
                try store.deleteSession(session)
                trashed.append(.session(session.id))
            }
            for video in selection.videos {
                try AutomationAccess.check()
                guard isAllowed() else { throw MCPTrashAuthorizationError.disabled }
                try store.deleteVideo(video)
                trashed.append(.video(video))
            }
        } catch {
            throw NSError(domain: "Clipato.MCPTrash", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Moved \(trashed.count) of \(selection.assets.count) items to Trash before failure. Completed assets: \(trashed). \(error.localizedDescription)"])
        }
        return ["trashed": try MCPTool.encode(trashed), "count": trashed.count]
    }

    private static var preparedApplication = false

    static func confirm(_ selection: Selection) async throws -> Bool {
        let application = NSApplication.shared
        if !preparedApplication {
            ClipatoApp.startCommandEventLoop()
            preparedApplication = true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("将 \(selection.assets.count) 个项目移入废纸篓？")
        alert.informativeText = L("这是来自外部自动化的请求。会同时移除 \(selection.collectionCount) 个收藏夹中的相关引用。文件可从系统废纸篓恢复。")
        let decision = MCPTrashDecision()
        let cancel = alert.addButton(withTitle: L("取消"))
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = decision
        cancel.action = #selector(MCPTrashDecision.cancel)
        cancel.setAccessibilityIdentifier("mcp-cancel-trash")
        let approve = alert.addButton(withTitle: L("移入废纸篓"))
        approve.hasDestructiveAction = true
        approve.keyEquivalent = ""
        approve.target = decision
        approve.action = #selector(MCPTrashDecision.approve)
        approve.setAccessibilityIdentifier("mcp-confirm-trash")
        let list = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 160))
        list.isEditable = false
        list.isRichText = false
        list.font = .systemFont(ofSize: 12)
        list.string = selection.names.joined(separator: "\n")
        let scroll = NSScrollView(frame: list.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        alert.accessoryView = scroll
        alert.window.title = L("Clipato · 自动化确认")
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        alert.window.setAccessibilityIdentifier("mcp-trash-confirmation")
        let session = application.beginModalSession(for: alert.window)
        defer {
            application.endModalSession(session)
            alert.window.orderOut(nil)
        }
        application.activate(ignoringOtherApps: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            try Task.checkCancellation()
            let response = application.runModalSession(session)
            if let approved = decision.approved { return approved }
            if response != .continue { return false }
            guard ContinuousClock.now < deadline else { throw MCPTrashAuthorizationError.timedOut }
            // Yield between AppKit event passes so MCP ping and cancellation remain responsive.
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
private final class MCPTrashDecision: NSObject {
    var approved: Bool?
    @objc func cancel() { approved = false }
    @objc func approve() { approved = true }
}
