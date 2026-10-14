import MySQLKit
import SwiftUI

final class EditRow {
    let key: Int
    var values: [GridValue]
    /// nil for new rows
    let original: [String?]?
    var state: RowState

    init(key: Int, values: [GridValue], original: [String?]?, state: RowState) {
        self.key = key
        self.values = values
        self.original = original
        self.state = state
    }
}

@Observable
final class TableDataModel: TabContent, GridSource {
    let id = UUID()
    let app: AppModel
    let connID: String
    let dbName: String
    let tableName: String
    let isView: Bool

    private(set) var columns: [QueryColumn] = []
    private(set) var colInfo: [ColumnInfo] = []
    private(set) var rows: [EditRow] = []
    private(set) var total: UInt64 = 0
    var page = 1
    var pageSize = 100
    var filter = ""
    var orderBy = ""
    private(set) var loading = false
    private(set) var lastSQL = ""
    private(set) var selection = IndexSet()
    /// bumped when rows are added, removed or replaced
    private(set) var revision = 0
    private(set) var changeCount = 0
    private(set) var sortColumn: Int?
    private(set) var sortAscending = true
    var preview: PreviewRequest?
    var committing = false
    @ObservationIgnored private weak var grid: GridController?
    @ObservationIgnored private var nextKey = 0

    struct PreviewRequest: Identifiable {
        let id = UUID()
        let statements: [String]
    }

    init(app: AppModel, connID: String, db: String, table: String, isView: Bool) {
        self.app = app
        self.connID = connID
        dbName = db
        tableName = table
        self.isView = isView
        Task { await load() }
    }

    var title: String { "\(tableName) @\(dbName)" }
    var dirty: Bool { changeCount > 0 }
    var db: String? { dbName }
    var table: String? { tableName }
    var hasPrimaryKey: Bool { colInfo.contains { $0.key == "PRI" } }
    var pageCount: Int { max(1, Int((total + UInt64(pageSize) - 1) / UInt64(pageSize))) }

    func onClose() {}

    // MARK: Loading

    func load() async {
        loading = true
        defer { loading = false }
        let db = app.db, connID = connID, dbName = dbName, tableName = tableName
        let filter = filter, orderBy = orderBy, offset = UInt64((page - 1) * pageSize), limit = UInt64(pageSize)
        do {
            if colInfo.isEmpty {
                colInfo = try await onBackground { try db.columns(connID, db: dbName, table: tableName) }
            }
            let p = try await onBackground {
                try db.fetchRows(connID, db: dbName, table: tableName, filter: filter, orderBy: orderBy, offset: offset, limit: limit)
            }
            columns = p.columns
            total = p.total
            lastSQL = p.sql
            rows = p.rows.map { values in
                defer { nextKey += 1 }
                return EditRow(key: nextKey, values: values.map(GridValue.init), original: values, state: .normal)
            }
            selection = []
            recount()
            revision += 1
        } catch {
            app.report(error)
        }
        trimMemory()
    }

    /// Reload, asking first when there are unsaved edits. Returns false if cancelled.
    @discardableResult
    func reload() async -> Bool {
        if changeCount > 0 {
            let ok = await app.confirm("放弃修改？", "有 \(changeCount) 处修改尚未提交，刷新将丢弃这些修改。", ok: "刷新", destructive: true)
            if !ok { return false }
        }
        await load()
        return true
    }

    func applyFilter() {
        page = 1
        Task { await reload() }
    }

    func go(to p: Int) {
        let old = page
        page = min(max(p, 1), pageCount)
        Task {
            if !(await reload()) { page = old }
        }
    }

    func setPageSize(_ size: Int) {
        let (oldSize, oldPage) = (pageSize, page)
        pageSize = size
        page = 1
        Task {
            if !(await reload()) {
                pageSize = oldSize
                page = oldPage
            }
        }
    }

    // MARK: GridSource

    var gridColumns: [QueryColumn] { columns }
    var rowCount: Int { rows.count }
    var isEditable: Bool { !isView }

    func value(row: Int, column: Int) -> GridValue { rows[row].values[column] }
    func state(row: Int) -> RowState { rows[row].state }

    func isChanged(row: Int, column: Int) -> Bool {
        let r = rows[row]
        guard let orig = r.original, r.state != .deleted else { return false }
        return r.values[column] != GridValue(orig[column])
    }

    func setValue(_ value: GridValue, row: Int, column: Int) {
        rows[row].values[column] = value
        recount()
    }

    func deleteRows(_ set: IndexSet) {
        let keys = Set(set.map { rows[$0].key })
        rows = rows.filter { !(keys.contains($0.key) && $0.state == .new) }
        for r in rows where keys.contains(r.key) { r.state = .deleted }
        selection = []
        recount()
        revision += 1
    }

    func sort(column: Int?, ascending: Bool) {
        let old = (sortColumn, sortAscending, orderBy)
        sortColumn = column
        sortAscending = ascending
        orderBy = column.map { "\(SQL.quoteIdent(columns[$0].name)) \(ascending ? "ASC" : "DESC")" } ?? ""
        page = 1
        Task {
            if !(await reload()) {
                (sortColumn, sortAscending, orderBy) = old
                revision += 1
            }
        }
    }

    func selectionChanged(_ rows: IndexSet) {
        selection = rows
    }

    func attach(_ grid: GridController) {
        self.grid = grid
    }

    // MARK: Edits

    func addRow() {
        rows.append(EditRow(key: nextKey, values: Array(repeating: .unset, count: columns.count), original: nil, state: .new))
        nextKey += 1
        recount()
        revision += 1
        grid?.table.noteNumberOfRowsChanged()
        grid?.scrollToBottom()
    }

    func deleteSelected() {
        deleteRows(selection)
    }

    func discard() {
        rows = rows.filter { $0.state != .new }.map {
            EditRow(key: $0.key, values: ($0.original ?? []).map(GridValue.init), original: $0.original, state: .normal)
        }
        recount()
        revision += 1
    }

    private func recount() {
        changeCount = rows.reduce(0) { n, r in
            switch r.state {
            case .new, .deleted: return n + 1
            case .normal:
                guard let orig = r.original else { return n }
                return n + (zip(r.values, orig).contains { $0 != GridValue($1) } ? 1 : 0)
            }
        }
    }

    var changes: TableChanges {
        let names = columns.map(\.name)
        func map(_ vals: [GridValue], only: (Int) -> Bool = { _ in true }) -> RowMap {
            var m = RowMap()
            for (i, v) in vals.enumerated() where v != .unset && only(i) {
                m.updateValue(v.string, forKey: names[i])
            }
            return m
        }
        var ch = TableChanges()
        for r in rows {
            switch r.state {
            case .new:
                ch.inserts.append(map(r.values))
            case .deleted:
                ch.deletes.append(map((r.original ?? []).map(GridValue.init)))
            case .normal:
                guard let orig = r.original else { continue }
                let o = orig.map(GridValue.init)
                if r.values != o {
                    ch.updates.append(RowUpdate(key: map(o), set: map(r.values) { r.values[$0] != o[$0] }))
                }
            }
        }
        return ch
    }

    func showPreview() async {
        let db = app.db, connID = connID, dbName = dbName, tableName = tableName, ch = changes
        do {
            let sql = try await onBackground { try db.previewChanges(connID, db: dbName, table: tableName, changes: ch) }
            preview = PreviewRequest(statements: sql)
        } catch {
            app.report(error)
        }
    }

    func commit() async {
        guard changeCount > 0 else { return }
        committing = true
        defer { committing = false }
        let db = app.db, connID = connID, dbName = dbName, tableName = tableName, ch = changes
        do {
            let n = try await onBackground { try db.applyChanges(connID, db: dbName, table: tableName, changes: ch) }
            app.toast(.success, "已提交，影响 \(n) 行")
            preview = nil
            await load()
        } catch {
            app.report(error)
        }
    }
}

struct TableDataView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TableDataModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filters
            Divider()
            ZStack {
                DataGridView(source: model, revision: model.revision)
                if model.loading {
                    ProgressView().controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
            status
        }
        .sheet(item: $model.preview) { p in
            PreviewSheet(statements: p.statements, committing: model.committing) {
                model.preview = nil
            } run: {
                Task { await model.commit() }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ToolButton("刷新", systemImage: "arrow.clockwise", showsTitle: false) { Task { await model.reload() } }
                .disabled(model.loading)
            if model.isEditable {
                ToolButton("新增", systemImage: "plus") { model.addRow() }
                ToolButton("删除", systemImage: "minus") { model.deleteSelected() }
                    .disabled(model.selection.isEmpty)
                Button {
                    FileHandle.standardError.write(("DEBUG commit button\n" + Thread.callStackSymbols.prefix(40).joined(separator: "\n") + "\n").data(using: .utf8)!)
                    Task { await model.showPreview() }
                } label: {
                    Label("提交" + (model.changeCount > 0 ? " (\(model.changeCount))" : ""), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.changeCount == 0)
                ToolButton("放弃", systemImage: "xmark") { model.discard() }
                    .disabled(model.changeCount == 0)
            }
            ToolButton("导出", systemImage: "square.and.arrow.down") {
                app.sheet = .export(TransferTarget(connID: model.connID, db: model.dbName, table: model.tableName))
            }
            if model.isEditable {
                ToolButton("导入", systemImage: "square.and.arrow.up") {
                    app.sheet = .importCSV(TransferTarget(connID: model.connID, db: model.dbName, table: model.tableName))
                }
            }
            if model.isView {
                Tag(text: "视图（只读）", color: .secondary)
            } else if !model.colInfo.isEmpty && !model.hasPrimaryKey {
                Tag(text: "无主键", color: .orange)
                    .help("没有主键：修改和删除将按所有列的原始值匹配行（LIMIT 1）")
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var filters: some View {
        HStack(spacing: 6) {
            Text("WHERE").font(.mono).foregroundStyle(.secondary).fixedSize()
            TextField("", text: $model.filter, prompt: Text("例如 id > 100 AND name LIKE '%abc%'"))
                .font(.mono)
                .onSubmit { model.applyFilter() }
                .frame(minWidth: 160, maxWidth: .infinity)
            Text("ORDER BY").font(.mono).foregroundStyle(.secondary).fixedSize()
            TextField("", text: $model.orderBy, prompt: Text("例如 id DESC"))
                .font(.mono)
                .onSubmit { model.applyFilter() }
                .frame(minWidth: 100, maxWidth: 320)
            Button("应用") { model.applyFilter() }.fixedSize()
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var status: some View {
        HStack(spacing: 8) {
            Label(model.lastSQL, systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.lastSQL)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Text("共 \(model.total) 行").foregroundStyle(.secondary)
            Pagination(page: model.page, count: model.pageCount) { model.go(to: $0) }
            Picker("", selection: Binding(get: { model.pageSize }, set: { model.setPageSize($0) })) {
                ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) / 页").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// ‹ 1 … 4 5 6 … 20 ›
struct Pagination: View {
    let page: Int
    let count: Int
    let go: (Int) -> Void

    private var slots: [Int?] {
        if count <= 7 { return Array(1...count) }
        var s: [Int?] = [1]
        let lo = max(2, min(page - 2, count - 5)), hi = min(count - 1, max(page + 2, 6))
        if lo > 2 { s.append(nil) }
        s += (lo...hi).map { $0 }
        if hi < count - 1 { s.append(nil) }
        s.append(count)
        return s
    }

    var body: some View {
        HStack(spacing: 2) {
            Button { go(page - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page <= 1)
            ForEach(Array(slots.enumerated()), id: \.offset) { _, p in
                if let p {
                    Button { go(p) } label: {
                        Text("\(p)")
                            .monospacedDigit()
                            .frame(minWidth: 18)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(p == page ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(p == page ? Color.accentColor : .primary)
                    }
                } else {
                    Text("…").foregroundStyle(.secondary)
                }
            }
            Button { go(page + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page >= count)
        }
        .buttonStyle(.borderless)
    }
}

struct PreviewSheet: View {
    let statements: [String]
    let committing: Bool
    let cancel: () -> Void
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("将要执行的 SQL").font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(statements.enumerated()), id: \.offset) { _, s in
                        SQLText(sql: s + ";")
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 420)
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button(action: run) {
                    if committing { ProgressView().controlSize(.small) } else { Text("执行（事务）") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(committing)
            }
        }
        .padding(16)
        .frame(width: 760)
    }
}
