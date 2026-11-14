import XCTest
@testable import HerdCore

final class SQLDialectTests: XCTestCase {
    func testPostgresQuoting() {
        let dialect = SQLDialect.postgres
        XCTAssertEqual(dialect.quote("orders"), "\"orders\"")
        XCTAssertEqual(dialect.quote("weird\"name"), "\"weird\"\"name\"")
        XCTAssertEqual(dialect.qualify(schema: "public", table: "orders"), "\"public\".\"orders\"")
        XCTAssertEqual(dialect.qualify(schema: nil, table: "orders"), "\"orders\"")
    }

    func testSQLServerQuoting() {
        let dialect = SQLDialect.sqlServer
        XCTAssertEqual(dialect.quote("Pedidos"), "[Pedidos]")
        XCTAssertEqual(dialect.quote("weird]name"), "[weird]]name]")
        XCTAssertEqual(dialect.qualify(schema: "dbo", table: "Pedidos"), "[dbo].[Pedidos]")
    }

    func testLimitedSelect() {
        XCTAssertEqual(
            SQLDialect.postgres.limitedSelect(schema: "public", table: "orders", limit: 100),
            "SELECT *\nFROM \"public\".\"orders\"\nLIMIT 100;"
        )
        XCTAssertEqual(
            SQLDialect.sqlServer.limitedSelect(schema: "dbo", table: "Pedidos", limit: 50),
            "SELECT TOP 50 *\nFROM [dbo].[Pedidos];"
        )
    }

    func testConnectionConfigDefaults() {
        let config = ConnectionConfig()
        XCTAssertEqual(config.engine, .postgres)
        XCTAssertEqual(config.port, 5432)
        XCTAssertEqual(config.maintenanceDatabase, "postgres")
        XCTAssertFalse(config.isRunnable)

        var named = config
        named.name = "local"
        XCTAssertTrue(named.isRunnable)

        named.engine = .sqlServer
        named.port = 1433
        XCTAssertFalse(named.isRunnable, "SQL Server has no driver yet")
    }
}
