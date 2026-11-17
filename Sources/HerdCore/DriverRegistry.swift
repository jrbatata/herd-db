import Foundation
import Observation

/// Keeps one driver alive per configured connection so every window shares it.
@MainActor
public final class DriverRegistry {
    private let store: ConnectionStore
    private let recorder: QueryLogRecorder?
    private var drivers: [UUID: any DatabaseDriver] = [:]

    public init(store: ConnectionStore, recorder: QueryLogRecorder? = nil) {
        self.store = store
        self.recorder = recorder
    }

    public func driver(for config: ConnectionConfig) -> any DatabaseDriver {
        if let existing = drivers[config.id] { return existing }

        let driver: any DatabaseDriver
        driver = DatabaseDriverFactory.make(
            config: config,
            password: store.password(for: config.id),
            recorder: recorder
        )
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

/// Escolhe o driver certo para a configuração, sem que a UI precise conhecer cada engine.
public enum DatabaseDriverFactory {
    public static func make(
        config: ConnectionConfig,
        password: String?,
        recorder: QueryLogRecorder? = nil
    ) -> any DatabaseDriver {
        switch config.engine {
        case .postgres:
            return PostgresDriver(config: config, password: password, recorder: recorder)
        case .sqlServer:
            return SQLServerDriver(config: config, password: password, recorder: recorder)
        }
    }
}
