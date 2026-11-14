import AppKit
import HerdCore

/// Floating, non-activating completion list anchored to the editor caret.
/// The text view keeps first responder; this controller only draws the popup
/// and tells the editor which key events it consumed.
@MainActor
final class SQLCompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var textView: SQLTextView?
    var request: ((SQLCompletionContext, String) async -> [SQLCompletionItem])?

    private let panel: NSPanel
    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))

    private var items: [SQLCompletionItem] = []
    private var context: SQLCompletionContext?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isInserting = false

    private let rowHeight: CGFloat = 24
    private let panelWidth: CGFloat = 340

    init(textView: SQLTextView) {
        self.textView = textView
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .ignoresCycle]

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 9
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.frame = NSRect(x: 3, y: 4, width: panelWidth - 6, height: 192)
        scrollView.autoresizingMask = [.width, .height]

        column.width = panelWidth - 6
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.autoresizingMask = [.width]

        scrollView.documentView = tableView
        effectView.addSubview(scrollView)
        panel.contentView = effectView
    }

    deinit {
        task?.cancel()
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Requests

    func textDidChange() {
        guard !isInserting else { return }
        requestCompletions(explicit: false)
    }

    func selectionDidChange() {
        guard let textView else { return }
        if textView.selectedRange().length > 0 {
            close()
        } else if panel.isVisible {
            reposition()
        }
    }

    func endEditing() {
        close()
    }

    func requestCompletions(explicit: Bool) {
        guard let textView, textView.window != nil else {
            close()
            return
        }

        task?.cancel()

        let sql = textView.string
        let cursor = textView.selectedRange().location
        guard let context = SQLCompletionEngine.context(in: sql, at: cursor, allowEmptyPrefix: explicit) else {
            close()
            return
        }

        if !explicit, case .general = context.kind, context.prefix.count < 2 {
            close()
            return
        }

        guard let request else { return }

        generation += 1
        let requestID = generation
        task = Task { [weak self] in
            let items = await request(context, sql)
            guard !Task.isCancelled, let self, self.generation == requestID else { return }
            guard let textView = self.textView,
                  textView.string == sql,
                  textView.selectedRange().location == cursor else { return }

            if items.isEmpty {
                self.close()
            } else {
                self.show(items, context: context)
            }
        }
    }

    // MARK: - Panel

    private func show(_ items: [SQLCompletionItem], context: SQLCompletionContext) {
        self.items = items
        self.context = context
        let size = preferredSize
        effectView.frame = NSRect(origin: .zero, size: size)
        scrollView.frame = effectView.bounds.insetBy(dx: 3, dy: 4)
        column.width = scrollView.bounds.width
        tableView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width,
                                 height: CGFloat(items.count) * rowHeight)
        tableView.reloadData()

        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }

        if reposition() {
            panel.orderFrontRegardless()
        } else {
            close()
        }
    }

    private func close() {
        task?.cancel()
        task = nil
        generation += 1
        items = []
        context = nil
        panel.orderOut(nil)
    }

    private var preferredSize: NSSize {
        let rows = min(max(items.count, 1), 8)
        return NSSize(width: panelWidth, height: CGFloat(rows) * rowHeight + 8)
    }

    @discardableResult
    private func reposition() -> Bool {
        guard !items.isEmpty, let textView, let window = textView.window else { return false }

        let text = textView.string as NSString
        let length = text.length
        let caret = min(max(textView.selectedRange().location, 0), length)
        var anchor = textView.firstRect(
            forCharacterRange: NSRange(location: caret, length: 0),
            actualRange: nil
        )

        if anchor.isEmpty, caret > 0 {
            var previous = textView.firstRect(
                forCharacterRange: NSRange(location: caret - 1, length: 1),
                actualRange: nil
            )
            previous.origin.x = previous.maxX
            anchor = previous
        }
        let editorFrame = window.convertToScreen(textView.convert(textView.visibleRect, to: nil))
        if anchor.isEmpty || !editorFrame.insetBy(dx: -12, dy: -12).intersects(anchor),
           let layout = textView.layoutManager, let container = textView.textContainer {
            let glyph = min(layout.glyphIndexForCharacter(at: min(caret, max(0, length - 1))),
                            max(0, layout.numberOfGlyphs - 1))
            let local = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            var point = textView.convert(local, to: nil)
            point.origin.x = point.maxX
            anchor = window.convertToScreen(point)
        }
        guard !anchor.isEmpty else { return false }

        let size = preferredSize
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 2)

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchor.maxY + 2
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        return true
    }

    // MARK: - Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            return false
        }

        switch event.keyCode {
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 36, 48:
            insertSelected()
            return true
        case 53:
            close()
            return true
        case 123, 124:
            close()
            return false
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        var row = tableView.selectedRow
        if row < 0 { row = 0 }
        row = (row + delta + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func insertSelected() {
        guard
            let item = selectedItem,
            let context,
            let textView
        else {
            close()
            return
        }

        isInserting = true
        textView.insertText(item.insertText, replacementRange: context.replacementRange)
        if let caretOffset = item.caretOffset {
            let location = context.replacementRange.location + caretOffset
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }
        isInserting = false

        close()
        textView.window?.makeFirstResponder(textView)
    }

    private var selectedItem: SQLCompletionItem? {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return items.first }
        return items[row]
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        insertSelected()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? CompletionCellView)
            ?? CompletionCellView()
        cell.identifier = identifier
        cell.configure(items[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }
}

// MARK: - Cell

private final class CompletionCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyDown
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .tertiaryLabelColor

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    func configure(_ item: SQLCompletionItem) {
        iconView.image = Self.symbol(for: item.kind).image(solid: false)
        titleLabel.stringValue = item.title
        titleLabel.font = item.kind == .snippet
            ? .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            : .systemFont(ofSize: 11.5)

        let detail = item.detail ?? Self.label(for: item.kind)
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        needsLayout = true
        applyColors()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        iconView.frame = NSRect(x: 9, y: (height - 12) / 2, width: 12, height: 12)

        let detailWidth = detailLabel.isHidden
            ? 0
            : min(118, detailLabel.intrinsicContentSize.width + 2)
        detailLabel.frame = NSRect(
            x: bounds.width - detailWidth - 9,
            y: (height - 14) / 2,
            width: detailWidth,
            height: 14
        )
        titleLabel.frame = NSRect(
            x: 28,
            y: (height - 16) / 2,
            width: max(0, detailLabel.frame.minX - 36),
            height: 16
        )
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        titleLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        detailLabel.textColor = selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
            : .tertiaryLabelColor
    }

    private static func symbol(for kind: SQLCompletionKind) -> IconSymbol {
        switch kind {
        case .schema: .folder
        case .table: .table
        case .view: .view
        case .column: .dot
        case .snippet: .newQuery
        case .keyword: .dot
        }
    }

    private static func label(for kind: SQLCompletionKind) -> String {
        switch kind {
        case .schema: "schema"
        case .table: "tabela"
        case .view: "view"
        case .column: "coluna"
        case .snippet: "snippet"
        case .keyword: "palavra-chave"
        }
    }
}

private final class CompletionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
