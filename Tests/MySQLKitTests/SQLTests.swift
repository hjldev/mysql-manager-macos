import Foundation
import Testing
@testable import MySQLKit

@Suite struct SQLTests {
    @Test func quoting() {
        #expect(SQL.quoteIdent("a`b") == "`a``b`")
        #expect(SQL.quote("it's\\") == "'it''s\\\\'")
        #expect(SQL.quote("a\nb\0") == "'a\\nb\\0'")
        #expect(SQL.quote("it's\\", noBackslashEscapes: true) == "'it''s\\'")
        #expect(hexString([0, 255, 16]) == "0x00FF10")
        #expect(SQL.fromHex("0x00ff10") == [0, 255, 16])
        #expect(SQL.fromHex("zz") == nil)
        #expect(SQL.fromHex("0x1") == nil)
    }

    @Test func splitBasic() {
        let s = SQL.splitStatements("select 1; select ';' ; -- c;\nselect `a;b` from t;")
        #expect(s == ["select 1", "select ';'", "-- c;\nselect `a;b` from t"])
    }

    @Test func splitCommentsOnly() {
        #expect(SQL.splitStatements("-- hi\n/* x */ ;").isEmpty)
        #expect(SQL.splitStatements("/*!40101 SET NAMES utf8 */;") == ["/*!40101 SET NAMES utf8 */"])
    }

    @Test func splitEscapes() {
        let s = SQL.splitStatements("insert into t values ('a\\';b', 'c''d;');select 2")
        #expect(s.count == 2)
    }

    @Test func splitDelimiter() {
        let sql = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$\nDELIMITER ;\nSELECT 3;"
        #expect(SQL.splitStatements(sql) == ["CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "SELECT 3"])
    }

    @Test func splitCRLF() {
        #expect(SQL.splitStatements("select 1;\r\nselect 2;\r\n") == ["select 1", "select 2"])
    }

    @Test func literals() {
        #expect(SQL.literal(nil, binary: false) == "NULL")
        #expect(SQL.literal("0x01", binary: true) == "0x01")
        #expect(SQL.literal("0x01", binary: false) == "'0x01'")
        #expect(SQL.literal("x", binary: true) == "'x'")
    }
}

/// A row map that may hold NULL values.
func row(_ pairs: (String, String?)...) -> RowMap {
    var m = RowMap()
    for (k, v) in pairs { m.updateValue(v, forKey: k) }
    return m
}

@Suite struct TableDataTests {
    func shape(pk: Bool) -> TableShape {
        TableShape(columns: ["id", "name", "data"], pk: pk ? ["id"] : [],
                   binary: ["id": false, "name": false, "data": true])
    }

    @Test func buildsWithPK() throws {
        let ch = TableChanges(
            inserts: [row(("name", "x"))],
            updates: [RowUpdate(key: row(("id", "1"), ("name", "a"), ("data", nil)), set: row(("name", "b'c")))],
            deletes: [row(("id", "2"), ("name", nil), ("data", "0x01"))]
        )
        let p = try buildStatements(db: "d", table: "t", shape: shape(pk: true), changes: ch).map { $0.render() }
        #expect(p[0] == "DELETE FROM `d`.`t` WHERE `id` <=> '2'")
        #expect(p[1] == "UPDATE `d`.`t` SET `name` = 'b''c' WHERE `id` <=> '1'")
        #expect(p[2] == "INSERT INTO `d`.`t` (`name`) VALUES ('x')")
    }

    @Test func buildsWithoutPK() throws {
        let ch = TableChanges(deletes: [row(("id", "2"), ("name", nil), ("data", "0x01"))])
        let p = try buildStatements(db: "d", table: "t", shape: shape(pk: false), changes: ch)[0].render()
        #expect(p == "DELETE FROM `d`.`t` WHERE `id` <=> '2' AND `name` <=> NULL AND `data` <=> 0x01 LIMIT 1")
    }

    @Test func questionMarksInNames() throws {
        let s = TableShape(columns: ["a?b"], pk: ["a?b"], binary: [:])
        let p = try buildStatements(db: "d", table: "t?", shape: s, changes: TableChanges(deletes: [row(("a?b", "1"))]))
        #expect(p[0].render() == "DELETE FROM `d`.`t?` WHERE `a?b` <=> '1'")
    }
}

@Suite struct DDLTests {
    func col(_ name: String, _ ty: String, _ len: String) -> ColumnDef {
        ColumnDef(origName: name, name: name, dataType: ty, length: len)
    }

    func table() -> TableDesign {
        var id = col("id", "int", "")
        id.nullable = false
        id.autoIncrement = true
        id.unsigned = true
        var t = TableDesign()
        t.name = "t"
        t.engine = "InnoDB"
        t.charset = "utf8mb4"
        t.collation = "utf8mb4_0900_ai_ci"
        t.columns = [id, col("name", "varchar", "50"), col("age", "int", "")]
        t.indexes = [IndexDef(name: "PRIMARY", kind: "PRIMARY", columns: ["id"])]
        return t
    }

    @Test func defaults() {
        #expect(DDL.renderDefault("abc", "varchar") == "'abc'")
        #expect(DDL.renderDefault("0", "int") == "0")
        #expect(DDL.renderDefault("0", "varchar") == "'0'")
        #expect(DDL.renderDefault("CURRENT_TIMESTAMP", "datetime") == "CURRENT_TIMESTAMP")
        #expect(DDL.renderDefault("''", "varchar") == "''")
        #expect(DDL.renderDefault("(uuid())", "char") == "(uuid())")
    }

    @Test func create() throws {
        let sql = try DDL.createTable(db: "d", table())
        #expect(sql.hasPrefix("CREATE TABLE `d`.`t` (\n  `id` int unsigned NOT NULL AUTO_INCREMENT,"))
        #expect(sql.contains("PRIMARY KEY (`id`)"))
        #expect(sql.hasSuffix(") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci"))
    }

    @Test func alterNoChange() throws {
        #expect(try DDL.alterTable(db: "d", old: table(), new: table()).isEmpty)
    }

    @Test func alterChanges() throws {
        let old = table()
        var new = old
        new.columns[1].name = "full_name"
        new.columns[1].length = "100"
        new.columns.remove(at: 2)
        var email = col("email", "varchar", "255")
        email.origName = nil
        email.defaultValue = ""
        email.comment = "mail"
        new.columns.insert(email, at: 1)
        new.indexes.append(IndexDef(name: "idx_email", kind: "UNIQUE", columns: ["email"]))
        new.comment = "users"
        let s = try DDL.alterTable(db: "d", old: old, new: new)
        #expect(s.count == 1)
        #expect(s[0] == "ALTER TABLE `d`.`t`\n  DROP COLUMN `age`,\n  ADD COLUMN `email` varchar(255) NULL COMMENT 'mail' AFTER `id`,\n  CHANGE COLUMN `name` `full_name` varchar(100) NULL,\n  ADD UNIQUE KEY `idx_email` (`email`),\n  COMMENT='users'")
    }

    @Test func alterReorder() throws {
        let old = table()
        var new = old
        new.columns.swapAt(1, 2)
        let s = try DDL.alterTable(db: "d", old: old, new: new)
        #expect(s[0] == "ALTER TABLE `d`.`t`\n  CHANGE COLUMN `age` `age` int NULL AFTER `id`,\n  CHANGE COLUMN `name` `name` varchar(50) NULL AFTER `age`")
    }

    @Test func indexPrefix() {
        #expect(DDL.renderIndexColumn("name(10)") == "`name`(10)")
        #expect(DDL.renderIndexColumn("fn(x)") == "`fn(x)`")
    }

    @Test func foreignKeyChangeIsDropAndAdd() throws {
        var old = table()
        old.foreignKeys = [ForeignKeyDef(name: "fk", columns: ["age"], refSchema: "d", refTable: "p", refColumns: ["id"])]
        var new = old
        new.foreignKeys[0].onDelete = "CASCADE"
        let s = try DDL.alterTable(db: "d", old: old, new: new)
        #expect(s == [
            "ALTER TABLE `d`.`t`\n  DROP FOREIGN KEY `fk`",
            "ALTER TABLE `d`.`t`\n  ADD CONSTRAINT `fk` FOREIGN KEY (`age`) REFERENCES `p` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT",
        ])
    }
}

@Suite struct TransferTests {
    func tempFile(_ contents: String) throws -> String {
        let path = NSTemporaryDirectory() + "mmtest-\(UUID().uuidString).csv"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func csvParsing() throws {
        let path = try tempFile("\u{FEFF}a,b,c\r\n1,\"x,\"\"y\"\"\",\n\n2,\"multi\nline\",z\n3")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = try CSVReader(path: path, delimiter: ",")
        #expect(try r.next() == ["a", "b", "c"])
        #expect(try r.next() == ["1", "x,\"y\"", ""])
        #expect(try r.next() == ["2", "multi\nline", "z"])
        #expect(try r.next() == ["3"])
        #expect(try r.next() == nil)
    }

    @Test func csvPreviewWithoutHeader() throws {
        let path = try tempFile("1\t2\n3\t4\t5\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = try Transfer.previewCSV(path: path, delimiter: "\\t", hasHeader: false)
        #expect(p.headers == ["column1", "column2", "column3"])
        #expect(p.rows == [["1", "2"], ["3", "4", "5"]])
    }

    @Test func exportFormats() throws {
        let cols = [QueryColumn(name: "id", isNumeric: true), QueryColumn(name: "name"), QueryColumn(name: "b", isBinary: true)]
        let rows: [[String?]] = [["1", "a,\"b\"", "0x01"], [nil, "c\nd", nil]]
        let dir = NSTemporaryDirectory()
        let csv = dir + "mm-\(UUID().uuidString).csv"
        let json = dir + "mm-\(UUID().uuidString).json"
        let sql = dir + "mm-\(UUID().uuidString).sql"
        defer { [csv, json, sql].forEach { try? FileManager.default.removeItem(atPath: $0) } }

        #expect(try Transfer.exportRows(columns: cols, rows: rows, format: .csv, path: csv) == 2)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: csv))
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self) == "id,name,b\n1,\"a,\"\"b\"\"\",0x01\n,\"c\nd\",\n")

        _ = try Transfer.exportRows(columns: cols, rows: rows, format: .json, path: json)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: json))) as! [[String: Any]]
        #expect(parsed[0]["id"] as? Int == 1)
        #expect(parsed[1]["name"] as? String == "c\nd")
        #expect(parsed[1]["id"] is NSNull)

        _ = try Transfer.exportRows(columns: cols, rows: rows, format: .sql, path: sql, table: "t")
        #expect(try String(contentsOfFile: sql, encoding: .utf8)
            == "INSERT INTO `t` (`id`, `name`, `b`) VALUES\n(1, 'a,\"b\"', 0x01),\n(NULL, 'c\\nd', NULL);\n")
    }
}

@Suite struct AuthTests {
    @Test func scrambles() {
        let nonce = Array(repeating: UInt8(1), count: 20)
        #expect(Auth.native("pw", nonce).count == 20)
        #expect(Auth.sha2("pw", nonce).count == 32)
        #expect(Auth.response(plugin: Auth.cachingSha2, password: "", nonce: nonce).isEmpty)
        #expect(Auth.xorPassword("ab", nonce) == [0x61 ^ 1, 0x62 ^ 1, 1])
    }

    @Test func spkiToPKCS1() {
        // SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { 0, SEQUENCE {...} } }
        let inner: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x05]
        let spki: [UInt8] = [0x30, 0x0E, 0x30, 0x02, 0x05, 0x00, 0x03, 0x06, 0x00] + inner
        #expect(Auth.pkcs1(fromSPKI: spki) == inner)
        #expect(Auth.pkcs1(fromSPKI: inner) == inner)
    }
}
