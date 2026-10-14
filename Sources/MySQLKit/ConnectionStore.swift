import Foundation

/// A saved connection. Stored in `connections.json` in the same format as
/// the Tauri app, so both apps see the same connections.
public struct ConnectionConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var host: String
    public var port: UInt16
    public var user: String
    /// Only present when saving, or in the file when `savePassword` is set.
    public var password: String?
    public var savePassword: Bool
    public var database: String?
    public var ssl: Bool
    /// `#rrggbb`
    public var color: String?

    public init(id: String = "", name: String = "", host: String = "127.0.0.1", port: UInt16 = 3306,
                user: String = "root", password: String? = nil, savePassword: Bool = true,
                database: String? = nil, ssl: Bool = false, color: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.savePassword = savePassword
        self.database = database
        self.ssl = ssl
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, user, password, savePassword, database, ssl, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        user = try c.decode(String.self, forKey: .user)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? true
        database = try c.decodeIfPresent(String.self, forKey: .database)
        ssl = try c.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(user, forKey: .user)
        try c.encodeIfPresent(password, forKey: .password)
        try c.encode(savePassword, forKey: .savePassword)
        try c.encode(database, forKey: .database)
        try c.encode(ssl, forKey: .ssl)
        try c.encode(color, forKey: .color)
    }
}

/// `connections.json` persistence. Passwords are kept in the file (mode 0600)
/// when `savePassword` is set.
public final class ConnectionStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("connections.json") }

    private func loadAll() throws -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ConnectionConfig].self, from: Data(contentsOf: fileURL))
    }

    private func writeAll(_ list: [ConnectionConfig]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let tmp = fileURL.appendingPathExtension("tmp")
        try encoder.encode(list).write(to: tmp)
        // the file contains passwords: readable by the current user only
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard rename(tmp.path, fileURL.path) == 0 else {
            throw MySQLError.message("无法保存连接配置：\(String(cString: strerror(errno)))")
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Saved connections with passwords removed.
    public func list() throws -> [ConnectionConfig] {
        try locked {
            try loadAll().map { var c = $0; c.password = nil; return c }
        }
    }

    /// Including the stored password.
    public func find(_ id: String) throws -> ConnectionConfig {
        try locked {
            guard let c = try loadAll().first(where: { $0.id == id }) else {
                throw MySQLError.message("连接 \(id) 不存在")
            }
            return c
        }
    }

    /// Insert or update. `password == nil` keeps the stored password.
    /// Returns the saved config without its password.
    public func save(_ config: ConnectionConfig) throws -> ConnectionConfig {
        try locked {
            var cfg = config
            var list = try loadAll()
            if cfg.id.isEmpty { cfg.id = UUID().uuidString.lowercased() }
            let existing = list.firstIndex { $0.id == cfg.id }
            var stored = cfg
            if !cfg.savePassword {
                stored.password = nil
            } else if stored.password == nil, let i = existing {
                stored.password = list[i].password
            }
            if let i = existing { list[i] = stored } else { list.append(stored) }
            try writeAll(list)
            cfg.password = nil
            return cfg
        }
    }

    public func remove(_ id: String) throws {
        try locked {
            try writeAll(try loadAll().filter { $0.id != id })
        }
    }

    public func password(for id: String) -> String? {
        (try? find(id))?.password
    }
}
