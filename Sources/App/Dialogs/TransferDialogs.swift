import MySQLKit
import SwiftUI

/// Progress reported from a background transfer.
@Observable
final class TransferProgress {
    var done = 0
    var total = 0
    var message = ""

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }

    /// A handler that can be called from any thread.
    var handler: ProgressHandler {
        { done, total, message in
            Task { @MainActor in
                self.done = done
                self.total = total
                self.message = message
            }
        }
    }
}

private struct DialogButtons: View {
    let cancelTitle: String
    let okTitle: String
    let running: Bool
    var okDisabled = false
    let cancel: () -> Void
    let ok: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(cancelTitle, action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(running)
            Button(action: ok) {
                if running { ProgressView().controlSize(.small) } else { Text(okTitle) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(running || okDisabled)
        }
    }
}

private struct PathField: View {
    let path: String
    let placeholder: String
    let pick: () -> Void

    var body: some View {
        HStack {
            TextField("", text: .constant(path), prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .disabled(true)
            Button("浏览", action: pick)
        }
    }
}

// MARK: - Export

struct ExportDialog: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: TransferTarget
    @State private var format = ExportFormat.csv
    @State private var path = ""
    @State private var filter = ""
    @State private var running = false
    @State private var progress = TransferProgress()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导出 \(target.table ?? "")").font(.headline)
            Form {
                Picker("格式", selection: $format) {
                    Text("CSV").tag(ExportFormat.csv)
                    Text("JSON").tag(ExportFormat.json)
                    Text("SQL INSERT").tag(ExportFormat.sql)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                LabeledContent("文件") { PathField(path: path, placeholder: "选择保存位置", pick: pick) }
                TextField("WHERE", text: $filter, prompt: Text("可选，过滤条件"))
                    .font(.mono)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.columns)
            if running || !progress.message.isEmpty {
                Text(progress.message).foregroundStyle(.secondary).font(.callout)
            }
            DialogButtons(cancelTitle: "取消", okTitle: "开始导出", running: running, cancel: { dismiss() }) {
                Task { await run() }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: format) {
            if !path.isEmpty {
                path = (path as NSString).deletingPathExtension + "." + format.rawValue
            }
        }
    }

    private func pick() {
        if let p = FilePanels.save(defaultName: "\(target.table ?? "export").\(format.rawValue)", extensions: [format.rawValue]) {
            path = p
        }
    }

    private func run() async {
        guard let table = target.table else { return }
        if path.isEmpty { pick() }
        guard !path.isEmpty else { return }
        running = true
        defer { running = false }
        let db = app.db, t = target, format = format, path = path, filter = filter, handler = progress.handler
        do {
            let n = try await onBackground {
                try db.exportTable(t.connID, db: t.db, table: table, format: format, path: path, filter: filter, progress: handler)
            }
            app.toast(.success, "已导出 \(n) 行")
            dismiss()
        } catch {
            app.report(error)
        }
    }
}

// MARK: - Dump

struct DumpDialog: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: TransferTarget
    @State private var includeData = true
    @State private var path = ""
    @State private var running = false
    @State private var progress = TransferProgress()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("转储 SQL 文件 - \(target.table ?? target.db)").font(.headline)
            Form {
                Picker("内容", selection: $includeData) {
                    Text("结构和数据").tag(true)
                    Text("仅结构").tag(false)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                LabeledContent("文件") { PathField(path: path, placeholder: "选择保存位置", pick: pick) }
            }
            .formStyle(.columns)
            if running {
                ProgressView(value: progress.fraction ?? 0)
                Text("\(progress.done) / \(progress.total) \(progress.message)").foregroundStyle(.secondary).font(.callout)
            }
            DialogButtons(cancelTitle: "取消", okTitle: "开始", running: running, cancel: { dismiss() }) {
                Task { await run() }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pick() {
        if let p = FilePanels.save(defaultName: "\(target.table ?? target.db).sql", extensions: ["sql"]) {
            path = p
        }
    }

    private func run() async {
        if path.isEmpty { pick() }
        guard !path.isEmpty else { return }
        running = true
        defer { running = false }
        let db = app.db, t = target, path = path, includeData = includeData, handler = progress.handler
        do {
            let rows = try await onBackground {
                try db.dumpDatabase(t.connID, db: t.db, path: path, includeData: includeData,
                                    tables: t.table.map { [$0] }, progress: handler)
            }
            app.toast(.success, includeData ? "转储完成，共 \(rows) 行数据" : "转储完成")
            dismiss()
        } catch {
            app.report(error)
        }
    }
}

// MARK: - CSV import

struct ImportDialog: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: TransferTarget
    @State private var path = ""
    @State private var delimiter = ","
    @State private var hasHeader = true
    @State private var emptyAsNull = true
    @State private var preview: CsvPreview?
    @State private var tableColumns: [String] = []
    @State private var mapping: [String] = [] // "" = skip
    @State private var running = false
    @State private var progress = TransferProgress()

    private static let delimiters = [("逗号 ,", ","), ("分号 ;", ";"), ("制表符 Tab", "\\t"), ("竖线 |", "|")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入 CSV 到 \(target.table ?? "")").font(.headline)
            Form {
                LabeledContent("文件") { PathField(path: path, placeholder: "选择 CSV 文件", pick: pick) }
                LabeledContent("分隔符") {
                    HStack(spacing: 16) {
                        Picker("", selection: $delimiter) {
                            ForEach(Self.delimiters, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Toggle("第一行是字段名", isOn: $hasHeader)
                        Toggle("空值作为 NULL", isOn: $emptyAsNull)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .formStyle(.columns)
            if let preview {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            ForEach(preview.headers.indices, id: \.self) { i in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preview.headers[i]).foregroundStyle(.secondary).font(.caption)
                                    Picker("", selection: binding(i)) {
                                        Text("跳过").tag("")
                                        ForEach(tableColumns, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                    .frame(minWidth: 110)
                                }
                            }
                        }
                        Divider()
                        ForEach(preview.rows.indices, id: \.self) { r in
                            GridRow {
                                ForEach(preview.headers.indices, id: \.self) { c in
                                    Text(c < preview.rows[r].count ? preview.rows[r][c] : "")
                                        .font(.mono)
                                        .lineLimit(1)
                                        .frame(maxWidth: 240, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 300)
                .border(Color(nsColor: .separatorColor))
            }
            if running {
                Text(progress.message).foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Text("导入在一个事务中执行，出错会全部回滚").foregroundStyle(.secondary).font(.callout)
                DialogButtons(cancelTitle: "取消", okTitle: "开始导入", running: running, okDisabled: preview == nil,
                              cancel: { dismiss() }) {
                    Task { await run() }
                }
            }
        }
        .padding(20)
        .frame(width: 760)
        .controlSize(.small)
        .task { await loadColumns() }
        .onChange(of: delimiter) { loadPreview() }
        .onChange(of: hasHeader) { loadPreview() }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding { i < mapping.count ? mapping[i] : "" } set: { v in
            if i < mapping.count { mapping[i] = v }
        }
    }

    private func loadColumns() async {
        guard let table = target.table else { return }
        let db = app.db, t = target
        do {
            tableColumns = try await onBackground { try db.columns(t.connID, db: t.db, table: table) }.map(\.name)
        } catch {
            app.report(error)
        }
    }

    private func pick() {
        guard let p = FilePanels.open(extensions: ["csv", "txt", "tsv"]) else { return }
        path = p
        if p.lowercased().hasSuffix(".tsv") { delimiter = "\\t" }
        loadPreview()
    }

    private func loadPreview() {
        guard !path.isEmpty else { return }
        do {
            let p = try Transfer.previewCSV(path: path, delimiter: delimiter, hasHeader: hasHeader)
            preview = p
            let lower = Dictionary(tableColumns.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            mapping = p.headers.enumerated().map { i, h in
                hasHeader ? (lower[h.trimmingCharacters(in: .whitespaces).lowercased()] ?? "")
                    : (i < tableColumns.count ? tableColumns[i] : "")
            }
        } catch {
            preview = nil
            app.report(error)
        }
    }

    private func run() async {
        guard let table = target.table, !path.isEmpty else { return }
        guard mapping.contains(where: { !$0.isEmpty }) else {
            app.toast(.warning, "请至少映射一个字段")
            return
        }
        running = true
        defer { running = false }
        let db = app.db, t = target, path = path, delimiter = delimiter, hasHeader = hasHeader
        let map = mapping.map { $0.isEmpty ? nil : $0 }, emptyAsNull = emptyAsNull, handler = progress.handler
        do {
            let n = try await onBackground {
                try db.importCSV(t.connID, db: t.db, table: table, path: path, delimiter: delimiter, hasHeader: hasHeader,
                                 mapping: map, emptyAsNull: emptyAsNull, progress: handler)
            }
            app.toast(.success, "已导入 \(n) 行")
            dismiss()
        } catch {
            app.report(error)
        }
    }
}

// MARK: - Run SQL file

struct RunSQLFileDialog: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: TransferTarget
    @State private var path = ""
    @State private var db = ""
    @State private var databases: [String] = []
    @State private var continueOnError = false
    @State private var running = false
    @State private var result: ScriptResult?
    @State private var progress = TransferProgress()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("运行 SQL 文件").font(.headline)
            Form {
                LabeledContent("文件") {
                    PathField(path: path, placeholder: "选择 .sql 文件") {
                        if let p = FilePanels.open(extensions: ["sql", "txt"]) { path = p }
                    }
                }
                Picker("数据库", selection: $db) {
                    Text("（不指定）").tag("")
                    ForEach(databases, id: \.self) { Text($0).tag($0) }
                }
                Toggle("遇到错误继续", isOn: $continueOnError)
                    .toggleStyle(.checkbox)
            }
            .formStyle(.columns)
            if running || result != nil {
                ProgressView(value: progress.fraction ?? 0)
                Text("\(progress.done) / \(progress.total)").foregroundStyle(.secondary).font(.callout)
            }
            if let result {
                Text("共 \(result.total) 条语句，成功 \(result.executed) 条，失败 \(result.errors.count) 条")
                    .foregroundStyle(.secondary)
                if !result.errors.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, e in
                                Text(e)
                                    .font(.mono)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
            DialogButtons(cancelTitle: "关闭", okTitle: "开始", running: running, okDisabled: path.isEmpty,
                          cancel: { dismiss() }) {
                Task { await run() }
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            db = target.db
            let service = app.db, connID = target.connID
            databases = (try? await onBackground { try service.databases(connID) }) ?? []
        }
    }

    private func run() async {
        guard !path.isEmpty else { return }
        running = true
        result = nil
        defer { running = false }
        let service = app.db, connID = target.connID, path = path, db = db.isEmpty ? nil : db
        let continueOnError = continueOnError, handler = progress.handler
        do {
            let r = try await onBackground {
                try service.runSQLFile(connID, db: db, path: path, continueOnError: continueOnError, progress: handler)
            }
            result = r
            if r.errors.isEmpty { app.toast(.success, "执行完成，共 \(r.executed) 条语句") }
            await app.refreshConnection(connID)
        } catch {
            app.report(error)
        }
    }
}
