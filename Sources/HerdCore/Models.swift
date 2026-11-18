import Foundation

// MARK: - Connections

/// How strongly the app guards operations that may change data.
public enum SafeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case silent
    case alert
    case alertReadOnly
    case secure
    case secureReadOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .silent: "Sem proteção"
        case .alert: "Confirmar todo comando"
        case .alertReadOnly: "Confirmar somente comandos de escrita"
        case .secure: "Pedir senha em todo comando"
        case .secureReadOnly: "Pedir senha somente em comandos de escrita"
        }
    }

    /// Rótulo curto para a cápsula da aba e o título da janela.
    public var compactName: String {
        switch self {
        case .silent: "Sem proteção"
        case .alert: "Confirma tudo"
        case .alertReadOnly: "Confirma escrita"
        case .secure: "Senha sempre"
        case .secureReadOnly: "Senha em escrita"
        }
    }

    public var summary: String {
        switch self {
        case .silent:
            "Executa os comandos direto, sem confirmar nada."
        case .alert:
            "Pede confirmação antes de executar qualquer comando."
        case .alertReadOnly:
            "Pede confirmação somente para comandos que alteram dados; SELECT, EXPLAIN e SHOW passam direto."
        case .secure:
            "Pede a senha da conexão antes de executar qualquer comando."
        case .secureReadOnly:
            "Pede a senha somente para comandos que alteram dados; SELECT, EXPLAIN e SHOW passam direto."
        }
    }

    /// Any level other than `silent` guards the connection.
    public var isRestricted: Bool { self != .silent }

    public var requiresPassword: Bool {
        self == .secure || self == .secureReadOnly
    }

    /// Read-only statements bypass the guard in the "2" variants.
    public var skipsReadOnly: Bool {
        self == .alertReadOnly || self == .secureReadOnly
    }
}

public enum DatabaseEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres
    case sqlServer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .sqlServer: "SQL Server"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .sqlServer: 1433
        }
    }

    public var symbolName: String {
        switch self {
        case .postgres: "database"
        case .sqlServer: "server"
        }
    }
}

public struct ConnectionConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    public var useTLS: Bool
    /// Accepts self-signed certificates (SQL Server's `TrustServerCertificate`).
    public var trustServerCertificate: Bool
    /// Confirmation level applied to every operation that can change data.
    public var safeMode: SafeMode
    /// Marks a connection as production so the UI can highlight it.
    public var isProduction: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, engine, host, port, username, database, useTLS, trustServerCertificate, safeMode, isProduction
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        engine: DatabaseEngine = .postgres,
        host: String = "localhost",
        port: Int = DatabaseEngine.postgres.defaultPort,
        username: String = NSUserName(),
        database: String = "",
        useTLS: Bool = false,
        trustServerCertificate: Bool = false,
        safeMode: SafeMode = .silent,
        isProduction: Bool = false
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.useTLS = useTLS
        self.trustServerCertificate = trustServerCertificate
        self.safeMode = safeMode
        self.isProduction = isProduction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        engine = try container.decode(DatabaseEngine.self, forKey: .engine)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        database = try container.decode(String.self, forKey: .database)
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        trustServerCertificate = try container.decodeIfPresent(Bool.self, forKey: .trustServerCertificate) ?? false
        // Configurações antigas não têm os campos; os padrões são sem proteção e não-produção.
        safeMode = try container.decodeIfPresent(SafeMode.self, forKey: .safeMode) ?? .silent
        isProduction = try container.decodeIfPresent(Bool.self, forKey: .isProduction) ?? false
    }

    public var endpoint: String { "\(host):\(port)" }

    /// A database we can always connect to in order to list the server's databases.
    public var maintenanceDatabase: String {
        let trimmed = database.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch engine {
        case .postgres: return "postgres"
        case .sqlServer: return "master"
        }
    }

    public var isRunnable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65535).contains(port)
    }
}

// MARK: - Schema objects

public struct DatabaseInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

public struct SchemaInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

public enum TableKind: String, Codable, Hashable, Sendable {
    case table
    case view

    public var displayName: String {
        switch self {
        case .table: "Tabela"
        case .view: "View"
        }
    }
}

public struct TableInfo: Identifiable, Hashable, Sendable {
    public var schema: String
    public var name: String
    public var kind: TableKind

    public var id: String { "\(schema).\(name)" }

    public init(schema: String, name: String, kind: TableKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }
}

public struct ColumnInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    /// `schema.table.column` of the referenced column, when this column is part of a foreign key.
    public var references: String?

    public var id: String { name }

    public init(
        name: String,
        dataType: String,
        isNullable: Bool,
        isPrimaryKey: Bool,
        references: String? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.references = references
    }
}

// MARK: - Column filters

/// Filtro aplicado a uma coluna do grid, sem exigir SQL.
public struct ColumnFilter: Identifiable, Hashable, Sendable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case contains
        case notContains
        case equals
        case notEquals
        case startsWith
        case endsWith
        case isEmpty
        case isNotEmpty

        public var displayName: String {
            switch self {
            case .contains: "Contém"
            case .notContains: "Não contém"
            case .equals: "Igual a"
            case .notEquals: "Diferente de"
            case .startsWith: "Começa com"
            case .endsWith: "Termina com"
            case .isEmpty: "É vazio"
            case .isNotEmpty: "Não é vazio"
            }
        }

        public var needsValue: Bool {
            switch self {
            case .isEmpty, .isNotEmpty: false
            default: true
            }
        }
    }

    public var column: String
    public var operation: Operation
    public var value: String

    public var id: String { column }

    public init(column: String, operation: Operation, value: String = "") {
        self.column = column
        self.operation = operation
        self.value = value
    }

    /// Texto curto exibido no cabeçalho e na barra de filtros.
    public var summary: String {
        switch operation {
        case .isEmpty, .isNotEmpty:
            return "\(column) \(operation.displayName.lowercased())"
        default:
            return "\(column) \(operation.displayName.lowercased()) \(value)"
        }
    }
}

// MARK: - Results

public struct TablePage: Sendable, Equatable {
    public let result: QueryResult
    public let totalRows: Int
    public let page: Int
    public let columns: [ColumnInfo]

    public init(result: QueryResult, totalRows: Int, page: Int, columns: [ColumnInfo] = []) {
        self.result = result
        self.totalRows = totalRows
        self.page = page
        self.columns = columns
    }
}

/// One tabular result produced by a statement.
public struct ResultSet: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String?]]

    public init(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
    }
}

public struct QueryResult: Sendable, Equatable {
    /// Every tabular result of the script, in order. `columns` and `rows` mirror the last one.
    public var sets: [ResultSet] = []
    public var columns: [String]
    public var rows: [[String?]]
    public var elapsed: TimeInterval
    public var message: String?
    /// How many commands the script contained.
    public var statementCount: Int

    public init(
        columns: [String] = [],
        rows: [[String?]] = [],
        elapsed: TimeInterval = 0,
        message: String? = nil,
        statementCount: Int = 1
    ) {
        self.columns = columns
        self.rows = rows
        self.elapsed = elapsed
        self.message = message
        self.statementCount = statementCount
    }

    public var isEmptyResultSet: Bool { columns.isEmpty }
}

public struct ServerInfo: Sendable, Equatable {
    public var version: String

    public init(version: String) {
        self.version = version
    }

    /// "PostgreSQL 18.1" out of the full version banner; "SQL Server 2022" for T-SQL.
    public var shortVersion: String {
        if version.contains("Azure SQL Edge") { return "Azure SQL Edge" }
        if version.contains("SQL Azure") { return "Azure SQL" }
        if let range = version.range(of: "SQL Server ") {
            let rest = version[range.upperBound...]
            let token = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if !token.isEmpty {
                return "SQL Server \(token)"
            }
        }
        let parts = version.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return version }
        return "\(parts[0]) \(parts[1])"
    }
}

// MARK: - Errors

public enum HerdError: LocalizedError, Sendable {
    case unsupportedEngine(DatabaseEngine)
    case connectionFailed(String)
    case queryFailed(String)
    case keychain(OSStatus)
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedEngine(let engine):
            "\(engine.displayName) ainda não é suportado."
        case .connectionFailed(let message):
            message
        case .queryFailed(let message):
            message
        case .keychain(let status):
            "Falha no Chaveiro (código \(status))."
        case .file(let message):
            message
        }
    }
}
