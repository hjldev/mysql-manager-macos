import Foundation

/// A result-set column.
public struct QueryColumn: Sendable, Hashable {
    public var name: String
    /// Protocol type name, e.g. `LONG`, `VAR_STRING`, `DATETIME`.
    public var typeName: String
    public var isBinary: Bool
    public var isNumeric: Bool

    public init(name: String, typeName: String = "", isBinary: Bool = false, isNumeric: Bool = false) {
        self.name = name
        self.typeName = typeName
        self.isBinary = isBinary
        self.isNumeric = isNumeric
    }
}

/// The OK packet that ends every statement result.
public struct QueryOK: Sendable {
    public var affectedRows: UInt64 = 0
    public var lastInsertID: UInt64 = 0
    var status: UInt16 = 0
}

public enum QueryEvent {
    /// A result set starts.
    case columns([QueryColumn])
    case row([String?])
    /// One statement result ends (after its rows, if it had a result set).
    case end(QueryOK)
}

/// One connection speaking the MySQL client/server protocol (text protocol).
/// Not thread-safe: use it from one thread at a time. `close()` may be called
/// from any thread and aborts a running query.
public final class MySQLConnection: @unchecked Sendable {
    public struct Options: Sendable {
        public var host: String
        public var port: UInt16
        public var user: String
        public var password: String
        public var database: String?
        public var ssl: Bool
        public var connectTimeout: TimeInterval

        public init(host: String, port: UInt16, user: String, password: String, database: String? = nil,
                    ssl: Bool = false, connectTimeout: TimeInterval = 10) {
            self.host = host
            self.port = port
            self.user = user
            self.password = password
            self.database = database
            self.ssl = ssl
            self.connectTimeout = connectTimeout
        }
    }

    private enum Capability {
        static let longPassword: UInt32 = 1
        static let longFlag: UInt32 = 4
        static let connectWithDB: UInt32 = 8
        static let protocol41: UInt32 = 0x200
        static let ssl: UInt32 = 0x800
        static let transactions: UInt32 = 0x2000
        static let secureConnection: UInt32 = 0x8000
        static let multiResults: UInt32 = 0x2_0000
        static let psMultiResults: UInt32 = 0x4_0000
        static let pluginAuth: UInt32 = 0x8_0000
        static let pluginAuthLenencData: UInt32 = 0x20_0000
        static let deprecateEOF: UInt32 = 0x100_0000
    }

    private enum Status {
        static let inTransaction: UInt16 = 0x0001
        static let moreResults: UInt16 = 0x0008
        static let noBackslashEscapes: UInt16 = 0x0200
    }

    public let serverVersion: String
    /// Server thread id, for `KILL QUERY`.
    public let connectionID: UInt32

    private let transport: Transport
    private var sequence: UInt8 = 0
    private var capabilities: UInt32 = 0
    private var status: UInt16 = 0
    private let stateLock = NSLock()
    private var _broken = false
    var lastUsed = Date()

    /// Set after an I/O or protocol error; the connection cannot be reused.
    public var isBroken: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _broken
    }

    public var inTransaction: Bool { status & Status.inTransaction != 0 }
    /// Whether string literals must not use backslash escapes (sql_mode NO_BACKSLASH_ESCAPES).
    public var noBackslashEscapes: Bool { status & Status.noBackslashEscapes != 0 }

    public init(_ options: Options) throws {
        let t = try Transport(host: options.host, port: options.port, timeout: options.connectTimeout)
        transport = t
        var seq: UInt8 = 0
        do {
            // initial handshake
            var r = PacketReader(try Self.readPacket(t, &seq))
            let proto = try r.u8()
            if proto == 0xFF { throw Self.parseError(r.bytes) }
            guard proto == 10 else { throw MySQLError.protocolViolation("不支持的协议版本 \(proto)") }
            serverVersion = String(decoding: try r.nullTerminated(), as: UTF8.self)
            connectionID = try r.u32()
            var nonce = Array(try r.bytes(8))
            try r.skip(1)
            var serverCaps = UInt32(try r.u16())
            _ = try r.u8() // charset
            let initialStatus = try r.u16()
            serverCaps |= UInt32(try r.u16()) << 16
            let nonceLength = Int(try r.u8())
            try r.skip(10)
            if serverCaps & Capability.secureConnection != 0 {
                let n = max(13, nonceLength - 8)
                nonce += try r.bytes(n).prefix(12)
            }
            var plugin = serverCaps & Capability.pluginAuth != 0
                ? String(decoding: try r.nullTerminated(), as: UTF8.self) : Auth.nativePassword
            if plugin.isEmpty { plugin = Auth.nativePassword }

            var caps = Capability.longPassword | Capability.longFlag | Capability.protocol41
                | Capability.transactions | Capability.secureConnection | Capability.multiResults
                | Capability.psMultiResults | Capability.pluginAuth | Capability.pluginAuthLenencData
                | Capability.deprecateEOF
            let db = options.database.flatMap { $0.isEmpty ? nil : $0 }
            if db != nil { caps |= Capability.connectWithDB }
            caps &= serverCaps | Capability.connectWithDB
            let charset: UInt8 = 45 // utf8mb4_general_ci
            // every stored property is set from here on
            sequence = seq
            status = initialStatus

            if options.ssl {
                guard serverCaps & Capability.ssl != 0 else { throw MySQLError.message("服务器不支持 SSL") }
                caps |= Capability.ssl
                var w = PacketWriter()
                w.u32(caps)
                w.u32(1 << 24)
                w.u8(charset)
                w.zeros(23)
                try writePacket(w.bytes)
                try transport.startTLS(host: options.host)
            }
            capabilities = caps

            var w = PacketWriter()
            w.u32(caps)
            w.u32(1 << 24)
            w.u8(charset)
            w.zeros(23)
            w.nullTerminated(options.user)
            w.lenencBytes(initialResponse(plugin: plugin, options: options, nonce: nonce))
            if let db { w.nullTerminated(db) }
            w.nullTerminated(plugin)
            try writePacket(w.bytes)
            try authenticate(plugin: plugin, nonce: nonce, options: options)

            _ = try execute("SET NAMES utf8mb4")
        } catch {
            t.close()
            throw error
        }
    }

    private func initialResponse(plugin: String, options: Options, nonce: [UInt8]) -> [UInt8] {
        if plugin == Auth.sha256Password && options.ssl && !options.password.isEmpty {
            return Array(options.password.utf8) + [0]
        }
        return Auth.response(plugin: plugin, password: options.password, nonce: nonce)
    }

    private func authenticate(plugin startPlugin: String, nonce startNonce: [UInt8], options: Options) throws {
        var plugin = startPlugin
        var nonce = startNonce
        while true {
            let p = try readPacket()
            switch p.first {
            case 0x00:
                status = try Self.parseOK(p).status
                return
            case 0xFF:
                throw Self.parseError(p)
            case 0xFE: // auth switch
                var r = PacketReader(p)
                try r.skip(1)
                plugin = String(decoding: try r.nullTerminated(), as: UTF8.self)
                nonce = Array(r.rest().prefix(20))
                try writePacket(initialResponse(plugin: plugin, options: options, nonce: nonce))
            case 0x01: // more auth data
                let data = Array(p.dropFirst())
                if plugin == Auth.cachingSha2 && data == [3] {
                    continue // fast auth succeeded; the OK packet follows
                }
                if plugin == Auth.cachingSha2 && data == [4] {
                    // full authentication: clear text over TLS, else RSA with the server key
                    if options.ssl {
                        try writePacket(Array(options.password.utf8) + [0])
                    } else {
                        try writePacket([2])
                    }
                    continue
                }
                // the server's public key (after our key request)
                let pem = String(decoding: data, as: UTF8.self)
                try writePacket(try Auth.rsaEncrypt(Auth.xorPassword(options.password, nonce), pem: pem))
            default:
                throw MySQLError.protocolViolation("意外的认证响应")
            }
        }
    }

    // MARK: Packets

    private static func readPacket(_ t: Transport, _ sequence: inout UInt8) throws -> [UInt8] {
        var payload: [UInt8] = []
        while true {
            let h = try t.read(4)
            let len = Int(h[0]) | Int(h[1]) << 8 | Int(h[2]) << 16
            sequence = h[3] &+ 1
            let part = try t.read(len)
            if len < 0xFF_FFFF && payload.isEmpty { return part }
            payload += part
            if len < 0xFF_FFFF { return payload }
        }
    }

    private func readPacket() throws -> [UInt8] {
        try Self.readPacket(transport, &sequence)
    }

    private func writePacket(_ payload: [UInt8]) throws {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 4)
        var off = 0
        while true {
            let n = min(payload.count - off, 0xFF_FFFF)
            out += [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), sequence]
            sequence &+= 1
            out += payload[off..<off + n]
            off += n
            if n < 0xFF_FFFF { break }
        }
        try transport.write(out)
    }

    private static func parseOK(_ p: [UInt8]) throws -> QueryOK {
        var r = PacketReader(p)
        try r.skip(1)
        var ok = QueryOK()
        ok.affectedRows = try r.lenencInt() ?? 0
        ok.lastInsertID = try r.lenencInt() ?? 0
        if !r.isAtEnd { ok.status = try r.u16() }
        return ok
    }

    private static func parseEOF(_ p: [UInt8]) throws -> QueryOK {
        var r = PacketReader(p)
        try r.skip(3) // header, warnings
        var ok = QueryOK()
        if !r.isAtEnd { ok.status = try r.u16() }
        return ok
    }

    static func parseError(_ p: [UInt8]) -> MySQLError {
        var r = PacketReader(p)
        guard (try? r.skip(1)) != nil, let code = try? r.u16() else {
            return .protocolViolation("错误包格式不正确")
        }
        var state = "HY000"
        if r.bytes.count > r.pos, r.bytes[r.pos] == UInt8(ascii: "#"), let s = try? r.bytes(6) {
            state = String(decoding: s.dropFirst(), as: UTF8.self)
        }
        return .server(code: code, sqlState: state, message: String(decoding: r.rest(), as: UTF8.self))
    }

    private static func parseColumn(_ p: [UInt8]) throws -> QueryColumn {
        var r = PacketReader(p)
        for _ in 0..<4 { _ = try r.lenencBytes() } // catalog, schema, table, org_table
        let name = try r.lenencString()
        _ = try r.lenencBytes() // org_name
        _ = try r.lenencInt() // fixed-length fields length
        let charset = try r.u16()
        _ = try r.u32() // column length
        let type = try r.u8()
        return QueryColumn(
            name: name,
            typeName: ColumnType.name(type),
            isBinary: ColumnType.isBinary(type, charset: charset),
            isNumeric: ColumnType.isNumeric(type)
        )
    }

    private static func parseRow(_ p: [UInt8], _ columns: [QueryColumn]) throws -> [String?] {
        var r = PacketReader(p)
        var out = [String?]()
        out.reserveCapacity(columns.count)
        for c in columns {
            guard let b = try r.lenencBytes() else {
                out.append(nil)
                continue
            }
            out.append(c.isBinary ? hexString(b) : String(decoding: b, as: UTF8.self))
        }
        return out
    }

    // MARK: Commands

    private func markBroken() {
        stateLock.lock()
        _broken = true
        stateLock.unlock()
        transport.close()
    }

    /// Run a command; I/O and protocol errors close the connection.
    private func command<T>(_ body: () throws -> T) throws -> T {
        guard !isBroken else { throw MySQLError.io("连接已断开") }
        do {
            let v = try body()
            lastUsed = Date()
            return v
        } catch let e as MySQLError where e.isServerError {
            lastUsed = Date()
            throw e
        } catch {
            markBroken()
            throw error
        }
    }

    /// Send `sql` with COM_QUERY and report every result it produces.
    /// If `handle` throws, the connection is closed (its results are not drained).
    public func query(_ sql: String, _ handle: (QueryEvent) throws -> Void) throws {
        try command {
            sequence = 0
            try writePacket([0x03] + Array(sql.utf8))
            try readResults(handle)
        }
    }

    private func readResults(_ handle: (QueryEvent) throws -> Void) throws {
        let deprecateEOF = capabilities & Capability.deprecateEOF != 0
        while true {
            let p = try readPacket()
            switch p.first {
            case 0x00:
                let ok = try Self.parseOK(p)
                status = ok.status
                try handle(.end(ok))
                if ok.status & Status.moreResults == 0 { return }
            case 0xFF:
                throw Self.parseError(p)
            case 0xFB:
                throw MySQLError.protocolViolation("不支持 LOAD DATA LOCAL INFILE")
            default:
                var r = PacketReader(p)
                let count = Int(try r.lenencInt() ?? 0)
                var columns = [QueryColumn]()
                columns.reserveCapacity(count)
                for _ in 0..<count {
                    columns.append(try Self.parseColumn(try readPacket()))
                }
                if !deprecateEOF { _ = try readPacket() }
                try handle(.columns(columns))
                while true {
                    let row = try readPacket()
                    if row.first == 0xFE && row.count < 0xFF_FFFF {
                        let ok = deprecateEOF ? try Self.parseOK(row) : try Self.parseEOF(row)
                        status = ok.status
                        try handle(.end(ok))
                        if ok.status & Status.moreResults == 0 { return }
                        break
                    }
                    if row.first == 0xFF { throw Self.parseError(row) }
                    try handle(.row(try Self.parseRow(row, columns)))
                }
            }
        }
    }

    /// Run statements that return no rows; returns the last OK.
    @discardableResult
    public func execute(_ sql: String) throws -> QueryOK {
        var last = QueryOK()
        try query(sql) { if case let .end(ok) = $0 { last = ok } }
        return last
    }

    /// Rows of the first result set.
    public func rows(_ sql: String) throws -> [[String?]] {
        var rows: [[String?]] = []
        var sets = 0
        try query(sql) { e in
            switch e {
            case .columns: sets += 1
            case let .row(r) where sets == 1: rows.append(r)
            default: break
            }
        }
        return rows
    }

    public func firstRow(_ sql: String) throws -> [String?]? {
        try rows(sql).first
    }

    public func ping() throws {
        try command {
            sequence = 0
            try writePacket([0x0E])
            let p = try readPacket()
            if p.first == 0xFF { throw Self.parseError(p) }
            status = try Self.parseOK(p).status
        }
    }

    /// Quote a string literal for this connection's sql_mode.
    public func quote(_ s: String) -> String {
        SQL.quote(s, noBackslashEscapes: noBackslashEscapes)
    }

    public func close() {
        if !isBroken {
            sequence = 0
            try? writePacket([0x01]) // COM_QUIT
        }
        markBroken()
    }

    /// Abort a query running on another thread (the connection is closed).
    public func abort() {
        stateLock.lock()
        _broken = true
        stateLock.unlock()
        transport.shutdown()
    }
}

enum ColumnType {
    static func name(_ t: UInt8) -> String {
        switch t {
        case 0: "DECIMAL"
        case 1: "TINY"
        case 2: "SHORT"
        case 3: "LONG"
        case 4: "FLOAT"
        case 5: "DOUBLE"
        case 6: "NULL"
        case 7: "TIMESTAMP"
        case 8: "LONGLONG"
        case 9: "INT24"
        case 10: "DATE"
        case 11: "TIME"
        case 12: "DATETIME"
        case 13: "YEAR"
        case 14: "NEWDATE"
        case 15: "VARCHAR"
        case 16: "BIT"
        case 17: "TIMESTAMP2"
        case 18: "DATETIME2"
        case 19: "TIME2"
        case 242: "VECTOR"
        case 245: "JSON"
        case 246: "NEWDECIMAL"
        case 247: "ENUM"
        case 248: "SET"
        case 249: "TINY_BLOB"
        case 250: "MEDIUM_BLOB"
        case 251: "LONG_BLOB"
        case 252: "BLOB"
        case 253: "VAR_STRING"
        case 254: "STRING"
        case 255: "GEOMETRY"
        default: "UNKNOWN"
        }
    }

    static func isNumeric(_ t: UInt8) -> Bool {
        [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(t)
    }

    /// BIT / GEOMETRY / VECTOR, and string types in the binary charset (63).
    static func isBinary(_ t: UInt8, charset: UInt16) -> Bool {
        switch t {
        case 16, 242, 255: true
        case 15, 249, 250, 251, 252, 253, 254: charset == 63
        default: false
        }
    }
}
