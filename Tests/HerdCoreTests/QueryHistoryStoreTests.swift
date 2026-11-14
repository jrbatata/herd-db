import Foundation
import XCTest
@testable import HerdCore

@MainActor
final class QueryHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herd-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsEntriesNewestFirst() {
        let store = QueryHistoryStore(directory: directory)
        let connection = UUID()

        store.record(connectionID: connection, database: "postgres", sql: "SELECT 1", duration: 0.01, rowCount: 1)
        store.record(connectionID: connection, database: "postgres", sql: "SELECT 2", duration: 0.02, rowCount: 1)

        XCTAssertEqual(store.entries.map(\.sql), ["SELECT 2", "SELECT 1"])
        XCTAssertEqual(store.entries(for: connection).count, 2)
    }

    func testDeduplicatesRepeatedCommand() {
        let store = QueryHistoryStore(directory: directory)
        let connection = UUID()

        store.record(connectionID: connection, database: "postgres", sql: "SELECT 1", duration: 0.01)
        store.record(connectionID: connection, database: "postgres", sql: "SELECT 2", duration: 0.01)
        store.record(connectionID: connection, database: "postgres", sql: "SELECT 1", duration: 0.03, rowCount: 7)

        XCTAssertEqual(store.entries.map(\.sql), ["SELECT 1", "SELECT 2"])
        XCTAssertEqual(store.entries[0].duration, 0.03)
        XCTAssertEqual(store.entries[0].rowCount, 7)
    }

    func testFiltersByConnectionAndDatabase() {
        let first = UUID()
        let second = UUID()
        let store = QueryHistoryStore(directory: directory)

        store.record(connectionID: first, database: "postgres", sql: "SELECT 1", duration: 0.01)
        store.record(connectionID: first, database: "app", sql: "SELECT 2", duration: 0.01)
        store.record(connectionID: second, database: "postgres", sql: "SELECT 3", duration: 0.01)

        XCTAssertEqual(store.entries(for: first).map(\.sql), ["SELECT 2", "SELECT 1"])
        XCTAssertEqual(store.entries(for: first, database: "postgres").map(\.sql), ["SELECT 1"])
        XCTAssertEqual(store.entries(for: second).map(\.sql), ["SELECT 3"])
    }

    func testCapsStoredEntries() {
        let store = QueryHistoryStore(directory: directory, limit: 3)
        for index in 0..<6 {
            store.record(connectionID: UUID(), database: "postgres", sql: "SELECT \(index)", duration: 0.01)
        }
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.sql), ["SELECT 5", "SELECT 4", "SELECT 3"])
    }

    func testPersistsAcrossInstances() {
        let connection = UUID()
        let store = QueryHistoryStore(directory: directory)
        store.record(connectionID: connection, database: "postgres", sql: "SELECT 42", duration: 0.5, rowCount: 1)

        let file = directory.appendingPathComponent("history.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes?[.posixPermissions] as? NSNumber, 0o600)

        let reloaded = QueryHistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].sql, "SELECT 42")
        XCTAssertEqual(reloaded.entries[0].connectionID, connection)
        XCTAssertEqual(reloaded.entries[0].rowCount, 1)
        XCTAssertEqual(reloaded.entries[0].duration, 0.5, accuracy: 0.001)
    }

    func testStoresFailures() {
        let store = QueryHistoryStore(directory: directory)
        store.record(
            connectionID: UUID(),
            database: "postgres",
            sql: "SELECT * FROM nope",
            duration: 0.01,
            errorMessage: "relation \"nope\" does not exist"
        )
        XCTAssertTrue(store.entries[0].isFailure)
        XCTAssertEqual(store.entries[0].errorMessage, "relation \"nope\" does not exist")
    }

    func testSummaryUsesFirstNonEmptyLine() {
        let entry = QueryHistoryEntry(
            connectionID: UUID(),
            database: "postgres",
            sql: "\n  -- comment\n  SELECT 1\n  FROM t;",
            duration: 0.01
        )
        XCTAssertEqual(entry.summary, "-- comment")
    }
}
