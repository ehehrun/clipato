import AppKit
import Carbon
import Combine

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case captureRegion, pinLatest, toggleRecording, captureDisplay, fixedCapture, togglePinnedMousePassthrough

    var id: String { rawValue }
    var title: String {
        switch self {
        case .captureRegion: return L("截取区域")
        case .pinLatest: return L("贴出最近图片")
        case .toggleRecording: return L("开始 / 停止录屏")
        case .captureDisplay: return L("截取当前屏幕")
        case .fixedCapture: return L("固定区域连续截图")
        case .togglePinnedMousePassthrough: return L("贴图鼠标穿透")
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String

    init(keyCode: UInt32, modifiers: UInt32) throws {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard keyCode <= 127, modifiers & ~allowed == 0 else {
            throw shortcutError(L("快捷键包含无效键码或修饰键。"))
        }
        guard ![kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
                kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
                kVK_CapsLock, kVK_Function].contains(Int(keyCode)) else {
            throw shortcutError(L("请按下完整快捷键，不能只使用修饰键。"))
        }
        guard modifiers != 0 || Self.functionKeys[keyCode] != nil else {
            throw shortcutError(L("普通按键需要搭配 ⌘、⌥、⌃ 或 ⇧；F1–F20 可单独使用。"))
        }
        let label = try Self.keyName(keyCode)
        self.keyCode = keyCode
        self.modifiers = modifiers
        displayName = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + label
    }

    static func from(event: NSEvent) throws -> GlobalShortcut {
        guard event.type == .keyDown else { throw shortcutError(L("请按下需要绑定的快捷键。")) }
        var modifiers: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey),
                              (.control, controlKey), (.shift, shiftKey)] where event.modifierFlags.contains(flag) {
            modifiers |= UInt32(value)
        }
        return try GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(keyCode: values.decode(UInt32.self, forKey: .keyCode),
                      modifiers: values.decode(UInt32.self, forKey: .modifiers))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(keyCode, forKey: .keyCode)
        try values.encode(modifiers, forKey: .modifiers)
    }

    private static let functionKeys: [UInt32: String] = Dictionary(uniqueKeysWithValues:
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            .enumerated().map { (UInt32($0.element), "F\($0.offset + 1)") })

    private static func keyName(_ keyCode: UInt32) throws -> String {
        if let function = functionKeys[keyCode] { return function }
        let special: [Int: String] = [
            kVK_Escape: "⎋", kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↩",
            kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadClear: "Clear"
        ]
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw shortcutError(L("当前键盘布局不可用，无法显示此快捷键。"))
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &length, &characters)
        guard status == noErr, length > 0 else {
            throw shortcutError(L("当前键盘布局无法识别这个按键（系统错误 \(status)）。"), code: Int(status))
        }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: GlobalShortcut]
    @Published private(set) var errors: [ShortcutAction: String] = [:]
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var isEnabled: Bool

    private static let bindingsKey = "FrameVault.shortcuts"
    private static let fixedCaptureAddedKey = "FrameVault.fixedCaptureShortcutAdded"
    private static let enabledKey = "FrameVault.shortcutsEnabled"
    private static let signature: OSType = 0x46565348
    private let defaults: UserDefaults
    private var actions: [ShortcutAction: () -> Void] = [:]
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var hotKeyActions: [UInt32: ShortcutAction] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var generation: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        do {
            if let saved = defaults.object(forKey: Self.bindingsKey) {
                guard let data = saved as? Data else { throw shortcutError(L("已保存的快捷键不是有效配置数据。")) }
                bindings = try JSONDecoder().decode([ShortcutAction: GlobalShortcut].self, from: data)
                try Self.validateDuplicates(bindings)
                if !defaults.bool(forKey: Self.fixedCaptureAddedKey) {
                    let shortcut = try GlobalShortcut(keyCode: UInt32(kVK_F4), modifiers: 0)
                    if bindings[.fixedCapture] == nil, !bindings.values.contains(shortcut) {
                        bindings[.fixedCapture] = shortcut
                        defaults.set(try JSONEncoder().encode(bindings), forKey: Self.bindingsKey)
                    }
                }
            } else {
                bindings = try Self.defaultBindings()
            }
            defaults.set(true, forKey: Self.fixedCaptureAddedKey)
        } catch {
            bindings = [:]
            errors = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
                ($0, L("读取快捷键失败：\(error.localizedDescription)"))
            })
        }
    }

    func start(actions: [ShortcutAction: () -> Void]) {
        self.actions = actions
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            guard identifier.signature == ShortcutManager.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard let action = owner.hotKeyActions[identifier.id] else { return OSStatus(eventNotHandledErr) }
                let generation = owner.generation
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == generation, owner.isEnabled,
                          owner.recordingAction == nil else { return }
                    owner.actions[action]?()
                }
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            for action in bindings.keys { errors[action] = L("无法监听全局快捷键（系统错误 \(status)）。") }
            return
        }
        if isEnabled && recordingAction == nil { resumeRegistrations() }
    }

    func setShortcut(_ shortcut: GlobalShortcut?, for action: ShortcutAction) throws {
        if let shortcut, let conflict = ShortcutAction.allCases.first(where: {
            $0 != action && bindings[$0] == shortcut
        }) {
            throw shortcutError(L("\(shortcut.displayName) 已用于「\(conflict.title)」，请使用不同快捷键。"))
        }
        var updated = bindings
        updated[action] = shortcut
        try Self.validateDuplicates(updated)
        let data = try JSONEncoder().encode(updated)
        if shortcut == bindings[action] && references[action] != nil && isEnabled && recordingAction == nil {
            return
        }
        if handler != nil && isEnabled {
            generation &+= 1
            if let shortcut {
                let (reference, id) = try register(shortcut, for: action)
                if recordingAction != nil {
                    let status = UnregisterEventHotKey(reference)
                    guard status == noErr else { throw shortcutError(L("无法结束快捷键占用检查（系统错误 \(status)）。"), code: Int(status)) }
                } else {
                    if let previous = references[action] {
                        let status = UnregisterEventHotKey(previous)
                        if status != noErr {
                            let cleanup = UnregisterEventHotKey(reference)
                            throw shortcutError(L("无法替换原快捷键（系统错误 \(status)，新注册清理 \(cleanup)）。"), code: Int(status))
                        }
                    }
                    hotKeyActions = hotKeyActions.filter { $0.value != action }
                    references[action] = reference
                    hotKeyActions[id] = action
                }
            } else if let reference = references[action] {
                let status = UnregisterEventHotKey(reference)
                guard status == noErr else { throw shortcutError(L("无法清除快捷键（系统错误 \(status)）。"), code: Int(status)) }
                references[action] = nil
                hotKeyActions = hotKeyActions.filter { $0.value != action }
            }
        }
        bindings = updated
        defaults.set(data, forKey: Self.bindingsKey)
        errors[action] = nil
    }

    func beginRecording(_ action: ShortcutAction) {
        recordingAction = action
        pauseRegistrations()
    }

    func endRecording() {
        guard recordingAction != nil else { return }
        recordingAction = nil
        if isEnabled && handler != nil { resumeRegistrations() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled && recordingAction == nil && handler != nil { resumeRegistrations() }
        else { pauseRegistrations() }
    }

    func restoreDefaults() throws {
        let restored = try Self.defaultBindings()
        let data = try JSONEncoder().encode(restored)
        if isEnabled && handler != nil {
            pauseRegistrations()
            guard references.isEmpty else {
                if recordingAction == nil { resumeRegistrations() }
                throw shortcutError(L("原快捷键未能释放，无法恢复默认设置。"))
            }
            do {
                for action in ShortcutAction.allCases {
                    guard let shortcut = restored[action] else { continue }
                    let (reference, id) = try register(shortcut, for: action)
                    references[action] = reference
                    if recordingAction == nil { hotKeyActions[id] = action }
                }
            } catch {
                pauseRegistrations()
                if recordingAction == nil { resumeRegistrations() }
                throw error
            }
            if recordingAction != nil {
                pauseRegistrations()
                guard references.isEmpty else { throw shortcutError(L("默认快捷键未能释放，请结束录入后重试。")) }
            }
        }
        bindings = restored
        errors = [:]
        defaults.set(data, forKey: Self.bindingsKey)
    }

    private static func defaultBindings() throws -> [ShortcutAction: GlobalShortcut] {
        [.captureRegion: try GlobalShortcut(keyCode: UInt32(kVK_F1), modifiers: 0),
         .pinLatest: try GlobalShortcut(keyCode: UInt32(kVK_F2), modifiers: 0),
         .toggleRecording: try GlobalShortcut(keyCode: UInt32(kVK_F3), modifiers: 0),
         .fixedCapture: try GlobalShortcut(keyCode: UInt32(kVK_F4), modifiers: 0),
         .togglePinnedMousePassthrough: try GlobalShortcut(keyCode: UInt32(kVK_F5), modifiers: 0)]
    }

    private static func validateDuplicates(_ candidates: [ShortcutAction: GlobalShortcut]) throws {
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let binding = candidates[action] else { continue }
            for other in ShortcutAction.allCases.dropFirst(index + 1) where candidates[other] == binding {
                throw shortcutError(L("\(binding.displayName) 已用于「\(other.title)」，请使用不同快捷键。"))
            }
        }
    }

    private func register(_ shortcut: GlobalShortcut, for action: ShortcutAction) throws -> (EventHotKeyRef, UInt32) {
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: Self.signature, id: nextID),
                                        GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw shortcutError(L("\(shortcut.displayName) 被系统或其他应用占用，无法用于「\(action.title)」（系统错误 \(status)）。"), code: Int(status))
        }
        return (reference, nextID)
    }

    private func pauseRegistrations() {
        generation &+= 1
        hotKeyActions.removeAll()
        for (action, reference) in references {
            let status = UnregisterEventHotKey(reference)
            if status == noErr { references[action] = nil }
            else { errors[action] = L("无法暂停快捷键（系统错误 \(status)）。") }
        }
    }

    private func resumeRegistrations() {
        pauseRegistrations()
        for action in ShortcutAction.allCases {
            guard let shortcut = bindings[action], references[action] == nil else { continue }
            do {
                let (reference, id) = try register(shortcut, for: action)
                references[action] = reference
                hotKeyActions[id] = action
                errors[action] = nil
            } catch {
                errors[action] = error.localizedDescription
            }
        }
    }

    deinit {
        for reference in references.values {
            let status = UnregisterEventHotKey(reference)
            if status != noErr { NSLog("Clipato 快捷键释放失败：%d", status) }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status != noErr { NSLog("Clipato 快捷键监听释放失败：%d", status) }
        }
    }
}

private func shortcutError(_ message: String, code: Int = 1) -> NSError {
    NSError(domain: "Clipato.Shortcut", code: code, userInfo: [NSLocalizedDescriptionKey: message])
}
