import Foundation
import HerdCore
import Observation

enum QueryRunState {
    case idle
    case running
    case success(QueryResult)
    case failure(String)
    case cancelled
}

enum QueryExecutionScope {
    /// Selection when there is one, otherwise the whole editor.
    case automatic
    /// Selection when there is one, otherwise the command under the cursor.
    case selection
    /// The whole editor, ignoring any selection.
    case all
}

struct QueryContext: Sendable {
    var connectionID: UUID
    var connectionName: String
    var database: String
    var schema: String?
}

@MainActor
@Observable
final class QueryTab: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let connectionName: String
    let schema: String?
    var sourceTable: String?
    var browseSQL: String?
    var tablePage: TablePage?
    var tableFilter = ""
    var tableSortColumn: String?
    var tableSortDescending = false
    /// Filtros por coluna aplicados no servidor ao navegar pela tabela.
    var columnFilters: [ColumnFilter] = []
    /// Quantidade de linhas carregadas por página ao navegar pela tabela.
    var tablePageSize = 250
    /// Alterna o rodapé entre dados e mensagens; comandos de escrita abrem mensagens sozinhos.
    var showMessages = false
    /// Mensagem detalhada da última operação, preservada entre recargas da grade.
    var runMessage: String?

    /// The database can be changed in the tab's toolbar.
    var database: String
    var title: String
    var sql: String
    var fileURL: URL?
    var fileEncoding: String.Encoding = .utf8
    var savedSQL: String
    var state: QueryRunState = .idle
    /// UTF-16 selection reported by the editor.
    var selection: NSRange = NSRange(location: 0, length: 0)

    @ObservationIgnored private var task: Task<Void, Never>?

    init(title: String, sql: String, context: QueryContext) {
        self.title = title
        self.sql = sql
        self.savedSQL = sql
        self.connectionID = context.connectionID
        self.connectionName = context.connectionName
        self.database = context.database
        self.schema = context.schema
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var hasText: Bool {
        !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasUnsavedChanges: Bool { sql != savedSQL }

    // MARK: - Running

    func run(app: AppModel, scope: QueryExecutionScope = .automatic) {
        guard !isRunning else { return }

        if let browseSQL, sql == browseSQL, !hasSelection, scope == .automatic {
            browseTable(app: app, page: 0)
            return
        }
        tablePage = nil

        let sql = textToRun(scope: scope)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runMessage = nil

        guard let config = app.connections.connection(id: connectionID) else {
            state = .failure("Esta conexão não existe mais.")
            return
        }

        guard SafeModeGate.authorize(sql: sql, config: config, connections: app.connections,
                                     action: "executar o script") else { return }

        let driver = app.drivers.driver(for: config)
        let database = self.database.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDatabase = database.isEmpty ? config.maintenanceDatabase : database
        let started = Date()
        state = .running

        task = Task { [weak self] in
            do {
                let result = try await driver.run(sql, database: targetDatabase)
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.state = .cancelled
                    return
                }
                self.state = .success(result)
                // Scripts que só alteram dados não têm grade: abra as mensagens.
                self.showMessages = result.isEmptyResultSet
                if result.isEmptyResultSet {
                    self.runMessage = Self.commandSummary(
                        statements: SQLStatementSplitter.split(sql),
                        result: result
                    )
                }
                app.history.record(
                    connectionID: self.connectionID,
                    database: targetDatabase,
                    sql: sql,
                    duration: result.elapsed,
                    rowCount: result.rows.count
                )
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.state = .cancelled
                    return
                }
                self.state = .failure(error.localizedDescription)
                app.history.record(
                    connectionID: self.connectionID,
                    database: targetDatabase,
                    sql: sql,
                    duration: Date().timeIntervalSince(started),
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    func browseTable(app: AppModel, page: Int) {
        guard !isRunning, let table = sourceTable,
              let config = app.connections.connection(id: connectionID) else { return }
        let driver = app.drivers.driver(for: config)
        let database = self.database
        let filter = tableFilter
        let sortColumn = tableSortColumn
        let descending = tableSortDescending
        let schema = self.schema
        let columnFilters = self.columnFilters
        let pageSize = self.tablePageSize
        state = .running
        showMessages = false
        task = Task { [weak self] in
            do {
                let loaded = try await driver.browseTable(database: database, schema: schema,
                                                          table: table, page: page, pageSize: pageSize,
                                                          filter: filter, sortColumn: sortColumn,
                                                          descending: descending,
                                                          columnFilters: columnFilters)
                guard let self, !Task.isCancelled else { return }
                self.tablePage = loaded
                self.state = .success(loaded.result)
            } catch is CancellationError {
                self?.state = .cancelled
            } catch {
                self?.state = .failure(error.localizedDescription)
            }
        }
    }

    /// Resume o que foi gravado pelo grid e deixa o rodapé nas mensagens.
    func recordCommit(statements: [String], result: QueryResult) {
        runMessage = Self.commandSummary(statements: statements, result: result)
        showMessages = true
    }

    /// "1 linha inserida · 2 linhas atualizadas · 42 ms", seguido do SQL aplicado.
    static func commandSummary(statements: [String], result: QueryResult) -> String {
        var counts: [String: Int] = [:]
        for statement in statements {
            let verb = statement.split(separator: " ").first.map { String($0).uppercased() } ?? "COMANDO"
            counts[verb, default: 0] += 1
        }

        func describe(_ verb: String, _ count: Int) -> String {
            let plural = count == 1 ? "linha" : "linhas"
            switch verb {
            case "INSERT": return "\(count) \(plural) inserida\(count == 1 ? "" : "s")"
            case "UPDATE": return "\(count) \(plural) atualizada\(count == 1 ? "" : "s")"
            case "DELETE": return "\(count) \(plural) removida\(count == 1 ? "" : "s")"
            default: return "\(count) \(verb)"
            }
        }

        let summary = counts.keys.sorted()
            .map { describe($0, counts[$0] ?? 0) }
            .joined(separator: " · ")
        let milliseconds = Int((result.elapsed * 1000).rounded())
        let header = summary.isEmpty ? "Comando executado" : summary
        return "\(header) · \(milliseconds) ms\n\n" + statements.joined(separator: "\n")
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Scope

    private func textToRun(scope: QueryExecutionScope) -> String {
        if scope == .all { return sql }
        let selected = selectedSQL
        if !selected.isEmpty { return selected }

        switch scope {
        case .automatic:
            return sql
        case .selection:
            return statementUnderCursor() ?? sql
        case .all:
            return sql
        }
    }

    var hasSelection: Bool { !selectedSQL.isEmpty }

    private var selectedSQL: String {
        guard selection.length > 0 else { return "" }
        let length = (sql as NSString).length
        let location = min(max(selection.location, 0), length)
        let range = NSRange(location: location, length: min(selection.length, max(0, length - location)))
        guard range.length > 0, let swiftRange = Range(range, in: sql) else { return "" }
        return String(sql[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func statementUnderCursor() -> String? {
        let statements = SQLStatementSplitter.statements(in: sql)
        guard !statements.isEmpty else { return nil }

        let location = selection.location
        if let hit = statements.first(where: { NSLocationInRange(location, $0.range) }) {
            return hit.text
        }
        if location > 0, let hit = statements.first(where: { NSLocationInRange(location - 1, $0.range) }) {
            return hit.text
        }
        return nil
    }
}
