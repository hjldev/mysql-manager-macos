import AppKit
import MySQLKit
import SwiftUI

struct ObjectTreeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)

            if model.roots.isEmpty {
                VStack(spacing: 10) {
                    Text("还没有连接").foregroundStyle(.secondary)
                    Button("新建连接") { model.sheet = .connection(ConnectionEditorRequest(config: nil)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ObjectOutline(model: model, state: model.treeState)
            }
        }
    }
}

extension AppModel {
    /// Everything the tree shows except the table / view rows, which only
    /// change with `treeRevision`. Reading it in a view body makes SwiftUI
    /// update the outline when any of it changes.
    var treeState: Int {
        var h = Hasher()
        h.combine(treeRevision)
        h.combine(search)
        h.combine(opened)
        for c in connections { h.combine(c.color) }
        func walk(_ list: [TreeNode]) {
            for n in list where n.kind != .table && n.kind != .view {
                h.combine(n.label)
                h.combine(n.isExpanded)
                h.combine(n.isLoading)
                h.combine(n.children == nil)
                if n.kind == .connection || n.kind == .database { walk(n.children ?? []) }
            }
        }
        walk(roots)
        return h.finalize()
    }
}

/// The object tree as an NSOutlineView. Rows get views only while on screen,
/// so a database with tens of thousands of tables stays fast and small (a
/// SwiftUI List keeps state for every row and hangs on large folders).
private struct ObjectOutline: NSViewRepresentable {
    let model: AppModel
    /// `AppModel.treeState`: a new value calls `updateNSView`.
    let state: Int

    func makeCoordinator() -> TreeOutlineController {
        TreeOutlineController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update()
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update()
    }
}

/// Return / Enter opens the selected row, like a double click.
private final class TreeOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class TreeOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let scrollView = NSScrollView()
    private let outline = TreeOutlineView()
    private let model: AppModel
    private var revision = -1
    private var search = ""
    /// While searching: the shown roots, and the shown children of each node.
    private var matchingRoots: [TreeNode] = []
    private var matches: [ObjectIdentifier: [TreeNode]] = [:]
    /// Set while the outline is changed to match the model, so its callbacks don't write back.
    private var syncing = false

    init(model: AppModel) {
        self.model = model
        super.init()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.rowHeight = 28
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onReturn = { [weak self] in self?.activate(row: self?.outline.selectedRow ?? -1) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    private var searching: Bool { !search.isEmpty }

    private func kids(_ node: TreeNode?) -> [TreeNode] {
        guard let node else { return searching ? matchingRoots : model.roots }
        return searching ? matches[ObjectIdentifier(node)] ?? [] : node.children ?? []
    }

    /// Loaded nodes open in the model, and while searching those with matches.
    private func wantsExpanded(_ node: TreeNode) -> Bool {
        node.children != nil && (node.isExpanded || searching && !kids(node).isEmpty)
    }

    func update() {
        let pattern = model.search.trimmingCharacters(in: .whitespaces)
        if model.treeRevision != revision || pattern != search {
            revision = model.treeRevision
            search = pattern
            reload()
        } else {
            syncExpansion(kids(nil))
            refreshVisibleRows()
        }
    }

    private func reload() {
        matches = [:]
        matchingRoots = searching ? filter(model.roots) : []
        let origin = scrollView.contentView.bounds.origin
        syncing = true
        defer { syncing = false }
        outline.reloadData()
        syncExpansion(kids(nil))
        if let id = model.selectedNodeID, let n = model.node(id) {
            let row = outline.row(forItem: n)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        outline.scroll(origin)
    }

    /// Search: nodes whose label matches, or that have matching descendants.
    private func filter(_ list: [TreeNode]) -> [TreeNode] {
        list.filter { n in
            let shown = n.children.map(filter) ?? []
            if !shown.isEmpty { matches[ObjectIdentifier(n)] = shown }
            return !shown.isEmpty || n.label.localizedCaseInsensitiveContains(search)
        }
    }

    /// Expand / collapse to match the model. Only folders are visited, never
    /// the (possibly many) table rows inside them.
    private func syncExpansion(_ list: [TreeNode]) {
        let was = syncing
        syncing = true
        defer { syncing = was }
        for n in list where n.kind != .table && n.kind != .view {
            let want = wantsExpanded(n)
            if want != outline.isItemExpanded(n) {
                if want { outline.expandItem(n) } else { outline.collapseItem(n) }
            }
            if want && (n.kind == .connection || n.kind == .database) { syncExpansion(kids(n)) }
        }
    }

    private func refreshVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        for row in rows.location..<rows.location + rows.length {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCell,
               let n = outline.item(atRow: row) as? TreeNode {
                configure(cell, n)
            }
        }
    }

    // MARK: Data source and delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        kids(item as? TreeNode).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        kids(item as? TreeNode)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: TreeCell.reuseID, owner: nil) as? TreeCell ?? TreeCell()
        if let n = item as? TreeNode { configure(cell, n) }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard !syncing, let n = item as? TreeNode, n.children == nil else { return true }
        model.setExpanded(n, true) // loads the children, then the model expands it
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !syncing, let n = notification.userInfo?["NSObject"] as? TreeNode { n.isExpanded = true }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !syncing, let n = notification.userInfo?["NSObject"] as? TreeNode { n.isExpanded = false }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        model.selectedNodeID = (outline.item(atRow: outline.selectedRow) as? TreeNode)?.id
    }

    @objc private func doubleClicked() {
        activate(row: outline.clickedRow)
    }

    private func activate(row: Int) {
        if let n = outline.item(atRow: row) as? TreeNode { model.activate(n) }
    }

    // MARK: Rows

    private static let blue = NSColor(Color.mmBlue)
    private static let orange = NSColor(Color.mmOrange)
    private static let purple = NSColor(Color.mmPurple)
    private static let green = NSColor(Color.mmGreen)

    private func configure(_ cell: TreeCell, _ n: TreeNode) {
        cell.show(symbol: icon(n), tint: color(n), text: n.label, tooltip: tooltip(n), loading: n.isLoading)
    }

    private func icon(_ n: TreeNode) -> String {
        switch n.kind {
        case .connection: "server.rack"
        case .database: "cylinder.split.1x2"
        case .tables, .views: "folder"
        case .table: "tablecells"
        case .view: "eye"
        }
    }

    private func color(_ n: TreeNode) -> NSColor {
        switch n.kind {
        case .connection:
            guard model.isOpen(n.connID) else { return .secondaryLabelColor }
            return Color(hex: model.connection(n.connID)?.color).map { NSColor($0) } ?? Self.green
        case .database: return n.children == nil ? .secondaryLabelColor : Self.orange // open once its tables are loaded
        case .tables, .views: return .secondaryLabelColor
        case .table: return Self.blue
        case .view: return Self.purple
        }
    }

    private func tooltip(_ n: TreeNode) -> String {
        switch n.kind {
        case .connection:
            if let v = model.opened[n.connID] { return "MySQL \(v)" }
            guard let c = model.connection(n.connID) else { return "" }
            return "\(c.user)@\(c.host):\(c.port)"
        case .table, .view:
            return n.info?.comment.flatMap { $0.isEmpty ? nil : $0 } ?? n.label
        default:
            return n.label
        }
    }

    // MARK: Context menu

    private enum MenuEntry {
        case item(String, TreeAction, enabled: Bool = true)
        case separator
    }

    private final class MenuCommand {
        let node: TreeNode
        let action: TreeAction

        init(node: TreeNode, action: TreeAction) {
            self.node = node
            self.action = action
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? TreeNode else { return }
        for entry in menuEntries(n) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, action, enabled):
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                item.representedObject = MenuCommand(node: n, action: action)
                menu.addItem(item)
            }
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? MenuCommand else { return }
        Task { await model.perform(c.action, on: c.node) }
    }

    private func menuEntries(_ n: TreeNode) -> [MenuEntry] {
        switch n.kind {
        case .connection:
            let open = model.isOpen(n.connID)
            return [
                .item(open ? "关闭连接" : "打开连接", open ? .close : .open),
                .item("新建查询", .query),
                .separator,
                .item("新建数据库", .createDatabase, enabled: open),
                .item("运行 SQL 文件", .runSQL, enabled: open),
                .item("刷新", .refresh, enabled: open),
                .separator,
                .item("编辑连接", .editConnection),
                .item("复制连接", .copyConnection),
                .item("删除连接", .deleteConnection),
            ]
        case .database:
            return [
                .item("关闭数据库", .closeDatabase, enabled: n.children != nil),
                .item("新建查询", .query),
                .item("新建表", .createTable),
                .separator,
                .item("运行 SQL 文件", .runSQL),
                .item("转储 SQL 文件", .dump),
                .separator,
                .item("刷新", .refresh),
                .item("删除数据库", .dropDatabase),
            ]
        case .tables:
            return [.item("新建表", .createTable), .item("刷新", .refresh)]
        case .views:
            return [.item("刷新", .refresh)]
        case .table:
            return [
                .item("打开表", .openTable),
                .item("设计表", .design),
                .item("新建查询", .query),
                .separator,
                .item("导出数据", .export),
                .item("导入 CSV", .importCSV),
                .item("转储 SQL 文件", .dumpTable),
                .separator,
                .item("复制表（结构）", .duplicate(withData: false)),
                .item("复制表（结构和数据）", .duplicate(withData: true)),
                .item("重命名", .rename),
                .item("清空表", .truncate),
                .item("删除表", .drop),
                .separator,
                .item("复制表名", .copyName),
                .item("刷新", .refresh),
            ]
        case .view:
            return [
                .item("打开视图", .openTable),
                .item("查看定义", .viewDDL),
                .item("导出数据", .export),
                .separator,
                .item("删除视图", .drop),
            ]
        }
    }
}

/// Icon, name and (while loading) a spinner.
private final class TreeCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("TreeCell")
    private static var symbols: [String: NSImage] = [:]

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        let stack = NSStackView(views: [icon, label, spinner])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(symbol: String, tint: NSColor, text: String, tooltip: String, loading: Bool) {
        if Self.symbols[symbol] == nil {
            Self.symbols[symbol] = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        icon.image = Self.symbols[symbol]
        icon.contentTintColor = tint
        label.stringValue = text
        toolTip = tooltip
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
