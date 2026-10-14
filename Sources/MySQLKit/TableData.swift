import Foundation

public struct TablePage: Sendable {
    public var columns: [QueryColumn]
    public var rows: [[String?]]
    public var total: UInt64
    public var sql: String
}

/// Column name → value (nil = NULL).
public typealias RowMap = [String: String?]

public struct RowUpdate: Sendable {
    /// Original values of the row (all columns), used to locate it.
    public var key: RowMap
    /// Changed columns only.
    public var set: RowMap

    public init(key: RowMap, set: RowMap) {
        self.key = key
        self.set = set
    }
}

public struct TableChanges: Sendable {
    public var inserts: [RowMap] = []
    public var updates: [RowUpdate] = []
    public var deletes: [RowMap] = []

    public init(inserts: [RowMap] = [], updates: [RowUpdate] = [], deletes: [RowMap] = []) {
        self.inserts = inserts
        self.updates = updates
        self.deletes = deletes
    }

    public var count: Int { inserts.count + updates.count + deletes.count }
}

extension MySQLConnection {
    func fetchRows(db: String, table: String, filter: String?, orderBy: String?, offset: UInt64, limit: UInt64) throws -> TablePage {
        var base = "FROM \(SQL.qualified(db, table))"
        if let f = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            base += " WHERE \(f)"
        }
        let total = try firstRow("SELECT COUNT(*) \(base)")?.first.flatMap { $0.flatMap { UInt64($0) } } ?? 0
        var sql = "SELECT * \(base)"
        if let o = orderBy?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
            sql += " ORDER BY \(o)"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"

        var columns: [QueryColumn] = []
        var rows: [[String?]] = []
        try query(sql) { e in
            switch e {
            case let .columns(c): columns = c
            case let .row(r): rows.append(r)
            case .end: break
            }
        }
        return TablePage(columns: columns, rows: rows, total: total, sql: sql)
    }

    func previewChanges(db: String, table: String, changes: TableChanges) throws -> [String] {
        let shape = try tableShape(db, table)
        return try buildStatements(db: db, table: table, shape: shape, changes: changes).map { $0.render() }
    }

    /// Apply all changes in one transaction. Fails (and rolls back) if a
    /// delete does not find its row.
    func applyChanges(db: String, table: String, changes: TableChanges) throws -> UInt64 {
        let shape = try tableShape(db, table)
        let statements = try buildStatements(db: db, table: table, shape: shape, changes: changes)
        try execute("START TRANSACTION")
        do {
            var total: UInt64 = 0
            for s in statements {
                let affected = try execute(s.render(noBackslashEscapes: noBackslashEscapes)).affectedRows
                if affected == 0 && s.isDelete {
                    throw MySQLError.message("未找到要删除的行（可能已被其他人修改）：\n\(s.render())")
                }
                total += affected
            }
            try execute("COMMIT")
            return total
        } catch {
            if !isBroken { _ = try? execute("ROLLBACK") }
            throw error
        }
    }

    fileprivate func tableShape(_ db: String, _ table: String) throws -> TableShape {
        let cols = try columns(of: db, table)
        guard !cols.isEmpty else { throw MySQLError.message("表 \(db).\(table) 不存在") }
        return TableShape(
            columns: cols.map(\.name),
            pk: cols.filter { $0.key == "PRI" }.map(\.name),
            binary: Dictionary(uniqueKeysWithValues: cols.map { ($0.name, TableShape.binaryTypes.contains($0.dataType)) })
        )
    }
}

struct TableShape {
    static let binaryTypes: Set<String> = [
        "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry", "point",
        "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection",
    ]
    var columns: [String]
    var pk: [String]
    var binary: [String: Bool]
}

/// A statement built from SQL text and values, rendered with the values as literals.
struct ParamStatement {
    enum Part {
        case text(String)
        case value(String?, binary: Bool)
    }

    var parts: [Part] = []
    var isDelete = false

    mutating func text(_ t: String) { parts.append(.text(t)) }
    mutating func value(_ v: String?, binary: Bool) { parts.append(.value(v, binary: binary)) }

    func render(noBackslashEscapes: Bool = false) -> String {
        parts.map {
            switch $0 {
            case let .text(t): t
            case let .value(v, binary): SQL.literal(v, binary: binary, noBackslashEscapes: noBackslashEscapes)
            }
        }.joined()
    }
}

private func appendWhere(_ s: inout ParamStatement, _ shape: TableShape, _ key: RowMap) throws {
    let keyCols = shape.pk.isEmpty ? shape.columns.filter { key[$0] != nil } : shape.pk
    guard !keyCols.isEmpty else { throw MySQLError.message("无法定位行：没有可用的键列") }
    s.text(" WHERE ")
    for (i, col) in keyCols.enumerated() {
        guard let v = key[col] else { throw MySQLError.message("缺少键列 \(col)") }
        s.text((i > 0 ? " AND " : "") + "\(SQL.quoteIdent(col)) <=> ")
        s.value(v, binary: shape.binary[col] ?? false)
    }
    if shape.pk.isEmpty { s.text(" LIMIT 1") }
}

func buildStatements(db: String, table: String, shape: TableShape, changes ch: TableChanges) throws -> [ParamStatement] {
    let target = SQL.qualified(db, table)
    let isBin = { (c: String) in shape.binary[c] ?? false }
    var out: [ParamStatement] = []

    for key in ch.deletes {
        var s = ParamStatement(isDelete: true)
        s.text("DELETE FROM \(target)")
        try appendWhere(&s, shape, key)
        out.append(s)
    }
    for up in ch.updates where !up.set.isEmpty {
        var s = ParamStatement()
        s.text("UPDATE \(target) SET ")
        // table column order, for deterministic SQL
        for (i, c) in shape.columns.filter({ up.set[$0] != nil }).enumerated() {
            s.text((i > 0 ? ", " : "") + "\(SQL.quoteIdent(c)) = ")
            s.value(up.set[c]!, binary: isBin(c))
        }
        try appendWhere(&s, shape, up.key)
        out.append(s)
    }
    for row in ch.inserts {
        let cols = shape.columns.filter { row[$0] != nil }
        var s = ParamStatement()
        if cols.isEmpty {
            s.text("INSERT INTO \(target) () VALUES ()")
        } else {
            s.text("INSERT INTO \(target) (\(cols.map(SQL.quoteIdent).joined(separator: ", "))) VALUES (")
            for (i, c) in cols.enumerated() {
                if i > 0 { s.text(", ") }
                s.value(row[c]!, binary: isBin(c))
            }
            s.text(")")
        }
        out.append(s)
    }
    return out
}
