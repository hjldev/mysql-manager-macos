import Foundation

public enum MySQLError: Error, LocalizedError, Sendable {
    /// ERR packet from the server. The connection stays usable.
    case server(code: UInt16, sqlState: String, message: String)
    /// Network or TLS failure. The connection is closed.
    case io(String)
    /// Unexpected bytes from the server. The connection is closed.
    case protocolViolation(String)
    /// Anything else, already worded for the user.
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .server(code, state, message): "ERROR \(code) (\(state)): \(message)"
        case let .io(m): m
        case let .protocolViolation(m): "协议错误：\(m)"
        case let .message(m): m
        }
    }

    var isServerError: Bool {
        if case .server = self { true } else { false }
    }
}

/// Little-endian reader over one packet payload.
struct PacketReader {
    let bytes: [UInt8]
    private(set) var pos = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { pos >= bytes.count }

    private func need(_ n: Int) throws {
        guard pos + n <= bytes.count else { throw MySQLError.protocolViolation("数据包过短") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func uint(_ n: Int) throws -> UInt64 {
        try need(n)
        var v: UInt64 = 0
        for i in 0..<n {
            v |= UInt64(bytes[pos + i]) << (8 * i)
        }
        pos += n
        return v
    }

    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }

    /// Length-encoded integer; nil for the NULL marker (0xFB).
    mutating func lenencInt() throws -> UInt64? {
        let first = try u8()
        switch first {
        case 0xFB: return nil
        case 0xFC: return try uint(2)
        case 0xFD: return try uint(3)
        case 0xFE: return try uint(8)
        default: return UInt64(first)
        }
    }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n)
        defer { pos += n }
        return bytes[pos..<pos + n]
    }

    /// Length-encoded string; nil for NULL.
    mutating func lenencBytes() throws -> ArraySlice<UInt8>? {
        guard let n = try lenencInt() else { return nil }
        return try bytes(Int(n))
    }

    mutating func lenencString() throws -> String {
        String(decoding: try lenencBytes() ?? [], as: UTF8.self)
    }

    mutating func nullTerminated() throws -> ArraySlice<UInt8> {
        guard let end = bytes[pos...].firstIndex(of: 0) else {
            defer { pos = bytes.count }
            return bytes[pos...]
        }
        defer { pos = end + 1 }
        return bytes[pos..<end]
    }

    mutating func rest() -> ArraySlice<UInt8> {
        defer { pos = bytes.count }
        return bytes[pos...]
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }
}

/// Little-endian packet payload builder.
struct PacketWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func uint(_ v: UInt64, _ n: Int) {
        for i in 0..<n {
            bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
        }
    }

    mutating func u16(_ v: UInt16) { uint(UInt64(v), 2) }
    mutating func u32(_ v: UInt32) { uint(UInt64(v), 4) }

    mutating func lenencInt(_ v: UInt64) {
        switch v {
        case ..<251: u8(UInt8(v))
        case ..<0x1_0000: u8(0xFC); uint(v, 2)
        case ..<0x100_0000: u8(0xFD); uint(v, 3)
        default: u8(0xFE); uint(v, 8)
        }
    }

    mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }

    mutating func lenencBytes(_ b: [UInt8]) {
        lenencInt(UInt64(b.count))
        bytes.append(contentsOf: b)
    }

    mutating func nullTerminated(_ s: String) {
        bytes.append(contentsOf: s.utf8)
        bytes.append(0)
    }

    mutating func zeros(_ n: Int) { bytes.append(contentsOf: repeatElement(0, count: n)) }
}

func hexString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    let digits = Array("0123456789ABCDEF".utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count * 2 + 2)
    out.append(UInt8(ascii: "0"))
    out.append(UInt8(ascii: "x"))
    for b in bytes {
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}
