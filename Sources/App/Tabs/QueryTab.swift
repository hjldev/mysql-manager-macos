import MySQLKit
import SwiftUI

@Observable
final class QueryTabModel: TabContent {
    enum ResultTab: Hashable {
        case messages
        case set(Int)
    }

    struct ResultSet: Identifiable {
        let id: Int // index into results
        let number: Int
        let grid: ResultGrid
    }

    let id = UUID()
    let app: AppModel
    var title: String
    private(set) var connID: String
    private(set) var db: String?
    let initialSQL: String
    private(set) var databases: [String] = []
    private(set) var schema: [String: [String]] = [:]
    private(set) var running = false
    private(set) var results: [StatementResult] = []
    private(set) var resultSets: [ResultSet] = []
    var activeResult = ResultTab.messages
    @ObservationIgnored let editor = EditorHandle()
    @ObservationIgnored private var session: QuerySession?

    init(app: AppModel, title: String, connID: String, db: String?, sql: String) {
        self.app = app
        self.title = title
        self.connID = connID
        self.db = db
        initialSQL = sql
        Task {
            await loadDatabases()
            await loadSchema()
            editor.focus()
        }
    }

    var dirty: Bool { false }
    var table: String? { nil }

    func onClose() {
        if let s = session {
            let db = app.db
            DispatchQueue.global().async { db.closeSession(s) }
        }
        session = nil
    }

    private func loadDatabases() async {
        let db = app.db, connID = connID
        do {
            try await app.ensureOpen(connID)
            databases = try await onBackground { try db.databases(connID) }
        } catch {
            databases = []
            app.report(error)
        }
    }

    private func loadSchema() async {
        guard let name = db, app.isOpen(connID) else {
            schema = [:]
            return
        }
        let db = app.db, connID = connID
        schema = (try? await onBackground { try db.completionSchema(connID, db: name) }) ?? [:]
    }

    func selectConnection(_ id: String) {
        guard id != connID else { return }
        onClose()
        connID = id
        db = nil
        schema = [:]
        Task { await loadDatabases() }
    }

    func selectDatabase(_ name: String?) {
        guard name != db else { return }
        db = name
        Task {
            await loadSchema()
            if let name, let s = session {
                do {
                    try await onBackground { try s.useDatabase(name) }
                } catch {
                    app.report(error)
                }
            }
        }
    }

    private func ensureSession() async throws -> QuerySession {
        if let s = session, s.connID == connID { return s }
        onClose()
        try await app.ensureOpen(connID)
        let db = app.db, connID = connID, name = self.db
        let s = try await onBackground { try db.openSession(connID, db: name) }
        session = s
        return s
    }

    func run(_ text: String? = nil) async {
        let sql = (text ?? editor.runnableText()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty, !running else { return }
        running = true
        defer { running = false }
        do {
            let s = try await ensureSession()
            results = await (try? onBackground { s.execute(sql) }) ?? []
            var sets: [ResultSet] = []
            for (i, r) in results.enumerated() where r.columns != nil && r.error == nil {
                sets.append(ResultSet(id: i, number: sets.count + 1, grid: ResultGrid(columns: r.columns!, rows: r.rows)))
            }
            resultSets = sets
            let hasError = results.contains { $0.error != nil }
            activeResult = hasError || sets.isEmpty ? .messages : .set(sets[0].id)
            await afterRun()
        } catch {
            app.report(error)
        }
        trimMemory()
    }

    /// Keep the tree, completion schema and database picker in sync with what ran.
    private func afterRun() async {
        let ok = results.filter { $0.error == nil }.map(\.sql)
        let ddl = ok.contains { $0.firstMatch(of: /^\s*(?i:create|drop|alter|rename|truncate)\b/) != nil }
        if ddl, let name = db {
            await app.refreshDatabase(connID, name)
            await loadSchema()
        }
        if ok.contains(where: { $0.firstMatch(of: /^\s*(?i:create|drop)\s+(?i:database|schema)\b/) != nil }) {
            await app.refreshConnection(connID)
            await loadDatabases()
        }
        if let use = ok.last(where: { $0.firstMatch(of: /^\s*(?i:use)\s+/) != nil }),
           let m = use.firstMatch(of: /^\s*(?i:use)\s+`?([^`;\s]+)`?/) {
            let name = String(m.1)
            if name != db {
                db = name
                await loadSchema()
            }
        }
    }

    func stop() {
        guard let s = session else { return }
        let db = app.db
        Task {
            do {
                try await onBackground { try db.cancel(s) }
            } catch {
                app.report(error)
            }
        }
    }

    func export(_ set: ResultSet, format: ExportFormat) {
        guard let path = FilePanels.save(defaultName: "result.\(format.rawValue)", extensions: [format.rawValue]) else { return }
        let r = results[set.id]
        let columns = r.columns ?? [], rows = r.rows
        Task {
            do {
                let n = try await onBackground { try Transfer.exportRows(columns: columns, rows: rows, format: format, path: path) }
                app.toast(.success, "已导出 \(n) 行")
            } catch {
                app.report(error)
            }
        }
    }

    func summary(_ r: StatementResult) -> String {
        if let e = r.error { return e }
        if r.columns != nil {
            return "\(r.rows.count) 行"
        }
        return "影响 \(r.affectedRows) 行" + (r.lastInsertID.map { "，LAST_INSERT_ID = \($0)" } ?? "")
    }
}

struct QueryTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: QueryTabModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                SQLEditorView(initialText: model.initialSQL, schema: model.schema, handle: model.editor)
                    .frame(minHeight: 80, idealHeight: 300)
                QueryResultsView(model: model)
                    .frame(minHeight: 100, idealHeight: 360)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.connID }, set: { model.selectConnection($0) })) {
                ForEach(app.connections) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 160)
            Picker("", selection: Binding(get: { model.db ?? "" }, set: { model.selectDatabase($0.isEmpty ? nil : $0) })) {
                Text("选择数据库").tag("")
                ForEach(model.databases, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
            Button {
                Task { await model.run() }
            } label: {
                if model.running {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("运行", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .help("运行选中的 SQL，未选中时运行全部（⌘↩）")
            .disabled(model.running)
            Button {
                model.stop()
            } label: {
                Label("停止", systemImage: "stop.fill")
            }
            .disabled(!model.running)
            Button("运行当前语句") {
                Task { await model.run(model.editor.currentStatement()) }
            }
            .buttonStyle(.borderless)
            .help("⇧⌘↩")
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

private struct QueryResultsView: View {
    @Bindable var model: QueryTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tab("信息", .messages)
                ForEach(model.resultSets) { s in tab("结果 \(s.number)", .set(s.id)) }
                Spacer()
            }
            .padding(.horizontal, 6)
            Divider()
            switch model.activeResult {
            case .messages:
                messages
            case let .set(i):
                if let s = model.resultSets.first(where: { $0.id == i }) {
                    resultView(s)
                } else {
                    messages
                }
            }
        }
    }

    private func tab(_ title: String, _ value: QueryTabModel.ResultTab) -> some View {
        let selected = model.activeResult == value
        return Button {
            model.activeResult = value
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.results.isEmpty {
                    Text("尚未执行").foregroundStyle(.secondary).padding(12)
                }
                ForEach(Array(model.results.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.sql)
                            .font(.mono)
                            .lineLimit(8)
                            .textSelection(.enabled)
                        if let e = r.error {
                            Text(e)
                                .font(.mono)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        } else {
                            HStack(spacing: 6) {
                                Tag(text: "OK", color: .green)
                                Text("\(model.summary(r)) · \(r.elapsedMs) ms").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func resultView(_ s: QueryTabModel.ResultSet) -> some View {
        let r = model.results[s.id]
        return VStack(spacing: 0) {
            DataGridView(source: s.grid)
            Divider()
            HStack(spacing: 4) {
                Text("\(model.summary(r)) · \(r.elapsedMs) ms").foregroundStyle(.secondary)
                Spacer()
                Button { model.export(s, format: .csv) } label: { Label("CSV", systemImage: "square.and.arrow.down") }
                Button("JSON") { model.export(s, format: .json) }
                Button("SQL") { model.export(s, format: .sql) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .id(s.id)
    }
}
