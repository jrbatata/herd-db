import Foundation
import HerdCore
import Observation

/// App-wide state: connections on disk and the drivers that serve them.
@MainActor
@Observable
final class AppModel {
    let connections: ConnectionStore
    let drivers: DriverRegistry

    init() {
        let connections = ConnectionStore()
        self.connections = connections
        self.drivers = DriverRegistry(store: connections)
    }

    func save(_ config: ConnectionConfig, password: String?) throws {
        try connections.upsert(config, password: password)
        drivers.invalidate(config.id)
    }

    func remove(_ config: ConnectionConfig) throws {
        drivers.invalidate(config.id)
        try connections.remove(config)
    }
}
