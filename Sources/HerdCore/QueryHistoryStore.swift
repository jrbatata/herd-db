import Foundation
import Observation

public struct QueryHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var database: String
    public var sql: String
    public var date: Date
    public var duration: TimeInterval
    public var rowCount: Int
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        connectionID: UUID,
        database: String,
        sql: String,
        date: Date = Date(),
        duration: TimeInterval,
        rowCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.sql = sql
        self.date = date
        self.duration = duration
        self.rowCount = rowCount
        self.errorMessage = errorMessage
    }

    public var isFailure: Bool { errorMessage != nil }

    /// First line of the command, for compact menus.
    public var summary: String {
        sql
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Per-connection history of executed commands, persisted next to the connections file.
@MainActor
@Observable
public final class QueryHistoryStore {
    public private(set) var entries: [QueryHistoryEntry] = []
    public private(set) var lastError: String?

    private let directory: URL
    private let fileURL: URL
    private let limit: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Maximum number of stored entries. Older commands are dropped.
    public static let defaultLimit = 200

    public init(directory: URL? = nil, limit: Int = defaultLimit) {
        let directory = directory ?? ConnectionStore.defaultDirectory
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("history.json")
        self.limit = max(1, limit)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    // MARK: - Reading

    /// Newest first. When `database` is nil, every database of the connection is included.
    public func entries(for connectionID: UUID, database: String? = nil) -> [QueryHistoryEntry] {
        entries.filter { entry in
            entry.connectionID == connectionID && (database == nil || entry.database == database)
        }
    }

    public func latest(for connectionID: UUID, database: String? = nil, limit: Int = 20) -> [QueryHistoryEntry] {
        Array(entries(for: connectionID, database: database).prefix(limit))
    }

    // MARK: - Writing

    @discardableResult
    public func record(
        connectionID: UUID,
        database: String,
        sql: String,
        duration: TimeInterval,
        rowCount: Int = 0,
        errorMessage: String? = nil
    ) -> QueryHistoryEntry {
        // Running the same command again should refresh its entry instead of duplicating it.
        entries.removeAll { entry in
            entry.connectionID == connectionID && entry.database == database && entry.sql == sql
        }

        let entry = QueryHistoryEntry(
            connectionID: connectionID,
            database: database,
            sql: sql,
            duration: duration,
            rowCount: rowCount,
            errorMessage: errorMessage
        )
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        persist()
        return entry
    }

    public func remove(_ entry: QueryHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    public func clear() {
        entries.removeAll()
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = Array(try decoder.decode([QueryHistoryEntry].self, from: data).prefix(limit))
            lastError = nil
        } catch {
            entries = []
            lastError = "Não foi possível ler \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastError = nil
        } catch {
            lastError = "Não foi possível salvar o histórico: \(error.localizedDescription)"
        }
    }
}
