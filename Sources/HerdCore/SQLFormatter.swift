import Foundation

/// Conservative formatter: changes keyword case and clause boundaries without
/// rewriting literals, quoted identifiers, comments or SQL expressions.
public enum SQLFormatter {
    private static let lineBreakKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "RETURNING", "JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "UNION",
        "VALUES", "SET"
    ]

    public static func format(_ sql: String, dialect: SQLDialect) -> String {
        let source = sql as NSString
        let output = NSMutableString(string: sql)
        let tokens = SQLTokenizer.tokens(in: sql).filter { $0.kind == .keyword }
        for token in tokens.reversed() {
            let keyword = source.substring(with: token.range).uppercased()
            output.replaceCharacters(in: token.range, with: keyword)

            let isDialectClause = keyword == "RETURNING" && dialect.family == .postgres
            guard (lineBreakKeywords.contains(keyword) && keyword != "RETURNING") || isDialectClause,
                  token.range.location > 0 else { continue }
            var start = token.range.location
            while start > 0 {
                let character = source.character(at: start - 1)
                guard character == 32 || character == 9 else { break }
                start -= 1
            }
            guard start < token.range.location, start > 0 else { continue }
            let preceding = source.character(at: start - 1)
            guard preceding != 10 && preceding != 13 else { continue }
            output.replaceCharacters(in: NSRange(location: start, length: token.range.location - start), with: "\n")
        }
        return output as String
    }
}
