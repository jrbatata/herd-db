import Foundation
import HerdCore
import Observation

/// App-wide state: connections on disk and the drivers that serve them.
@MainActor
@Observable
final class AppModel {
    let connections: ConnectionStore
    let drivers: DriverRegistry
    let history: QueryHistoryStore
    let catalog: SQLCatalogStore
    let queryLog: QueryLogStore

    init() {
        let connections = ConnectionStore()
        let queryLog = QueryLogStore()
        self.connections = connections
        self.queryLog = queryLog
        self.drivers = DriverRegistry(store: connections, recorder: queryLog.recorder)
        self.history = QueryHistoryStore()
        self.catalog = SQLCatalogStore()
    }

    func save(_ config: ConnectionConfig, password: String?) throws {
        try connections.upsert(normalized(config), password: password)
        drivers.invalidate(config.id)
        catalog.invalidate(connectionID: config.id)
    }

    /// Atualiza metadados (como a proteção) sem derrubar a conexão aberta.
    func update(_ config: ConnectionConfig) throws {
        try connections.update(normalized(config))
    }

    /// Produção nunca fica sem proteção, venha a alteração de onde vier.
    private func normalized(_ config: ConnectionConfig) -> ConnectionConfig {
        guard config.isProduction, !config.safeMode.isRestricted else { return config }
        var updated = config
        updated.safeMode = .secure
        return updated
    }

    func remove(_ config: ConnectionConfig) throws {
        drivers.invalidate(config.id)
        catalog.invalidate(connectionID: config.id)
        try connections.remove(config)
    }
}
