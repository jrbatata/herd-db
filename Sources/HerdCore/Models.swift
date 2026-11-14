import Foundation

// MARK: - Connections

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

    /// Engines that already have a working driver. SQL Server arrives in phase 6.
    public var isAvailable: Bool {
        self == .postgres
    }

    public var symbolName: String {
        switch self {
        case .postgres: "cylinder.split.1x2"
        case .sqlServer: "server.rack"
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

    public init(
        id: UUID = UUID(),
        name: String = "",
        engine: DatabaseEngine = .postgres,
        host: String = "localhost",
        port: Int = DatabaseEngine.postgres.defaultPort,
        username: String = NSUserName(),
        database: String = "",
        useTLS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.useTLS = useTLS
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
        engine.isAvailable
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

// MARK: - Results

public struct QueryResult: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String?]]
    public var elapsed: TimeInterval
    public var message: String?

    public init(columns: [String] = [], rows: [[String?]] = [], elapsed: TimeInterval = 0, message: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.elapsed = elapsed
        self.message = message
    }

    public var isEmptyResultSet: Bool { columns.isEmpty }
}

public struct ServerInfo: Sendable, Equatable {
    public var version: String

    public init(version: String) {
        self.version = version
    }

    /// "PostgreSQL 18.1" out of the full version banner.
    public var shortVersion: String {
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
