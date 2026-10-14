import Foundation
import Testing
@testable import MySQLKit

/// Against a real server, using the first connection saved by the app:
///   MM_LIVE=1 swift test --filter LiveTests
/// Works in a scratch database `mm_native_test`, dropped at the end.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MM_LIVE"] == "1"), .serialized)
struct LiveTests {
    static let db = "mm_native_test"
    let service: DatabaseService
    let connID: String

    init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sting.mysqlmanager")
        service = DatabaseService(configDirectory: dir)
        connID = try #require(try service.listConnections().first).id
        _ = try service.openConnection(connID)
        try service.executeStatements(connID, db: nil, ["CREATE DATABASE IF NOT EXISTS \(Self.db)"])
    }

    func options(ssl: Bool) throws -> MySQLConnection.Options {
        let cfg = try service.store.find(connID)
        return MySQLConnection.Options(host: cfg.host, port: cfg.port, user: cfg.user, password: cfg.password ?? "",
                                       database: Self.db, ssl: ssl)
    }

    @Test func fullAuthenticationWithRSAAndTLS() throws {
        // empty the caching_sha2_password cache so the next logins need full authentication
        try service.executeStatements(connID, db: nil, ["FLUSH PRIVILEGES"])
        let plain = try MySQLConnection(try options(ssl: false))
        #expect(try plain.firstRow("SELECT DATABASE()")?.first == Self.db)
        plain.close()

        try service.executeStatements(connID, db: nil, ["FLUSH PRIVILEGES"])
        let tls = try MySQLConnection(try options(ssl: true))
        let cipher = try tls.firstRow("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
        #expect((cipher?[1] ?? "")?.isEmpty == false)
        tls.close()
    }

    @Test func multiResultsAndValues() throws {
        let s = try service.openSession(connID, db: Self.db)
        defer { service.closeSession(s) }
        let setup = s.execute("""
            DROP PROCEDURE IF EXISTS p2;
            DELIMITER $$
            CREATE PROCEDURE p2() BEGIN SELECT 1 AS a; SELECT 'x' AS b, NULL AS c; END$$
            DELIMITER ;
            DROP TABLE IF EXISTS t_ok;
            CREATE TABLE t_ok (id int AUTO_INCREMENT PRIMARY KEY, b varbinary(4), d datetime(3), n decimal(10,2), s text)
            """)
        #expect(setup.allSatisfy { $0.error == nil }, "\(setup.map(\.error))")

        let r = s.execute("CALL p2()")
        try #require(r.count == 2)
        #expect(r[0].rows == [["1"]])
        #expect(r[1].rows == [["x", nil]])

        let ins = s.execute("INSERT INTO t_ok (b, d, n, s) VALUES (0x0102, '2024-01-02 03:04:05.678', 12.5, '中文 ''q'''), (NULL, NULL, NULL, NULL)")
        #expect(ins[0].affectedRows == 2)
        #expect(ins[0].lastInsertID == 1)
        #expect(ins[0].columns == nil)

        let sel = s.execute("SELECT b, d, n, s FROM t_ok ORDER BY id")[0]
        #expect(sel.rows[0] == ["0x0102", "2024-01-02 03:04:05.678", "12.50", "中文 'q'"])
        #expect(sel.columns?.map(\.isBinary) == [true, false, false, false])
        #expect(sel.columns?.map(\.isNumeric) == [false, false, true, false])

        #expect(s.execute("SELECT * FROM information_schema.COLLATIONS LIMIT 5")[0].rows.count == 5)

        // an error stops the script and the session stays usable
        let err = s.execute("SELECT 1; SELEC 2; SELECT 3")
        #expect(err.count == 2)
        #expect(err[1].error?.contains("1064") == true)
        #expect(s.execute("SELECT 42")[0].rows == [["42"]])
    }

    @Test func cancelRunningQuery() async throws {
        let s = try service.openSession(connID, db: Self.db)
        defer { service.closeSession(s) }
        let start = Date()
        async let result = Task.detached { s.execute("SELECT SLEEP(10)") }.value
        try await Task.sleep(for: .milliseconds(500))
        try service.cancel(s)
        _ = await result
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(s.execute("SELECT 1")[0].rows == [["1"]])
    }

    @Test func designEditAndTransfer() throws {
        try service.executeStatements(connID, db: Self.db, ["DROP TABLE IF EXISTS t_design, t_design2"])
        var t = TableDesign.newTable()
        t.name = "t_design"
        var name = ColumnDef(name: "name", dataType: "varchar", length: "50")
        name.defaultValue = "n/a"
        name.comment = "名字"
        var created = ColumnDef(name: "created", dataType: "datetime", length: "")
        created.defaultValue = "CURRENT_TIMESTAMP"
        created.onUpdate = "CURRENT_TIMESTAMP"
        t.columns += [name, created, ColumnDef(name: "data", dataType: "varbinary", length: "8")]
        t.indexes.append(IndexDef(name: "idx_name", kind: "INDEX", columns: ["name(10)"]))
        t.comment = "测试"
        try service.executeStatements(connID, db: Self.db, try DDL.preview(db: Self.db, original: nil, design: t))

        // loading it back gives no diff
        let loaded = try service.tableDesign(connID, db: Self.db, table: "t_design")
        #expect(try DDL.preview(db: Self.db, original: loaded, design: loaded).isEmpty)
        #expect(loaded.columns[1].defaultValue == "'n/a'")
        #expect(loaded.columns[2].onUpdate?.uppercased() == "CURRENT_TIMESTAMP")
        #expect(loaded.indexes.map(\.columns) == [["id"], ["name(10)"]])

        var changed = loaded
        changed.name = "t_design2"
        changed.columns[1].length = "100"
        changed.columns.swapAt(1, 2)
        try service.executeStatements(connID, db: Self.db, try DDL.preview(db: Self.db, original: loaded, design: changed))
        let reloaded = try service.tableDesign(connID, db: Self.db, table: "t_design2")
        #expect(reloaded.columns.map(\.name) == ["id", "created", "name", "data"])
        #expect(reloaded.columns[2].length == "100")

        // grid edits
        func r(_ pairs: (String, String?)...) -> RowMap {
            var m = RowMap()
            for (k, v) in pairs { m.updateValue(v, forKey: k) }
            return m
        }
        let insert = TableChanges(inserts: [r(("name", "a'b\\c")), r(("name", nil), ("data", "0x00FF")), r()])
        #expect(try service.applyChanges(connID, db: Self.db, table: "t_design2", changes: insert) == 3)
        var page = try service.fetchRows(connID, db: Self.db, table: "t_design2", filter: nil, orderBy: "`id`", offset: 0, limit: 10)
        #expect(page.total == 3)
        #expect(page.rows.map { $0[2] } == ["a'b\\c", nil, "n/a"])
        #expect(page.rows[1][3] == "0x00FF")

        let key0 = Dictionary(uniqueKeysWithValues: zip(page.columns.map(\.name), page.rows[0]))
        let key2 = Dictionary(uniqueKeysWithValues: zip(page.columns.map(\.name), page.rows[2]))
        let edit = TableChanges(updates: [RowUpdate(key: key0, set: r(("name", "changed")))], deletes: [key2])
        #expect(try service.previewChanges(connID, db: Self.db, table: "t_design2", changes: edit).count == 2)
        _ = try service.applyChanges(connID, db: Self.db, table: "t_design2", changes: edit)
        page = try service.fetchRows(connID, db: Self.db, table: "t_design2", filter: "name IS NOT NULL", orderBy: nil, offset: 0, limit: 10)
        #expect(page.rows.map { $0[2] } == ["changed"])

        // deleting a row that is gone rolls everything back
        let stale = TableChanges(inserts: [r(("name", "x"))], deletes: [key2])
        #expect(throws: MySQLError.self) { try service.applyChanges(connID, db: Self.db, table: "t_design2", changes: stale) }
        #expect(try service.fetchRows(connID, db: Self.db, table: "t_design2", filter: nil, orderBy: nil, offset: 0, limit: 10).total == 2)

        // export, dump, import, run the dump back
        let dir = NSTemporaryDirectory() + "mm-live-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let csvPath = dir + "t.csv"
        #expect(try service.exportTable(connID, db: Self.db, table: "t_design2", format: .csv, path: csvPath, filter: nil) { _, _, _ in } == 2)
        try service.executeStatements(connID, db: Self.db, ["TRUNCATE TABLE t_design2"])
        let preview = try Transfer.previewCSV(path: csvPath, delimiter: ",", hasHeader: true)
        #expect(preview.headers == ["id", "created", "name", "data"])
        let imported = try service.importCSV(connID, db: Self.db, table: "t_design2", path: csvPath, delimiter: ",",
                                             hasHeader: true, mapping: ["id", nil, "name", nil], emptyAsNull: true) { _, _, _ in }
        #expect(imported == 2)

        let dumpPath = dir + "dump.sql"
        #expect(try service.dumpDatabase(connID, db: Self.db, path: dumpPath, includeData: true, tables: ["t_design2"]) { _, _, _ in } == 2)
        try service.executeStatements(connID, db: Self.db, ["DROP TABLE t_design2"])
        let script = try service.runSQLFile(connID, db: Self.db, path: dumpPath, continueOnError: false) { _, _, _ in }
        #expect(script.errors.isEmpty, "\(script.errors)")
        #expect(try service.fetchRows(connID, db: Self.db, table: "t_design2", filter: nil, orderBy: nil, offset: 0, limit: 10).total == 2)
    }

    @Test func zzDropScratchDatabase() throws {
        try service.dropDatabase(connID, name: Self.db)
        #expect(try !service.databases(connID).contains(Self.db))
    }
}
