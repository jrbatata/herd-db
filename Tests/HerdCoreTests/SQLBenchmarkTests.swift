import Foundation
import XCTest
@testable import HerdCore

/// Benchmarks de tokenização e autocomplete por tamanho de script.
/// Rodam apenas com `HERD_BENCH=1` para não pesar na suíte normal:
///
///     HERD_BENCH=1 swift test --filter SQLBenchmarkTests
final class SQLBenchmarkTests: XCTestCase {
    private let catalog = SQLCatalog(
        schemas: ["public"],
        tables: [TableInfo(schema: "public", name: "users", kind: .table)],
        columns: [
            CatalogColumn(schema: "public", table: "users", name: "id", dataType: "integer"),
            CatalogColumn(schema: "public", table: "users", name: "name", dataType: "text"),
            CatalogColumn(schema: "public", table: "users", name: "created_at", dataType: "timestamp"),
        ]
    )

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HERD_BENCH"] == "1",
            "Defina HERD_BENCH=1 para rodar os benchmarks."
        )
    }

    // MARK: - Tokenizer

    func testTokenizer1kLines() { measureTokenizer(1_000) }
    func testTokenizer10kLines() { measureTokenizer(10_000) }
    func testTokenizer50kLines() { measureTokenizer(50_000) }

    private func measureTokenizer(_ lines: Int) {
        let sql = script(lines: lines)
        measure(metrics: [XCTClockMetric()]) {
            _ = SQLTokenizer.tokens(in: sql)
        }
    }

    // MARK: - Autocomplete

    func testCompletion1kLines() { measureCompletion(1_000) }
    func testCompletion10kLines() { measureCompletion(10_000) }
    func testCompletion50kLines() { measureCompletion(50_000) }

    private func measureCompletion(_ lines: Int) {
        let sql = script(lines: lines) + "\nSELECT * FROM users WHERE na"
        let cursor = (sql as NSString).length
        measure(metrics: [XCTClockMetric()]) {
            _ = SQLCompletionEngine.suggestions(in: sql, at: cursor, catalog: catalog)
        }
    }

    private func script(lines: Int) -> String {
        var sql = ""
        sql.reserveCapacity(lines * 44)
        for index in 0..<lines {
            sql += "SELECT id, name FROM users WHERE id = \(index);\n"
        }
        return sql
    }
}
