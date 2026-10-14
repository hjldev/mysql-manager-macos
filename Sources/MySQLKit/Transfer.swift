import Foundation

public enum ExportFormat: String, Sendable, CaseIterable {
    case csv, json, sql
}

public struct CsvPreview: Sendable {
    public var headers: [String]
    public var rows: [[String]]
}

public struct ScriptResult: Sendable {
    public var total: Int
    public var executed: Int
    public var errors: [String]
}

/// (done, total, message); total is 0 when unknown.
public typealias ProgressHandler = @Sendable (Int, Int, String) -> Void

/// Buffered writes to a new file.
final class FileWriter {
    private let handle: FileHandle
    private var buffer = Data()

    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw MySQLError.message("无法创建文件 \(path)")
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func write(_ s: String) throws {
        buffer.append(contentsOf: s.utf8)
        if buffer.count >= 256 * 1024 { try flush() }
    }

    func write(_ bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes)
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        try flush()
        try handle.close()
    }
}

/// Streams rows into a file in one of the export formats.
final class RowWriter {
    private static let sqlBatch = 100
    private let out: FileWriter
    private let format: ExportFormat
    private let table: String
    private var columns: [QueryColumn] = []
    private var batch: [String] = []
    private(set) var count = 0

    init(_ out: FileWriter, format: ExportFormat, table: String) {
        self.out = out
        self.format = format
        self.table = table
    }

    func begin(_ columns: [QueryColumn]) throws {
        self.columns = columns
        switch format {
        case .csv:
            try out.write([0xEF, 0xBB, 0xBF]) // UTF-8 BOM for Excel
            try out.write(columns.map { csvField($0.name) }.joined(separator: ",") + "\n")
        case .json:
            try out.write("[")
        case .sql:
            break
        }
    }

    func row(_ cells: [String?]) throws {
        switch format {
        case .csv:
            try out.write(cells.map { csvField($0 ?? "") }.joined(separator: ",") + "\n")
        case .json:
            let fields = zip(columns, cells).map { meta, cell in
                jsonString(meta.name) + ":" + jsonValue(cell, numeric: meta.isNumeric)
            }
            try out.write((count > 0 ? "," : "") + "\n  {" + fields.joined(separator: ",") + "}")
        case .sql:
            let values = zip(columns, cells).map { meta, cell in sqlLiteral(cell, meta) }
            batch.append("(" + values.joined(separator: ", ") + ")")
            if batch.count >= Self.sqlBatch { try flushBatch() }
        }
        count += 1
    }

    private func flushBatch() throws {
        guard !batch.isEmpty else { return }
        let cols = columns.map { SQL.quoteIdent($0.name) }.joined(separator: ", ")
        try out.write("INSERT INTO \(SQL.quoteIdent(table)) (\(cols)) VALUES\n\(batch.joined(separator: ",\n"));\n")
        batch.removeAll(keepingCapacity: true)
    }

    /// Writes the trailer; the file stays open (dumps keep appending).
    func finish() throws -> Int {
        switch format {
        case .json: try out.write("\n]\n")
        case .sql: try flushBatch()
        case .csv: break
        }
        return count
    }
}

func csvField(_ s: String) -> String {
    guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return s }
    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

func jsonString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

/// Numbers of numeric columns stay numbers (as the server wrote them).
func jsonValue(_ cell: String?, numeric: Bool) -> String {
    guard let s = cell else { return "null" }
    if numeric, s.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil {
        return s
    }
    return jsonString(s)
}

/// A cell as an SQL literal, for SQL exports.
func sqlLiteral(_ cell: String?, _ meta: QueryColumn) -> String {
    guard let s = cell else { return "NULL" }
    if meta.isBinary && s.hasPrefix("0x") { return s }
    if meta.isNumeric && !s.isEmpty { return s }
    return SQL.quote(s)
}

/// Streaming CSV parser: quoted fields, doubled quotes, CRLF/LF/CR line ends,
/// UTF-8 BOM, records of any length. Empty lines are skipped.
final class CSVReader {
    private let handle: FileHandle
    private let delimiter: UInt8
    private var chunk: [UInt8] = []
    private var pos = 0
    private var eof = false
    private var started = false

    init(path: String, delimiter: String) throws {
        guard let h = FileHandle(forReadingAtPath: path) else { throw MySQLError.message("无法打开文件 \(path)") }
        handle = h
        switch delimiter {
        case "\\t", "tab", "\t": self.delimiter = 0x09
        default: self.delimiter = delimiter.utf8.first ?? 0x2C
        }
    }

    deinit {
        try? handle.close()
    }

    private func nextByte() throws -> UInt8? {
        if pos >= chunk.count {
            if eof { return nil }
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty {
                eof = true
                return nil
            }
            chunk = [UInt8](data)
            pos = 0
            if !started {
                started = true
                if chunk.starts(with: [0xEF, 0xBB, 0xBF]) { pos = 3 }
                if pos >= chunk.count { return try nextByte() }
            }
        }
        defer { pos += 1 }
        return chunk[pos]
    }

    private func peekByte() throws -> UInt8? {
        guard let b = try nextByte() else { return nil }
        pos -= 1
        return b
    }

    func next() throws -> [String]? {
        var record: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var any = false
        while let b = try nextByte() {
            any = true
            if inQuotes {
                if b == 0x22 {
                    if try peekByte() == 0x22 {
                        _ = try nextByte()
                        field.append(0x22)
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(b)
                }
                continue
            }
            switch b {
            case 0x22 where field.isEmpty:
                inQuotes = true
            case delimiter:
                record.append(String(decoding: field, as: UTF8.self))
                field.removeAll(keepingCapacity: true)
            case 0x0A, 0x0D:
                if b == 0x0D, try peekByte() == 0x0A { _ = try nextByte() }
                if record.isEmpty && field.isEmpty {
                    any = false
                    continue // empty line
                }
                record.append(String(decoding: field, as: UTF8.self))
                return record
            default:
                field.append(b)
            }
        }
        guard any else { return nil }
        record.append(String(decoding: field, as: UTF8.self))
        return record
    }
}

public enum Transfer {
    /// First rows of a CSV file, for the import column mapping.
    public static func previewCSV(path: String, delimiter: String, hasHeader: Bool) throws -> CsvPreview {
        let r = try CSVReader(path: path, delimiter: delimiter)
        var headers: [String] = []
        if hasHeader { headers = try r.next() ?? [] }
        var rows: [[String]] = []
        while rows.count < 10, let rec = try r.next() {
            rows.append(rec)
        }
        if !hasHeader {
            let n = rows.map(\.count).max() ?? 0
            headers = (0..<n).map { "column\($0 + 1)" }
        }
        return CsvPreview(headers: headers, rows: rows)
    }

    /// Rows already loaded in the app (query results) to a file.
    public static func exportRows(columns: [QueryColumn], rows: [[String?]], format: ExportFormat, path: String,
                                  table: String = "query_result") throws -> Int {
        let out = try FileWriter(path: path)
        let w = RowWriter(out, format: format, table: table)
        try w.begin(columns)
        for r in rows { try w.row(r) }
        let n = try w.finish()
        try out.close()
        return n
    }
}

extension MySQLConnection {
    /// Stream the result of `sql` into `writer`.
    fileprivate func stream(_ sql: String, into writer: RowWriter, onRow: (Int) -> Void = { _ in }) throws {
        var began = false
        try query(sql) { e in
            switch e {
            case let .columns(c) where !began:
                try writer.begin(c)
                began = true
            case let .row(r):
                try writer.row(r)
                onRow(writer.count)
            default:
                break
            }
        }
        if !began { try writer.begin([]) }
    }

    func exportTable(db: String, table: String, format: ExportFormat, path: String, filter: String?,
                     progress: ProgressHandler) throws -> Int {
        var sql = "SELECT * FROM \(SQL.qualified(db, table))"
        if let f = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty { sql += " WHERE \(f)" }
        let out = try FileWriter(path: path)
        let w = RowWriter(out, format: format, table: table)
        try stream(sql, into: w) { n in
            if n % 5000 == 0 { progress(n, 0, "\(n) 行") }
        }
        let n = try w.finish()
        try out.close()
        progress(n, n, "完成")
        return n
    }

    /// Dump structure (and optionally data) of a database, or of `tables` only.
    /// Returns the number of data rows written.
    func dumpDatabase(db: String, path: String, includeData: Bool, tables: [String]?,
                      progress: ProgressHandler) throws -> Int {
        let all = try rows("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(quote(db)) ORDER BY TABLE_NAME
            """)
        let selected = all.compactMap { r -> (String, Bool)? in
            guard let name = r[0], tables?.contains(name) ?? true else { return nil }
            return (name, (r[1] ?? "").contains("VIEW"))
        }
        // tables first, views afterwards (they may depend on tables)
        let ordered = selected.filter { !$0.1 } + selected.filter { $0.1 }

        let out = try FileWriter(path: path)
        try out.write("-- MySQL Manager dump\n-- Database: \(db)\n\n")
        try out.write("SET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS = 0;\n\n")
        var totalRows = 0
        for (done, (table, isView)) in ordered.enumerated() {
            progress(done, ordered.count, table)
            let ddl = try showCreate(db, table)
            let kw = isView ? "VIEW" : "TABLE"
            try out.write("-- ----------------------------\n-- \(kw) \(table)\n-- ----------------------------\n")
            try out.write("DROP \(kw) IF EXISTS \(SQL.quoteIdent(table));\n\(ddl);\n\n")
            if includeData && !isView {
                let w = RowWriter(out, format: .sql, table: table)
                try stream("SELECT * FROM \(SQL.qualified(db, table))", into: w)
                totalRows += try w.finish()
                try out.write("\n")
            }
        }
        try out.write("SET FOREIGN_KEY_CHECKS = 1;\n")
        try out.close()
        progress(ordered.count, ordered.count, "完成")
        return totalRows
    }

    /// Import a CSV file in one transaction. `mapping[i]` is the target column
    /// for CSV column i (nil = skip). Returns the row count.
    func importCSV(db: String, table: String, path: String, delimiter: String, hasHeader: Bool,
                   mapping: [String?], emptyAsNull: Bool, progress: ProgressHandler) throws -> Int {
        let targets = mapping.enumerated().compactMap { i, m -> (Int, String)? in
            guard let m, !m.isEmpty else { return nil }
            return (i, m)
        }
        guard !targets.isEmpty else { throw MySQLError.message("请至少映射一个字段") }
        let head = "INSERT INTO \(SQL.qualified(db, table)) (\(targets.map { SQL.quoteIdent($0.1) }.joined(separator: ", "))) VALUES "
        let reader = try CSVReader(path: path, delimiter: delimiter)
        if hasHeader { _ = try reader.next() }

        try execute("START TRANSACTION")
        do {
            var batch: [String] = []
            var count = 0
            var line = 0
            func flush() throws {
                guard !batch.isEmpty else { return }
                do {
                    try execute(head + batch.joined(separator: ", "))
                } catch let e as MySQLError where e.isServerError {
                    throw MySQLError.message("第 \(line) 行附近：\(e.localizedDescription)")
                }
                count += batch.count
                batch.removeAll(keepingCapacity: true)
                progress(count, 0, "\(count) 行")
            }
            while let rec = try reader.next() {
                line += 1
                let values = targets.map { i, _ -> String in
                    let v = i < rec.count ? rec[i] : ""
                    return emptyAsNull && v.isEmpty ? "NULL" : quote(v)
                }
                batch.append("(" + values.joined(separator: ", ") + ")")
                if batch.count >= 500 { try flush() }
            }
            try flush()
            try execute("COMMIT")
            progress(count, count, "完成")
            return count
        } catch {
            if !isBroken { _ = try? execute("ROLLBACK") }
            throw error
        }
    }

    func runScript(_ text: String, continueOnError: Bool, progress: ProgressHandler) -> ScriptResult {
        let statements = SQL.splitStatements(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var result = ScriptResult(total: statements.count, executed: 0, errors: [])
        for (i, s) in statements.enumerated() {
            do {
                try execute(s)
                result.executed += 1
            } catch {
                result.errors.append("#\(i + 1): \(error.localizedDescription)\n\(s.prefix(200))")
                if !continueOnError || isBroken { break }
            }
            if i % 50 == 0 { progress(i + 1, statements.count, "") }
        }
        progress(statements.count, statements.count, "完成")
        return result
    }
}
