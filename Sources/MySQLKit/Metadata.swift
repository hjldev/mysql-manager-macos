import Foundation

public struct TableInfo: Sendable, Hashable {
    public var name: String
    public var isView: Bool
    public var engine: String?
    public var rows: UInt64?
    public var comment: String?
    public var dataLength: UInt64?
    public var updateTime: String?
}

public struct ColumnInfo: Sendable, Hashable {
    public var name: String
    public var dataType: String
    public var columnType: String
    public var nullable: Bool
    public var defaultValue: String?
    public var key: String
    public var extra: String
    public var comment: String
    public var charset: String?
    public var collation: String?
    public var generationExpression: String?
}

public struct CharsetInfo: Sendable, Hashable {
    public var name: String
    public var defaultCollation: String
}

struct IndexInfo {
    var name: String
    var unique: Bool
    var indexType: String
    var columns: [String]
    var comment: String
}

struct ForeignKeyInfo {
    var name: String
    var columns: [String]
    var refSchema: String
    var refTable: String
    var refColumns: [String]
    var onUpdate: String
    var onDelete: String
}

struct TableOptions {
    var engine: String?
    var collation: String?
    var charset: String?
    var comment: String
}

/// Schema metadata from information_schema.
extension MySQLConnection {
    func databases() throws -> [String] {
        try rows("SHOW DATABASES").compactMap { $0.first ?? nil }
    }

    func charsets() throws -> [CharsetInfo] {
        try rows("SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS ORDER BY 1")
            .map { CharsetInfo(name: $0[0] ?? "", defaultCollation: $0[1] ?? "") }
    }

    func collations(charset: String) throws -> [String] {
        try rows("SELECT COLLATION_NAME FROM information_schema.COLLATIONS WHERE CHARACTER_SET_NAME = \(quote(charset)) ORDER BY 1")
            .compactMap { $0[0] }
    }

    func tables(in db: String) throws -> [TableInfo] {
        try rows("""
            SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, TABLE_COMMENT, DATA_LENGTH, CAST(UPDATE_TIME AS CHAR) \
            FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(quote(db)) ORDER BY TABLE_NAME
            """)
            .map {
                TableInfo(
                    name: $0[0] ?? "",
                    isView: ($0[1] ?? "").contains("VIEW"),
                    engine: $0[2],
                    rows: $0[3].flatMap { UInt64($0) },
                    comment: $0[4],
                    dataLength: $0[5].flatMap { UInt64($0) },
                    updateTime: $0[6]
                )
            }
    }

    func columns(of db: String, _ table: String) throws -> [ColumnInfo] {
        try rows("""
            SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, EXTRA, \
            COLUMN_COMMENT, CHARACTER_SET_NAME, COLLATION_NAME, GENERATION_EXPRESSION \
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(quote(db)) AND TABLE_NAME = \(quote(table)) \
            ORDER BY ORDINAL_POSITION
            """)
            .map {
                ColumnInfo(
                    name: $0[0] ?? "",
                    dataType: $0[1] ?? "",
                    columnType: $0[2] ?? "",
                    nullable: $0[3] == "YES",
                    defaultValue: $0[4],
                    key: $0[5] ?? "",
                    extra: $0[6] ?? "",
                    comment: $0[7] ?? "",
                    charset: $0[8],
                    collation: $0[9],
                    generationExpression: $0[10].flatMap { $0.isEmpty ? nil : $0 }
                )
            }
    }

    func indexes(of db: String, _ table: String) throws -> [IndexInfo] {
        let rows = try rows("""
            SELECT INDEX_NAME, NON_UNIQUE, INDEX_TYPE, COLUMN_NAME, INDEX_COMMENT, SUB_PART \
            FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(quote(db)) AND TABLE_NAME = \(quote(table)) \
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """)
        var out: [IndexInfo] = []
        for r in rows {
            let name = r[0] ?? ""
            var column = r[3] ?? ""
            if let n = r[5] { column += "(\(n))" }
            if let i = out.firstIndex(where: { $0.name == name }) {
                out[i].columns.append(column)
            } else {
                out.append(IndexInfo(name: name, unique: r[1] == "0", indexType: r[2] ?? "", columns: [column], comment: r[4] ?? ""))
            }
        }
        return out
    }

    func foreignKeys(of db: String, _ table: String) throws -> [ForeignKeyInfo] {
        let rows = try rows("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, \
            k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE \
            FROM information_schema.KEY_COLUMN_USAGE k \
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r \
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME \
              AND r.TABLE_NAME = k.TABLE_NAME \
            WHERE k.TABLE_SCHEMA = \(quote(db)) AND k.TABLE_NAME = \(quote(table)) AND k.REFERENCED_TABLE_NAME IS NOT NULL \
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        var out: [ForeignKeyInfo] = []
        for r in rows {
            let name = r[0] ?? ""
            if let i = out.firstIndex(where: { $0.name == name }) {
                out[i].columns.append(r[1] ?? "")
                out[i].refColumns.append(r[4] ?? "")
            } else {
                out.append(ForeignKeyInfo(name: name, columns: [r[1] ?? ""], refSchema: r[2] ?? "", refTable: r[3] ?? "",
                                          refColumns: [r[4] ?? ""], onUpdate: r[5] ?? "", onDelete: r[6] ?? ""))
            }
        }
        return out
    }

    func tableOptions(of db: String, _ table: String) throws -> TableOptions {
        let r = try firstRow("""
            SELECT t.ENGINE, t.TABLE_COLLATION, t.TABLE_COMMENT, c.CHARACTER_SET_NAME \
            FROM information_schema.TABLES t \
            LEFT JOIN information_schema.COLLATIONS c ON c.COLLATION_NAME = t.TABLE_COLLATION \
            WHERE t.TABLE_SCHEMA = \(quote(db)) AND t.TABLE_NAME = \(quote(table))
            """)
        return TableOptions(engine: r?[0] ?? nil, collation: r?[1] ?? nil, charset: r?[3] ?? nil, comment: (r?[2] ?? nil) ?? "")
    }

    /// SHOW CREATE TABLE / VIEW — the DDL is the second column.
    func showCreate(_ db: String, _ table: String) throws -> String {
        guard let r = try firstRow("SHOW CREATE TABLE \(SQL.qualified(db, table))"), r.count > 1 else { return "" }
        return r[1] ?? ""
    }

    /// Table name → column names, for editor completion.
    func completionSchema(_ db: String) throws -> [String: [String]] {
        var map: [String: [String]] = [:]
        for r in try rows("""
            SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(quote(db)) \
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """) {
            map[r[0] ?? "", default: []].append(r[1] ?? "")
        }
        return map
    }
}
