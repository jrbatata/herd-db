import Foundation
import XCTest
@testable import HerdCore

@MainActor
final class QueryLogTests: XCTestCase {
    private let connectionID = UUID()

    private func makeEntry(
        _ sql: String,
        date: Date = Date(),
        source: QueryLogSource = .user,
        rowCount: Int = 0,
        errorMessage: String? = nil
    ) -> QueryLogEntry {
        QueryLogEntry(
            date: date,
            connectionID: connectionID,
            connectionName: "local",
            database: "postgres",
            sql: sql,
            source: source,
            duration: 0.01,
            rowCount: rowCount,
            errorMessage: errorMessage
        )
    }

    func testKeepsSmallSQLIntact() {
        let sql = "SELECT 1"
        let entry = makeEntry(sql)

        XCTAssertEqual(entry.sql, sql)
        XCTAssertFalse(entry.isTruncated)
        XCTAssertEqual(entry.originalLength, sql.count)
        XCTAssertNil(entry.truncatedNote)
    }

    func testTruncatesLargeSQLWithNote() {
        let sql = String(repeating: "a", count: QueryLogEntry.maximumSQLCharacters + 500)
        let entry = makeEntry(sql)

        XCTAssertTrue(entry.isTruncated)
        XCTAssertEqual(entry.sql.count, QueryLogEntry.maximumSQLCharacters)
        XCTAssertEqual(entry.originalLength, sql.count)
        XCTAssertNotNil(entry.truncatedNote)
    }

    func testSummaryUsesFirstNonEmptyLine() {
        let entry = makeEntry("\n\n  SELECT 1\nFROM t;")
        XCTAssertEqual(entry.summary, "SELECT 1")
    }

    func testStoreKeepsNewestFirst() {
        let store = QueryLogStore()
        let now = Date()

        store.append(makeEntry("SELECT 1", date: now.addingTimeInterval(-2)))
        store.append(makeEntry("SELECT 3", date: now))
        store.append(makeEntry("SELECT 2", date: now.addingTimeInterval(-1)))

        XCTAssertEqual(store.entries.map(\.sql), ["SELECT 3", "SELECT 2", "SELECT 1"])
    }

    func testStoreEnforcesLimit() {
        let store = QueryLogStore(limit: 3)
        let now = Date()

        for index in 0..<5 {
            store.append(makeEntry("SELECT \(index)", date: now.addingTimeInterval(Double(index))))
        }

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.sql), ["SELECT 4", "SELECT 3", "SELECT 2"])
    }

    func testStoreClearRemovesEverything() {
        let store = QueryLogStore()
        store.append(makeEntry("SELECT 1"))
        store.clear()

        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRecorderDeliversToSink() {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [QueryLogEntry] = []

            func append(_ entry: QueryLogEntry) {
                lock.lock()
                storage.append(entry)
                lock.unlock()
            }

            var entries: [QueryLogEntry] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        let box = Box()
        let recorder = QueryLogRecorder { box.append($0) }
        recorder.record(makeEntry("SELECT 1", source: .catalog))
        recorder.record(makeEntry("SELECT 2", source: .browse))

        XCTAssertEqual(box.entries.map(\.sql), ["SELECT 1", "SELECT 2"])
        XCTAssertEqual(box.entries.map(\.source), [.catalog, .browse])
    }
}
