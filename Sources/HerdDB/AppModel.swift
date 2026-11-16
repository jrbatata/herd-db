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

    init() {
        let connections = ConnectionStore()
        self.connections = connections
        self.drivers = DriverRegistry(store: connections)
        self.history = QueryHistoryStore()
        self.catalog = SQLCatalogStore()
    }

    func save(_ config: ConnectionConfig, password: String?) throws {
        try connections.upsert(config, password: password)
        drivers.invalidate(config.id)
        catalog.invalidate(connectionID: config.id)
    }

    /// Atualiza metadados (como o Safe Mode) sem derrubar a conexão aberta.
    func update(_ config: ConnectionConfig) throws {
        try connections.update(config)
    }

    func remove(_ config: ConnectionConfig) throws {
        drivers.invalidate(config.id)
        catalog.invalidate(connectionID: config.id)
        try connections.remove(config)
    }
}
