import Foundation

/// SQL text helpers: identifier/literal quoting and statement splitting.
public enum SQL {
    /// Quote an identifier with backticks, escaping embedded backticks.
    public static func quoteIdent(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// `db`.`table`
    public static func qualified(_ db: String, _ table: String) -> String {
        quoteIdent(db) + "." + quoteIdent(table)
    }

    /// Quote a string literal. With the default sql_mode backslashes are
    /// escape characters; under NO_BACKSLASH_ESCAPES only quotes are doubled.
    public static func quote(_ s: String, noBackslashEscapes: Bool = false) -> String {
        var out = "'"
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count + 2)
        for c in s.unicodeScalars {
            switch c {
            case "'": out += "''"
            case "\\" where !noBackslashEscapes: out += "\\\\"
            case "\0" where !noBackslashEscapes: out += "\\0"
            case "\n" where !noBackslashEscapes: out += "\\n"
            case "\r" where !noBackslashEscapes: out += "\\r"
            case "\u{1A}" where !noBackslashEscapes: out += "\\Z"
            default: out.unicodeScalars.append(c)
            }
        }
        out += "'"
        return out
    }

    /// `0x…` hex text back into bytes; nil if not valid hex.
    public static func fromHex(_ s: String) -> [UInt8]? {
        guard s.hasPrefix("0x") || s.hasPrefix("0X") else { return nil }
        let h = Array(s.utf8.dropFirst(2))
        guard h.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(h.count / 2)
        var i = 0
        while i < h.count {
            guard let a = nibble(h[i]), let b = nibble(h[i + 1]) else { return nil }
            out.append(a << 4 | b)
            i += 2
        }
        return out
    }

    /// A value as an SQL literal: NULL, hex for binary columns given as
    /// `0x…`, otherwise a quoted string (MySQL converts it for numeric columns).
    public static func literal(_ value: String?, binary: Bool, noBackslashEscapes: Bool = false) -> String {
        guard let value else { return "NULL" }
        if binary && fromHex(value) != nil { return value }
        return quote(value, noBackslashEscapes: noBackslashEscapes)
    }

    /// Split a script into individual statements. Handles quotes, backticks,
    /// comments and the client-side `DELIMITER` command.
    public static func splitStatements(_ sql: String) -> [String] {
        var out: [String] = []
        var delim: [Unicode.Scalar] = [";"]
        var cur = String.UnicodeScalarView()
        let chars = Array(sql.unicodeScalars)
        let n = chars.count
        var i = 0
        var atLineStart = true

        func flush() {
            let t = String(cur).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !isOnlyComments(t) { out.append(t) }
            cur.removeAll()
        }
        func curIsBlank() -> Bool {
            cur.allSatisfy { $0.properties.isWhitespace }
        }

        while i < n {
            // DELIMITER command at the start of a line (only when the current statement is empty)
            if atLineStart && curIsBlank() && i + 10 <= n {
                let word = String(String.UnicodeScalarView(chars[i..<i + 10]))
                if word.caseInsensitiveCompare("DELIMITER ") == .orderedSame {
                    var j = i + 10
                    var line = String.UnicodeScalarView()
                    while j < n && chars[j] != "\n" {
                        line.append(chars[j])
                        j += 1
                    }
                    let d = String(line).trimmingCharacters(in: .whitespaces)
                    if !d.isEmpty { delim = Array(d.unicodeScalars) }
                    cur.removeAll()
                    i = j
                    continue
                }
            }
            let c = chars[i]
            switch c {
            case "'", "\"", "`":
                cur.append(c)
                i += 1
                while i < n {
                    let d = chars[i]
                    cur.append(d)
                    i += 1
                    if d == "\\" && c != "`" && i < n {
                        cur.append(chars[i])
                        i += 1
                    } else if d == c {
                        if i < n && chars[i] == c {
                            cur.append(chars[i])
                            i += 1
                        } else {
                            break
                        }
                    }
                }
                atLineStart = false
                continue
            case "-" where i + 1 < n && chars[i + 1] == "-" && (i + 2 >= n || chars[i + 2].properties.isWhitespace),
                 "#":
                while i < n && chars[i] != "\n" {
                    cur.append(chars[i])
                    i += 1
                }
                continue
            case "/" where i + 1 < n && chars[i + 1] == "*":
                cur.append("/")
                cur.append("*")
                i += 2
                while i < n {
                    if chars[i] == "*" && i + 1 < n && chars[i + 1] == "/" {
                        cur.append("*")
                        cur.append("/")
                        i += 2
                        break
                    }
                    cur.append(chars[i])
                    i += 1
                }
                continue
            default:
                break
            }
            if i + delim.count <= n && chars[i..<i + delim.count].elementsEqual(delim) {
                flush()
                i += delim.count
                atLineStart = false
                continue
            }
            cur.append(c)
            atLineStart = c == "\n"
            i += 1
        }
        flush()
        return out
    }

    static func isOnlyComments(_ s: String) -> Bool {
        var rest = Substring(s).drop { $0.isWhitespace }
        while true {
            if rest.isEmpty { return true }
            if rest.hasPrefix("--") || rest.hasPrefix("#") {
                guard let p = rest.firstIndex(of: "\n") else { return true }
                rest = rest[rest.index(after: p)...].drop { $0.isWhitespace }
            } else if rest.hasPrefix("/*") && !rest.hasPrefix("/*!") {
                guard let r = rest.range(of: "*/") else { return true }
                rest = rest[r.upperBound...].drop { $0.isWhitespace }
            } else {
                return false
            }
        }
    }
}
