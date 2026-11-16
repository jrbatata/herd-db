import Foundation
import Observation

/// Origem de uma consulta registrada no console. O histórico guarda apenas o que
/// o usuário executa; o console mostra tudo o que chega ao servidor.
public enum QueryLogSource: String, CaseIterable, Sendable {
    /// Executada pelo editor SQL.
    case user
    /// Paginação do grid de resultados.
    case browse
    /// Consulta interna ao catálogo (árvore, autocomplete, paleta).
    case catalog
    /// Gravação das alterações pendentes do grid.
    case commit
    /// `pg_cancel_backend` disparado ao cancelar uma execução.
    case cancel
    /// Demais consultas internas do driver.
    case system

    public var displayName: String {
        switch self {
        case .user: "Script"
        case .browse: "Paginação"
        case .catalog: "Catálogo"
        case .commit: "Commit do grid"
        case .cancel: "Cancelamento"
        case .system: "Interno"
        }
    }
}

/// Uma consulta enviada ao servidor, com o resultado resumido.
public struct QueryLogEntry: Identifiable, Hashable, Sendable {
    /// Consultas maiores são guardadas apenas até este tamanho, com uma nota.
    public static let maximumSQLCharacters = 4_000

    public var id: UUID
    public var date: Date
    public var connectionID: UUID
    public var connectionName: String
    public var database: String
    /// SQL truncado quando maior que `maximumSQLCharacters`.
    public var sql: String
    public var source: QueryLogSource
    public var duration: TimeInterval
    public var rowCount: Int
    public var errorMessage: String?
    /// Tamanho do SQL original antes do truncamento.
    public var originalLength: Int
    public var isTruncated: Bool

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        connectionID: UUID,
        connectionName: String,
        database: String,
        sql: String,
        source: QueryLogSource,
        duration: TimeInterval = 0,
        rowCount: Int = 0,
        errorMessage: String? = nil,
        maximumSQLCharacters: Int = QueryLogEntry.maximumSQLCharacters
    ) {
        self.id = id
        self.date = date
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.database = database
        self.source = source
        self.duration = duration
        self.rowCount = rowCount
        self.errorMessage = errorMessage
        self.originalLength = sql.count

        let limit = max(1, maximumSQLCharacters)
        if sql.count > limit {
            self.sql = String(sql.prefix(limit))
            self.isTruncated = true
        } else {
            self.sql = sql
            self.isTruncated = false
        }
    }

    public var isFailure: Bool { errorMessage != nil }

    /// Primeira linha do comando, para resumos compactos.
    public var summary: String {
        let line = sql
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? sql.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    public var truncatedNote: String? {
        guard isTruncated else { return nil }
        return "SQL truncado: exibindo \(sql.count) de \(originalLength) caracteres."
    }
}

/// Ponte thread-safe entre os drivers (atores) e a interface.
public final class QueryLogRecorder: @unchecked Sendable {
    public typealias Sink = @Sendable (QueryLogEntry) -> Void

    private let lock = NSLock()
    private var sink: Sink?

    public init(sink: Sink? = nil) {
        self.sink = sink
    }

    public func attach(_ sink: @escaping Sink) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    public func record(_ entry: QueryLogEntry) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(entry)
    }
}

/// Console de log em memória. Mantém as entradas mais recentes primeiro.
@MainActor
@Observable
public final class QueryLogStore {
    public private(set) var entries: [QueryLogEntry] = []
    public let limit: Int
    public nonisolated let recorder: QueryLogRecorder

    /// Número máximo de entradas guardadas.
    public static let defaultLimit = 1_000

    public init(limit: Int = defaultLimit) {
        let limit = max(1, limit)
        self.limit = limit

        let recorder = QueryLogRecorder()
        self.recorder = recorder
        recorder.attach { [weak self] entry in
            Task { @MainActor in
                self?.append(entry)
            }
        }
    }

    /// Insere mantendo a ordem por data, mesmo que as tarefas cheguem fora de ordem.
    public func append(_ entry: QueryLogEntry) {
        let index = entries.firstIndex { $0.date <= entry.date } ?? entries.endIndex
        entries.insert(entry, at: index)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    public func clear() {
        entries.removeAll()
    }
}
