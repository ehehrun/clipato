import AppKit

final class AnnotationTextEditor: NSTextView, NSTextViewDelegate {
    private(set) var annotation: ImageAnnotation
    var onFinish: ((ImageAnnotation?) -> Void)?
    private let storage: NSTextStorage
    private let maximumHeight: CGFloat
    private var displayScale: CGFloat = 1
    private var displayOrigin = CGPoint.zero

    init(annotation: ImageAnnotation, maximumHeight: CGFloat) {
        self.annotation = annotation
        self.maximumHeight = maximumHeight
        let storage = NSTextStorage()
        self.storage = storage
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: annotation.textWidth, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        identifier = NSUserInterfaceItemIdentifier("annotation-text-input")
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = true
        backgroundColor = .black.withAlphaComponent(0.06)
        textContainerInset = .zero
        textContainer!.lineFragmentPadding = 0
        textContainer!.widthTracksTextView = false
        textContainer!.heightTracksTextView = false
        textContainer!.containerSize = CGSize(width: annotation.textWidth, height: .greatestFiniteMagnitude)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        string = annotation.text
        delegate = self
        wantsLayer = true
        layer!.borderWidth = 1
        layer!.borderColor = NSColor.systemBlue.cgColor
        applyStyle()
        updateLanguage()
        NotificationCenter.default.addObserver(self, selector: #selector(updateLanguage), name: .clipatoLanguageDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    @objc private func updateLanguage() {
        setAccessibilityLabel(L("标注文字，回车换行，Command 回车完成，Esc 取消"))
    }

    func place(at origin: CGPoint, scale: CGFloat) {
        displayOrigin = origin
        displayScale = scale
        updateSize()
    }

    func updateStyle(color: NSColor, fontSize: CGFloat) {
        annotation = ImageAnnotation(tool: .text, points: annotation.points, color: color, width: annotation.width,
                                     text: string, fontSize: fontSize, textWidth: annotation.textWidth)
        applyStyle()
        updateSize()
    }

    private func applyStyle() {
        font = NSFont.systemFont(ofSize: annotation.fontSize)
        textColor = annotation.color
        insertionPointColor = annotation.color
        typingAttributes = annotation.textAttributes
        textStorage!.addAttributes(annotation.textAttributes, range: NSRange(location: 0, length: textStorage!.length))
    }

    func textDidChange(_ notification: Notification) {
        annotation.text = string
        updateSize()
    }

    private func updateSize() {
        let container = textContainer!
        layoutManager!.ensureLayout(for: container)
        let height = min(maximumHeight, max(annotation.fontSize * 1.5, ceil(layoutManager!.usedRect(for: container).maxY)))
        let size = CGSize(width: annotation.textWidth, height: height)
        frame = CGRect(origin: displayOrigin, size: CGSize(width: size.width * displayScale, height: size.height * displayScale))
        bounds = CGRect(origin: .zero, size: size)
    }

    func finish(commit: Bool) {
        // Complete the current IME composition before reading the final plain text.
        if commit { unmarkText() }
        annotation.text = string
        let result = commit && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? annotation : nil
        let callback = onFinish
        onFinish = nil
        callback?(result)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            let range = markedRange()
            inputContext?.discardMarkedText()
            insertText("", replacementRange: range)
        } else {
            finish(commit: false)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command), !hasMarkedText() {
            finish(commit: true)
        } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 53 {
            cancelOperation(nil)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            // An IME owns Return while composing; leave that event on its normal input path.
            guard !hasMarkedText() else { return false }
            if event.modifierFlags.contains(.command) { finish(commit: true) }
            else { insertNewline(nil) }
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
