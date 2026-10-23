import SwiftUI
import AppKit

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: ShortcutManager
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("快捷键设置")).consoleFont(17, weight: .semibold)
                    Text(L("点击录入框，然后按下功能键或组合键。Esc 取消，Delete 清除。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            HStack {
                Toggle(L("启用全局快捷键"), isOn: Binding(get: { shortcuts.isEnabled }, set: { shortcuts.setEnabled($0) }))
                    .toggleStyle(.switch).consoleFont(12, weight: .medium)
                Spacer()
                Text(shortcuts.isEnabled ? L("录入时自动暂停，完成后恢复") : L("已暂停 · 配置保留"))
                    .consoleFont(10).foregroundStyle(Palette.muted)
            }.padding(.vertical, 10)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutSettingRow(shortcuts: shortcuts, action: action)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Mac 的亮度、音量键可能需要同时按 Fn / 🌐。也可在系统设置 → 键盘 → 键盘快捷键 → 功能键中，开启「将 F1、F2 等键用作标准功能键」。"))
                    .consoleFont(10).foregroundStyle(Palette.muted).lineSpacing(3)
                HStack {
                    Button(L("打开键盘设置")) {
                        let opened = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        errorMessage = opened ? nil : L("无法打开系统键盘设置。")
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                    Spacer()
                    Button(L("恢复默认")) {
                        shortcuts.endRecording()
                        do {
                            try shortcuts.restoreDefaults()
                            errorMessage = nil
                        } catch { errorMessage = error.localizedDescription }
                    }.buttonStyle(QuietButtonStyle())
                }.consoleFont(11)
                if let errorMessage {
                    Text(errorMessage).consoleFont(11).foregroundStyle(.red)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
        .tint(Palette.accent)
        .foregroundStyle(Palette.foreground)
        .onDisappear { shortcuts.endRecording() }
        .focusEffectDisabled()
    }
}

private struct ShortcutSettingRow: View {
    @Environment(\.consoleFontScale) private var fontScale
    @ObservedObject var shortcuts: ShortcutManager
    let action: ShortcutAction
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text(action.title).consoleFont(12, weight: .medium).frame(width: 137 * fontScale, alignment: .leading)
                ShortcutRecorder(shortcuts: shortcuts, action: action, onError: { inputError = $0 })
                    .frame(minWidth: 140 * fontScale, maxWidth: 194 * fontScale)
                    .frame(height: 32 * fontScale)
                Button {
                    do {
                        try shortcuts.setShortcut(nil, for: action)
                        shortcuts.endRecording()
                        inputError = nil
                    } catch { inputError = error.localizedDescription }
                } label: {
                    Image(systemName: "xmark").consoleFont(10, weight: .semibold).frame(width: 26 * fontScale, height: 28 * fontScale)
                }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help(L("清除\(action.title)快捷键"))
                    .accessibilityLabel(L("清除\(action.title)快捷键"))
                    .disabled(shortcuts.bindings[action] == nil && shortcuts.recordingAction != action)
                Spacer(minLength: 0)
                status.consoleFont(10).frame(width: 88 * fontScale, alignment: .trailing)
            }
            if let message = inputError ?? (shortcuts.isEnabled ? shortcuts.errors[action] : nil) {
                Text(message).consoleFont(10).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay { SurfaceBorder(cornerRadius: 6) }
        .onChange(of: shortcuts.recordingAction) { _, value in
            if value != action { inputError = nil }
        }
    }

    @ViewBuilder private var status: some View {
        if !shortcuts.isEnabled {
            Text(L("已暂停")).foregroundStyle(Palette.muted)
        } else if shortcuts.recordingAction == action {
            Label(L("录入中"), systemImage: "keyboard").foregroundStyle(Palette.accent)
        } else if shortcuts.recordingAction != nil {
            Text(L("录入暂停")).foregroundStyle(Palette.muted)
        } else if inputError != nil || shortcuts.errors[action] != nil {
            Label(L("未生效"), systemImage: "exclamationmark.circle").foregroundStyle(.red)
        } else if shortcuts.bindings[action] == nil {
            Text(L("未设置")).foregroundStyle(Palette.muted)
        } else {
            Label(L("已启用"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Environment(\.consoleFontScale) private var fontScale
    let shortcuts: ShortcutManager
    let action: ShortcutAction
    let onError: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderControl {
        let view = ShortcutRecorderControl(shortcuts: shortcuts, action: action, onError: onError)
        view.fontScale = fontScale
        return view
    }

    func updateNSView(_ view: ShortcutRecorderControl, context: Context) {
        view.fontScale = fontScale
        view.onError = onError
        view.refresh()
    }

    static func dismantleNSView(_ view: ShortcutRecorderControl, coordinator: ()) {
        view.cancelRecording()
    }
}

final class ShortcutRecorderControl: NSView {
    let action: ShortcutAction
    private let shortcuts: ShortcutManager
    var onError: (String?) -> Void
    var fontScale: CGFloat = 1 {
        didSet {
            if fontScale != oldValue { needsDisplay = true }
        }
    }
    private var attemptedName: String?
    private var resignObserver: NSObjectProtocol?

    init(shortcuts: ShortcutManager, action: ShortcutAction, onError: @escaping (String?) -> Void) {
        self.shortcuts = shortcuts
        self.action = action
        self.onError = onError
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        shortcuts.beginRecording(action)
        attemptedName = nil
        onError(nil)
        refresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self { _ = becomeFirstResponder() }
        else { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard shortcuts.recordingAction == action else { return super.keyDown(with: event) }
        record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, shortcuts.recordingAction == action else { return false }
        record(event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            cancelRecording()
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func cancelRecording() {
        if shortcuts.recordingAction == action { shortcuts.endRecording() }
        attemptedName = nil
        refresh()
    }

    func refresh() {
        if shortcuts.recordingAction != action { attemptedName = nil }
        setAccessibilityLabel(L("\(action.title)快捷键"))
        setAccessibilityHelp(L("点击后按下快捷键；Esc 取消，Delete 清除"))
        setAccessibilityValue(displayedTitle)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let recording = shortcuts.recordingAction == action
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(Palette.background).setFill()
        shape.fill()
        NSColor(recording ? Palette.accent : Palette.line).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let title = displayedTitle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12 * fontScale, weight: .medium),
            .foregroundColor: recording || shortcuts.bindings[action] != nil ? NSColor(Palette.foreground) : NSColor(Palette.muted)
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            cancelRecording()
            onError(nil)
            window?.makeFirstResponder(nil)
            return
        }
        do {
            let shortcut: GlobalShortcut?
            if event.keyCode == 51 || event.keyCode == 117 {
                shortcut = nil
            } else {
                let candidate = try GlobalShortcut.from(event: event)
                shortcut = candidate
                attemptedName = candidate.displayName
            }
            try shortcuts.setShortcut(shortcut, for: action)
            onError(nil)
            shortcuts.endRecording()
            window?.makeFirstResponder(nil)
        } catch { onError(error.localizedDescription) }
        refresh()
    }

    private var displayedTitle: String {
        attemptedName ?? (shortcuts.recordingAction == action ? L("按下快捷键…") : shortcuts.bindings[action]?.displayName ?? L("点击设置"))
    }
}

struct ShortcutLabel: View {
    @ObservedObject var shortcuts: ShortcutManager
    let action: ShortcutAction

    var body: some View {
        Text(shortcuts.bindings[action]?.displayName ?? L("未设置"))
    }
}
