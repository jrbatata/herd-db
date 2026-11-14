import Foundation

public enum SQLTokenKind: Equatable, Sendable {
    case keyword
    case string
    case number
    case comment
    case quotedIdentifier
    case parameter
}

public struct SQLToken: Equatable, Sendable {
    public var range: NSRange
    public var kind: SQLTokenKind

    public init(range: NSRange, kind: SQLTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Single-pass SQL tokenizer used for syntax highlighting. It never reports
/// keywords inside strings, quoted identifiers, dollar-quoted bodies or comments.
public enum SQLTokenizer {
    public static func tokens(in sql: String) -> [SQLToken] {
        let units = Array(sql.utf16)
        guard !units.isEmpty else { return [] }

        var tokens: [SQLToken] = []
        var index = 0
        let count = units.count

        func emit(_ kind: SQLTokenKind, from start: Int, to end: Int) {
            guard end > start else { return }
            tokens.append(SQLToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        while index < count {
            let unit = units[index]

            if isWhitespace(unit) {
                index += 1
                continue
            }

            // -- line comment
            if unit == ascii("-"), index + 1 < count, units[index + 1] == ascii("-") {
                let start = index
                index += 2
                while index < count, units[index] != ascii("\n") { index += 1 }
                emit(.comment, from: start, to: index)
                continue
            }

            // /* nested block comment */
            if unit == ascii("/"), index + 1 < count, units[index + 1] == ascii("*") {
                let start = index
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
                emit(.comment, from: start, to: index)
                continue
            }

            // $tag$ ... $tag$
            if unit == ascii("$"), let delimiter = dollarDelimiter(units, at: index) {
                let start = index
                let pattern = Array(delimiter.utf16)
                index += pattern.count
                while index < count {
                    if units[index] == pattern[0], matches(units, at: index, pattern) {
                        index += pattern.count
                        break
                    }
                    index += 1
                }
                emit(.string, from: start, to: index)
                continue
            }

            // $1 positional parameter
            if unit == ascii("$"), index + 1 < count, isDigit(units[index + 1]) {
                let start = index
                index += 1
                while index < count, isDigit(units[index]) { index += 1 }
                emit(.parameter, from: start, to: index)
                continue
            }

            // '...' string
            if unit == ascii("'") {
                let start = index
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
                emit(.string, from: start, to: index)
                continue
            }

            // "..." quoted identifier
            if unit == ascii("\"") {
                let start = index
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
                emit(.quotedIdentifier, from: start, to: index)
                continue
            }

            // number
            if isDigit(unit) {
                let start = index
                while index < count, isDigit(units[index]) { index += 1 }
                if index < count, units[index] == ascii(".") {
                    index += 1
                    while index < count, isDigit(units[index]) { index += 1 }
                }
                if index < count, units[index] == ascii("e") || units[index] == ascii("E") {
                    var exponent = index + 1
                    if exponent < count, units[exponent] == ascii("+") || units[exponent] == ascii("-") {
                        exponent += 1
                    }
                    if exponent < count, isDigit(units[exponent]) {
                        index = exponent
                        while index < count, isDigit(units[index]) { index += 1 }
                    }
                }
                emit(.number, from: start, to: index)
                continue
            }

            // identifier or keyword
            if isIdentifierStart(unit) {
                let start = index
                index += 1
                while index < count, isIdentifierBody(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if keywords.contains(word.uppercased()) {
                    emit(.keyword, from: start, to: index)
                }
                continue
            }

            index += 1
        }

        return tokens
    }

    // MARK: - Keywords

    public static let keywords: Set<String> = [
        "ALL", "ALTER", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "BEGIN", "BETWEEN",
        "BIGINT", "BIGSERIAL", "BOOLEAN", "BY", "BYTEA", "CASCADE", "CASE", "CAST", "CHAR",
        "CHECK", "COALESCE", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE",
        "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATE", "DECIMAL", "DEFAULT",
        "DELETE", "DESC", "DISTINCT", "DO", "DOUBLE", "DROP", "ELSE", "END", "ENUM", "EXCEPT",
        "EXISTS", "EXPLAIN", "FALSE", "FILTER", "FIRST", "FLOAT", "FOR", "FOREIGN", "FROM", "FULL",
        "GRANT", "GROUP", "HAVING", "IF", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INT",
        "INTEGER", "INTERSECT", "INTERVAL", "INTO", "IS", "JOIN", "JSON", "JSONB", "KEY", "LAST",
        "LATERAL", "LEFT", "LIKE", "LIMIT", "MATERIALIZED", "NOT", "NOTHING", "NULL", "NULLS",
        "NUMERIC", "OFFSET", "ON", "ONLY", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRECISION",
        "PRIMARY", "REAL", "RECURSIVE", "REFERENCES", "REFRESH", "RESTRICT", "RETURNING", "REVOKE",
        "RIGHT", "ROLLBACK", "ROW", "ROWS", "SCHEMA", "SELECT", "SERIAL", "SET", "SMALLINT", "TABLE",
        "TEMPORARY", "TEXT", "THEN", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TRANSACTION", "TRUE",
        "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USING", "UUID", "VACUUM", "VALUES", "VARCHAR",
        "VIEW", "WHEN", "WHERE", "WINDOW", "WITH",
    ]

    // MARK: - Scanning helpers

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue ?? 0)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == ascii("_") || unit >= 0x80
    }

    private static func isIdentifierBody(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == ascii("$")
    }

    private static func isEscapeString(_ units: [UInt16], quoteAt index: Int) -> Bool {
        guard index >= 1 else { return false }
        let previous = units[index - 1]
        guard previous == ascii("E") || previous == ascii("e") else { return false }
        guard index >= 2 else { return true }
        return !isIdentifierBody(units[index - 2])
    }

    private static func dollarDelimiter(_ units: [UInt16], at index: Int) -> String? {
        var cursor = index + 1
        while cursor < units.count, units[cursor] != ascii("$") {
            let unit = units[cursor]
            let isLetter = (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
            guard isLetter || isDigit(unit) || unit == ascii("_") else { return nil }
            if cursor == index + 1, isDigit(unit) { return nil }
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
