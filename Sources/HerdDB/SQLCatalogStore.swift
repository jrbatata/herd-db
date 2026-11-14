import Foundation
import HerdCore
import Observation

/// Caches the object catalog (schemas, tables and columns) per connection/database.
/// Autocomplete loads it lazily the first time it is needed and reuses it afterwards.
@MainActor
@Observable
final class SQLCatalogStore {
    private struct Key: Hashable {
        let connectionID: UUID
        let database: String
    }

    private var catalogs: [Key: SQLCatalog] = [:]
    private var tasks: [Key: Task<SQLCatalog?, Never>] = [:]

    func catalog(
        connectionID: UUID,
        database: String,
        driver: any DatabaseDriver
    ) async -> SQLCatalog? {
        let key = Key(connectionID: connectionID, database: database)
        if let cached = catalogs[key] { return cached }
        if let running = tasks[key] { return await running.value }

        let task = Task<SQLCatalog?, Never> {
            try? await driver.catalog(database: database)
        }
        tasks[key] = task
        let value = await task.value
        tasks[key] = nil
        if let value {
            catalogs[key] = value
        }
        return value
    }

    func invalidate(connectionID: UUID) {
        for key in catalogs.keys where key.connectionID == connectionID {
            catalogs[key] = nil
        }
        for key in tasks.keys where key.connectionID == connectionID {
            tasks[key]?.cancel()
            tasks[key] = nil
        }
    }

    func invalidateAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        catalogs.removeAll()
    }
}
