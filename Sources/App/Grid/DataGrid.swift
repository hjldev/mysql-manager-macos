import AppKit
import MySQLKit
import SwiftUI

enum GridValue: Equatable {
    case text(String)
    case null
    /// column default (new rows only)
    case unset

    init(_ s: String?) {
        self = s.map { .text($0) } ?? .null
    }

    var string: String? {
        if case let .text(s) = self { s } else { nil }
    }
}

enum RowState { case normal, new, deleted }

/// What a grid shows. Row and column indexes are in display order.
@MainActor
protocol GridSource: AnyObject {
    var gridColumns: [QueryColumn] { get }
    var rowCount: Int { get }
    var isEditable: Bool { get }
    var sortColumn: Int? { get }
    var sortAscending: Bool { get }
    func value(row: Int, column: Int) -> GridValue
    func state(row: Int) -> RowState
    func isChanged(row: Int, column: Int) -> Bool
    func setValue(_ value: GridValue, row: Int, column: Int)
    func deleteRows(_ rows: IndexSet)
    /// nil clears sorting
    func sort(column: Int?, ascending: Bool)
    func selectionChanged(_ rows: IndexSet)
    func attach(_ grid: GridController)
}

extension GridSource {
    var isEditable: Bool { false }
    func state(row: Int) -> RowState { .normal }
    func isChanged(row: Int, column: Int) -> Bool { false }
    func setValue(_ value: GridValue, row: Int, column: Int) {}
    func deleteRows(_ rows: IndexSet) {}
    func selectionChanged(_ rows: IndexSet) {}
    func attach(_ grid: GridController) {}
}

/// Read-only rows of a query result, sorted on the client.
@Observable
final class ResultGrid: GridSource {
    let gridColumns: [QueryColumn]
    let rows: [[String?]]
    private var order: [Int]?
    private(set) var sortColumn: Int?
    private(set) var sortAscending = true

    init(columns: [QueryColumn], rows: [[String?]]) {
        gridColumns = columns
        self.rows = rows
    }

    var rowCount: Int { rows.count }

    func value(row: Int, column: Int) -> GridValue {
        GridValue(rows[order?[row] ?? row][column])
    }

    func sort(column: Int?, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        guard let column else {
            order = nil
            return
        }
        let numeric = gridColumns[column].isNumeric
        order = rows.indices.sorted { a, b in
            let x = rows[a][column], y = rows[b][column]
            let less: Bool
            switch (x, y) {
            case (nil, nil): return a < b
            case (nil, _): less = true
            case (_, nil): less = false
            case let (x?, y?):
                if numeric, let dx = Double(x), let dy = Double(y) {
                    if dx == dy { return a < b }
                    less = dx < dy
                } else {
                    let r = x.localizedStandardCompare(y)
                    if r == .orderedSame { return a < b }
                    less = r == .orderedAscending
                }
            }
            return ascending ? less : !less
        }
    }
}

/// SwiftUI wrapper; a new `revision` reloads the rows.
struct DataGridView: NSViewRepresentable {
    let source: any GridSource
    var revision = 0

    func makeCoordinator() -> GridController {
        GridController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(source: source, revision: revision)
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(source: source, revision: revision)
    }
}

final class GridController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    private enum EditEnd { case commit, cancel, move(Int) }

    let scrollView = NSScrollView()
    let table = GridTableView()
    private var source: (any GridSource)?
    private var columns: [QueryColumn] = []
    private var revision = -1
    private var editor: NSTextField?
    private var editing: (row: Int, column: Int)?
    private var editEnd = EditEnd.commit

    override init() {
        super.init()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 1, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 22
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.controller = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    func update(source: any GridSource, revision: Int) {
        let isNew = self.source !== source
        if isNew {
            self.source = source
            source.attach(self)
        }
        if isNew || columns != source.gridColumns {
            finishEdit(.cancel)
            rebuildColumns(source.gridColumns)
            table.reloadData()
        } else if revision != self.revision {
            finishEdit(.cancel)
            table.reloadData()
        }
        self.revision = revision
        updateSortIndicator()
    }

    private func rebuildColumns(_ cols: [QueryColumn]) {
        columns = cols
        while let c = table.tableColumns.last {
            table.removeTableColumn(c)
        }
        let num = NSTableColumn(identifier: .init("#"))
        num.title = "#"
        num.width = 56
        num.minWidth = 30
        table.addTableColumn(num)
        for (i, c) in cols.enumerated() {
            let col = NSTableColumn(identifier: .init("c\(i)"))
            col.title = c.name
            col.headerToolTip = "\(c.name) (\(c.typeName))"
            let base = max(CGFloat(c.name.count) * 8 + 40, 90)
            col.width = min(max(base, c.isNumeric ? 90 : 150), 320)
            col.minWidth = 40
            table.addTableColumn(col)
        }
    }

    /// Data column index of a table column (nil for the row-number column).
    private func dataColumn(_ tc: NSTableColumn?) -> Int? {
        guard let id = tc?.identifier.rawValue, id.hasPrefix("c") else { return nil }
        return Int(id.dropFirst())
    }

    private func dataColumn(at index: Int) -> Int? {
        index >= 0 && index < table.numberOfColumns ? dataColumn(table.tableColumns[index]) : nil
    }

    func scrollToBottom() {
        table.scrollRowToVisible(table.numberOfRows - 1)
    }

    func reloadRow(_ row: Int) {
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        source?.rowCount ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let source else { return nil }
        let cell = tableView.makeView(withIdentifier: GridCell.reuseID, owner: nil) as? GridCell ?? GridCell()
        let state = source.state(row: row)
        if let c = dataColumn(tableColumn) {
            cell.show(source.value(row: row, column: c), numeric: columns[c].isNumeric, state: state,
                      changed: source.isChanged(row: row, column: c))
        } else {
            cell.showRowNumber(row + 1, state: state)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        source?.selectionChanged(table.selectedRowIndexes)
    }

    // MARK: Sorting (header click: ascending → descending → none)

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let source, let c = dataColumn(tableColumn) else { return }
        finishEdit(.cancel)
        if source.sortColumn != c {
            source.sort(column: c, ascending: true)
        } else if source.sortAscending {
            source.sort(column: c, ascending: false)
        } else {
            source.sort(column: nil, ascending: true)
        }
        updateSortIndicator()
        table.reloadData()
    }

    private func updateSortIndicator() {
        for c in table.tableColumns {
            table.setIndicatorImage(nil, in: c)
        }
        if let s = source?.sortColumn, let col = table.tableColumn(withIdentifier: .init("c\(s)")) {
            let name = source!.sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
            table.setIndicatorImage(NSImage(named: NSImage.Name(name)), in: col)
            table.highlightedTableColumn = col
        } else {
            table.highlightedTableColumn = nil
        }
    }

    // MARK: Editing

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, let c = dataColumn(at: table.clickedColumn) else { return }
        beginEdit(row: table.clickedRow, column: c)
    }

    private func canEdit(row: Int, column: Int) -> Bool {
        guard let source, source.isEditable, row < source.rowCount, column < columns.count else { return false }
        return source.state(row: row) != .deleted && !columns[column].isBinary
    }

    func beginEdit(row: Int, column: Int) {
        guard canEdit(row: row, column: column), let source else { return }
        finishEdit(.commit)
        let index = table.column(withIdentifier: .init("c\(column)"))
        guard index >= 0 else { return }
        table.scrollRowToVisible(row)
        table.scrollColumnToVisible(index)
        let field = NSTextField(frame: table.frameOfCell(atColumn: index, row: row))
        field.stringValue = source.value(row: row, column: column).string ?? ""
        field.font = GridCell.font
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        table.addSubview(field)
        editor = field
        editing = (row, column)
        editEnd = .commit
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): editEnd = .commit
        case #selector(NSResponder.cancelOperation(_:)): editEnd = .cancel
        case #selector(NSResponder.insertTab(_:)): editEnd = .move(1)
        case #selector(NSResponder.insertBacktab(_:)): editEnd = .move(-1)
        default: return false
        }
        table.window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let end = editEnd
        editEnd = .commit
        // let the field editor finish before the field goes away
        DispatchQueue.main.async { [weak self] in self?.finishEdit(end) }
    }

    private func finishEdit(_ end: EditEnd) {
        guard let (row, column) = editing, let field = editor else { return }
        editing = nil
        editor = nil
        let text = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        if table.window?.firstResponder == nil || table.window?.firstResponder === field.currentEditor() {
            table.window?.makeFirstResponder(table)
        }
        guard let source else { return }
        if case .cancel = end { return }
        let cur = source.value(row: row, column: column)
        let untouchedEmpty = (cur == .null || cur == .unset) && text.isEmpty
        if !untouchedEmpty && cur != .text(text) {
            source.setValue(.text(text), row: row, column: column)
            reloadRow(row)
        }
        if case let .move(delta) = end {
            // next editable column in display order
            let order = table.tableColumns.compactMap { dataColumn($0) }
            guard var i = order.firstIndex(of: column) else { return }
            while true {
                i += delta
                guard i >= 0 && i < order.count else { return }
                if canEdit(row: row, column: order[i]) {
                    beginEdit(row: row, column: order[i])
                    return
                }
            }
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let source, table.clickedRow >= 0 else { return }
        let row = table.clickedRow
        let col = dataColumn(at: table.clickedColumn)
        let copyValue = menu.add("复制值") { [weak self] in
            guard let self, let col else { return }
            self.copyToPasteboard(source.value(row: row, column: col).string ?? "")
        }
        copyValue.isEnabled = col != nil
        menu.add("复制行") { [weak self] in
            guard let self else { return }
            self.copyToPasteboard((0..<self.columns.count).map { source.value(row: row, column: $0).string ?? "" }
                .joined(separator: "\t"))
        }
        guard source.isEditable else { return }
        let editable = col.map { canEdit(row: row, column: $0) } ?? false
        menu.addItem(.separator())
        menu.add("编辑") { [weak self] in
            if let col { self?.beginEdit(row: row, column: col) }
        }.isEnabled = editable
        menu.add("设为 NULL") { [weak self] in
            guard let col else { return }
            source.setValue(.null, row: row, column: col)
            self?.reloadRow(row)
        }.isEnabled = editable
        menu.add("设为空字符串") { [weak self] in
            guard let col else { return }
            source.setValue(.text(""), row: row, column: col)
            self?.reloadRow(row)
        }.isEnabled = editable
        menu.addItem(.separator())
        let selected = table.selectedRowIndexes
        let targets = selected.contains(row) ? selected : IndexSet(integer: row)
        menu.add(targets.count > 1 ? "删除选中的 \(targets.count) 行" : "删除行") {
            source.deleteRows(targets)
        }
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Selected rows as tab-separated text, in on-screen column order.
    func copySelection() {
        guard let source, !table.selectedRowIndexes.isEmpty else { return }
        let order = table.tableColumns.compactMap { dataColumn($0) }
        copyToPasteboard(table.selectedRowIndexes.map { row in
            order.map { source.value(row: row, column: $0).string ?? "" }.joined(separator: "\t")
        }.joined(separator: "\n"))
    }
}

final class GridTableView: NSTableView {
    weak var controller: GridController?

    @objc func copy(_ sender: Any?) {
        controller?.copySelection()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// Target object running a closure for a menu item (kept alive by the item).
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() {
        handler()
    }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        addItem(item)
        return item
    }
}

/// Draws its text directly: one view per visible cell, no subviews or constraints.
final class GridCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("GridCell")
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    private static let left = paragraph(.left)
    private static let right = paragraph(.right)
    /// Longer values are cut for display; the full value stays in the row data.
    private static let maxShown = 300

    private static let newTint = NSColor(red: 24 / 255, green: 160 / 255, blue: 88 / 255, alpha: 0.14)
    private static let deletedTint = NSColor(red: 208 / 255, green: 48 / 255, blue: 80 / 255, alpha: 0.14)
    private static let changedTint = NSColor(red: 240 / 255, green: 160 / 255, blue: 32 / 255, alpha: 0.26)

    private static func paragraph(_ a: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = a
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    private enum Style { case value, placeholder, rowNumber }

    private var text = ""
    private var style = Style.value
    private var numeric = false
    private var state = RowState.normal
    private var changed = false

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    func show(_ value: GridValue, numeric: Bool, state: RowState, changed: Bool) {
        switch value {
        case let .text(s):
            var shown = s.utf8.count > Self.maxShown ? String(s.prefix(Self.maxShown)) + "…" : s
            if shown.contains(where: \.isNewline) { shown = shown.replacing(/\r\n|\r|\n/, with: "↵") }
            text = shown
            style = .value
        case .null:
            text = "NULL"
            style = .placeholder
        case .unset:
            text = "(默认)"
            style = .placeholder
        }
        self.numeric = numeric
        self.state = state
        self.changed = changed
        needsDisplay = true
    }

    func showRowNumber(_ n: Int, state: RowState) {
        text = String(n)
        style = .rowNumber
        numeric = false
        self.state = state
        changed = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint: NSColor? = switch state {
        case .new: Self.newTint
        case .deleted: Self.deletedTint
        case .normal: changed ? Self.changedTint : nil
        }
        if let tint {
            tint.setFill()
            bounds.fill()
        }
        let selected = backgroundStyle == .emphasized
        let color: NSColor = switch (style, selected) {
        case (_, true): .alternateSelectedControlTextColor
        case (.value, _): state == .deleted ? .secondaryLabelColor : .labelColor
        case (.placeholder, _): .tertiaryLabelColor
        case (.rowNumber, _): .secondaryLabelColor
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: style == .placeholder ? Self.italic : Self.font,
            .foregroundColor: color,
            .paragraphStyle: numeric ? Self.right : Self.left,
        ]
        if state == .deleted && style != .rowNumber {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        let rect = NSRect(x: 6, y: ((bounds.height - Self.lineHeight) / 2).rounded(),
                          width: bounds.width - 12, height: Self.lineHeight)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}
