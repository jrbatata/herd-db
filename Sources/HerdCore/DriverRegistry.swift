import Foundation
import Observation

/// Keeps one driver alive per configured connection so every window shares it.
@MainActor
public final class DriverRegistry {
    private let store: ConnectionStore
    private var drivers: [UUID: any DatabaseDriver] = [:]

    public init(store: ConnectionStore) {
        self.store = store
    }

    public func driver(for config: ConnectionConfig) -> any DatabaseDriver {
        if let existing = drivers[config.id] { return existing }

        let driver: any DatabaseDriver
        switch config.engine {
        case .postgres:
            driver = PostgresDriver(config: config, password: store.password(for: config.id))
        case .sqlServer:
            driver = UnsupportedDriver(engine: .sqlServer)
        }
        drivers[config.id] = driver
        return driver
    }

    public func invalidate(_ id: UUID) {
        guard let driver = drivers.removeValue(forKey: id) else { return }
        Task { await driver.shutdown() }
    }

    public func shutdownAll() {
        let current = drivers.values
        drivers.removeAll()
        for driver in current {
            Task { await driver.shutdown() }
        }
    }
}
