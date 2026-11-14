import AppKit
import SwiftUI
import HerdCore

/// Editor SQL nativo (NSTextView/TextKit 1) com numeração de linhas e realce de sintaxe.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SQLTextView(frame: .zero)
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

        context.coordinator.highlightNow()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        if !coordinator.isEditing, textView.string != text {
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
        var isEditing = false

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            isEditing = true
            parent.text = textView.string
            highlightNow()
            ruler?.syncToText()
            isEditing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.selection = textView.selectedRange()
        }

        func highlightNow() {
            guard let textView else { return }
            SQLHighlight.apply(to: textView)
        }
    }
}

// MARK: - Text view behaviour

final class SQLTextView: NSTextView {
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

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)
        for token in SQLTokenizer.tokens(in: textView.string) {
            guard let color = colors[token.kind] else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
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

    /// Recomputes the line index and the gutter width. Called on every text change.
    func syncToText() {
        guard let string = textView?.string else { return }
        lineStarts = Self.computeLineStarts(in: string as NSString)

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
