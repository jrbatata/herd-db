import Foundation

/// One command found in a SQL script.
public struct SQLStatement: Equatable, Sendable {
    public var text: String
    /// UTF-16 range of the command inside the original script, without surrounding whitespace.
    public var range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

/// Splits a script on top-level semicolons, ignoring semicolons inside strings,
/// quoted identifiers, dollar-quoted bodies and comments.
public enum SQLStatementSplitter {
    /// The executable commands of `sql`, in order.
    public static func split(_ sql: String) -> [String] {
        statements(in: sql).map(\.text)
    }

    /// The executable commands of `sql` along with their positions.
    public static func statements(in sql: String) -> [SQLStatement] {
        let units = Array(sql.utf16)
        guard !units.isEmpty else { return [] }

        var result: [SQLStatement] = []
        var statementStart: Int?
        var statementEnd: Int?
        var index = 0
        let count = units.count

        func flush() {
            if let start = statementStart, let end = statementEnd, end > start,
               let range = Range(NSRange(location: start, length: end - start), in: sql) {
                result.append(SQLStatement(text: String(sql[range]), range: NSRange(location: start, length: end - start)))
            }
            statementStart = nil
            statementEnd = nil
        }

        func begin(at offset: Int) {
            if statementStart == nil { statementStart = offset }
        }

        while index < count {
            let unit = units[index]

            if isWhitespace(unit) {
                index += 1
                continue
            }

            // -- line comment
            if unit == ascii("-"), index + 1 < count, units[index + 1] == ascii("-") {
                index += 2
                while index < count, units[index] != ascii("\n") { index += 1 }
                continue
            }

            // /* block comment, PostgreSQL allows nesting */
            if unit == ascii("/"), index + 1 < count, units[index + 1] == ascii("*") {
                index += 2
                var depth = 1
                while index < count, depth > 0 {
                    if units[index] == ascii("/"), index + 1 < count, units[index + 1] == ascii("*") {
                        depth += 1
                        index += 2
                    } else if units[index] == ascii("*"), index + 1 < count, units[index + 1] == ascii("/") {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                continue
            }

            // $tag$ dollar-quoted body
            if unit == ascii("$"), let delimiter = dollarDelimiter(units, at: index) {
                begin(at: index)
                let pattern = Array(delimiter.utf16)
                index += pattern.count
                while index < count {
                    if units[index] == pattern[0], matches(units, at: index, pattern) {
                        index += pattern.count
                        break
                    }
                    index += 1
                }
                statementEnd = index
                continue
            }

            // '...' string literal, with E'...' backslash escapes
            if unit == ascii("'") {
                begin(at: index)
                let allowsBackslashEscapes = isEscapeString(units, quoteAt: index)
                index += 1
                while index < count {
                    if allowsBackslashEscapes, units[index] == ascii("\\") {
                        index = min(index + 2, count)
                        continue
                    }
                    if units[index] == ascii("'") {
                        if index + 1 < count, units[index + 1] == ascii("'") {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                statementEnd = index
                continue
            }

            // "..." quoted identifier
            if unit == ascii("\"") {
                begin(at: index)
                index += 1
                while index < count {
                    if units[index] == ascii("\"") {
                        if index + 1 < count, units[index + 1] == ascii("\"") {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                statementEnd = index
                continue
            }

            // top-level command separator
            if unit == ascii(";") {
                flush()
                index += 1
                continue
            }

            begin(at: index)
            index += 1
            statementEnd = index
        }

        flush()
        return result
    }

    // MARK: - Scanning helpers

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue ?? 0)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    private static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
            || (0x41...0x5A).contains(unit)
            || (0x61...0x7A).contains(unit)
            || unit == ascii("_")
            || unit == ascii("$")
            || unit >= 0x80
    }

    /// True when the quote belongs to `E'...'` (or `e'...'`).
    private static func isEscapeString(_ units: [UInt16], quoteAt index: Int) -> Bool {
        guard index >= 1 else { return false }
        let previous = units[index - 1]
        guard previous == ascii("E") || previous == ascii("e") else { return false }
        guard index >= 2 else { return true }
        return !isIdentifierUnit(units[index - 2])
    }

    /// Returns `$tag$` when a dollar-quote opener starts at `index`, otherwise nil.
    private static func dollarDelimiter(_ units: [UInt16], at index: Int) -> String? {
        var cursor = index + 1
        while cursor < units.count, units[cursor] != ascii("$") {
            let unit = units[cursor]
            let isLetter = (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            let isDigit = (0x30...0x39).contains(unit)
            guard isLetter || isDigit || unit == ascii("_") else { return nil }
            if cursor == index + 1, isDigit { return nil }
            cursor += 1
        }
        guard cursor < units.count else { return nil }
        return String(decoding: units[index...cursor], as: UTF16.self)
    }

    private static func matches(_ units: [UInt16], at offset: Int, _ pattern: [UInt16]) -> Bool {
        guard offset + pattern.count <= units.count else { return false }
        for index in pattern.indices where units[offset + index] != pattern[index] {
            return false
        }
        return true
    }
}
