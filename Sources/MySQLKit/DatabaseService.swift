import Foundation

public struct StatementResult: Sendable {
    public var sql: String
    /// nil for statements that don't return a result set.
    public var columns: [QueryColumn]?
    public var rows: [[String?]]
    public var affectedRows: UInt64
    public var lastInsertID: UInt64?
    public var elapsedMs: Int
    public var error: String?
}

/// A dedicated connection for one query tab, so that `USE db`, session
/// variables and transactions persist between executions.
public final class QuerySession: @unchecked Sendable {
    public let connID: String
    let connection: MySQLConnection
    private let lock = NSLock()

    init(connID: String, connection: MySQLConnection) {
        self.connID = connID
        self.connection = connection
    }

    var threadID: UInt32 { connection.connectionID }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public func useDatabase(_ db: String) throws {
        try locked { _ = try connection.execute("USE \(SQL.quoteIdent(db))") }
    }

    /// Run every statement of `sql` in order. Stops at the first error, which
    /// is reported as the last result. Result sets are returned in full;
    /// the statement's own `LIMIT` decides how many rows come back.
    public func execute(_ sql: String) -> [StatementResult] {
        locked {
            var results: [StatementResult] = []
            for stmt in SQL.splitStatements(sql) {
                do {
                    results += try run(stmt)
                } catch {
                    results.append(StatementResult(sql: stmt, columns: nil, rows: [], affectedRows: 0, lastInsertID: nil,
                                                   elapsedMs: 0, error: error.localizedDescription))
                    break
                }
            }
            return results
        }
    }

    private func run(_ stmt: String) throws -> [StatementResult] {
        let start = Date()
        var out: [StatementResult] = []
        var columns: [QueryColumn]?
        var rows: [[String?]] = []
        try connection.query(stmt) { e in
            switch e {
            case let .columns(c):
                columns = c
            case let .row(r):
                rows.append(r)
            case let .end(ok):
                out.append(StatementResult(
                    sql: stmt, columns: columns, rows: rows, affectedRows: ok.affectedRows,
                    lastInsertID: ok.lastInsertID == 0 ? nil : ok.lastInsertID,
                    elapsedMs: Int(Date().timeIntervalSince(start) * 1000), error: nil
                ))
                columns = nil
                rows = []
            }
        }
        // CALL returns a trailing OK packet as an empty result; drop it
        if out.count > 1 {
            out.removeAll { $0.columns == nil && $0.affectedRows == 0 }
        }
        return out
    }

    public func close() {
        if lock.try() {
            connection.close()
            lock.unlock()
        } else {
            connection.abort() // a query is running
        }
    }
}

/// Everything the app does with servers. Methods block: call them off the
/// main thread. Thread-safe.
public final class DatabaseService: @unchecked Sendable {
    public let store: ConnectionStore
    private let lock = NSLock()
    private var pools: [String: ConnectionPool] = [:]
    private var sessions: [ObjectIdentifier: QuerySession] = [:]

    public init(configDirectory: URL) {
        store = ConnectionStore(directory: configDirectory)
    }

    private func pool(_ connID: String) throws -> ConnectionPool {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pools[connID] else { throw MySQLError.message("连接未打开") }
        return p
    }

    @discardableResult
    private func with<T>(_ connID: String, _ body: (MySQLConnection) throws -> T) throws -> T {
        try pool(connID).with(body)
    }

    @discardableResult
    private func with<T>(_ connID: String, db: String?, _ body: (MySQLConnection) throws -> T) throws -> T {
        try with(connID) { c in
            if let db, !db.isEmpty { try c.execute("USE \(SQL.quoteIdent(db))") }
            return try body(c)
        }
    }

    private static func options(_ cfg: ConnectionConfig, password: String?) -> MySQLConnection.Options {
        MySQLConnection.Options(host: cfg.host, port: cfg.port, user: cfg.user, password: password ?? "",
                                database: cfg.database, ssl: cfg.ssl)
    }

    private func resolvePassword(_ cfg: ConnectionConfig) -> String? {
        cfg.password ?? (cfg.id.isEmpty ? nil : store.password(for: cfg.id))
    }

    // MARK: Connections

    public func listConnections() throws -> [ConnectionConfig] { try store.list() }

    /// `password == nil` keeps the stored password.
    public func saveConnection(_ config: ConnectionConfig) throws -> ConnectionConfig { try store.save(config) }

    public func deleteConnection(_ id: String) throws {
        closeConnection(id)
        try store.remove(id)
    }

    /// Connect with a possibly unsaved config. Returns the server version.
    public func testConnection(_ config: ConnectionConfig) throws -> String {
        let c = try MySQLConnection(Self.options(config, password: resolvePassword(config)))
        defer { c.close() }
        return c.serverVersion
    }

    /// Open a pool for a saved connection; `password` is used when none is stored.
    /// Returns the server version.
    public func openConnection(_ id: String, password: String? = nil) throws -> String {
        var cfg = try store.find(id)
        if let password { cfg.password = password }
        let p = ConnectionPool(options: Self.options(cfg, password: cfg.password))
        let version = try p.with { $0.serverVersion }
        lock.lock()
        let old = pools.updateValue(p, forKey: id)
        lock.unlock()
        old?.close()
        return version
    }

    public func closeConnection(_ id: String) {
        lock.lock()
        let p = pools.removeValue(forKey: id)
        let s = sessions.values.filter { $0.connID == id }
        s.forEach { sessions[ObjectIdentifier($0)] = nil }
        lock.unlock()
        s.forEach { $0.close() }
        p?.close()
    }

    public func hasSavedPassword(_ id: String) -> Bool {
        store.password(for: id) != nil
    }

    // MARK: Metadata

    public func databases(_ connID: String) throws -> [String] { try with(connID) { try $0.databases() } }
    public func charsets(_ connID: String) throws -> [CharsetInfo] { try with(connID) { try $0.charsets() } }

    public func collations(_ connID: String, charset: String) throws -> [String] {
        try with(connID) { try $0.collations(charset: charset) }
    }

    public func tables(_ connID: String, db: String) throws -> [TableInfo] {
        try with(connID) { try $0.tables(in: db) }
    }

    public func columns(_ connID: String, db: String, table: String) throws -> [ColumnInfo] {
        try with(connID) { try $0.columns(of: db, table) }
    }

    public func tableDDL(_ connID: String, db: String, table: String) throws -> String {
        try with(connID) { try $0.showCreate(db, table) }
    }

    public func completionSchema(_ connID: String, db: String) throws -> [String: [String]] {
        try with(connID) { try $0.completionSchema(db) }
    }

    // MARK: Query sessions

    public func openSession(_ connID: String, db: String?) throws -> QuerySession {
        let opts = try pool(connID).options
        let c = try MySQLConnection(opts)
        do {
            if let db, !db.isEmpty { try c.execute("USE \(SQL.quoteIdent(db))") }
        } catch {
            c.close()
            throw error
        }
        let s = QuerySession(connID: connID, connection: c)
        lock.lock()
        sessions[ObjectIdentifier(s)] = s
        lock.unlock()
        return s
    }

    public func closeSession(_ s: QuerySession) {
        lock.lock()
        sessions[ObjectIdentifier(s)] = nil
        lock.unlock()
        s.close()
    }

    /// Abort the statement running on a session.
    public func cancel(_ s: QuerySession) throws {
        try with(s.connID) { try $0.execute("KILL QUERY \(s.threadID)") }
    }

    // MARK: Table data

    public func fetchRows(_ connID: String, db: String, table: String, filter: String?, orderBy: String?,
                          offset: UInt64, limit: UInt64) throws -> TablePage {
        try with(connID) {
            try $0.fetchRows(db: db, table: table, filter: filter, orderBy: orderBy, offset: offset, limit: limit)
        }
    }

    /// The statements `applyChanges` would run.
    public func previewChanges(_ connID: String, db: String, table: String, changes: TableChanges) throws -> [String] {
        try with(connID) { try $0.previewChanges(db: db, table: table, changes: changes) }
    }

    /// Apply in one transaction; returns the affected row count.
    public func applyChanges(_ connID: String, db: String, table: String, changes: TableChanges) throws -> UInt64 {
        try with(connID) { try $0.applyChanges(db: db, table: table, changes: changes) }
    }

    // MARK: DDL

    public func tableDesign(_ connID: String, db: String, table: String) throws -> TableDesign {
        try with(connID) { try $0.tableDesign(db, table) }
    }

    public func executeStatements(_ connID: String, db: String?, _ statements: [String]) throws {
        try with(connID, db: db) { c in
            for s in statements { try c.execute(s) }
        }
    }

    public func createDatabase(_ connID: String, name: String, charset: String? = nil, collation: String? = nil) throws {
        var sql = "CREATE DATABASE \(SQL.quoteIdent(name))"
        if let charset, !charset.isEmpty { sql += " CHARACTER SET \(SQL.quoteIdent(charset))" }
        if let collation, !collation.isEmpty { sql += " COLLATE \(SQL.quoteIdent(collation))" }
        try with(connID) { try $0.execute(sql) }
    }

    public func dropDatabase(_ connID: String, name: String) throws {
        try with(connID) { try $0.execute("DROP DATABASE \(SQL.quoteIdent(name))") }
    }

    public func dropTable(_ connID: String, db: String, table: String, isView: Bool) throws {
        try with(connID) { try $0.execute("DROP \(isView ? "VIEW" : "TABLE") \(SQL.qualified(db, table))") }
    }

    public func truncateTable(_ connID: String, db: String, table: String) throws {
        try with(connID) { try $0.execute("TRUNCATE TABLE \(SQL.qualified(db, table))") }
    }

    public func renameTable(_ connID: String, db: String, table: String, to newName: String) throws {
        try with(connID) {
            try $0.execute("RENAME TABLE \(SQL.qualified(db, table)) TO \(SQL.qualified(db, newName))")
        }
    }

    public func duplicateTable(_ connID: String, db: String, table: String, to newName: String, withData: Bool) throws {
        let (src, dst) = (SQL.qualified(db, table), SQL.qualified(db, newName))
        try with(connID) { c in
            try c.execute("CREATE TABLE \(dst) LIKE \(src)")
            if withData { try c.execute("INSERT INTO \(dst) SELECT * FROM \(src)") }
        }
    }

    // MARK: Import / export

    public func exportTable(_ connID: String, db: String, table: String, format: ExportFormat, path: String,
                            filter: String?, progress: @escaping ProgressHandler) throws -> Int {
        try with(connID) {
            try $0.exportTable(db: db, table: table, format: format, path: path, filter: filter, progress: progress)
        }
    }

    public func dumpDatabase(_ connID: String, db: String, path: String, includeData: Bool, tables: [String]?,
                             progress: @escaping ProgressHandler) throws -> Int {
        try with(connID) {
            try $0.dumpDatabase(db: db, path: path, includeData: includeData, tables: tables, progress: progress)
        }
    }

    public func importCSV(_ connID: String, db: String, table: String, path: String, delimiter: String,
                          hasHeader: Bool, mapping: [String?], emptyAsNull: Bool,
                          progress: @escaping ProgressHandler) throws -> Int {
        try with(connID) {
            try $0.importCSV(db: db, table: table, path: path, delimiter: delimiter, hasHeader: hasHeader,
                             mapping: mapping, emptyAsNull: emptyAsNull, progress: progress)
        }
    }

    public func runSQLFile(_ connID: String, db: String?, path: String, continueOnError: Bool,
                           progress: @escaping ProgressHandler) throws -> ScriptResult {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try with(connID, db: db) { $0.runScript(text, continueOnError: continueOnError, progress: progress) }
    }
}
