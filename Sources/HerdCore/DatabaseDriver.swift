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
    /// Functions and procedures of one schema; used by the sidebar and the palette.
    func listRoutines(database: String, schema: String) async throws -> [RoutineInfo]
    /// Every table, view, materialized view and routine of a database.
    func listObjects(database: String) async throws -> [DatabaseObject]

    /// Snapshot of schemas, tables and columns used by autocomplete.
    func catalog(database: String) async throws -> SQLCatalog
    /// Flattened columns of every schema; used by the default `catalog` implementation.
    func listCatalogColumns(database: String) async throws -> [CatalogColumn]

    func run(_ sql: String, database: String) async throws -> QueryResult
    /// Executa com uma origem explícita, usada pelo console de log.
    func run(_ sql: String, database: String, source: QueryLogSource) async throws -> QueryResult
    func browseTable(database: String, schema: String?, table: String,
                     page: Int, pageSize: Int, filter: String,
                     sortColumn: String?, descending: Bool) async throws -> TablePage

    func shutdown() async
}

public extension DatabaseDriver {
    func run(_ sql: String, database: String, source: QueryLogSource) async throws -> QueryResult {
        try await run(sql, database: database)
    }

    func browseTable(database: String, schema: String?, table: String,
                     page: Int, pageSize: Int, filter: String,
                     sortColumn: String?, descending: Bool) async throws -> TablePage {
        throw HerdError.queryFailed("Este driver não oferece paginação de tabelas.")
    }
    func catalog(database: String) async throws -> SQLCatalog {
        let schemas = try await listSchemas(database: database).map(\.name)
        var tables: [TableInfo] = []
        for schema in schemas {
            tables.append(contentsOf: try await listTables(database: database, schema: schema))
        }
        let columns = try await listCatalogColumns(database: database)
        return SQLCatalog(schemas: schemas, tables: tables, columns: columns)
    }

    func listCatalogColumns(database: String) async throws -> [CatalogColumn] {
        []
    }

    func listRoutines(database: String, schema: String) async throws -> [RoutineInfo] {
        []
    }

    func listObjects(database: String) async throws -> [DatabaseObject] {
        let schemas = try await listSchemas(database: database).map(\.name)
        var objects: [DatabaseObject] = []
        for schema in schemas {
            let tables = try await listTables(database: database, schema: schema)
            objects.append(contentsOf: tables.map {
                DatabaseObject(
                    schema: $0.schema,
                    name: $0.name,
                    kind: $0.kind == .view ? .view : .table
                )
            })
            let routines = try await listRoutines(database: database, schema: schema)
            objects.append(contentsOf: routines.map {
                DatabaseObject(schema: $0.schema, name: $0.name, kind: $0.kind.objectKind)
            })
        }
        return objects
    }
}
