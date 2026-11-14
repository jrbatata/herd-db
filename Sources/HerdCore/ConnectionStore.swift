import Foundation
import Observation

/// Persists connection metadata as JSON in Application Support and passwords in the keychain.
@MainActor
@Observable
public final class ConnectionStore {
    public private(set) var connections: [ConnectionConfig] = []
    public private(set) var loadError: String?

    private let directory: URL
    private let fileURL: URL
    private let passwords: any PasswordStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil, passwords: any PasswordStore = KeychainStore()) {
        let directory = directory ?? Self.defaultDirectory
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("connections.json")
        self.passwords = passwords

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        load()
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("herd-db", isDirectory: true)
    }

    // MARK: - Reading

    public func password(for id: UUID) -> String? {
        passwords.password(for: id)
    }

    public func connection(id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    // MARK: - Writing

    public func upsert(_ config: ConnectionConfig, password: String?) throws {
        var updated = connections
        if let index = updated.firstIndex(where: { $0.id == config.id }) {
            updated[index] = config
        } else {
            updated.append(config)
        }

        try persist(updated)
        connections = updated
        try passwords.setPassword(password, for: config.id)
    }

    public func remove(_ config: ConnectionConfig) throws {
        var updated = connections
        updated.removeAll { $0.id == config.id }
        try persist(updated)
        connections = updated
        try passwords.setPassword(nil, for: config.id)
    }

    public func reload() {
        load()
    }

    // MARK: - Disk

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            connections = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            connections = try decoder.decode([ConnectionConfig].self, from: data)
            loadError = nil
        } catch {
            connections = []
            loadError = "Não foi possível ler \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func persist(_ list: [ConnectionConfig]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(list)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw HerdError.file("Não foi possível salvar as conexões: \(error.localizedDescription)")
        }
    }
}
