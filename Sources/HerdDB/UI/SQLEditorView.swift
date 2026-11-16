import AppKit
import SwiftUI
import HerdCore

/// Editor SQL nativo (NSTextView/TextKit 1) com numeração de linhas e realce de sintaxe.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var dialect: SQLDialect
    var onReady: (SQLTextView) -> Void
    var completions: @MainActor (SQLCompletionContext, String) async -> [SQLCompletionItem]

    init(
        text: Binding<String>,
        selection: Binding<NSRange>,
        dialect: SQLDialect = .postgres,
        onReady: @escaping (SQLTextView) -> Void = { _ in },
        completions: @escaping @MainActor (SQLCompletionContext, String) async -> [SQLCompletionItem] = { _, _ in [] }
    ) {
        self._text = text
        self._selection = selection
        self.dialect = dialect
        self.onReady = onReady
        self.completions = completions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(frame: .zero)
        textView.dialect = dialect
        configure(textView)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let ruler = SQLLineNumberRuler(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        let completionController = SQLCompletionController(textView: textView)
        completionController.request = { [weak coordinator = context.coordinator] context, sql in
            guard let coordinator else { return [] }
            return await coordinator.parent.completions(context, sql)
        }
        textView.completionController = completionController
        context.coordinator.completionController = completionController

        context.coordinator.highlightNow()
        onReady(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.dialect = dialect

        if !coordinator.isEditing, textView.string != text {
            // The text came from outside the editor (tab switch, clear, format),
            // so any popup anchored to the old content is stale.
            coordinator.completionController?.endEditing()
            textView.string = text
            coordinator.highlightNow()
            coordinator.ruler?.syncToText()
        }

        if !coordinator.isEditing, !NSEqualRanges(textView.selectedRange(), selection) {
            let length = (textView.string as NSString).length
            let location = min(max(selection.location, 0), length)
            let limit = max(0, length - location)
            textView.setSelectedRange(NSRange(location: location, length: min(max(selection.length, 0), limit)))
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // The popup is a separate window: it survives the editor being removed
        // unless it is closed explicitly (for example when switching tabs).
        coordinator.completionController?.endEditing()
        coordinator.completionController = nil
    }

    private func configure(_ textView: SQLTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.font = SQLHighlight.font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 9)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = SQLHighlight.baseAttributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        weak var ruler: SQLLineNumberRuler?
        var completionController: SQLCompletionController?
        var isEditing = false
        private var pendingEditLocation: Int?
        private var highlightTask: Task<Void, Never>?
        private var highlightGeneration = 0

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            pendingEditLocation = min(pendingEditLocation ?? affectedCharRange.location, affectedCharRange.location)
            ruler?.applyEdit(in: affectedCharRange, replacement: replacementString ?? "")
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            parent.text = textView.string
            scheduleHighlight(from: pendingEditLocation ?? 0)
            pendingEditLocation = nil
            isEditing = false
            completionController?.textDidChange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.selection = textView.selectedRange()
            completionController?.selectionDidChange()
        }

        func textDidEndEditing(_ notification: Notification) {
            completionController?.endEditing()
        }

        func highlightNow() {
            guard let textView else { return }
            highlightGeneration += 1
            highlightTask?.cancel()
            SQLHighlight.apply(SQLTokenizer.tokens(in: textView.string), to: textView)
        }

        private func scheduleHighlight(from editLocation: Int) {
            guard let textView else { return }
            let snapshot = textView.string
            let ns = snapshot as NSString
            let location = min(max(editLocation, 0), ns.length)
            let start = ns.lineRange(for: NSRange(location: location, length: 0)).location
            let range = NSRange(location: start, length: ns.length - start)

            highlightGeneration += 1
            let generation = highlightGeneration
            highlightTask?.cancel()
            highlightTask = Task { [weak self, weak textView] in
                let tokens = await Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return [SQLToken]() }
                    return SQLTokenizer.tokens(in: snapshot)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      self.highlightGeneration == generation,
                      textView.string == snapshot else { return }
                SQLHighlight.apply(tokens, to: textView, in: range)
            }
        }
    }
}

// MARK: - Text view behaviour

final class SQLTextView: NSTextView {
    weak var completionController: SQLCompletionController?
    var dialect: SQLDialect = .postgres

    enum Action {
        case find, replace, goToLine, indent, unindent, comment, toggleCase, clear, format
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (tab switch, editor rebuilt) must take the popup
        // with it, since the popup lives in its own window.
        if window == nil {
            completionController?.endEditing()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking in the text means the user is done with the suggestions.
        completionController?.endEditing()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Desfazer", #selector(undoSQL), key: "z", enabled: undoManager?.canUndo == true)
        add("Refazer", #selector(redoSQL), key: "z", modifiers: [.command, .shift], enabled: undoManager?.canRedo == true)
        menu.addItem(.separator())
        add("Recortar", #selector(cut(_:)), key: "x", enabled: selectedRange().length > 0)
        add("Copiar", #selector(copy(_:)), key: "c", enabled: selectedRange().length > 0)
        add("Colar", #selector(paste(_:)), key: "v", enabled: NSPasteboard.general.canReadItem(withDataConformingToTypes: ["public.utf8-plain-text", "public.plain-text"]))
        add("Selecionar Tudo", #selector(selectAll(_:)), key: "a")
        menu.addItem(.separator())
        add("Buscar", #selector(findSQL), key: "f")
        add("Substituir", #selector(replaceSQL), key: "f", modifiers: [.command, .option])
        add("Ir para linha/coluna…", #selector(goToLineSQL), key: "g", modifiers: [.control])
        menu.addItem(.separator())
        add("Indentar seleção", #selector(indentSQL), key: "]")
        add("Remover indentação", #selector(unindentSQL), key: "[")
        add("Comentar/descomentar", #selector(commentSQL), key: "/")
        add("Alternar maiúsculas/minúsculas", #selector(toggleCaseSQL), key: "u", modifiers: [.control, .shift], enabled: selectedRange().length > 0)
        add("Limpar consulta", #selector(clearSQL), enabled: !string.isEmpty)
        menu.addItem(.separator())
        add("Formatar SQL", #selector(formatSQL), key: "f", modifiers: [.option, .shift], enabled: !string.isEmpty)
        return menu
    }

    @objc private func undoSQL() { undoManager?.undo() }
    @objc private func redoSQL() { undoManager?.redo() }

    func perform(_ action: Action) {
        switch action {
        case .find: findSQL()
        case .replace: replaceSQL()
        case .goToLine: goToLineSQL()
        case .indent: indentSQL()
        case .unindent: unindentSQL()
        case .comment: commentSQL()
        case .toggleCase: toggleCaseSQL()
        case .clear: clearSQL()
        case .format: formatSQL()
        }
    }

    @objc private func findSQL() {
        let item = NSMenuItem()
        item.tag = 1
        performTextFinderAction(item)
    }

    @objc private func replaceSQL() {
        let item = NSMenuItem()
        item.tag = 12
        performTextFinderAction(item)
    }

    @objc private func goToLineSQL() {
        let alert = NSAlert()
        alert.messageText = "Ir para linha/coluna"
        alert.addButton(withTitle: "Ir")
        alert.addButton(withTitle: "Cancelar")
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.spacing = 8
        let lineField = NSTextField(string: "1")
        lineField.placeholderString = "Linha"
        let columnField = NSTextField(string: "1")
        columnField.placeholderString = "Coluna"
        fields.addArrangedSubview(lineField)
        fields.addArrangedSubview(columnField)
        fields.frame = NSRect(x: 0, y: 0, width: 240, height: 56)
        alert.accessoryView = fields
        guard alert.runModal() == .alertFirstButtonReturn,
              let requestedLine = Int(lineField.stringValue), requestedLine > 0,
              let requestedColumn = Int(columnField.stringValue), requestedColumn > 0 else { return }
        let source = string as NSString
        var position = 0
        var currentLine = 1
        while currentLine < requestedLine && position < source.length {
            let line = source.lineRange(for: NSRange(location: position, length: 0))
            position = NSMaxRange(line)
            currentLine += 1
        }
        let line = source.lineRange(for: NSRange(location: min(position, source.length), length: 0))
        let lineEnd = line.location + (source.substring(with: line).trimmingCharacters(in: .newlines) as NSString).length
        let destination = min(line.location + requestedColumn - 1, lineEnd)
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: destination, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    @objc private func indentSQL() { transformLines { "    " + $0 } }
    @objc private func unindentSQL() {
        transformLines { line in
            if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return line
        }
    }
    @objc private func commentSQL() {
        let source = string as NSString
        let range = source.lineRange(for: selectedRange())
        let lines = source.substring(with: range).components(separatedBy: "\n")
        let active = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !active.isEmpty && active.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        transformLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if remove, let mark = line.range(of: "--") {
                var result = line
                result.removeSubrange(mark)
                return result
            }
            return "-- " + line
        }
    }
    @objc private func toggleCaseSQL() {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let value = (string as NSString).substring(with: range)
        let changed = value == value.uppercased() ? value.lowercased() : value.uppercased()
        replace(range, with: changed, selectReplacement: true)
    }
    @objc private func clearSQL() {
        replace(NSRange(location: 0, length: (string as NSString).length), with: "")
    }
    @objc private func formatSQL() {
        let selected = selectedRange()
        let range = selected.length > 0 ? selected : NSRange(location: 0, length: (string as NSString).length)
        guard range.length > 0 else { return }
        let source = (string as NSString).substring(with: range)
        let formatted = SQLFormatter.format(source, dialect: dialect)
        replace(range, with: formatted, selectReplacement: selected.length > 0)
    }

    private func transformLines(_ transform: (String) -> String) {
        let range = (string as NSString).lineRange(for: selectedRange())
        let source = (string as NSString).substring(with: range)
        let result = source.components(separatedBy: "\n").map(transform).joined(separator: "\n")
        replace(range, with: result, selectReplacement: selectedRange().length > 0)
    }

    private func replace(_ range: NSRange, with replacement: String, selectReplacement: Bool = false) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        let location = range.location + (selectReplacement ? 0 : (replacement as NSString).length)
        let length = selectReplacement ? (replacement as NSString).length : 0
        setSelectedRange(NSRange(location: location, length: length))
        scrollRangeToVisible(selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !modifiers.contains(.command),
           !modifiers.contains(.option),
           !modifiers.contains(.control),
           !hasMarkedText(),
           let quote = quoteCharacter(for: event, modifiers: modifiers) {
            handleQuoteKey(quote)
            return
        }

        if let completionController {
            if event.keyCode == 49, modifiers.contains(.control) || modifiers.contains(.option) {
                completionController.requestCompletions(explicit: true)
                return
            }
            if event.keyCode == 96,
               !modifiers.contains(.command),
               !modifiers.contains(.option),
               !modifiers.contains(.control) {
                completionController.requestCompletions(explicit: true)
                return
            }
            if completionController.handleKey(event) {
                return
            }
        }
        if event.keyCode == 48 {
            if modifiers.contains(.shift) {
                unindentSQL()
                return
            }
            if modifiers.isEmpty && selectedRange().length > 0 {
                indentSQL()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Some keyboard layouts (including Brazilian Pro) expose the quote key as a
    /// dead key, so AppKit reports an empty `characters` value. SQL needs the
    /// literal ASCII quote immediately instead of waiting for text composition.
    /// Inside strings and comments the dead key is preserved so accented text
    /// (`é`, `á`, `ü`…) can still be typed.
    private func quoteCharacter(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Character? {
        if let typed = event.characters,
           typed == "'" || typed == "\"" {
            return typed.first
        }

        guard event.keyCode == 39,
              event.characters?.isEmpty != false,
              !isInsideLiteralOrComment(at: selectedRange().location)
        else { return nil }
        return modifiers.contains(.shift) ? "\"" : "'"
    }

    /// Inserts `'` or `"` as a pair, steps over an existing closing quote,
    /// wraps a selection and leaves the caret between the new quotes.
    private func handleQuoteKey(_ quote: Character) {
        let ns = string as NSString
        let selection = selectedRange()
        let location = min(max(selection.location, 0), ns.length)
        let unit = quote.utf16.first ?? 0

        if selection.length > 0 {
            let selected = ns.substring(with: selection)
            insertText("\(quote)\(selected)\(quote)", replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1, length: (selected as NSString).length))
            scrollRangeToVisible(selectedRange())
            return
        }

        // A closing quote already sits at the caret: step over it.
        if location < ns.length, ns.character(at: location) == unit {
            setSelectedRange(NSRange(location: location + 1, length: 0))
            return
        }

        let emptyRange = NSRange(location: location, length: 0)

        // Inside a string or comment a quote is plain text.
        if isInsideLiteralOrComment(at: location) {
            insertText(String(quote), replacementRange: emptyRange)
            return
        }

        // Never pair in the middle of a word.
        if location < ns.length, isWordUnit(ns.character(at: location)) {
            insertText(String(quote), replacementRange: emptyRange)
            return
        }

        insertText("\(quote)\(quote)", replacementRange: emptyRange)
        setSelectedRange(NSRange(location: location + 1, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// True when the caret is inside an open string, quoted identifier or comment,
    /// where adding a closing quote would be wrong.
    private func isInsideLiteralOrComment(at location: Int) -> Bool {
        SQLTokenizer.isInsideLiteralOrComment(string, at: location)
    }

    private func isWordUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
            || (0x41...0x5A).contains(unit)
            || (0x61...0x7A).contains(unit)
            || unit == 0x5F
            || unit == 0x24
            || unit >= 0x80
    }

    /// Tab insere quatro espaços, como o resto das ferramentas SQL.
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    /// Mantém a indentação da linha atual ao quebrar linha.
    override func insertNewline(_ sender: Any?) {
        let string = self.string as NSString
        let location = min(selectedRange().location, string.length)
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        let prefix = string.substring(with: NSRange(location: line.location, length: max(0, location - line.location)))
        let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indent, replacementRange: selectedRange())
    }
}

// MARK: - Syntax highlighting

@MainActor
enum SQLHighlight {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }()

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
    ]

    private static let colors: [SQLTokenKind: NSColor] = [
        .keyword: dynamic(light: rgb(33, 79, 143), dark: rgb(125, 181, 245)),
        .string: dynamic(light: rgb(41, 115, 51), dark: rgb(140, 212, 151)),
        .number: dynamic(light: rgb(140, 61, 158), dark: rgb(217, 166, 232)),
        .comment: dynamic(light: rgb(117, 117, 122), dark: rgb(148, 148, 153)),
        .quotedIdentifier: dynamic(light: rgb(133, 87, 13), dark: rgb(224, 179, 114)),
        .parameter: dynamic(light: rgb(166, 79, 13), dark: rgb(242, 166, 102)),
    ]

    static func apply(
        _ tokens: [SQLToken],
        to textView: NSTextView,
        in requestedRange: NSRange? = nil
    ) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        let range = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        for token in tokens {
            guard let color = colors[token.kind] else { continue }
            let tokenRange = NSIntersectionRange(token.range, range)
            guard tokenRange.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: tokenRange)
        }
        storage.endEditing()

        textView.typingAttributes = baseAttributes
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Line numbers

final class SQLLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private var lineStarts: [Int] = [0]
    private let minimumThickness: CGFloat = 36

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = minimumThickness
        syncToText()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Recomputes the complete line index for initial/external text replacement.
    func syncToText() {
        guard let string = textView?.string else { return }
        lineStarts = Self.computeLineStarts(in: string as NSString)
        updateThicknessAndDisplay()
    }

    /// Updates line offsets from the pending text edit without rescanning the
    /// complete document. Called before NSTextView applies the replacement.
    func applyEdit(in range: NSRange, replacement: String) {
        let oldEnd = NSMaxRange(range)
        let replacementLength = (replacement as NSString).length
        let delta = replacementLength - range.length

        var updated = lineStarts.filter { $0 <= range.location || $0 > oldEnd }
        for index in updated.indices where updated[index] > oldEnd {
            updated[index] += delta
        }

        let replacementStarts = Self.computeLineStarts(in: replacement as NSString).dropFirst()
        updated.append(contentsOf: replacementStarts.map { range.location + $0 })
        lineStarts = Array(Set(updated)).sorted()
        if lineStarts.first != 0 { lineStarts.insert(0, at: 0) }
        updateThicknessAndDisplay()
    }

    private func updateThicknessAndDisplay() {
        let digits = String(lineStarts.count).count
        let thickness = max(minimumThickness, CGFloat(12 + digits * 7))
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
            scrollView?.tile()
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        let separator = NSRect(x: ruleThickness - 0.5, y: bounds.minY, width: 0.5, height: bounds.height)
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        separator.fill()

        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let scrollView,
            !lineStarts.isEmpty
        else { return }

        let visible = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let string = textView.string as NSString

        let topPoint = NSPoint(x: 0, y: visible.minY - inset)
        let topCharacter = layoutManager.characterIndex(
            for: topPoint,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let firstLine = max(0, (lineStarts.lastIndex { $0 <= topCharacter } ?? 0) - 1)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        for lineIndex in firstLine..<lineStarts.count {
            let start = lineStarts[lineIndex]
            let lineRange = string.lineRange(for: NSRange(location: start, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)

            let fragment: NSRect
            if glyphRange.length == 0 {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty { continue }
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            }

            let y = fragment.minY + inset - visible.minY
            if y > bounds.maxY { break }
            guard y + fragment.height >= bounds.minY else { continue }

            let number = "\(lineIndex + 1)" as NSString
            let size = number.size(withAttributes: attributes)
            let origin = NSPoint(
                x: ruleThickness - size.width - 8,
                y: y + (fragment.height - size.height) / 2
            )
            number.draw(at: origin, withAttributes: attributes)
        }
    }

    private static func computeLineStarts(in string: NSString) -> [Int] {
        let length = string.length
        var starts = [0]
        var index = 0

        while index < length {
            let line = string.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(line)
            if next <= index { break }
            index = next
            if index < length || (length > 0 && string.character(at: length - 1) == 0x0A) {
                starts.append(index)
            }
        }

        return starts
    }
}
