import CosmoMSSQL
import CosmoSQLCore
import Foundation

/// SQL Server driver backed by CosmoMSSQL (TDS 7.4 in pure Swift).
/// One pool per database, created lazily as the user browses the tree.
public actor SQLServerDriver: DatabaseDriver {
    public nonisolated let dialect: SQLDialect = .sqlServer

    private let config: ConnectionConfig
    private let password: String?
    private let recorder: QueryLogRecorder?
    private var pools: [String: MSSQLConnectionPool] = [:]

    /// Maximum stored rows per result set.
    private static let maximumRows = 20_000

    public init(config: ConnectionConfig, password: String?, recorder: QueryLogRecorder? = nil) {
        self.config = config
        self.password = password
        self.recorder = recorder
    }

    // MARK: - Connection

    private nonisolated func normalizedDatabase(_ database: String?) -> String {
        let trimmed = (database ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? config.maintenanceDatabase : trimmed
    }

    private func pool(for database: String?) -> MSSQLConnectionPool {
        let name = normalizedDatabase(database)
        if let existing = pools[name] { return existing }

        let configuration = MSSQLConnection.Configuration(
            host: config.host,
            port: config.port,
            database: name,
            username: config.username,
            password: password ?? "",
            tls: config.useTLS ? .require : .prefer,
            trustServerCertificate: config.trustServerCertificate,
            connectTimeout: 20
        )
        let pool = MSSQLConnectionPool(configuration: configuration, maxConnections: 1)
        pools[name] = pool
        return pool
    }

    /// Runs one batch and returns every result set. Closing the connection on
    /// cancellation makes the pending read fail instead of waiting for the server.
    private func fetch(_ sql: String, database: String?, binds: [SQLValue] = []) async throws -> [SQLResultSet] {
        let pool = pool(for: database)
        let statement = binds.isEmpty ? sql : Self.bindPlaceholders(sql, count: binds.count)
        return try await pool.withConnection { connection in
            try await withTaskCancellationHandler {
                try await connection.queryMulti(statement, binds)
            } onCancel: {
                Task { try? await connection.close() }
            }
        }
    }

    /// O `queryMulti` do CosmoMSSQL não converte `?` em `@p1`, então fazemos aqui.
    private static func bindPlaceholders(_ sql: String, count: Int) -> String {
        var result = ""
        var index = 1
        for character in sql {
            if character == "?" {
                result += "@p\(index)"
                index += 1
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - DatabaseDriver

    public func test() async throws -> ServerInfo {
        let database = config.maintenanceDatabase
        do {
            let sets = try await record(
                "SELECT @@VERSION",
                database: database,
                source: .system,
                rowCount: { _ in 1 }
            ) {
                try await fetch("SELECT @@VERSION", database: database)
            }
            guard let version = sets.first?.rows.first?.values.first?.asString() else {
                throw HerdError.connectionFailed("O servidor não retornou a versão.")
            }
            return ServerInfo(version: version)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
    }

    public func listDatabases() async throws -> [DatabaseInfo] {
        let sql = """
            SELECT name
            FROM sys.databases
            WHERE state_desc = 'ONLINE'
            ORDER BY name;
            """
        do {
            return try await stringRows(sql, database: config.maintenanceDatabase)
                .map(DatabaseInfo.init(name:))
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listSchemas(database: String) async throws -> [SchemaInfo] {
        let sql = """
            SELECT name
            FROM sys.schemas
            WHERE name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest')
            ORDER BY name;
            """
        do {
            return try await stringRows(sql, database: database)
                .map(SchemaInfo.init(name:))
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listTables(database: String, schema: String) async throws -> [TableInfo] {
        let sql = """
            SELECT o.name,
                   CASE WHEN o.type = 'V' THEN 'view' ELSE 'table' END
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE s.name = ? AND o.type IN ('U', 'V')
            ORDER BY o.name;
            """
        do {
            let rows = try await queryRows(sql, database: database, binds: [.string(schema)])
            return rows.compactMap { row in
                guard let name = row.values.first?.asString() else { return nil }
                let kind = row.values.count > 1 && row.values[1].asString() == "view" ? TableKind.view : .table
                return TableInfo(schema: schema, name: name, kind: kind)
            }
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listRoutines(database: String, schema: String) async throws -> [RoutineInfo] {
        let sql = """
            SELECT o.name,
                   CASE WHEN o.type IN ('P', 'PC') THEN 'procedure' ELSE 'function' END
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE s.name = ?
              AND o.type IN ('P', 'PC', 'FN', 'IF', 'TF', 'FS', 'FT', 'AF')
            ORDER BY o.name;
            """
        do {
            let rows = try await queryRows(sql, database: database, binds: [.string(schema)])
            return rows.compactMap { row in
                guard let name = row.values.first?.asString() else { return nil }
                let kind: RoutineKind = row.values.count > 1 && row.values[1].asString() == "procedure"
                    ? .procedure
                    : .function
                return RoutineInfo(schema: schema, name: name, kind: kind)
            }
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listColumns(database: String, schema: String, table: String) async throws -> [ColumnInfo] {
        let sql = """
            SELECT c.name,
                   \(Self.typeExpression) AS data_type,
                   CAST(c.is_nullable AS bit) AS is_nullable,
                   CAST(CASE WHEN EXISTS (
                       SELECT 1
                       FROM sys.indexes i
                       JOIN sys.index_columns ic
                         ON ic.object_id = i.object_id AND ic.index_id = i.index_id
                       WHERE i.object_id = c.object_id
                         AND i.is_primary_key = 1
                         AND ic.column_id = c.column_id
                   ) THEN 1 ELSE 0 END AS bit) AS is_pk,
                   ref.reference
            FROM sys.columns c
            JOIN sys.objects o ON o.object_id = c.object_id
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            JOIN sys.types t ON t.user_type_id = c.user_type_id
            OUTER APPLY (
                SELECT TOP 1 rs.name + '.' + rt.name + '.' + rc.name AS reference
                FROM sys.foreign_key_columns fkc
                JOIN sys.tables rt ON rt.object_id = fkc.referenced_object_id
                JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
                JOIN sys.columns rc
                  ON rc.object_id = fkc.referenced_object_id
                 AND rc.column_id = fkc.referenced_column_id
                WHERE fkc.parent_object_id = c.object_id
                  AND fkc.parent_column_id = c.column_id
            ) ref
            WHERE s.name = ? AND o.name = ? AND o.type IN ('U', 'V')
            ORDER BY c.column_id;
            """
        do {
            let rows = try await queryRows(
                sql,
                database: database,
                binds: [.string(schema), .string(table)]
            )
            return rows.compactMap { row in
                guard row.values.count >= 5,
                      let name = row.values.first?.asString() else { return nil }
                let dataType = SQLServerCellFormatter.string(row.values[1], typeID: row.columns[1].dataTypeID) ?? ""
                return ColumnInfo(
                    name: name,
                    dataType: dataType,
                    isNullable: SQLServerCellFormatter.bool(row.values[2]) ?? true,
                    isPrimaryKey: SQLServerCellFormatter.bool(row.values[3]) ?? false,
                    references: row.values[4].asString()
                )
            }
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func listCatalogColumns(database: String) async throws -> [CatalogColumn] {
        let sql = """
            SELECT s.name, o.name, c.name, \(Self.typeExpression) AS data_type
            FROM sys.columns c
            JOIN sys.objects o ON o.object_id = c.object_id
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            JOIN sys.types t ON t.user_type_id = c.user_type_id
            WHERE o.type IN ('U', 'V')
              AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
            ORDER BY s.name, o.name, c.column_id;
            """
        do {
            let rows = try await queryRows(sql, database: database)
            return rows.compactMap { row in
                guard row.values.count >= 4,
                      let schema = row.values[0].asString(),
                      let table = row.values[1].asString(),
                      let name = row.values[2].asString() else { return nil }
                let dataType = SQLServerCellFormatter.string(row.values[3], typeID: row.columns[3].dataTypeID) ?? ""
                return CatalogColumn(schema: schema, table: table, name: name, dataType: dataType)
            }
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func run(_ sql: String, database: String) async throws -> QueryResult {
        try await run(sql, database: database, source: .user)
    }

    public func run(_ sql: String, database: String, source: QueryLogSource) async throws -> QueryResult {
        let statements = SQLStatementSplitter.split(sql)
        guard !statements.isEmpty else {
            return QueryResult(message: "Nenhum comando para executar.", statementCount: 0)
        }

        let start = Date()
        var allSets: [ResultSet] = []

        for (index, statement) in statements.enumerated() {
            try Task.checkCancellation()

            let sets: [SQLResultSet]
            do {
                sets = try await record(
                    statement,
                    database: database,
                    source: source,
                    rowCount: { $0.reduce(0) { $0 + $1.rows.count } }
                ) {
                    try await fetch(statement, database: database)
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let error = error as? HerdError { throw error }
                throw Self.queryError(error, index: index, total: statements.count)
            }

            for set in sets where !set.columns.isEmpty {
                let columns = set.columns.map(\.name)
                let rows = set.rows.prefix(Self.maximumRows).map { row in
                    row.values.enumerated().map { offset, value in
                        SQLServerCellFormatter.string(value, typeID: set.columns[offset].dataTypeID)
                    }
                }
                let resultSet = ResultSet(columns: columns, rows: rows)
                // O decoder emite um set vazio com as colunas anteriores ao iniciar
                // o próximo conjunto do mesmo lote; não queremos duplicar a tabela.
                if resultSet.rows.isEmpty,
                   let last = allSets.last,
                   last.columns == resultSet.columns {
                    continue
                }
                allSets.append(resultSet)
            }
        }

        var result = QueryResult()
        if let last = allSets.last {
            result.columns = last.columns
            result.rows = last.rows
        }
        result.sets = allSets
        result.elapsed = Date().timeIntervalSince(start)
        result.statementCount = statements.count

        if statements.count > 1 {
            result.message = "\(statements.count) comandos executados"
        } else if allSets.isEmpty {
            result.message = "Comando executado"
        }

        return result
    }

    public func browseTable(database: String, schema: String?, table: String,
                            page: Int, pageSize: Int, filter: String,
                            sortColumn: String?, descending: Bool) async throws -> TablePage {
        let schemaName = schema ?? "dbo"
        let columns = try await listColumns(database: database, schema: schemaName, table: table)
        let target = dialect.qualify(schema: schemaName, table: table)
        let safePage = max(0, page)
        let safeSize = min(max(pageSize, 1), 500)
        let offset = safePage.multipliedReportingOverflow(by: safeSize)
        guard !offset.overflow else { throw HerdError.queryFailed("Página fora do intervalo.") }

        // Escaping the literal keeps arbitrary search text out of the SQL syntax.
        let escaped = filter.replacingOccurrences(of: "'", with: "''")
        let terms = columns.map {
            "CHARINDEX(N'\(escaped)', CONVERT(nvarchar(max), \(dialect.quote($0.name)))) > 0"
        }
        let predicate = filter.isEmpty || terms.isEmpty ? "" : " WHERE " + terms.joined(separator: " OR ")

        let countSQL = "SELECT COUNT_BIG(*) FROM \(target)\(predicate);"
        let counted = try await run(countSQL, database: database, source: .browse)
        let totalText: String? = counted.rows.first?.first ?? nil
        let total = Int(totalText ?? "0") ?? 0

        let sortColumns: [String]
        if let sortColumn, columns.contains(where: { $0.name == sortColumn }) {
            sortColumns = [sortColumn]
        } else {
            let primaryKeys = columns.filter(\.isPrimaryKey).map(\.name)
            sortColumns = primaryKeys.isEmpty ? columns.prefix(1).map(\.name) : primaryKeys
        }
        let order = sortColumns.isEmpty
            ? " ORDER BY (SELECT NULL)"
            : " ORDER BY " + sortColumns.map {
                "CASE WHEN \(dialect.quote($0)) IS NULL THEN 1 ELSE 0 END, \(dialect.quote($0)) \(descending ? "DESC" : "ASC")"
            }.joined(separator: ", ")
        let dataSQL = """
            SELECT * FROM \(target)\(predicate)\(order)
            OFFSET \(offset.partialValue) ROWS FETCH NEXT \(safeSize) ROWS ONLY;
            """
        let result = try await run(dataSQL, database: database, source: .browse)
        return TablePage(result: result, totalRows: total, page: safePage, columns: columns)
    }

    public func shutdown() async {
        let current = pools.values
        pools.removeAll()
        for pool in current {
            await pool.closeAll()
        }
    }

    // MARK: - Helpers

    private static let typeExpression = """
        CASE
            WHEN t.name IN ('varchar', 'char', 'varbinary', 'binary') THEN
                t.name + '(' +
                CASE WHEN c.max_length = -1 THEN 'max'
                     ELSE CONVERT(varchar(10), c.max_length) END + ')'
            WHEN t.name IN ('nvarchar', 'nchar') THEN
                t.name + '(' +
                CASE WHEN c.max_length = -1 THEN 'max'
                     ELSE CONVERT(varchar(10), c.max_length / 2) END + ')'
            WHEN t.name IN ('decimal', 'numeric') THEN
                t.name + '(' + CONVERT(varchar(10), c.precision) + ',' +
                CONVERT(varchar(10), c.scale) + ')'
            WHEN t.name IN ('datetime2', 'time', 'datetimeoffset') THEN
                t.name + '(' + CONVERT(varchar(10), c.scale) + ')'
            ELSE t.name
        END
        """

    private func queryRows(_ sql: String, database: String, binds: [SQLValue] = []) async throws -> [SQLRow] {
        let sets = try await fetch(sql, database: database, binds: binds)
        return sets.first?.rows ?? []
    }

    private func stringRows(_ sql: String, database: String) async throws -> [String] {
        let rows = try await queryRows(sql, database: database)
        return rows.compactMap { $0.values.first?.asString() }
    }

    private static func queryError(_ error: Error, index: Int, total: Int) -> Error {
        let message = describe(error)
        guard total > 1 else { return HerdError.queryFailed(message) }
        return HerdError.queryFailed("Comando \(index + 1) de \(total): \(message)")
    }

    /// Registra a consulta no console, mantendo duração e resultado mesmo em falha.
    private func record<Value>(
        _ sql: String,
        database: String?,
        source: QueryLogSource,
        rowCount: (Value) -> Int = { _ in 0 },
        _ body: () async throws -> Value
    ) async throws -> Value {
        guard let recorder else { return try await body() }

        let started = Date()
        let logDatabase = normalizedDatabase(database)
        do {
            let value = try await body()
            recorder.record(QueryLogEntry(
                connectionID: config.id,
                connectionName: config.name,
                database: logDatabase,
                sql: sql,
                source: source,
                duration: Date().timeIntervalSince(started),
                rowCount: rowCount(value)
            ))
            return value
        } catch {
            recorder.record(QueryLogEntry(
                connectionID: config.id,
                connectionName: config.name,
                database: logDatabase,
                sql: sql,
                source: source,
                duration: Date().timeIntervalSince(started),
                errorMessage: Self.describe(error)
            ))
            throw error
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? SQLError {
            switch error {
            case .serverError(_, let message, _):
                return message.isEmpty ? error.description : message
            case .connectionError(let message),
                 .tlsError(let message),
                 .authenticationFailed(let message),
                 .protocolError(let message):
                return message
            case .typeMismatch:
                return error.description
            case .unsupported(let feature):
                return "Recurso não suportado: \(feature)"
            case .columnNotFound(let name):
                return "Coluna não encontrada: \(name)"
            case .connectionClosed:
                return "A conexão foi encerrada pelo servidor. Se ele exige TLS, ligue a opção “Exigir TLS”."
            case .timeout:
                return "A operação excedeu o tempo limite."
            }
        }
        if let error = error as? HerdError {
            return error.localizedDescription
        }
        return error.localizedDescription
    }
}

// MARK: - Cell formatting

enum SQLServerCellFormatter {
    static func string(_ value: SQLValue, typeID: UInt32?) -> String? {
        switch value {
        case .null:
            return nil
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .int8(let value):
            return String(value)
        case .int16(let value):
            return String(value)
        case .int32(let value):
            return String(value)
        case .int64(let value):
            return String(value)
        case .float(let value):
            return String(value)
        case .double(let value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(format: "%.0f", value)
                : String(value)
        case .decimal(let value):
            return NSDecimalNumber(decimal: value).stringValue
        case .string(let value):
            return value
        case .bytes(let bytes):
            return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        case .uuid(let value):
            return value.uuidString
        case .date(let value):
            return dateFormatter(for: typeID).string(from: value)
        }
    }

    static func bool(_ value: SQLValue) -> Bool? {
        switch value {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .int8(let value): return value != 0
        case .int16(let value): return value != 0
        case .int32(let value): return value != 0
        case .int64(let value): return value != 0
        default: return nil
        }
    }

    private static func dateFormatter(for typeID: UInt32?) -> DateFormatter {
        switch typeID {
        case 0x28: // date
            return dateOnlyFormatter
        case 0x29: // time
            return timeOnlyFormatter
        default:
            return timestampFormatter
        }
    }

    private static var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static var dateOnlyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static var timeOnlyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}
