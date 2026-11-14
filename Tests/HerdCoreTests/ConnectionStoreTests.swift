import Foundation
import XCTest
@testable import HerdCore

private final class InMemoryPasswordStore: PasswordStore {
    var values: [UUID: String] = [:]
    func password(for id: UUID) -> String? { values[id] }
    func setPassword(_ password: String?, for id: UUID) throws {
        values[id] = password
    }
}

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private var directory: URL!
    private var passwords: InMemoryPasswordStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-db-tests-\(UUID().uuidString)", isDirectory: true)
        passwords = InMemoryPasswordStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testUpsertPersistsAndClearsPassword() throws {
        let store = ConnectionStore(directory: directory, passwords: passwords)
        XCTAssertTrue(store.connections.isEmpty)

        var config = ConnectionConfig(name: "local", host: "127.0.0.1")
        try store.upsert(config, password: "segredo")
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.password(for: config.id), "segredo")

        let file = directory.appendingPathComponent("connections.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // A second store reads the same file.
        let reloaded = ConnectionStore(directory: directory, passwords: passwords)
        XCTAssertEqual(reloaded.connections, [config])

        config.name = "local renomeado"
        try reloaded.upsert(config, password: "outra")
        XCTAssertEqual(reloaded.connections.first?.name, "local renomeado")
        XCTAssertEqual(passwords.values[config.id], "outra")

        try reloaded.remove(config)
        XCTAssertTrue(reloaded.connections.isEmpty)
        XCTAssertNil(passwords.values[config.id])
    }

    func testCorruptedFileSurfacesLoadError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("connections.json"))

        let store = ConnectionStore(directory: directory, passwords: passwords)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertNotNil(store.loadError)
    }
}
