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
        pgConfig.options.maximumConnections = 4
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
                SELECT table_name, table_type
                FROM information_schema.tables
                WHERE table_schema = \(schema)
                  AND table_type IN ('BASE TABLE', 'VIEW')
                ORDER BY table_name;
                """)
            var result: [TableInfo] = []
            for try await row in rows {
                let (name, type) = try row.decode((String, String).self)
                result.append(
                    TableInfo(
                        schema: schema,
                        name: name,
                        kind: type == "VIEW" ? .view : .table
                    )
                )
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

    public func run(_ sql: String, database: String) async throws -> QueryResult {
        let client = try await connectClient(database)
        let start = Date()

        do {
            let sequence = try await client.query(PostgresQuery(unsafeSQL: sql))
            let columns = sequence.columns.map(\.name)
            var rows: [[String?]] = []

            for try await row in sequence {
                rows.append(row.map { PostgresCellFormatter.string(from: $0) })
                if rows.count >= 20_000 { break }
            }

            return QueryResult(
                columns: columns,
                rows: rows,
                elapsed: Date().timeIntervalSince(start)
            )
        } catch {
            throw HerdError.queryFailed(Self.describe(error))
        }
    }

    public func shutdown() async {
        for task in runners.values { task.cancel() }
        runners.removeAll()
        clients.removeAll()
    }

    // MARK: - Helpers

    private func connectClient(_ database: String?) async throws -> PostgresClient {
        do {
            return try await client(for: database)
        } catch {
            throw HerdError.connectionFailed(Self.describe(error))
        }
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
