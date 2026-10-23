import AppKit

class EscapeClosingWindow: NSWindow {
    var onSpace: (() -> Bool)?
    var onEscape: (() -> Bool)?
    private var handledSpace = false

    convenience init(contentRect: CGRect) {
        self.init(contentRect: contentRect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        collectionBehavior = [.primary, .managed, .participatesInCycle]
        tabbingMode = .disallowed
    }

    override func cancelOperation(_ sender: Any?) {
        // A sheet owns cancellation until its own controls finish or dismiss it.
        guard attachedSheet == nil else { return }
        if onEscape?() == true { return }
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onSpace {
            if !event.isARepeat { handledSpace = onSpace() }
            if handledSpace { return }
        }
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
