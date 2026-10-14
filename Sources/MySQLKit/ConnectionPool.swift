import Foundation

/// Up to 16 connections to one server, handed out one caller at a time.
final class ConnectionPool: @unchecked Sendable {
    let options: MySQLConnection.Options
    private let cond = NSCondition()
    private var idle: [MySQLConnection] = []
    private var open = 0
    private var closed = false
    private let maxOpen = 16
    /// Idle connections older than this are pinged before reuse.
    private let checkAfter: TimeInterval = 30

    init(options: MySQLConnection.Options) {
        self.options = options
    }

    func acquire() throws -> MySQLConnection {
        cond.lock()
        while true {
            if closed {
                cond.unlock()
                throw MySQLError.message("连接已关闭")
            }
            if let c = idle.popLast() {
                cond.unlock()
                if Date().timeIntervalSince(c.lastUsed) < checkAfter { return c }
                if (try? c.ping()) != nil { return c }
                c.close()
                cond.lock()
                open -= 1
                continue
            }
            if open < maxOpen {
                open += 1
                cond.unlock()
                do {
                    return try MySQLConnection(options)
                } catch {
                    cond.lock()
                    open -= 1
                    cond.signal()
                    cond.unlock()
                    throw error
                }
            }
            cond.wait()
        }
    }

    func release(_ c: MySQLConnection) {
        if !c.isBroken && c.inTransaction {
            _ = try? c.execute("ROLLBACK")
        }
        cond.lock()
        if c.isBroken || closed {
            open -= 1
            cond.signal()
            cond.unlock()
            c.close()
            return
        }
        idle.append(c)
        cond.signal()
        cond.unlock()
    }

    func with<T>(_ body: (MySQLConnection) throws -> T) throws -> T {
        let c = try acquire()
        defer { release(c) }
        return try body(c)
    }

    /// Close idle connections now; busy ones close when released.
    func close() {
        cond.lock()
        closed = true
        let list = idle
        idle = []
        open -= list.count
        cond.broadcast()
        cond.unlock()
        list.forEach { $0.close() }
    }
}
