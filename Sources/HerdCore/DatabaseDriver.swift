import Foundation

/// A connection to a database server. One driver instance serves one connection
/// configuration and is shared by every window.
public protocol DatabaseDriver: Sendable {
    var dialect: SQLDialect { get }

    /// Connects and returns the server banner.
    func test() async throws -> ServerInfo

    func listDatabases() async throws -> [DatabaseInfo]
    func listSchemas(database: String) async throws -> [SchemaInfo]
    func listTables(database: String, schema: String) async throws -> [TableInfo]
    func listColumns(database: String, schema: String, table: String) async throws -> [ColumnInfo]

    func run(_ sql: String, database: String) async throws -> QueryResult

    func shutdown() async
}
