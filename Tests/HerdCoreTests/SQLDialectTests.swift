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

    func testReadyQueries() {
        let dialect = SQLDialect.postgres
        XCTAssertEqual(
            dialect.readyQuery(.select, schema: "public", table: "orders"),
            "SELECT *\nFROM \"public\".\"orders\";"
        )
        XCTAssertEqual(
            dialect.readyQuery(.selectLimited, schema: nil, table: "orders"),
            "SELECT *\nFROM \"orders\"\nLIMIT 10;"
        )
        XCTAssertEqual(
            dialect.readyQuery(.insert, schema: "public", table: "orders"),
            "INSERT INTO \"public\".\"orders\" (coluna1, coluna2)\nVALUES (valor1, valor2);"
        )
        XCTAssertEqual(
            dialect.readyQuery(.update, schema: "public", table: "orders"),
            "UPDATE \"public\".\"orders\"\nSET coluna1 = valor1\nWHERE condicao;"
        )
        XCTAssertEqual(
            dialect.readyQuery(.delete, schema: "public", table: "orders"),
            "DELETE FROM \"public\".\"orders\"\nWHERE condicao;"
        )
    }

    func testReadyQueryTitles() {
        XCTAssertEqual(
            SQLReadyQuery.allCases.map(\.title),
            ["SELECT", "SELECT (10 linhas)", "INSERT", "UPDATE", "DELETE"]
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
