import Foundation
import HerdCore
import Observation

enum QueryRunState {
    case idle
    case running
    case success(QueryResult)
    case failure(String)
}

struct QueryContext: Sendable {
    var connectionID: UUID
    var database: String
    var schema: String?
    var label: String
}

@MainActor
@Observable
final class QueryTab: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let database: String
    let schema: String?
    let contextLabel: String

    var title: String
    var sql: String
    var state: QueryRunState = .idle

    @ObservationIgnored private var task: Task<Void, Never>?

    init(title: String, sql: String, context: QueryContext) {
        self.title = title
        self.sql = sql
        self.connectionID = context.connectionID
        self.database = context.database
        self.schema = context.schema
        self.contextLabel = context.label
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func run(app: AppModel) {
        guard !isRunning else { return }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let config = app.connections.connection(id: connectionID) else {
            state = .failure("Esta conexão não existe mais.")
            return
        }

        let driver = app.drivers.driver(for: config)
        let sql = self.sql
        let database = self.database
        state = .running

        task = Task { [weak self] in
            do {
                let result = try await driver.run(sql, database: database)
                guard !Task.isCancelled else { return }
                self?.state = .success(result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failure(error.localizedDescription)
            }
        }
    }
}
