import Foundation
import NIOCore
import NIOSSL
import PostgresNIO

/// PostgreSQL driver backed by postgres-nio. One pooled client per database,
/// created lazily as the user browses the tree.
public actor PostgresDriver: DatabaseDriver {
    public nonisolated let dialect: SQLDialect = .postgres

    private let config: ConnectionConfig
    private let password: String?
    private var clients: [String: PostgresClient] = [:]
    private var runners: [String: Task<Void, Never>] = [:]

    public init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    // MARK: - Connection

    private func client(for database: String?) async throws -> PostgresClient {
        let name = normalizedDatabase(database)
        if let existing = clients[name] { return existing }

        var pgConfig = PostgresClient.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: password,
            database: name,
            tls: config.useTLS ? .prefer(.makeClientConfiguration()) : .disable
        )
        pgConfig.options.maximumConnections = 6
        pgConfig.options.minimumConnections = 0
        pgConfig.options.connectionIdleTimeout = .seconds(120)

        let client = PostgresClient(configuration: pgConfig)
        clients[name] = client
        runners[name] = Task { await client.run() }
        await Task.yield()
        return client
    }

    private func normalizedDatabase(_ database: String?) -> String {
        let trimmed = (database ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? config.maintenanceDatabase : trimmed
    }

    // MARK: - DatabaseDriver

    public func test() async throws -> ServerInfo {
        let client = try await client(for: config.maintenanceDatabase)
        do {
            let rows = try await client.query("SELECT version()")
            for try await row in rows {
                let version = try row.decode(String.self)
                return ServerInfo(version: version)
            }
            throw HerdError.connectionFailed("O servidor não retornou a versão.")
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
    }

    public func listDatabases() async throws -> [DatabaseInfo] {
        let client = try await connectClient(config.maintenanceDatabase)
        do {
            let rows = try await client.query("""
                SELECT datname
                FROM pg_database
                WHERE datallowconn AND NOT datistemplate
                ORDER BY datname;
                """)
            var result: [DatabaseInfo] = []
            for try await row in rows {
                result.append(DatabaseInfo(name: try row.decode(String.self)))
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listSchemas(database: String) async throws -> [SchemaInfo] {
        let client = try await connectClient(database)
        do {
            let rows = try await client.query("""
                SELECT nspname
                FROM pg_namespace
                WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
                ORDER BY nspname;
                """)
            var result: [SchemaInfo] = []
            for try await row in rows {
                result.append(SchemaInfo(name: try row.decode(String.self)))
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listTables(database: String, schema: String) async throws -> [TableInfo] {
        let client = try await connectClient(database)
        do {
            let rows = try await client.query("""
                SELECT c.relname,
                       CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'view' ELSE 'table' END
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(schema)
                  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                ORDER BY c.relname;
                """)
            var result: [TableInfo] = []
            for try await row in rows {
                let (name, type) = try row.decode((String, String).self)
                result.append(
                    TableInfo(
                        schema: schema,
                        name: name,
                        kind: type == "view" ? .view : .table
                    )
                )
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listRoutines(database: String, schema: String) async throws -> [RoutineInfo] {
        let client = try await connectClient(database)
        do {
            let rows = try await client.query("""
                SELECT p.proname,
                       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = \(schema)
                  AND p.prokind IN ('f', 'p')
                ORDER BY p.proname;
                """)
            var result: [RoutineInfo] = []
            for try await row in rows {
                let (name, kind) = try row.decode((String, String).self)
                result.append(
                    RoutineInfo(
                        schema: schema,
                        name: name,
                        kind: kind == "procedure" ? .procedure : .function
                    )
                )
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listObjects(database: String) async throws -> [DatabaseObject] {
        let client = try await connectClient(database)
        do {
            let rows = try await client.query("""
                SELECT n.nspname,
                       c.relname,
                       CASE c.relkind
                           WHEN 'v' THEN 'view'
                           WHEN 'm' THEN 'materializedView'
                           ELSE 'table'
                       END
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                  AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                UNION ALL
                SELECT n.nspname,
                       p.proname,
                       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
                  AND p.prokind IN ('f', 'p')
                ORDER BY 1, 2;
                """)
            var seen = Set<String>()
            var result: [DatabaseObject] = []
            for try await row in rows {
                let (schema, name, kind) = try row.decode((String, String, String).self)
                guard let objectKind = DatabaseObjectKind(rawValue: kind) else { continue }
                let object = DatabaseObject(schema: schema, name: name, kind: objectKind)
                // Funções sobrecarregadas repetem schema/nome: a paleta mostra uma vez.
                guard seen.insert(object.id).inserted else { continue }
                result.append(object)
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listColumns(database: String, schema: String, table: String) async throws -> [ColumnInfo] {
        let client = try await connectClient(database)
        do {
            let rows = try await client.query("""
                SELECT a.attname AS name,
                       format_type(a.atttypid, a.atttypmod) AS data_type,
                       NOT a.attnotnull AS is_nullable,
                       EXISTS (
                           SELECT 1
                           FROM pg_index i
                           WHERE i.indrelid = c.oid
                             AND i.indisprimary
                             AND a.attnum = ANY(i.indkey)
                       ) AS is_pk,
                       (
                           SELECT fn.nspname || '.' || ft.relname || '.' || fa.attname
                           FROM pg_constraint con
                           JOIN pg_class ft ON ft.oid = con.confrelid
                           JOIN pg_namespace fn ON fn.oid = ft.relnamespace
                           JOIN pg_attribute fa ON fa.attrelid = ft.oid AND fa.attnum = con.confkey[1]
                           WHERE con.contype = 'f'
                             AND con.conrelid = c.oid
                             AND a.attnum = ANY(con.conkey)
                           LIMIT 1
                       ) AS references
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_attribute a ON a.attrelid = c.oid
                WHERE n.nspname = \(schema)
                  AND c.relname = \(table)
                  AND a.attnum > 0
                  AND NOT a.attisdropped
                ORDER BY a.attnum;
                """)
            var result: [ColumnInfo] = []
            for try await row in rows {
                let (name, dataType, nullable, isPK, references) =
                    try row.decode((String, String, Bool, Bool, String?).self)
                result.append(
                    ColumnInfo(
                        name: name,
                        dataType: dataType,
                        isNullable: nullable,
                        isPrimaryKey: isPK,
                        references: references
                    )
                )
            }
            return result
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func catalog(database: String) async throws -> SQLCatalog {
        let client = try await connectClient(database)
        do {
            let schemaSequence = try await client.query("""
                SELECT nspname
                FROM pg_namespace
                WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
                ORDER BY nspname;
                """)
            var schemas: [String] = []
            for try await row in schemaSequence {
                schemas.append(try row.decode(String.self))
            }

            let tableSequence = try await client.query("""
                SELECT table_schema, table_name, table_type
                FROM information_schema.tables
                WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
                  AND table_type IN ('BASE TABLE', 'VIEW')
                ORDER BY table_schema, table_name;
                """)
            var tables: [TableInfo] = []
            for try await row in tableSequence {
                let (schema, name, type) = try row.decode((String, String, String).self)
                tables.append(TableInfo(schema: schema, name: name, kind: type == "VIEW" ? .view : .table))
            }

            let columns = try await listCatalogColumns(database: database)
            return SQLCatalog(schemas: schemas, tables: tables, columns: columns)
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listCatalogColumns(database: String) async throws -> [CatalogColumn] {
        let client = try await connectClient(database)
        do {
            let sequence = try await client.query("""
                SELECT table_schema, table_name, column_name, data_type
                FROM information_schema.columns
                WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
                ORDER BY table_schema, table_name, ordinal_position;
                """)
            var columns: [CatalogColumn] = []
            for try await row in sequence {
                let (schema, table, name, dataType) =
                    try row.decode((String, String, String, String).self)
                columns.append(
                    CatalogColumn(schema: schema, table: table, name: name, dataType: dataType)
                )
            }
            return columns
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func run(_ sql: String, database: String) async throws -> QueryResult {
        let statements = SQLStatementSplitter.split(sql)
        guard !statements.isEmpty else {
            return QueryResult(message: "Nenhum comando para executar.", statementCount: 0)
        }

        let client = try await connectClient(database)
        let start = Date()

        let table: QueryResult?
        do {
            table = try await client.withConnection { connection -> QueryResult? in
                // Cancelling needs the backend id: postgres-nio only discards the stream
                // locally, so we ask another connection to run pg_cancel_backend for us.
                let backendID = try await Self.backendID(on: connection)

                return try await withTaskCancellationHandler {
                    var lastTable: QueryResult?
                    var allSets: [ResultSet] = []

                    for (index, statement) in statements.enumerated() {
                        try Task.checkCancellation()

                        let sequence: PostgresRowSequence
                        do {
                            sequence = try await connection.query(
                                PostgresQuery(unsafeSQL: statement),
                                logger: Self.logger
                            )
                        } catch {
                            throw Self.queryError(error, index: index, total: statements.count)
                        }

                        let columns = sequence.columns.map(\.name)
                        var rows: [[String?]] = []

                        do {
                            for try await row in sequence {
                                rows.append(row.map { PostgresCellFormatter.string(from: $0) })
                                if rows.count >= Self.maximumRows { break }
                            }
                        } catch {
                            throw Self.queryError(error, index: index, total: statements.count)
                        }

                        if !columns.isEmpty {
                            lastTable = QueryResult(columns: columns, rows: rows)
                            allSets.append(ResultSet(columns: columns, rows: rows))
                        }
                    }

                    lastTable?.sets = allSets
                    return lastTable
                } onCancel: {
                    guard let backendID else { return }
                    // The pool is sized so one spare connection exists for this request.
                    Task.detached {
                        _ = try? await client.query(
                            "SELECT pg_cancel_backend(CAST(\(Int(backendID)) AS int))"
                        ).collect()
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HerdError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HerdError.queryFailed(Self.describe(error))
        }

        var result = table ?? QueryResult()
        result.elapsed = Date().timeIntervalSince(start)
        result.statementCount = statements.count

        if statements.count > 1 {
            result.message = "\(statements.count) comandos executados"
        } else if result.isEmptyResultSet {
            result.message = "Comando executado"
        }

        return result
    }

    public func browseTable(database: String, schema: String?, table: String,
                            page: Int, pageSize: Int, filter: String,
                            sortColumn: String?, descending: Bool) async throws -> TablePage {
        let schemaName = schema ?? "public"
        let columns = try await listColumns(database: database, schema: schemaName, table: table)
        let target = dialect.qualify(schema: schemaName, table: table)
        let safePage = max(0, page)
        let safeSize = min(max(pageSize, 1), 500)
        let offset = safePage.multipliedReportingOverflow(by: safeSize)
        guard !offset.overflow else { throw HerdError.queryFailed("Página fora do intervalo.") }

        // Hex-encoded UTF-8 is decoded by PostgreSQL, so arbitrary search text never
        // becomes SQL syntax. Identifiers come only from the catalog and are quoted.
        let hex = filter.utf8.map { String(format: "%02x", $0) }.joined()
        let search = "(convert_from(decode('\(hex)', 'hex'), 'UTF8') COLLATE \"default\")"
        let terms = columns.map { "strpos(lower(\(dialect.quote($0.name))::text), lower(\(search))) > 0" }
        let predicate = filter.isEmpty || terms.isEmpty ? "" : " WHERE " + terms.joined(separator: " OR ")
        let countSQL = "SELECT count(*) FROM \(target)\(predicate);"
        let counted = try await run(countSQL, database: database)
        let totalText: String? = counted.rows.first?.first ?? nil
        let total = Int(totalText ?? "0") ?? 0

        let sortColumns: [String]
        if let sortColumn, columns.contains(where: { $0.name == sortColumn }) {
            sortColumns = [sortColumn]
        } else {
            let primaryKeys = columns.filter(\.isPrimaryKey).map(\.name)
            sortColumns = primaryKeys.isEmpty ? columns.prefix(1).map(\.name) : primaryKeys
        }
        let order = sortColumns.isEmpty ? "" : " ORDER BY " + sortColumns.map {
            "\(dialect.quote($0)) \(descending ? "DESC" : "ASC") NULLS LAST"
        }.joined(separator: ", ")
        let dataSQL = "SELECT * FROM \(target)\(predicate)\(order) LIMIT \(safeSize) OFFSET \(offset.partialValue);"
        let result = try await run(dataSQL, database: database)
        return TablePage(result: result, totalRows: total, page: safePage, columns: columns)
    }

    public func shutdown() async {
        for task in runners.values { task.cancel() }
        runners.removeAll()
        clients.removeAll()
    }

    // MARK: - Helpers

    /// Maximum stored rows per result set.
    private static let maximumRows = 20_000
    private static let logger = Logger(label: "herd-db.postgres")

    private func connectClient(_ database: String?) async throws -> PostgresClient {
        do {
            return try await client(for: database)
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
    }

    private static func queryError(_ error: Error, index: Int, total: Int) -> Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        let message = describe(error)
        guard total > 1 else { return HerdError.queryFailed(message) }
        return HerdError.queryFailed("Comando \(index + 1) de \(total): \(message)")
    }

    private static func backendID(on connection: PostgresConnection) async throws -> Int32? {
        let sequence = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT pg_backend_pid()"),
            logger: logger
        )
        for try await row in sequence {
            return try? row.decode(Int32.self)
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? PSQLError {
            if let message = error.serverInfo?[.message] {
                if let detail = error.serverInfo?[.detail], !detail.isEmpty {
                    return "\(message)\n\(detail)"
                }
                return message
            }
            return error.localizedDescription
        }
        if let error = error as? HerdError {
            return error.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Cell formatting

enum PostgresCellFormatter {
    static func string(from cell: PostgresCell) -> String? {
        guard cell.bytes != nil else { return nil }

        switch cell.dataType {
        case .bool:
            return (try? cell.decode(Bool.self)).map { $0 ? "true" : "false" }
        case .int2, .int4, .int8, .oid:
            return (try? cell.decode(Int.self)).map(String.init)
        case .float4, .float8:
            return (try? cell.decode(Double.self)).map { value in
                value == value.rounded() && abs(value) < 1e15
                    ? String(format: "%.0f", value)
                    : String(value)
            }
        case .numeric:
            guard let value = try? cell.decode(Decimal.self) else { return hex(cell) }
            return NSDecimalNumber(decimal: value).stringValue
        case .uuid:
            return (try? cell.decode(UUID.self))?.uuidString
        case .timestamp, .timestamptz:
            guard let date = try? cell.decode(Date.self) else { return hex(cell) }
            return Self.timestampFormatter.string(from: date)
        case .date:
            guard let date = try? cell.decode(Date.self) else { return hex(cell) }
            return Self.dateFormatter.string(from: date)
        case .bytea:
            return hex(cell)
        case .json, .jsonb, .text, .varchar, .bpchar, .name, .char, .xml:
            return try? cell.decode(String.self)
        default:
            if cell.format == .text {
                return try? cell.decode(String.self)
            }
            return hex(cell)
        }
    }

    private static func hex(_ cell: PostgresCell) -> String? {
        guard let bytes = cell.bytes else { return nil }
        guard bytes.readableBytes > 0 else { return "" }
        return "\\x" + bytes.readableBytesView.map { String(format: "%02x", $0) }.joined()
    }

    private static var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
