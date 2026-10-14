import AppKit
import SwiftUI

/// Lets the query tab read and drive its editor.
final class EditorHandle {
    weak var textView: SQLTextView?

    var text: String { textView?.string ?? "" }

    /// The selection if there is one, otherwise the whole script.
    func runnableText() -> String {
        guard let tv = textView else { return "" }
        let sel = tv.selectedRange()
        return sel.length > 0 ? (tv.string as NSString).substring(with: sel) : tv.string
    }

    /// The statement under the cursor, delimited by `;`.
    func currentStatement() -> String {
        guard let tv = textView else { return "" }
        let doc = tv.string as NSString
        let pos = tv.selectedRange().location
        let before = doc.range(of: ";", options: .backwards, range: NSRange(location: 0, length: pos))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = doc.range(of: ";", range: NSRange(location: pos, length: doc.length - pos))
        let end = after.location == NSNotFound ? doc.length : after.location
        return doc.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

struct SQLEditorView: NSViewRepresentable {
    let initialText: String
    var schema: [String: [String]]
    var placeholder = "在此输入 SQL…"
    let handle: EditorHandle

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = SQLTextView.make()
        tv.placeholder = placeholder
        tv.schema = schema
        tv.setText(initialText)
        handle.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? SQLTextView)?.schema = schema
    }
}

final class SQLTextView: NSTextView {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    var placeholder = ""
    /// table → columns, for completion
    var schema: [String: [String]] = [:]
    private let popup = CompletionPopup()
    private var completionRange = NSRange(location: 0, length: 0)
    private var highlightPending = false
    private var ruler: LineNumberRuler?

    static func make() -> (NSScrollView, SQLTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let tv = SQLTextView(frame: .zero, textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width, .height]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.font = font
        tv.textColor = .textColor
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let ruler = LineNumberRuler(textView: tv, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.ruler = ruler
        return (scroll, tv)
    }

    func setText(_ s: String) {
        string = s
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
        textDidReplace()
    }

    private func textDidReplace() {
        ruler?.textChanged()
        highlightNow()
    }

    override func didChangeText() {
        super.didChangeText()
        ruler?.textChanged()
        scheduleHighlight()
    }

    // MARK: Highlighting (temporary attributes: not part of the text or undo)

    private func scheduleHighlight() {
        if (string as NSString).length < 20_000 {
            highlightNow()
            return
        }
        guard !highlightPending else { return }
        highlightPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.highlightPending = false
            self?.highlightNow()
        }
    }

    private func highlightNow() {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        SQLSyntax.highlight(string) { range, color in
            lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
        }
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: Self.font, .foregroundColor: NSColor.placeholderTextColor])
    }

    // MARK: Completion

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if s.count == 1, let c = s.unicodeScalars.first, SQLSyntax.isIdentifier(c) || c == "." {
            updateCompletions(opening: true)
        } else {
            popup.hide()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        if popup.isVisible { updateCompletions(opening: false) }
    }

    override func keyDown(with event: NSEvent) {
        if popup.isVisible {
            switch event.keyCode {
            case 125: popup.move(1); return // down
            case 126: popup.move(-1); return // up
            case 36, 76, 48: acceptCompletion(); return // return, enter, tab
            case 53: popup.hide(); return // escape
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        popup.hide()
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        popup.hide()
        return super.resignFirstResponder()
    }

    private func updateCompletions(opening: Bool) {
        guard selectedRange().length == 0 else { return popup.hide() }
        let ns = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0, let c = Unicode.Scalar(ns.character(at: start - 1)), SQLSyntax.isIdentifier(c) {
            start -= 1
        }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        var qualifier: String?
        if start > 0 && ns.character(at: start - 1) == 0x2E { // "."
            var qEnd = start - 1
            var qStart = qEnd
            if qEnd > 0 && ns.character(at: qEnd - 1) == 0x60 { // `name`.
                qEnd -= 1
                qStart = qEnd
                while qStart > 0 && ns.character(at: qStart - 1) != 0x60 { qStart -= 1 }
                qualifier = ns.substring(with: NSRange(location: qStart, length: qEnd - qStart))
            } else {
                while qStart > 0, let c = Unicode.Scalar(ns.character(at: qStart - 1)), SQLSyntax.isIdentifier(c) {
                    qStart -= 1
                }
                qualifier = ns.substring(with: NSRange(location: qStart, length: qEnd - qStart))
            }
        }
        if qualifier == nil && prefix.isEmpty { return popup.hide() }
        if !opening && !popup.isVisible { return }

        let items = SQLSyntax.completions(prefix: prefix, qualifier: qualifier, schema: schema,
                                          statement: statementAround(caret))
        guard !items.isEmpty, !(items.count == 1 && items[0].text == prefix) else { return popup.hide() }
        completionRange = NSRange(location: start, length: caret - start)
        guard let window else { return }
        let rect = firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
        popup.show(items, below: rect, parent: window) { [weak self] in self?.acceptCompletion() }
    }

    private func acceptCompletion() {
        guard let item = popup.selected else { return popup.hide() }
        popup.hide()
        let text = SQLSyntax.needsQuoting(item.text) && item.kind != .keyword ? "`\(item.text)`" : item.text
        if shouldChangeText(in: completionRange, replacementString: text) {
            textStorage?.replaceCharacters(in: completionRange, with: text)
            didChangeText()
            setSelectedRange(NSRange(location: completionRange.location + (text as NSString).length, length: 0))
        }
    }

    /// Text of the statement around `pos`, for alias and table lookups.
    private func statementAround(_ pos: Int) -> String {
        let doc = string as NSString
        let before = doc.range(of: ";", options: .backwards, range: NSRange(location: 0, length: pos))
        let start = before.location == NSNotFound ? 0 : before.location + 1
        let after = doc.range(of: ";", range: NSRange(location: pos, length: doc.length - pos))
        let end = after.location == NSNotFound ? doc.length : after.location
        return doc.substring(with: NSRange(location: start, length: end - start))
    }
}

// MARK: - Syntax: highlighting and completion candidates

enum SQLSyntax {
    static let keywords = """
        SELECT FROM WHERE AND OR NOT IN IS NULL LIKE REGEXP BETWEEN EXISTS INSERT INTO VALUES UPDATE SET \
        DELETE CREATE ALTER DROP TABLE DATABASE SCHEMA INDEX VIEW PRIMARY KEY FOREIGN REFERENCES UNIQUE \
        DEFAULT AUTO_INCREMENT JOIN INNER LEFT RIGHT OUTER CROSS NATURAL ON USING GROUP BY ORDER HAVING \
        LIMIT OFFSET AS DISTINCT UNION ALL CASE WHEN THEN ELSE END ASC DESC SHOW DESCRIBE EXPLAIN \
        USE BEGIN COMMIT ROLLBACK START TRANSACTION TRUNCATE RENAME IF WITH RECURSIVE CALL PROCEDURE \
        FUNCTION TRIGGER RETURNS RETURN DECLARE DELIMITER ENGINE CHARSET CHARACTER COLLATE COMMENT \
        CONSTRAINT CHECK REPLACE IGNORE DUPLICATE TRUE FALSE INT INTEGER BIGINT SMALLINT TINYINT \
        MEDIUMINT DECIMAL NUMERIC FLOAT DOUBLE VARCHAR CHAR TEXT TINYTEXT MEDIUMTEXT LONGTEXT BLOB \
        LONGBLOB BINARY VARBINARY DATE DATETIME TIMESTAMP TIME YEAR JSON BOOLEAN BOOL ENUM UNSIGNED \
        ZEROFILL COLUMN ADD MODIFY CHANGE FIRST AFTER KILL QUERY GRANT REVOKE PROCESSLIST VARIABLES STATUS \
        COUNT SUM AVG MIN MAX CONCAT IFNULL COALESCE NOW CURRENT_TIMESTAMP SUBSTRING LENGTH LOWER UPPER \
        DATE_FORMAT FOR SHARE LOCK OVER PARTITION ROWS WINDOW
        """.split(separator: " ").map(String.init)

    private static let pattern = try! NSRegularExpression(
        pattern: [
            #"(?<comment>--[^\n]*|#[^\n]*|/\*[\s\S]*?(?:\*/|$))"#,
            #"(?<string>'(?:[^'\\]|\\.)*'?|"(?:[^"\\]|\\.)*"?)"#,
            #"(?<ident>`[^`]*`?)"#,
            #"(?<number>\b\d+(?:\.\d+)?\b)"#,
            #"(?<keyword>\b(?:"# + keywords.joined(separator: "|") + #")\b)"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    private static let styles: [(group: String, color: NSColor)] = [
        ("comment", .systemGreen),
        ("string", .systemRed),
        ("ident", .systemTeal),
        ("number", .systemOrange),
        ("keyword", .systemPurple),
    ]

    /// One alternation, so the leftmost token wins (a keyword inside a string stays a string).
    static func highlight(_ text: String, _ apply: (NSRange, NSColor) -> Void) {
        let full = NSRange(location: 0, length: (text as NSString).length)
        pattern.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            for s in styles {
                let r = m.range(withName: s.group)
                if r.location != NSNotFound {
                    apply(r, s.color)
                    return
                }
            }
        }
    }

    static func isIdentifier(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c == "$" || c.properties.isAlphabetic || ("0"..."9").contains(c)
    }

    static func needsQuoting(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_$]*/) == nil
    }

    struct Item: Equatable {
        enum Kind { case column, table, keyword }
        let text: String
        let kind: Kind
    }

    private static let tableRef = try! NSRegularExpression(
        pattern: #"(?:FROM|JOIN|UPDATE|INTO)\s+(?:`?[\w$]+`?\.)?`?([\w$]+)`?(?:\s+(?:AS\s+)?`?([\w$]+)`?)?"#,
        options: [.caseInsensitive]
    )

    /// Tables referenced in a statement: alias (or name) → table name.
    static func referencedTables(_ statement: String, schema: [String: [String]]) -> [String: String] {
        var out: [String: String] = [:]
        let ns = statement as NSString
        for m in tableRef.matches(in: statement, range: NSRange(location: 0, length: ns.length)) {
            let table = ns.substring(with: m.range(at: 1))
            guard let real = schema.keys.first(where: { $0.caseInsensitiveCompare(table) == .orderedSame }) else { continue }
            out[real.lowercased()] = real
            if m.range(at: 2).location != NSNotFound {
                let alias = ns.substring(with: m.range(at: 2))
                if !keywords.contains(alias.uppercased()) { out[alias.lowercased()] = real }
            }
        }
        return out
    }

    static func completions(prefix: String, qualifier: String?, schema: [String: [String]], statement: String) -> [Item] {
        let p = prefix.lowercased()
        var items: [Item] = []
        if let qualifier {
            let refs = referencedTables(statement, schema: schema)
            let table = refs[qualifier.lowercased()]
                ?? schema.keys.first { $0.caseInsensitiveCompare(qualifier) == .orderedSame }
            for c in table.flatMap({ schema[$0] }) ?? [] where c.lowercased().hasPrefix(p) {
                items.append(Item(text: c, kind: .column))
            }
            return items
        }
        let refs = referencedTables(statement, schema: schema)
        var seen = Set<String>()
        for t in Set(refs.values).sorted() {
            for c in schema[t] ?? [] where c.lowercased().hasPrefix(p) && seen.insert(c).inserted {
                items.append(Item(text: c, kind: .column))
            }
        }
        for t in schema.keys.sorted() where t.lowercased().hasPrefix(p) {
            items.append(Item(text: t, kind: .table))
        }
        for k in keywords where k.lowercased().hasPrefix(p) {
            items.append(Item(text: k, kind: .keyword))
        }
        // exact-case prefix matches first, keep kind order otherwise
        let exact = items.filter { $0.text.hasPrefix(prefix) }
        let rest = items.filter { !$0.text.hasPrefix(prefix) }
        return Array((exact + rest).prefix(60))
    }
}

// MARK: - Completion popup

final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var panel: NSPanel?
    private let table = NSTableView()
    private var items: [SQLSyntax.Item] = []
    private var onAccept: (() -> Void)?
    private let rowHeight: CGFloat = 20

    var isVisible: Bool { panel?.isVisible ?? false }

    var selected: SQLSyntax.Item? {
        let r = table.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        let col = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        scroll.frame = effect.bounds
        scroll.autoresizingMask = [.width, .height]
        effect.addSubview(scroll)
        p.contentView = effect
        return p
    }

    func show(_ items: [SQLSyntax.Item], below caret: NSRect, parent: NSWindow, onAccept: @escaping () -> Void) {
        let p = panel ?? makePanel()
        panel = p
        self.items = items
        self.onAccept = onAccept
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let height = CGFloat(min(items.count, 10)) * rowHeight + 4
        p.setFrame(NSRect(x: caret.minX - 6, y: caret.minY - height - 2, width: 300, height: height), display: true)
        if p.parent == nil { parent.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    func move(_ delta: Int) {
        let r = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func clicked() {
        if table.clickedRow >= 0 { onAccept?() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.reuseID, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.item = items[row]
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("CompletionCell")
    var item: SQLSyntax.Item? {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized
        let (tag, tint): (String, NSColor) = switch item.kind {
        case .column: ("列", .systemBlue)
        case .table: ("表", .systemOrange)
        case .keyword: ("关键字", .systemPurple)
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let y = (bounds.height - 15) / 2
        (item.text as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: [
            .font: font, .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ])
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : tint,
        ]
        let w = (tag as NSString).size(withAttributes: tagAttrs).width
        (tag as NSString).draw(at: NSPoint(x: bounds.width - w - 10, y: y + 1), withAttributes: tagAttrs)
    }
}

// MARK: - Line numbers

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// UTF-16 offsets where lines start
    private var lineStarts: [Int] = [0]
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func redraw() {
        needsDisplay = true
    }

    func textChanged() {
        guard let s = textView?.string.utf16 else { return }
        var starts = [0]
        var i = 0
        for u in s {
            i += 1
            if u == 10 { starts.append(i) }
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let thickness = CGFloat(digits) * 7.5 + 16
        if abs(thickness - ruleThickness) > 0.5 { ruleThickness = thickness }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let length = (tv.string as NSString).length
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // first visible line: last line start <= chars.location
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= chars.location { lo = mid } else { hi = mid - 1 }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let offset = convert(NSPoint.zero, from: tv).y + tv.textContainerInset.height
        for line in lo..<lineStarts.count {
            let start = lineStarts[line]
            if start > NSMaxRange(chars) { break }
            // the empty line after a trailing newline (or an empty text) has no glyphs
            let frag = start >= length
                ? lm.extraLineFragmentRect
                : lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attrs)
            let y = frag.minY + offset + (frag.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
        }
    }
}
