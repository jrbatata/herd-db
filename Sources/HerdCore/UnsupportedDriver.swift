import Foundation

/// Placeholder for engines whose driver is not implemented yet (SQL Server, phase 6).
public struct UnsupportedDriver: DatabaseDriver {
    public let engine: DatabaseEngine
    public let dialect: SQLDialect

    public init(engine: DatabaseEngine) {
        self.engine = engine
        self.dialect = engine == .sqlServer ? .sqlServer : .postgres
    }

    public func test() async throws -> ServerInfo { throw HerdError.unsupportedEngine(engine) }
    public func listDatabases() async throws -> [DatabaseInfo] { throw HerdError.unsupportedEngine(engine) }
    public func listSchemas(database: String) async throws -> [SchemaInfo] { throw HerdError.unsupportedEngine(engine) }
    public func listTables(database: String, schema: String) async throws -> [TableInfo] { throw HerdError.unsupportedEngine(engine) }
    public func listColumns(database: String, schema: String, table: String) async throws -> [ColumnInfo] { throw HerdError.unsupportedEngine(engine) }
    public func run(_ sql: String, database: String) async throws -> QueryResult { throw HerdError.unsupportedEngine(engine) }
    public func shutdown() async {}
}
