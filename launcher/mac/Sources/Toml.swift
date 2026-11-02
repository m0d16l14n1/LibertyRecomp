// native.toml, edited in place: the top-level `key = value` lines the launcher
// knows are changed or added, and everything else in the file (comments, other
// options, the order) stays as it is. The game's pause menu saves the same file
// (rex::cvar::SaveConfig: every option that differs from its default), so the
// two take turns on one file and each shows what the other set. Only
// single-line values are read and written: everything the launcher sets is a
// string, a number or a boolean. (From the MCLA port's launcher.)

import Foundation

enum TomlValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// The value as TOML writes it.
    var literal: String {
        switch self {
        case .string(let s):
            var out = "\""
            for c in s.unicodeScalars {
                switch c {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                default:
                    if c.value < 0x20 { out += String(format: "\\u%04X", c.value) } else { out.unicodeScalars.append(c) }
                }
            }
            return out + "\""
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        }
    }

    /// A value as the launcher compares them: "1", "1.0" and 1 are one value.
    var key: String {
        switch self {
        case .string(let s): return "s:" + s
        case .int(let i): return "n:" + String(Double(i))
        case .double(let d): return "n:" + String(d)
        case .bool(let b): return b ? "b:1" : "b:0"
        }
    }

    var asString: String? { if case .string(let s) = self { return s }; return nil }
    var asDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" ? true : s == "false" ? false : nil
        default: return nil
        }
    }

    /// Parses the value part of a line (after `=`), up to a comment. Nil for what the launcher doesn't read.
    static func parse(_ text: Substring) -> (TomlValue, Substring.Index)? {
        var i = text.startIndex
        while i < text.endIndex, text[i] == " " || text[i] == "\t" { i = text.index(after: i) }
        guard i < text.endIndex else { return nil }
        if text[i] == "\"" {
            var out = ""
            var j = text.index(after: i)
            while j < text.endIndex {
                let c = text[j]
                if c == "\"" { return (.string(out), text.index(after: j)) }
                if c == "\\" {
                    j = text.index(after: j)
                    guard j < text.endIndex else { return nil }
                    switch text[j] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case "u":
                        let hexEnd = text.index(j, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
                        if let v = UInt32(text[text.index(after: j)..<hexEnd], radix: 16), let u = Unicode.Scalar(v) {
                            out.unicodeScalars.append(u)
                            j = text.index(before: hexEnd)
                        }
                    default: out.append(text[j])
                    }
                } else {
                    out.append(c)
                }
                j = text.index(after: j)
            }
            return nil
        }
        if text[i] == "'" {
            let rest = text[text.index(after: i)...]
            guard let end = rest.firstIndex(of: "'") else { return nil }
            return (.string(String(rest[..<end])), text.index(after: end))
        }
        var j = i
        while j < text.endIndex, text[j] != "#", text[j] != " ", text[j] != "\t" { j = text.index(after: j) }
        let word = String(text[i..<j])
        if word == "true" { return (.bool(true), j) }
        if word == "false" { return (.bool(false), j) }
        let digits = word.replacingOccurrences(of: "_", with: "")
        if let n = Int(digits) { return (.int(n), j) }
        if let d = Double(digits) { return (.double(d), j) }
        return nil
    }
}

/// The lines of a TOML file and the top-level keys in them.
struct TomlDocument {
    private(set) var lines: [String]

    init(text: String) {
        var l = text.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        lines = l.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    private static func isTable(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    /// The key of a top-level `key = value` line, where its value starts, and the line's index.
    private func statements() -> [(key: String, line: Int, valueStart: String.Index)] {
        var out: [(String, Int, String.Index)] = []
        for (n, line) in lines.enumerated() {
            if TomlDocument.isTable(line) { break }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = trimmed.first, first != "#", let eq = trimmed.firstIndex(of: "=") else { continue }
            var key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") { key = String(key.dropFirst().dropLast()) }
            out.append((key, n, line.index(after: eq)))
        }
        return out
    }

    func value(_ key: String) -> TomlValue? {
        for s in statements().reversed() where s.key == key {
            return TomlValue.parse(lines[s.line][s.valueStart...])?.0
        }
        return nil
    }

    func contains(_ key: String) -> Bool { statements().contains { $0.key == key } }

    /// All top-level keys with the values the launcher can read.
    func values() -> [String: TomlValue] {
        var out: [String: TomlValue] = [:]
        for s in statements() {
            if let v = TomlValue.parse(lines[s.line][s.valueStart...])?.0 { out[s.key] = v }
        }
        return out
    }

    /// Sets a key: its line keeps its place (and a comment after the value); a new key goes after the
    /// other top-level lines, before the first table.
    mutating func set(_ key: String, _ value: TomlValue) {
        let all = statements()
        if let s = all.last(where: { $0.key == key }) {
            let line = lines[s.line]
            var tail = ""
            if let (_, end) = TomlValue.parse(line[s.valueStart...]) {
                let after = line[end...]
                if let hash = after.firstIndex(of: "#") { tail = "  " + after[hash...] }
            }
            lines[s.line] = String(line[..<s.valueStart]) + " " + value.literal + tail
            // A key twice: the earlier ones go (TOML would refuse the file).
            for other in all.reversed() where other.key == key && other.line != s.line { lines.remove(at: other.line) }
            return
        }
        var at = lines.count
        if let table = lines.firstIndex(where: TomlDocument.isTable) {
            at = table
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
        }
        lines.insert("\(key) = \(value.literal)", at: at)
    }

    /// Removes a key, so the game's default applies.
    mutating func remove(_ key: String) {
        for s in statements().reversed() where s.key == key { lines.remove(at: s.line) }
    }
}
