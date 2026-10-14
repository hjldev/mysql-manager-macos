import Darwin
import Foundation
import Security

/// Blocking TCP socket with optional TLS, buffered for packet reads.
/// Used by one thread at a time; `shutdown()` may be called from any thread
/// to unblock a pending read.
final class Transport: @unchecked Sendable {
    private let fd: Int32
    private var tls: SSLContext?
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0
    private var end = 0
    private let closeLock = NSLock()
    private var closed = false

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        fd = try Self.openSocket(host: host, port: port, timeout: timeout)
    }

    private static func openSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let list else {
            throw MySQLError.io("无法解析主机 \(host)：\(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(list) }

        var lastError = "无法连接到 \(host):\(port)"
        var node: UnsafeMutablePointer<addrinfo>? = list
        while let ai = node?.pointee {
            node = ai.ai_next
            let s = socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol)
            if s < 0 { continue }
            do {
                try connect(s, ai, timeout: timeout)
                var on: Int32 = 1
                let size = socklen_t(MemoryLayout<Int32>.size)
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
                setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &on, size)
                setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, size)
                return s
            } catch {
                lastError = "无法连接到 \(host):\(port)：\(error.localizedDescription)"
                Darwin.close(s)
            }
        }
        throw MySQLError.io(lastError)
    }

    /// Non-blocking connect with a timeout, then back to blocking mode.
    private static func connect(_ s: Int32, _ ai: addrinfo, timeout: TimeInterval) throws {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(s, ai.ai_addr, ai.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { throw MySQLError.io(String(cString: strerror(errno))) }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            let n = poll(&pfd, 1, Int32(timeout * 1000))
            if n == 0 { throw MySQLError.io("连接超时") }
            if n < 0 { throw MySQLError.io(String(cString: strerror(errno))) }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { throw MySQLError.io(String(cString: strerror(err))) }
        }
        _ = fcntl(s, F_SETFL, flags)
    }

    deinit {
        close()
    }

    /// Exactly `count` bytes.
    func read(_ count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            if start == end { try refill() }
            let take = min(count - out.count, end - start)
            out.append(contentsOf: buffer[start..<start + take])
            start += take
        }
        return out
    }

    private func refill() throws {
        let n = try buffer.withUnsafeMutableBytes { try rawRead($0.baseAddress!, $0.count) }
        guard n > 0 else { throw MySQLError.io("服务器断开了连接") }
        start = 0
        end = n
    }

    private func rawRead(_ p: UnsafeMutableRawPointer, _ len: Int) throws -> Int {
        if let tls {
            var processed = 0
            let status = SSLRead(tls, p, len, &processed)
            if processed > 0 { return processed }
            if status == errSSLClosedGraceful || status == errSSLClosedNoNotify { return 0 }
            throw MySQLError.io("TLS 读取失败（\(status)）")
        }
        while true {
            let n = Darwin.read(fd, p, len)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            throw MySQLError.io("读取失败：\(String(cString: strerror(errno)))")
        }
    }

    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let p = raw.baseAddress! + off
                let left = raw.count - off
                if let tls {
                    var processed = 0
                    let status = SSLWrite(tls, p, left, &processed)
                    if status != noErr && processed == 0 { throw MySQLError.io("TLS 写入失败（\(status)）") }
                    off += processed
                } else {
                    let n = Darwin.write(fd, p, left)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw MySQLError.io("写入失败：\(String(cString: strerror(errno)))")
                    }
                    off += n
                }
            }
        }
    }

    /// Switch the connection to TLS (after the client's SSLRequest packet).
    /// The server certificate is not verified, like the Tauri client.
    func startTLS(host: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw MySQLError.io("无法创建 TLS 上下文")
        }
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)
        SSLSetConnection(ctx, UnsafeRawPointer(bitPattern: Int(fd) + 1))
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        _ = host.withCString { SSLSetPeerDomainName(ctx, $0, strlen($0)) }
        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
        } while status == errSSLWouldBlock || status == errSSLPeerAuthCompleted
        guard status == noErr else { throw MySQLError.io("TLS 握手失败（\(status)）") }
        tls = ctx
    }

    /// Unblock a read in progress on another thread.
    func shutdown() {
        closeLock.lock()
        defer { closeLock.unlock() }
        if !closed { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        if let tls { SSLClose(tls) }
        Darwin.close(fd)
    }
}

// SecureTransport I/O callbacks over a blocking socket; the connection ref is fd + 1.

private func tlsRead(_ conn: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: conn) - 1)
    let want = length.pointee
    var got = 0
    while got < want {
        let n = Darwin.read(fd, data + got, want - got)
        if n > 0 {
            got += n
        } else if n < 0 && errno == EINTR {
            continue
        } else {
            length.pointee = got
            return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort
        }
    }
    length.pointee = got
    return noErr
}

private func tlsWrite(_ conn: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
    let fd = Int32(Int(bitPattern: conn) - 1)
    let want = length.pointee
    var sent = 0
    while sent < want {
        let n = Darwin.write(fd, data + sent, want - sent)
        if n >= 0 {
            sent += n
        } else if errno != EINTR {
            length.pointee = sent
            return errSSLClosedAbort
        }
    }
    length.pointee = sent
    return noErr
}
