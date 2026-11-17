import CosmoMSSQL
import CosmoSQLCore
import Foundation

public struct SQLServerBackupOptions: Sendable {
    public var compression: Bool
    public var checksum: Bool
    public var copyOnly: Bool

    public init(compression: Bool = true, checksum: Bool = true, copyOnly: Bool = false) {
        self.compression = compression
        self.checksum = checksum
        self.copyOnly = copyOnly
    }
}

public struct SQLServerBackupFile: Identifiable, Hashable, Sendable {
    public var logicalName: String
    public var physicalName: String
    /// "D" for data, "L" for log.
    public var type: String
    public var sizeBytes: Int64?

    public var id: String { logicalName }
    public var isLog: Bool { type.uppercased() == "L" }

    public init(logicalName: String, physicalName: String, type: String, sizeBytes: Int64? = nil) {
        self.logicalName = logicalName
        self.physicalName = physicalName
        self.type = type
        self.sizeBytes = sizeBytes
    }
}

public struct SQLServerRestoreMove: Hashable, Sendable {
    public var logicalName: String
    public var physicalName: String

    public init(logicalName: String, physicalName: String) {
        self.logicalName = logicalName
        self.physicalName = physicalName
    }
}

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
        let pool = MSSQLConnectionPool(configuration: connectionConfiguration(database: name), maxConnections: 1)
        pools[name] = pool
        return pool
    }

    private func connectionConfiguration(database: String) -> MSSQLConnection.Configuration {
        MSSQLConnection.Configuration(
            host: config.host,
            port: config.port,
            database: database,
            username: config.username,
            password: password ?? "",
            tls: config.useTLS ? .require : .prefer,
            trustServerCertificate: config.trustServerCertificate,
            connectTimeout: 20
        )
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

    // MARK: - Backup and restore

    /// Caminho sugerido para o `.bak`, usando o diretório padrão do servidor.
    public func suggestedBackupPath(for database: String) async throws -> String {
        let sql = """
            SELECT COALESCE(
                CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultBackupPath')),
                CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath')),
                N''
            ) AS path;
            """
        let rows = try await queryRows(sql, database: config.maintenanceDatabase)
        var base = rows.first?.values.first?.asString() ?? ""
        guard !base.isEmpty else { return "" }

        let separator = base.contains("\\") ? "\\" : "/"
        if !base.hasSuffix("/") && !base.hasSuffix("\\") {
            base += separator
        }
        let safeName = database.map { character in
            "/\\:*?\"<>|".contains(character) ? "_" : String(character)
        }.joined()
        return "\(base)\(safeName)_\(Self.backupTimestamp.string(from: Date())).bak"
    }

    public func backupDatabase(
        _ database: String,
        to path: String,
        options: SQLServerBackupOptions = SQLServerBackupOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HerdError.queryFailed("Informe o caminho do arquivo de backup no servidor.")
        }

        var clauses = ["INIT", "STATS = 10"]
        if options.compression { clauses.append("COMPRESSION") }
        if options.checksum { clauses.append("CHECKSUM") }
        if options.copyOnly { clauses.append("COPY_ONLY") }

        let sql = """
            BACKUP DATABASE \(dialect.quote(database))
            TO DISK = \(Self.literal(trimmed))
            WITH \(clauses.joined(separator: ", "));
            """
        try await runServerOperation(sql, progress: progress)
    }

    /// Lê os arquivos lógicos e físicos de um `.bak` antes do restore.
    ///
    /// O `RESTORE FILELISTONLY` devolve colunas `nchar`, que o driver TDS ainda
    /// não decodifica. Capturamos o resultado numa tabela temporária e
    /// selecionamos apenas as colunas necessárias, já em `nvarchar`.
    public func backupFileList(_ path: String) async throws -> [SQLServerBackupFile] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HerdError.queryFailed("Informe o caminho do arquivo de backup no servidor.")
        }

        let restore = "RESTORE FILELISTONLY FROM DISK = \(Self.literal(trimmed))"
        let sql = """
            CREATE TABLE #herd_filelist (
                LogicalName nvarchar(128) NULL,
                PhysicalName nvarchar(260) NULL,
                [Type] nvarchar(1) NULL,
                FileGroupName nvarchar(128) NULL,
                Size numeric(20,0) NULL,
                MaxSize numeric(20,0) NULL,
                FileId numeric(20,0) NULL,
                CreateLSN numeric(25,0) NULL,
                DropLSN numeric(25,0) NULL,
                UniqueId uniqueidentifier NULL,
                ReadOnlyLSN numeric(25,0) NULL,
                ReadWriteLSN numeric(25,0) NULL,
                BackupSizeInBytes bigint NULL,
                SourceBlockSize int NULL,
                FileGroupId int NULL,
                LogGroupGUID uniqueidentifier NULL,
                DifferentialBaseLSN numeric(25,0) NULL,
                DifferentialBaseGUID uniqueidentifier NULL,
                IsReadOnly bit NULL,
                IsPresent bit NULL,
                TDEThumbprint varbinary(32) NULL,
                SnapshotUrl nvarchar(4000) NULL
            );
            INSERT INTO #herd_filelist EXEC(\(Self.literal(restore)));
            SELECT LogicalName, PhysicalName, [Type], Size FROM #herd_filelist;
            DROP TABLE #herd_filelist;
            """
        let sets = try await fetch(sql, database: config.maintenanceDatabase)
        guard let set = sets.first else { return [] }

        let names = set.columns.map { $0.name.lowercased() }
        func index(_ name: String) -> Int? { names.firstIndex(of: name) }
        guard let logicalIndex = index("logicalname"),
              let physicalIndex = index("physicalname"),
              let typeIndex = index("type") else {
            throw HerdError.queryFailed("O arquivo não parece ser um backup válido do SQL Server.")
        }
        let sizeIndex = index("size")

        return set.rows.compactMap { row in
            guard row.values.indices.contains(logicalIndex),
                  row.values.indices.contains(physicalIndex),
                  row.values.indices.contains(typeIndex),
                  let logical = row.values[logicalIndex].asString(),
                  let physical = row.values[physicalIndex].asString(),
                  let type = row.values[typeIndex].asString() else { return nil }
            let size = sizeIndex.flatMap { idx in
                row.values.indices.contains(idx) ? SQLServerCellFormatter.int(row.values[idx]) : nil
            }
            return SQLServerBackupFile(
                logicalName: logical,
                physicalName: physical,
                type: type,
                sizeBytes: size
            )
        }
    }

    public func databaseExists(_ name: String) async throws -> Bool {
        let rows = try await queryRows(
            "SELECT database_id FROM sys.databases WHERE name = ?;",
            database: config.maintenanceDatabase,
            binds: [.string(name)]
        )
        return !rows.isEmpty
    }

    public func restoreDatabase(
        _ database: String,
        from path: String,
        moves: [SQLServerRestoreMove],
        replace: Bool = false,
        closeExisting: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw HerdError.queryFailed("Informe o caminho do arquivo de backup no servidor.")
        }
        let target = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw HerdError.queryFailed("Informe o nome do banco de destino.")
        }

        var clauses: [String] = []
        if replace { clauses.append("REPLACE") }
        clauses.append("STATS = 10")
        clauses.append(contentsOf: moves.map {
            "MOVE \(Self.literal($0.logicalName)) TO \(Self.literal($0.physicalName))"
        })
        let sql = """
            RESTORE DATABASE \(dialect.quote(target))
            FROM DISK = \(Self.literal(trimmedPath))
            WITH \(clauses.joined(separator: ", "));
            """

        let exists = try await databaseExists(target)
        let singleUser = exists && closeExisting
        if exists, let existing = pools.removeValue(forKey: target) {
            await existing.closeAll()
        }
        if singleUser {
            _ = try? await queryRows(
                "ALTER DATABASE \(dialect.quote(target)) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;",
                database: config.maintenanceDatabase
            )
        }

        do {
            try await runServerOperation(sql, progress: progress)
        } catch {
            if singleUser {
                _ = try? await queryRows(
                    "ALTER DATABASE \(dialect.quote(target)) SET MULTI_USER;",
                    database: config.maintenanceDatabase
                )
            }
            throw error
        }

        if singleUser {
            _ = try? await queryRows(
                "ALTER DATABASE \(dialect.quote(target)) SET MULTI_USER;",
                database: config.maintenanceDatabase
            )
        }
    }

    /// Executa BACKUP/RESTORE numa conexão dedicada e acompanha o progresso
    /// consultando `sys.dm_exec_requests` por outra conexão.
    private func runServerOperation(
        _ sql: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let configuration = connectionConfiguration(database: config.maintenanceDatabase)
        let connection: MSSQLConnection
        do {
            connection = try await MSSQLConnection.connect(configuration: configuration)
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
        defer { Task { try? await connection.close() } }

        var monitor: Task<Void, Never>?
        if let progress, let spid = try? await Self.sessionID(on: connection) {
            monitor = Task {
                await Self.monitorProgress(
                    spid: spid,
                    configuration: configuration,
                    progress: progress
                )
            }
        }
        defer { monitor?.cancel() }

        do {
            _ = try await withTaskCancellationHandler {
                try await connection.queryMulti(sql)
            } onCancel: {
                Task { try? await connection.close() }
            }
            progress?(100)
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    private static func sessionID(on connection: MSSQLConnection) async throws -> Int? {
        let rows = try await connection.query("SELECT @@SPID AS spid;")
        return intValue(rows.first?.values.first)
    }

    private static func monitorProgress(
        spid: Int,
        configuration: MSSQLConnection.Configuration,
        progress: @Sendable (Double) -> Void
    ) async {
        guard let monitor = try? await MSSQLConnection.connect(configuration: configuration) else { return }
        defer { Task { try? await monitor.close() } }

        while !Task.isCancelled {
            if let rows = try? await monitor.query(
                "SELECT percent_complete FROM sys.dm_exec_requests WHERE session_id = \(spid);"
            ), let value = doubleValue(rows.first?.values.first) {
                progress(min(max(value, 0), 100))
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
    }

    private static func literal(_ value: String) -> String {
        "N'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func intValue(_ value: SQLValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let v): return v
        case .int8(let v): return Int(v)
        case .int16(let v): return Int(v)
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(exactly: v)
        case .decimal(let v): return NSDecimalNumber(decimal: v).intValue
        default: return nil
        }
    }

    private static func doubleValue(_ value: SQLValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let v): return v
        case .float(let v): return Double(v)
        case .int(let v): return Double(v)
        case .int8(let v): return Double(v)
        case .int16(let v): return Double(v)
        case .int32(let v): return Double(v)
        case .int64(let v): return Double(v)
        case .decimal(let v): return NSDecimalNumber(decimal: v).doubleValue
        default: return nil
        }
    }

    private static var backupTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
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
            case .serverError(let code, let message, _):
                if code == 18456 {
                    return """
                        Login recusado pelo SQL Server. Confira usuário e senha e se o servidor aceita “SQL Server Authentication”. \
                        Contas do Windows (DOMÍNIO\\usuário) usam NTLM, que o herd ainda não suporta.
                        """
                }
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

    static func int(_ value: SQLValue) -> Int64? {
        switch value {
        case .int(let v): return Int64(v)
        case .int8(let v): return Int64(v)
        case .int16(let v): return Int64(v)
        case .int32(let v): return Int64(v)
        case .int64(let v): return v
        case .decimal(let v): return NSDecimalNumber(decimal: v).int64Value
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
