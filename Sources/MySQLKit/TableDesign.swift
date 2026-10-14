import Foundation

public struct ColumnDef: Sendable, Identifiable, Hashable {
    public var id = UUID()
    /// Name of the column in the existing table (nil for new columns).
    public var origName: String?
    public var name: String
    public var dataType: String
    /// Contents of the parentheses: `255`, `10,2`, `'a','b'`.
    public var length: String
    public var unsigned = false
    public var zerofill = false
    public var nullable = true
    /// Default as SQL expression text; plain text is quoted automatically.
    public var defaultValue: String?
    public var autoIncrement = false
    public var onUpdate: String?
    public var comment = ""
    public var charset: String?
    public var collation: String?
    public var generated: String?
    public var generatedStored = false

    public init(origName: String? = nil, name: String = "", dataType: String = "varchar", length: String = "255") {
        self.origName = origName
        self.name = name
        self.dataType = dataType
        self.length = length
    }
}

public struct IndexDef: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    /// PRIMARY | UNIQUE | INDEX | FULLTEXT | SPATIAL
    public var kind: String
    /// Column names, optionally with a prefix length: `name(10)`.
    public var columns: [String]
    public var comment = ""

    public init(name: String, kind: String, columns: [String], comment: String = "") {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.comment = comment
    }
}

public struct ForeignKeyDef: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var columns: [String]
    public var refSchema: String
    public var refTable: String
    public var refColumns: [String]
    public var onUpdate: String
    public var onDelete: String

    public init(name: String, columns: [String] = [], refSchema: String, refTable: String = "", refColumns: [String] = [],
                onUpdate: String = "RESTRICT", onDelete: String = "RESTRICT") {
        self.name = name
        self.columns = columns
        self.refSchema = refSchema
        self.refTable = refTable
        self.refColumns = refColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    /// Same definition, ignoring the UI identity.
    func sameDefinition(_ o: ForeignKeyDef) -> Bool {
        name == o.name && columns == o.columns && refSchema == o.refSchema && refTable == o.refTable
            && refColumns == o.refColumns && onUpdate == o.onUpdate && onDelete == o.onDelete
    }
}

public struct TableDesign: Sendable, Hashable {
    public var name = ""
    public var engine = "InnoDB"
    public var charset = "utf8mb4"
    public var collation = ""
    public var comment = ""
    public var columns: [ColumnDef] = []
    public var indexes: [IndexDef] = []
    public var foreignKeys: [ForeignKeyDef] = []

    public init() {}

    /// A new table with an auto-increment `id` primary key.
    public static func newTable() -> TableDesign {
        var id = ColumnDef(name: "id", dataType: "int", length: "")
        id.nullable = false
        id.autoIncrement = true
        id.unsigned = true
        var t = TableDesign()
        t.columns = [id]
        t.indexes = [IndexDef(name: "PRIMARY", kind: "PRIMARY", columns: ["id"])]
        return t
    }
}

public enum DDL {
    static let numericTypes: Set<String> = [
        "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double",
        "real", "bit", "year",
    ]

    static func isRawDefault(_ expr: String, _ dataType: String) -> Bool {
        let u = expr.uppercased()
        return u == "NULL"
            || u.hasPrefix("CURRENT_TIMESTAMP")
            || u.hasPrefix("NOW(")
            || u.hasPrefix("LOCALTIME")
            || u == "TRUE"
            || u == "FALSE"
            || expr.hasPrefix("(")
            || expr.hasPrefix("'")
            || expr.hasPrefix("\"")
            || u.hasPrefix("B'")
            || u.hasPrefix("X'")
            || u.hasPrefix("0X")
            || (Double(expr) != nil && numericTypes.contains(dataType.lowercased()))
    }

    static func renderDefault(_ expr: String, _ dataType: String) -> String {
        let t = expr.trimmingCharacters(in: .whitespaces)
        return isRawDefault(t, dataType) ? t : SQL.quote(t)
    }

    static func renderType(_ c: ColumnDef) -> String {
        var s = c.dataType.trimmingCharacters(in: .whitespaces).lowercased()
        let len = c.length.trimmingCharacters(in: .whitespaces)
        if !len.isEmpty { s += "(\(len))" }
        if c.unsigned { s += " unsigned" }
        if c.zerofill { s += " zerofill" }
        return s
    }

    public static func renderColumn(_ c: ColumnDef) -> String {
        var s = "\(SQL.quoteIdent(c.name)) \(renderType(c))"
        if let cs = c.charset, !cs.isEmpty { s += " CHARACTER SET \(cs)" }
        if let co = c.collation, !co.isEmpty { s += " COLLATE \(co)" }
        if let g = c.generated?.trimmingCharacters(in: .whitespaces), !g.isEmpty {
            s += " GENERATED ALWAYS AS (\(g)) \(c.generatedStored ? "STORED" : "VIRTUAL")"
            s += c.nullable ? " NULL" : " NOT NULL"
        } else {
            s += c.nullable ? " NULL" : " NOT NULL"
            if let d = c.defaultValue, !d.trimmingCharacters(in: .whitespaces).isEmpty {
                s += " DEFAULT \(renderDefault(d, c.dataType))"
            }
            if let u = c.onUpdate?.trimmingCharacters(in: .whitespaces), !u.isEmpty {
                s += " ON UPDATE \(u)"
            }
            if c.autoIncrement { s += " AUTO_INCREMENT" }
        }
        if !c.comment.isEmpty { s += " COMMENT \(SQL.quote(c.comment))" }
        return s
    }

    /// `name(10)` → "`name`(10)"
    static func renderIndexColumn(_ col: String) -> String {
        let col = col.trimmingCharacters(in: .whitespaces)
        if let p = col.lastIndex(of: "("), col.hasSuffix(")") {
            let inner = col[col.index(after: p)..<col.index(before: col.endIndex)]
            if inner.allSatisfy(\.isASCIIDigitChar) {
                return SQL.quoteIdent(String(col[..<p])) + col[p...]
            }
        }
        return SQL.quoteIdent(col)
    }

    static func renderIndex(_ i: IndexDef) -> String {
        let cols = i.columns.map(renderIndexColumn).joined(separator: ", ")
        var s = switch i.kind.uppercased() {
        case "PRIMARY": "PRIMARY KEY (\(cols))"
        case "UNIQUE": "UNIQUE KEY \(SQL.quoteIdent(i.name)) (\(cols))"
        case "FULLTEXT": "FULLTEXT KEY \(SQL.quoteIdent(i.name)) (\(cols))"
        case "SPATIAL": "SPATIAL KEY \(SQL.quoteIdent(i.name)) (\(cols))"
        default: "KEY \(SQL.quoteIdent(i.name)) (\(cols))"
        }
        if !i.comment.isEmpty { s += " COMMENT \(SQL.quote(i.comment))" }
        return s
    }

    static func indexKey(_ i: IndexDef) -> String {
        i.kind.uppercased() == "PRIMARY" ? "PRIMARY" : i.name
    }

    static func renderForeignKey(_ db: String, _ f: ForeignKeyDef) -> String {
        let cols = { (v: [String]) in v.map(SQL.quoteIdent).joined(separator: ", ") }
        let target = f.refSchema.isEmpty || f.refSchema == db ? SQL.quoteIdent(f.refTable) : SQL.qualified(f.refSchema, f.refTable)
        var s = f.name.isEmpty ? "" : "CONSTRAINT \(SQL.quoteIdent(f.name)) "
        s += "FOREIGN KEY (\(cols(f.columns))) REFERENCES \(target) (\(cols(f.refColumns)))"
        if !f.onDelete.isEmpty { s += " ON DELETE \(f.onDelete)" }
        if !f.onUpdate.isEmpty { s += " ON UPDATE \(f.onUpdate)" }
        return s
    }

    static func renderOptions(_ t: TableDesign) -> [String] {
        var o: [String] = []
        if !t.engine.isEmpty { o.append("ENGINE=\(t.engine)") }
        if !t.charset.isEmpty { o.append("DEFAULT CHARSET=\(t.charset)") }
        if !t.collation.isEmpty { o.append("COLLATE=\(t.collation)") }
        o.append("COMMENT=\(SQL.quote(t.comment))")
        return o
    }

    public static func createTable(db: String, _ t: TableDesign) throws -> String {
        guard !t.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw MySQLError.message("请输入表名") }
        guard !t.columns.isEmpty else { throw MySQLError.message("表至少需要一个字段") }
        var parts = t.columns.map(renderColumn)
        parts += t.indexes.map(renderIndex)
        parts += t.foreignKeys.map { renderForeignKey(db, $0) }
        var opts = renderOptions(t)
        if t.comment.isEmpty { opts.removeLast() }
        return "CREATE TABLE \(SQL.qualified(db, t.name)) (\n  \(parts.joined(separator: ",\n  "))\n) \(opts.joined(separator: " "))"
    }

    public static func alterTable(db: String, old: TableDesign, new: TableDesign) throws -> [String] {
        guard !new.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw MySQLError.message("请输入表名") }
        var stmts: [String] = []
        if new.name != old.name {
            stmts.append("ALTER TABLE \(SQL.qualified(db, old.name)) RENAME TO \(SQL.qualified(db, new.name))")
        }
        let target = SQL.qualified(db, new.name)

        // foreign keys: drop removed/changed first, add new/changed at the end
        let fkDrop = old.foreignKeys
            .filter { o in !new.foreignKeys.contains { $0.sameDefinition(o) } }
            .map { "DROP FOREIGN KEY \(SQL.quoteIdent($0.name))" }
        let fkAdd = new.foreignKeys
            .filter { n in !old.foreignKeys.contains { $0.sameDefinition(n) } }
            .map { "ADD \(renderForeignKey(db, $0))" }
        if !fkDrop.isEmpty {
            stmts.append("ALTER TABLE \(target)\n  \(fkDrop.joined(separator: ",\n  "))")
        }

        var clauses: [String] = []

        // indexes compared by name and rendered definition
        let oldIdx = old.indexes.map { (indexKey($0), renderIndex($0)) }
        let newIdx = new.indexes.map { (indexKey($0), renderIndex($0)) }
        for (k, def) in oldIdx where !newIdx.contains(where: { $0.0 == k && $0.1 == def }) {
            clauses.append(k == "PRIMARY" ? "DROP PRIMARY KEY" : "DROP INDEX \(SQL.quoteIdent(k))")
        }

        // columns
        let surviving = new.columns.compactMap(\.origName)
        for oc in old.columns where !surviving.contains(oc.name) {
            clauses.append("DROP COLUMN \(SQL.quoteIdent(oc.name))")
        }
        let oldOrder = old.columns.map(\.name).filter { surviving.contains($0) }
        var prev: String?
        var survivingPos = 0
        for nc in new.columns {
            let position = prev.map { " AFTER \(SQL.quoteIdent($0))" } ?? " FIRST"
            if let orig = nc.origName {
                let moved = survivingPos >= oldOrder.count || oldOrder[survivingPos] != orig
                survivingPos += 1
                let oldDef = old.columns.first { $0.name == orig }.map(renderColumn)
                let changed = oldDef != renderColumn(nc)
                if changed || moved {
                    clauses.append("CHANGE COLUMN \(SQL.quoteIdent(orig)) \(renderColumn(nc))\(moved ? position : "")")
                }
            } else {
                clauses.append("ADD COLUMN \(renderColumn(nc))\(position)")
            }
            prev = nc.name
        }

        for (k, def) in newIdx where !oldIdx.contains(where: { $0.0 == k && $0.1 == def }) {
            clauses.append("ADD \(def)")
        }

        let oldOpts = renderOptions(old)
        for (i, o) in renderOptions(new).enumerated() where (i >= oldOpts.count || oldOpts[i] != o) && !o.isEmpty {
            clauses.append(o)
        }

        if !clauses.isEmpty {
            stmts.append("ALTER TABLE \(target)\n  \(clauses.joined(separator: ",\n  "))")
        }
        if !fkAdd.isEmpty {
            stmts.append("ALTER TABLE \(target)\n  \(fkAdd.joined(separator: ",\n  "))")
        }
        return stmts
    }

    /// Statements turning `original` into `design` (CREATE TABLE when `original` is nil).
    public static func preview(db: String, original: TableDesign?, design: TableDesign) throws -> [String] {
        guard let original else { return [try createTable(db: db, design)] }
        return try alterTable(db: db, old: original, new: design)
    }
}

extension Character {
    var isASCIIDigitChar: Bool { isASCII && isNumber }
}

extension MySQLConnection {
    /// Load an existing table into the designer model.
    func tableDesign(_ db: String, _ table: String) throws -> TableDesign {
        let cols = try columns(of: db, table)
        let idx = try indexes(of: db, table)
        let fks = try foreignKeys(of: db, table)
        let opts = try tableOptions(of: db, table)

        var t = TableDesign()
        t.name = table
        t.engine = opts.engine ?? ""
        t.charset = opts.charset ?? ""
        t.collation = opts.collation ?? ""
        t.comment = opts.comment
        t.columns = cols.map { ci in
            let ct = ci.columnType.lowercased()
            var length = ""
            if let a = ci.columnType.firstIndex(of: "("), let b = ci.columnType.lastIndex(of: ")"), a < b {
                length = String(ci.columnType[ci.columnType.index(after: a)..<b])
            }
            let extra = ci.extra.lowercased()
            let numeric = DDL.numericTypes.contains(ci.dataType)
            var c = ColumnDef(origName: ci.name, name: ci.name, dataType: ci.dataType, length: length)
            c.unsigned = ct.contains(" unsigned")
            c.zerofill = ct.contains(" zerofill")
            c.nullable = ci.nullable
            c.defaultValue = ci.defaultValue.map { d in
                let du = d.uppercased()
                if extra.contains("default_generated") {
                    let fn = du.hasPrefix("CURRENT_TIMESTAMP") || du.hasPrefix("NOW(") || du.hasPrefix("LOCALTIME")
                    return fn ? d : "(\(d))"
                }
                if (numeric && Double(d) != nil) || du.hasPrefix("B'") || du == "NULL" { return d }
                return SQL.quote(d)
            }
            c.autoIncrement = extra.contains("auto_increment")
            if let r = extra.range(of: "on update ") {
                let offset = extra.distance(from: extra.startIndex, to: r.upperBound)
                c.onUpdate = String(ci.extra.dropFirst(offset)).trimmingCharacters(in: .whitespaces)
            }
            c.comment = ci.comment
            c.charset = ci.charset
            c.collation = ci.collation
            c.generated = ci.generationExpression
            c.generatedStored = extra.contains("stored generated")
            return c
        }
        t.indexes = idx.map { i in
            let kind = i.name == "PRIMARY" ? "PRIMARY"
                : (i.indexType == "FULLTEXT" || i.indexType == "SPATIAL") ? i.indexType
                : i.unique ? "UNIQUE" : "INDEX"
            return IndexDef(name: i.name, kind: kind, columns: i.columns, comment: i.comment)
        }
        t.foreignKeys = fks.map {
            ForeignKeyDef(name: $0.name, columns: $0.columns, refSchema: $0.refSchema, refTable: $0.refTable,
                          refColumns: $0.refColumns, onUpdate: $0.onUpdate, onDelete: $0.onDelete)
        }
        return t
    }
}
