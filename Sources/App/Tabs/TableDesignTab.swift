import MySQLKit
import SwiftUI

@Observable
final class TableDesignModel: TabContent {
    enum Pane: Hashable { case columns, indexes, foreignKeys, options, sql, ddl }

    let id = UUID()
    let app: AppModel
    let connID: String
    let dbName: String
    private(set) var tableName: String?
    private(set) var original: TableDesign?
    var design = TableDesign.newTable() {
        didSet { schedulePreview() }
    }
    private(set) var loading = false
    private(set) var saving = false
    var pane = Pane.columns
    var selectedColumn: ColumnDef.ID?
    private(set) var ddl = ""
    private(set) var previewSQL: [String] = []
    private(set) var previewError = ""
    private(set) var charsets: [String] = []
    private(set) var tableCollations: [String] = []
    private(set) var columnCollations: [String] = []
    private(set) var schema: [String: [String]] = [:]
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(app: AppModel, connID: String, db: String, table: String?) {
        self.app = app
        self.connID = connID
        dbName = db
        tableName = table
        Task { await load() }
    }

    var title: String { tableName.map { "设计 \($0)" } ?? "新建表" }
    var dirty: Bool { isNew || !previewSQL.isEmpty }
    var isNew: Bool { original == nil }
    var db: String? { dbName }
    var table: String? { tableName }
    var columnNames: [String] { design.columns.map(\.name).filter { !$0.isEmpty } }

    func onClose() {
        previewTask?.cancel()
    }

    func load() async {
        loading = true
        defer { loading = false }
        let db = app.db, connID = connID, dbName = dbName
        charsets = ((try? await onBackground { try db.charsets(connID) }) ?? []).map(\.name)
        schema = (try? await onBackground { try db.completionSchema(connID, db: dbName) }) ?? [:]
        do {
            if let t = tableName {
                let d = try await onBackground { try db.tableDesign(connID, db: dbName, table: t) }
                original = d
                design = d
                ddl = try await onBackground { try db.tableDDL(connID, db: dbName, table: t) }
            } else {
                original = nil
                design = .newTable()
            }
            selectedColumn = design.columns.first?.id
        } catch {
            app.report(error)
        }
        updatePreview()
        await loadTableCollations()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { updatePreview() }
        }
    }

    private func updatePreview() {
        do {
            previewSQL = try DDL.preview(db: dbName, original: original, design: design)
            previewError = ""
        } catch {
            previewSQL = []
            previewError = error.localizedDescription
        }
    }

    func loadTableCollations() async {
        tableCollations = await collations(design.charset)
    }

    func loadColumnCollations(_ charset: String?) async {
        columnCollations = await collations(charset)
    }

    private func collations(_ charset: String?) async -> [String] {
        guard let cs = charset, !cs.isEmpty else { return [] }
        let db = app.db, connID = connID
        return (try? await onBackground { try db.collations(connID, charset: cs) }) ?? []
    }

    func save() async {
        updatePreview()
        if !previewError.isEmpty {
            app.toast(.error, previewError)
            return
        }
        if previewSQL.isEmpty {
            app.toast(.info, "没有需要保存的修改")
            return
        }
        saving = true
        defer { saving = false }
        let db = app.db, connID = connID, dbName = dbName, statements = previewSQL
        do {
            try await onBackground { try db.executeStatements(connID, db: dbName, statements) }
            let name = design.name
            app.toast(.success, isNew ? "已创建表 \(name)" : "已保存")
            tableName = name
            await load()
            await app.refreshDatabase(connID, dbName)
        } catch {
            app.report(error)
        }
    }

    // MARK: Columns

    var current: ColumnDef? {
        design.columns.first { $0.id == selectedColumn }
    }

    private var currentIndex: Int? {
        design.columns.firstIndex { $0.id == selectedColumn }
    }

    func column(_ id: ColumnDef.ID) -> Binding<ColumnDef> {
        Binding {
            self.design.columns.first { $0.id == id } ?? ColumnDef()
        } set: { v in
            if let i = self.design.columns.firstIndex(where: { $0.id == id }) { self.design.columns[i] = v }
        }
    }

    func addColumn(insert: Bool) {
        let c = ColumnDef()
        let at = insert ? (currentIndex ?? 0) : design.columns.count
        design.columns.insert(c, at: at)
        selectedColumn = c.id
    }

    func removeColumn() {
        guard let i = currentIndex else { return }
        let name = design.columns[i].name
        design.columns.remove(at: i)
        for k in design.indexes.indices {
            design.indexes[k].columns.removeAll { baseName($0) == name }
        }
        design.indexes.removeAll { $0.columns.isEmpty }
        if !design.columns.isEmpty {
            selectedColumn = design.columns[min(i, design.columns.count - 1)].id
        } else {
            selectedColumn = nil
        }
    }

    func moveColumn(_ delta: Int) {
        guard let i = currentIndex else { return }
        let j = i + delta
        guard j >= 0 && j < design.columns.count else { return }
        design.columns.swapAt(i, j)
    }

    /// `name(10)` → `name`
    func baseName(_ c: String) -> String {
        c.replacing(/\(\d+\)$/, with: "")
    }

    func renameColumn(_ id: ColumnDef.ID, to name: String) {
        guard let i = design.columns.firstIndex(where: { $0.id == id }) else { return }
        let old = design.columns[i].name
        design.columns[i].name = name
        guard !old.isEmpty else { return }
        let fix = { (c: String) in self.baseName(c) == old ? name + c.dropFirst(old.count) : c }
        for k in design.indexes.indices { design.indexes[k].columns = design.indexes[k].columns.map(fix) }
        for k in design.foreignKeys.indices { design.foreignKeys[k].columns = design.foreignKeys[k].columns.map(fix) }
    }

    private var primaryIndex: Int? {
        design.indexes.firstIndex { $0.kind == "PRIMARY" }
    }

    func isPrimaryKey(_ c: ColumnDef) -> Bool {
        guard let p = primaryIndex else { return false }
        return design.indexes[p].columns.contains { baseName($0) == c.name }
    }

    func setPrimaryKey(_ id: ColumnDef.ID, _ on: Bool) {
        guard let i = design.columns.firstIndex(where: { $0.id == id }), !design.columns[i].name.isEmpty else { return }
        let name = design.columns[i].name
        if on {
            design.columns[i].nullable = false
            if primaryIndex == nil {
                design.indexes.insert(IndexDef(name: "PRIMARY", kind: "PRIMARY", columns: []), at: 0)
            }
            if !isPrimaryKey(design.columns[i]) { design.indexes[primaryIndex!].columns.append(name) }
        } else if let p = primaryIndex {
            design.indexes[p].columns.removeAll { baseName($0) == name }
            if design.indexes[p].columns.isEmpty { design.indexes.remove(at: p) }
        }
    }

    // MARK: Indexes and foreign keys

    func addIndex() {
        let n = design.indexes.count + 1
        design.indexes.append(IndexDef(name: "idx_\(design.name.isEmpty ? "new" : design.name)_\(n)", kind: "INDEX", columns: []))
    }

    func index(_ id: IndexDef.ID) -> Binding<IndexDef> {
        Binding {
            self.design.indexes.first { $0.id == id } ?? IndexDef(name: "", kind: "INDEX", columns: [])
        } set: { v in
            if let i = self.design.indexes.firstIndex(where: { $0.id == id }) { self.design.indexes[i] = v }
        }
    }

    func addForeignKey() {
        let n = design.foreignKeys.count + 1
        design.foreignKeys.append(ForeignKeyDef(name: "fk_\(design.name.isEmpty ? "new" : design.name)_\(n)", refSchema: dbName))
    }

    func foreignKey(_ id: ForeignKeyDef.ID) -> Binding<ForeignKeyDef> {
        Binding {
            self.design.foreignKeys.first { $0.id == id } ?? ForeignKeyDef(name: "", refSchema: "")
        } set: { v in
            if let i = self.design.foreignKeys.firstIndex(where: { $0.id == id }) { self.design.foreignKeys[i] = v }
        }
    }
}

struct TableDesignView: View {
    @Bindable var model: TableDesignModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Picker("", selection: $model.pane) {
                Text("字段").tag(TableDesignModel.Pane.columns)
                Text("索引").tag(TableDesignModel.Pane.indexes)
                Text("外键").tag(TableDesignModel.Pane.foreignKeys)
                Text("选项").tag(TableDesignModel.Pane.options)
                Text("SQL 预览").tag(TableDesignModel.Pane.sql)
                if !model.isNew { Text("DDL").tag(TableDesignModel.Pane.ddl) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(6)
            Divider()
            ZStack {
                switch model.pane {
                case .columns: ColumnsPane(model: model)
                case .indexes: IndexesPane(model: model)
                case .foreignKeys: ForeignKeysPane(model: model)
                case .options: OptionsPane(model: model)
                case .sql: SQLPane(model: model)
                case .ddl: CodePane(text: model.ddl)
                }
                if model.loading { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.design.charset) { Task { await model.loadTableCollations() } }
        .onChange(of: model.current?.charset) { _, cs in Task { await model.loadColumnCollations(cs) } }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.save() }
            } label: {
                if model.saving { ProgressView().controlSize(.mini) } else { Label("保存", systemImage: "square.and.arrow.down.on.square") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.previewError.isEmpty || model.saving)
            if !model.isNew {
                ToolButton("重新加载", systemImage: "arrow.clockwise") { Task { await model.load() } }
            }
            Text("表名").foregroundStyle(.secondary).padding(.leading, 8)
            TextField("表名", text: $model.design.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Text("@ \(model.dbName)").foregroundStyle(.secondary)
            Spacer().frame(width: 12)
            switch model.pane {
            case .columns:
                ToolButton("添加字段", systemImage: "plus") { model.addColumn(insert: false) }
                ToolButton("插入字段", systemImage: "text.insert") { model.addColumn(insert: true) }
                ToolButton("删除字段", systemImage: "minus") { model.removeColumn() }
                    .disabled(model.current == nil)
                ToolButton("上移", systemImage: "arrow.up", showsTitle: false) { model.moveColumn(-1) }
                ToolButton("下移", systemImage: "arrow.down", showsTitle: false) { model.moveColumn(1) }
            case .indexes:
                ToolButton("添加索引", systemImage: "plus") { model.addIndex() }
            case .foreignKeys:
                ToolButton("添加外键", systemImage: "plus") { model.addForeignKey() }
            default:
                EmptyView()
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct ColumnsPane: View {
    @Bindable var model: TableDesignModel

    var body: some View {
        VStack(spacing: 0) {
            Table(model.design.columns, selection: $model.selectedColumn) {
                TableColumn("名") { c in
                    TextField("", text: Binding(get: { c.name }, set: { model.renameColumn(c.id, to: $0) }))
                        .selects(c.id, in: model)
                }
                .width(min: 100, ideal: 160)
                TableColumn("类型") { c in
                    ComboField(text: model.column(c.id).dataType, items: MySQLTypes.all)
                }
                .width(min: 90, ideal: 130)
                TableColumn("长度") { c in
                    TextField("", text: model.column(c.id).length).selects(c.id, in: model)
                }
                .width(min: 50, ideal: 80)
                TableColumn("不是 null") { c in
                    Toggle("", isOn: Binding(get: { !c.nullable }, set: { model.column(c.id).wrappedValue.nullable = !$0 }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                .width(64)
                TableColumn("主键") { c in
                    Toggle("", isOn: Binding(get: { model.isPrimaryKey(c) }, set: { model.setPrimaryKey(c.id, $0) }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                .width(40)
                TableColumn("自增") { c in
                    Toggle("", isOn: model.column(c.id).autoIncrement).toggleStyle(.checkbox).labelsHidden()
                }
                .width(40)
                TableColumn("无符号") { c in
                    Toggle("", isOn: model.column(c.id).unsigned).toggleStyle(.checkbox).labelsHidden()
                }
                .width(48)
                TableColumn("默认值") { c in
                    TextField(c.nullable ? "NULL" : "", text: Binding(
                        get: { c.defaultValue ?? "" },
                        set: { model.column(c.id).wrappedValue.defaultValue = $0.isEmpty ? nil : $0 }
                    ))
                    .selects(c.id, in: model)
                }
                .width(min: 90, ideal: 150)
                TableColumn("注释") { c in
                    TextField("", text: model.column(c.id).comment).selects(c.id, in: model)
                }
                .width(min: 120, ideal: 220)
            }
            .textFieldStyle(.plain)
            .controlSize(.small)
            if let c = model.current {
                Divider()
                ColumnDetail(model: model, column: model.column(c.id))
            }
        }
    }
}

private extension View {
    /// Focusing a field in a table row selects that row.
    func selects(_ id: ColumnDef.ID, in model: TableDesignModel) -> some View {
        simultaneousGesture(TapGesture().onEnded { model.selectedColumn = id })
    }
}

private struct ColumnDetail: View {
    let model: TableDesignModel
    @Binding var column: ColumnDef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("字符集").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { column.charset ?? "" }, set: {
                        column.charset = $0.isEmpty ? nil : $0
                        column.collation = nil
                    })) {
                        Text("（表默认）").tag("")
                        ForEach(model.charsets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Text("排序规则").foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { column.collation ?? "" }, set: { column.collation = $0.isEmpty ? nil : $0 })) {
                        Text("（默认）").tag("")
                        ForEach(model.columnCollations, id: \.self) { Text($0).tag($0) }
                        if let c = column.collation, !model.columnCollations.contains(c) { Text(c).tag(c) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("ON UPDATE").foregroundStyle(.secondary)
                    TextField("例如 CURRENT_TIMESTAMP", text: Binding(get: { column.onUpdate ?? "" },
                                                                    set: { column.onUpdate = $0.isEmpty ? nil : $0 }))
                    Text("生成表达式").foregroundStyle(.secondary)
                    TextField("虚拟列表达式，如 price * qty", text: Binding(get: { column.generated ?? "" },
                                                                    set: { column.generated = $0.isEmpty ? nil : $0 }))
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack(spacing: 16) {
                        Toggle("STORED", isOn: $column.generatedStored)
                            .disabled((column.generated ?? "").isEmpty)
                        Toggle("填充零", isOn: $column.zerofill)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("默认值：纯文本会自动加引号；以 ' ( 开头或 NULL / CURRENT_TIMESTAMP 等将按表达式原样使用。空字符串请输入 ''")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Comma-separated column list with a menu of known columns; `name(10)` sets a prefix length.
struct ColumnsField: View {
    @Binding var columns: [String]
    let options: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            Menu {
                ForEach(options, id: \.self) { opt in
                    Toggle(opt, isOn: Binding(get: { columns.contains { base($0) == opt } }, set: { on in
                        if on { columns.append(opt) } else { columns.removeAll { base($0) == opt } }
                    }))
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .onAppear { text = columns.joined(separator: ", ") }
        .onChange(of: columns) { text = columns.joined(separator: ", ") }
    }

    private func base(_ c: String) -> String {
        c.replacing(/\(\d+\)$/, with: "")
    }

    private func commit() {
        let parsed = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parsed != columns { columns = parsed }
    }
}

private struct IndexesPane: View {
    @Bindable var model: TableDesignModel

    var body: some View {
        Table(model.design.indexes) {
            TableColumn("名") { i in
                TextField("", text: model.index(i.id).name).disabled(i.kind == "PRIMARY")
            }
            .width(min: 120, ideal: 200)
            TableColumn("字段（可写 name(10) 指定前缀长度）") { i in
                ColumnsField(columns: model.index(i.id).columns, options: model.columnNames)
            }
            .width(min: 200, ideal: 300)
            TableColumn("索引类型") { i in
                Picker("", selection: Binding(get: { i.kind }, set: { v in
                    model.index(i.id).wrappedValue.kind = v
                    if v == "PRIMARY" { model.index(i.id).wrappedValue.name = "PRIMARY" }
                })) {
                    ForEach(MySQLTypes.indexKinds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            .width(min: 100, ideal: 130)
            TableColumn("注释") { i in
                TextField("", text: model.index(i.id).comment)
            }
            .width(min: 120, ideal: 200)
            TableColumn("") { i in
                Button { model.design.indexes.removeAll { $0.id == i.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            .width(30)
        }
        .textFieldStyle(.plain)
        .controlSize(.small)
    }
}

private struct ForeignKeysPane: View {
    @Bindable var model: TableDesignModel

    var body: some View {
        Table(model.design.foreignKeys) {
            TableColumn("名") { f in
                TextField("", text: model.foreignKey(f.id).name)
            }
            .width(min: 100, ideal: 160)
            TableColumn("字段") { f in
                ColumnsField(columns: model.foreignKey(f.id).columns, options: model.columnNames)
            }
            .width(min: 120, ideal: 170)
            TableColumn("参考表") { f in
                ComboField(text: model.foreignKey(f.id).refTable, items: model.schema.keys.sorted())
            }
            .width(min: 120, ideal: 160)
            TableColumn("参考字段") { f in
                ColumnsField(columns: model.foreignKey(f.id).refColumns, options: model.schema[f.refTable] ?? [])
            }
            .width(min: 120, ideal: 170)
            TableColumn("删除时") { f in
                rulePicker(model.foreignKey(f.id).onDelete)
            }
            .width(min: 90, ideal: 110)
            TableColumn("更新时") { f in
                rulePicker(model.foreignKey(f.id).onUpdate)
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { f in
                Button { model.design.foreignKeys.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            .width(30)
        }
        .textFieldStyle(.plain)
        .controlSize(.small)
    }

    private func rulePicker(_ value: Binding<String>) -> some View {
        Picker("", selection: value) {
            ForEach(MySQLTypes.fkRules, id: \.self) { Text($0).tag($0) }
            if !MySQLTypes.fkRules.contains(value.wrappedValue) { Text(value.wrappedValue).tag(value.wrappedValue) }
        }
        .labelsHidden()
    }
}

private struct OptionsPane: View {
    @Bindable var model: TableDesignModel

    var body: some View {
        Form {
            LabeledContent("引擎") {
                ComboField(text: $model.design.engine, items: MySQLTypes.engines)
            }
            Picker("字符集", selection: Binding(get: { model.design.charset }, set: {
                model.design.charset = $0
                model.design.collation = ""
            })) {
                ForEach(model.charsets, id: \.self) { Text($0).tag($0) }
                if !model.charsets.contains(model.design.charset) { Text(model.design.charset).tag(model.design.charset) }
            }
            Picker("排序规则", selection: $model.design.collation) {
                Text("（字符集默认）").tag("")
                ForEach(model.tableCollations, id: \.self) { Text($0).tag($0) }
                if !model.design.collation.isEmpty && !model.tableCollations.contains(model.design.collation) {
                    Text(model.design.collation).tag(model.design.collation)
                }
            }
            LabeledContent("注释") {
                TextEditor(text: $model.design.comment)
                    .font(.body)
                    .frame(minHeight: 50, maxHeight: 90)
                    .border(Color(nsColor: .separatorColor))
            }
        }
        .formStyle(.columns)
        .controlSize(.small)
        .frame(maxWidth: 520, alignment: .leading)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SQLPane: View {
    let model: TableDesignModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.previewError.isEmpty {
                    Text(model.previewError)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                } else if model.previewSQL.isEmpty {
                    Text("没有修改").foregroundStyle(.secondary)
                }
                ForEach(Array(model.previewSQL.enumerated()), id: \.offset) { _, s in
                    SQLText(sql: s + ";")
                }
            }
            .padding(12)
        }
    }
}

private struct CodePane: View {
    let text: String

    var body: some View {
        ScrollView {
            SQLText(sql: text).padding(12)
        }
    }
}
