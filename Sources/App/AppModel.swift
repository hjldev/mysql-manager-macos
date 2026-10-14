import AppKit
import MySQLKit
import Observation
import SwiftUI

// MARK: - Object tree

@Observable
final class TreeNode: Identifiable {
    enum Kind { case connection, database, tables, views, table, view }

    let id: String
    let kind: Kind
    let connID: String
    let db: String?
    let table: String?
    var label: String
    var info: TableInfo?
    /// nil until loaded. Set through `AppModel.setChildren` so the tree view reloads.
    var children: [TreeNode]?
    var isExpanded = false
    var isLoading = false

    init(id: String, kind: Kind, connID: String, db: String? = nil, table: String? = nil, label: String,
         info: TableInfo? = nil, children: [TreeNode]? = nil) {
        self.id = id
        self.kind = kind
        self.connID = connID
        self.db = db
        self.table = table
        self.label = label
        self.info = info
        self.children = children
    }

    var isExpandable: Bool {
        switch kind {
        case .connection, .database: true
        case .tables, .views: !(children ?? []).isEmpty
        case .table, .view: false
        }
    }
}

// MARK: - Tabs

@MainActor
protocol TabContent: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var dirty: Bool { get }
    var connID: String { get }
    var db: String? { get }
    var table: String? { get }
    func onClose()
}

enum WorkTab: Identifiable {
    case query(QueryTabModel)
    case data(TableDataModel)
    case design(TableDesignModel)

    var content: any TabContent {
        switch self {
        case let .query(m): m
        case let .data(m): m
        case let .design(m): m
        }
    }

    var id: UUID { content.id }

    var systemImage: String {
        switch self {
        case .query: "chevron.left.forwardslash.chevron.right"
        case .data: "tablecells"
        case .design: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Dialog requests

struct TransferTarget: Identifiable {
    let id = UUID()
    let connID: String
    let db: String
    var table: String?
}

struct ConnectionEditorRequest: Identifiable {
    let id = UUID()
    /// nil for a new connection; an empty id makes a copy
    let config: ConnectionConfig?
}

/// A text prompt shown as a sheet; `resolve` is called exactly once.
final class PromptRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    let value: String
    let password: Bool
    private var continuation: CheckedContinuation<String?, Never>?

    init(title: String, label: String, value: String, password: Bool, continuation: CheckedContinuation<String?, Never>) {
        self.title = title
        self.label = label
        self.value = value
        self.password = password
        self.continuation = continuation
    }

    func resolve(_ v: String?) {
        continuation?.resume(returning: v)
        continuation = nil
    }
}

enum Sheet: Identifiable {
    case connection(ConnectionEditorRequest)
    case prompt(PromptRequest)
    case export(TransferTarget)
    case dump(TransferTarget)
    case importCSV(TransferTarget)
    case runSQL(TransferTarget)

    var id: UUID {
        switch self {
        case let .connection(r): r.id
        case let .prompt(r): r.id
        case let .export(t), let .dump(t), let .importCSV(t), let .runSQL(t): t.id
        }
    }
}

// MARK: - App state

@Observable
final class AppModel {
    let db: DatabaseService
    var connections: [ConnectionConfig] = []
    /// connection id → server version, for open connections
    var opened: [String: String] = [:]
    var roots: [TreeNode] = []
    /// Bumped whenever `roots` or any node's children change.
    private(set) var treeRevision = 0
    var selectedNodeID: String?
    var search = ""
    var tabs: [WorkTab] = []
    var activeTabID: UUID?
    var toasts: [Toast] = []

    /// The one sheet shown at a time.
    var sheet: Sheet?

    /// nil follows the system appearance
    var dark: Bool? {
        didSet { applyTheme() }
    }

    private var queryCounter = 0

    init() {
        // shared with the Tauri app, so saved connections show up in both
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sting.mysqlmanager")
        db = DatabaseService(configDirectory: dir)
        switch UserDefaults.standard.string(forKey: "theme") {
        case "dark": dark = true
        case "light": dark = false
        default: dark = nil
        }
        applyTheme()
        Task { await loadConnections() }
    }

    private func applyTheme() {
        NSApp?.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
        if let dark { UserDefaults.standard.set(dark ? "dark" : "light", forKey: "theme") }
    }

    var isDark: Bool {
        dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func toggleTheme() {
        dark = !isDark
    }

    // MARK: Messages

    func toast(_ kind: Toast.Kind, _ text: String) {
        let t = Toast(kind: kind, text: text)
        toasts.append(t)
        let seconds: Double = kind == .error ? 8 : 3
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            dismissToast(t)
        }
    }

    func dismissToast(_ t: Toast) {
        toasts.removeAll { $0.id == t.id }
    }

    func report(_ error: Error) {
        if error is Cancelled { return }
        toast(.error, error.localizedDescription)
    }

    /// Run `work`, reporting errors as toasts.
    func attempt(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            report(error)
        }
    }

    func ask(_ title: String, label: String = "", value: String = "", password: Bool = false) async -> String? {
        await withCheckedContinuation { cont in
            if case let .prompt(old) = sheet { old.resolve(nil) }
            sheet = .prompt(PromptRequest(title: title, label: label, value: value, password: password, continuation: cont))
        }
    }

    func confirm(_ title: String, _ message: String, ok: String = "确定", destructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let button = alert.addButton(withTitle: ok)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "取消")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    // MARK: Connections

    func connection(_ id: String) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    func isOpen(_ id: String) -> Bool { opened[id] != nil }

    func loadConnections() async {
        await attempt {
            let db = db
            connections = try await onBackground { try db.listConnections() }
            syncTree()
        }
    }

    func saveConnection(_ cfg: ConnectionConfig) async throws -> ConnectionConfig {
        let db = db
        let saved = try await onBackground { try db.saveConnection(cfg) }
        if let i = connections.firstIndex(where: { $0.id == saved.id }) {
            connections[i] = saved
        } else {
            connections.append(saved)
        }
        syncTree()
        return saved
    }

    /// Open the connection, asking for the password when none is saved.
    func ensureOpen(_ connID: String) async throws {
        if isOpen(connID) { return }
        guard let cfg = connection(connID) else { throw MySQLError.message("连接不存在") }
        let db = db
        var password: String?
        let saved = await (try? onBackground { db.hasSavedPassword(connID) }) ?? false
        if !cfg.savePassword || !saved {
            password = await ask("连接 \(cfg.name)", label: "密码", password: true)
            if password == nil { throw Cancelled() }
        }
        let pw = password
        opened[connID] = try await onBackground { try db.openConnection(connID, password: pw) }
    }

    func closeConnection(_ connID: String) async {
        let db = db
        _ = try? await onBackground { db.closeConnection(connID) }
        opened[connID] = nil
        collapseConnection(connID)
    }

    func deleteConnection(_ connID: String) async throws {
        closeTabs { $0.connID == connID }
        let db = db
        try await onBackground { try db.deleteConnection(connID) }
        connections.removeAll { $0.id == connID }
        opened[connID] = nil
        syncTree()
    }

    // MARK: Tree

    /// Rebuild root nodes from the connection list, keeping loaded children.
    func syncTree() {
        let old = Dictionary(uniqueKeysWithValues: roots.map { ($0.connID, $0) })
        roots = connections.map { c in
            if let prev = old[c.id] {
                prev.label = c.name
                return prev
            }
            return TreeNode(id: "conn:\(c.id)", kind: .connection, connID: c.id, label: c.name)
        }
        treeRevision += 1
    }

    func setChildren(_ node: TreeNode, _ children: [TreeNode]?) {
        node.children = children
        treeRevision += 1
    }

    func node(_ id: String) -> TreeNode? {
        func find(_ list: [TreeNode]) -> TreeNode? {
            for n in list {
                if n.id == id { return n }
                if let c = n.children, let f = find(c) { return f }
            }
            return nil
        }
        return find(roots)
    }

    private func dbChildren(_ connID: String, _ db: String, _ tables: [TableInfo]) -> [TreeNode] {
        let t = tables.filter { !$0.isView }
        let v = tables.filter(\.isView)
        func leaf(_ x: TableInfo, _ kind: TreeNode.Kind) -> TreeNode {
            let k = kind == .view ? "view" : "table"
            return TreeNode(id: "\(k):\(connID):\(db):\(x.name)", kind: kind, connID: connID, db: db, table: x.name,
                            label: x.name, info: x)
        }
        return [
            TreeNode(id: "tables:\(connID):\(db)", kind: .tables, connID: connID, db: db, label: "表 (\(t.count))",
                     children: t.map { leaf($0, .table) }),
            TreeNode(id: "views:\(connID):\(db)", kind: .views, connID: connID, db: db, label: "视图 (\(v.count))",
                     children: v.map { leaf($0, .view) }),
        ]
    }

    /// Load the children of a connection or database node.
    func load(_ node: TreeNode) async throws {
        let db = db
        let connID = node.connID
        node.isLoading = true
        defer { node.isLoading = false }
        switch node.kind {
        case .connection:
            try await ensureOpen(connID)
            let names = try await onBackground { try db.databases(connID) }
            let old = Dictionary((node.children ?? []).map { ($0.db ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            setChildren(node, names.map {
                old[$0] ?? TreeNode(id: "db:\(connID):\($0)", kind: .database, connID: connID, db: $0, label: $0)
            })
        case .database:
            let name = node.db ?? ""
            let tables = try await onBackground { try db.tables(connID, db: name) }
            let wasExpanded = Set((node.children ?? []).filter(\.isExpanded).map(\.id))
            setChildren(node, dbChildren(connID, name, tables))
            for c in node.children ?? [] where wasExpanded.contains(c.id) { c.isExpanded = true }
        default:
            break
        }
    }

    /// Expand or collapse a node, loading its children the first time.
    func setExpanded(_ node: TreeNode, _ expanded: Bool) {
        guard expanded else {
            node.isExpanded = false
            return
        }
        if node.children != nil {
            node.isExpanded = true
            return
        }
        Task {
            do {
                try await load(node)
                node.isExpanded = true
            } catch {
                node.isExpanded = false
                report(error)
            }
        }
    }

    func refreshConnection(_ connID: String) async {
        guard let n = node("conn:\(connID)"), n.children != nil else { return }
        await attempt {
            try await load(n)
            // re-load expanded databases below
            for c in n.children ?? [] where c.isExpanded || c.children != nil {
                try await load(c)
            }
        }
    }

    func refreshDatabase(_ connID: String, _ db: String) async {
        guard let n = node("db:\(connID):\(db)"), n.children != nil else { return }
        await attempt { try await load(n) }
    }

    func collapseConnection(_ connID: String) {
        guard let n = node("conn:\(connID)") else { return }
        setChildren(n, nil)
        n.isExpanded = false
        trimMemory()
    }

    func collapseDatabase(_ connID: String, _ db: String) {
        guard let n = node("db:\(connID):\(db)") else { return }
        setChildren(n, nil)
        n.isExpanded = false
        trimMemory()
    }

    // MARK: Tabs

    var activeTab: WorkTab? {
        tabs.first { $0.id == activeTabID }
    }

    private func add(_ tab: WorkTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    @discardableResult
    func openQuery(connID: String, db: String?, sql: String = "") -> QueryTabModel {
        let db = db.flatMap { $0.isEmpty ? nil : $0 }
        queryCounter += 1
        let title = "查询 \(queryCounter)" + (db.map { " @\($0)" } ?? "")
        let m = QueryTabModel(app: self, title: title, connID: connID, db: db, sql: sql)
        add(.query(m))
        return m
    }

    func openTableData(connID: String, db: String, table: String, isView: Bool) {
        if let t = tabs.first(where: {
            if case let .data(m) = $0 { m.connID == connID && m.db == db && m.table == table } else { false }
        }) {
            activeTabID = t.id
            return
        }
        add(.data(TableDataModel(app: self, connID: connID, db: db, table: table, isView: isView)))
    }

    /// `table == nil` designs a new table.
    func openDesign(connID: String, db: String, table: String?) {
        if let table, let t = tabs.first(where: {
            if case let .design(m) = $0 { m.connID == connID && m.db == db && m.table == table } else { false }
        }) {
            activeTabID = t.id
            return
        }
        add(.design(TableDesignModel(app: self, connID: connID, db: db, table: table)))
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].content.onClose()
        tabs.remove(at: i)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
        trimMemory()
    }

    /// Close a tab, asking first when it has unsaved changes.
    func requestCloseTab(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.content.dirty {
            let ok = await confirm("关闭", "「\(tab.content.title)」有未保存的修改，关闭后将丢失。", ok: "关闭", destructive: true)
            if !ok { return }
        }
        closeTab(id)
    }

    func closeTabs(where pred: (any TabContent) -> Bool) {
        for t in tabs where pred(t.content) {
            closeTab(t.id)
        }
    }

    /// Close matching tabs (confirming when some have unsaved changes).
    /// Returns false if the user cancelled.
    func closeTabsConfirming(where pred: (any TabContent) -> Bool) async -> Bool {
        let dirty = tabs.map(\.content).filter { pred($0) && $0.dirty }
        if !dirty.isEmpty {
            let ok = await confirm("关闭", "以下窗口有未保存的修改，关闭后将丢失：\n" + dirty.map(\.title).joined(separator: "、"),
                                   ok: "关闭", destructive: true)
            if !ok { return false }
        }
        closeTabs(where: pred)
        return true
    }

    /// New query on the connection/database selected in the tree.
    func newQuery() {
        let sel = selectedNodeID.flatMap(node)
        guard let connID = sel?.connID ?? opened.keys.first ?? connections.first?.id else {
            toast(.warning, "请先创建一个连接")
            return
        }
        openQuery(connID: connID, db: sel?.db)
    }
}
