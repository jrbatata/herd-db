import Foundation

/// Everything that differs between engines sits behind a dialect:
/// identifier quoting, limiting and catalog lookup conventions.
public struct SQLDialect: Sendable, Equatable {
    public enum Family: String, Sendable {
        case postgres
        case sqlServer
    }

    public let family: Family

    public init(family: Family) {
        self.family = family
    }

    public static let postgres = SQLDialect(family: .postgres)
    public static let sqlServer = SQLDialect(family: .sqlServer)

    public func quote(_ identifier: String) -> String {
        switch family {
        case .postgres:
            return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        case .sqlServer:
            return "[\(identifier.replacingOccurrences(of: "]", with: "]]"))]"
        }
    }

    public func qualify(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else { return quote(table) }
        return "\(quote(schema)).\(quote(table))"
    }

    public func limitedSelect(schema: String?, table: String, limit: Int) -> String {
        let target = qualify(schema: schema, table: table)
        switch family {
        case .postgres:
            return "SELECT *\nFROM \(target)\nLIMIT \(limit);"
        case .sqlServer:
            return "SELECT TOP \(limit) *\nFROM \(target);"
        }
    }
}
