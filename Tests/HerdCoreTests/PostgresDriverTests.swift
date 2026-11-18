import Foundation
import XCTest
@testable import HerdCore

/// Hits a real PostgreSQL server. Disabled unless HERD_TEST_PG=1.
final class PostgresDriverTests: XCTestCase {
    func testBrowseAndQuery() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let config = ConnectionConfig(
            name: "local",
            host: "127.0.0.1",
            port: 5432,
            username: ProcessInfo.processInfo.environment["PGUSER"] ?? NSUserName(),
            database: "postgres"
        )
        let driver = PostgresDriver(config: config, password: nil)
        addTeardownBlock { await driver.shutdown() }

        let info = try await driver.test()
        XCTAssertTrue(info.version.contains("PostgreSQL"), info.version)

        let databases = try await driver.listDatabases()
        XCTAssertTrue(databases.contains { $0.name == "postgres" })

        let schema = "herd_test_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock {
            _ = try? await driver.run("DROP SCHEMA IF EXISTS \(schema) CASCADE;", database: "postgres")
        }

        _ = try await driver.run("CREATE SCHEMA \(schema);", database: "postgres")
        _ = try await driver.run(
            "CREATE TABLE \(schema).owners (id serial PRIMARY KEY, name text NOT NULL);",
            database: "postgres"
        )
        _ = try await driver.run(
            """
            CREATE TABLE \(schema).items (
                id serial PRIMARY KEY,
                owner_id integer REFERENCES \(schema).owners(id),
                name text NOT NULL,
                price numeric(10,2),
                created_at timestamptz DEFAULT now()
            );
            """,
            database: "postgres"
        )
        _ = try await driver.run(
            "INSERT INTO \(schema).items (owner_id, name, price) VALUES (NULL, 'Água', 12.50), (NULL, 'Café', NULL);",
            database: "postgres"
        )

        let schemas = try await driver.listSchemas(database: "postgres")
        XCTAssertTrue(schemas.contains { $0.name == schema })

        let tables = try await driver.listTables(database: "postgres", schema: schema)
        XCTAssertEqual(Set(tables.map(\.name)), ["owners", "items"])

        let columns = try await driver.listColumns(database: "postgres", schema: schema, table: "items")
        XCTAssertEqual(columns.map(\.name), ["id", "owner_id", "name", "price", "created_at"])

        let id = try XCTUnwrap(columns.first { $0.name == "id" })
        XCTAssertTrue(id.isPrimaryKey)
        XCTAssertFalse(id.isNullable)

        let owner = try XCTUnwrap(columns.first { $0.name == "owner_id" })
        XCTAssertEqual(owner.references, "\(schema).owners.id")

        let price = try XCTUnwrap(columns.first { $0.name == "price" })
        XCTAssertTrue(price.isNullable)

        let result = try await driver.run(
            "SELECT name, price FROM \(schema).items ORDER BY name;",
            database: "postgres"
        )
        XCTAssertEqual(result.columns, ["name", "price"])
        XCTAssertEqual(result.rows.count, 2)

        let agua = try XCTUnwrap(result.rows.first { $0[0] == "Água" })
        XCTAssertEqual(agua[1], "12.5")

        let cafe = try XCTUnwrap(result.rows.first { $0[0] == "Café" })
        XCTAssertNil(cafe[1])

        let firstPage = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 1, filter: "", sortColumn: nil, descending: false
        )
        XCTAssertEqual(firstPage.totalRows, 2)
        XCTAssertEqual(firstPage.result.rows.count, 1)
        XCTAssertEqual(firstPage.result.rows.first?[2], "Água")

        let secondPage = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 1,
            pageSize: 1, filter: "", sortColumn: "name", descending: false
        )
        XCTAssertEqual(secondPage.page, 1)
        XCTAssertEqual(secondPage.result.rows.first?[2], "Café")

        let filteredPage = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "Ág", sortColumn: "name", descending: true
        )
        XCTAssertEqual(filteredPage.totalRows, 1)
        XCTAssertEqual(filteredPage.result.rows.first?[2], "Água")

        let onlyFilled = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "", sortColumn: "name", descending: false,
            columnFilters: [ColumnFilter(column: "price", operation: .isNotEmpty)]
        )
        XCTAssertEqual(onlyFilled.totalRows, 1)
        XCTAssertEqual(onlyFilled.result.rows.first?[2], "Água")

        let onlyEmpty = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "", sortColumn: "name", descending: false,
            columnFilters: [ColumnFilter(column: "price", operation: .isEmpty)]
        )
        XCTAssertEqual(onlyEmpty.totalRows, 1)
        XCTAssertEqual(onlyEmpty.result.rows.first?[2], "Café")

        let contains = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "", sortColumn: "name", descending: false,
            columnFilters: [ColumnFilter(column: "name", operation: .contains, value: "ÁG")]
        )
        XCTAssertEqual(contains.totalRows, 1)
        XCTAssertEqual(contains.result.rows.first?[2], "Água")

        let unknownColumn = try await driver.browseTable(
            database: "postgres", schema: schema, table: "items", page: 0,
            pageSize: 500, filter: "", sortColumn: nil, descending: false,
            columnFilters: [ColumnFilter(column: "não_existe", operation: .isEmpty)]
        )
        XCTAssertEqual(unknownColumn.totalRows, 2, "Colunas fora do catálogo devem ser ignoradas.")

        let binaries = try await driver.run(
            #"SELECT ''::bytea AS empty, '\x00ff'::bytea AS data, NULL::bytea AS missing;"#,
            database: "postgres"
        )
        XCTAssertEqual(binaries.rows[0][0], "")
        XCTAssertEqual(binaries.rows[0][1], "\\x00ff")
        XCTAssertNil(binaries.rows[0][2])

        let failure = await XCTAssertThrowsErrorAsync {
            _ = try await driver.run("SELECT * FROM \(schema).does_not_exist;", database: "postgres")
        }
        XCTAssertNotNil(failure)
    }

    // MARK: - Phase 3: catalog

    func testCatalogSnapshotIncludesSchemasTablesViewsAndColumns() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let schema = "herd_catalog_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock {
            _ = try? await driver.run("DROP SCHEMA IF EXISTS \(schema) CASCADE;", database: "postgres")
        }

        _ = try await driver.run(
            """
            CREATE SCHEMA \(schema);
            CREATE TABLE \(schema).owners (id serial PRIMARY KEY, name text NOT NULL);
            CREATE VIEW \(schema).owner_names AS SELECT name FROM \(schema).owners;
            """,
            database: "postgres"
        )

        let catalog = try await driver.catalog(database: "postgres")

        XCTAssertTrue(catalog.schemas.contains(schema))
        XCTAssertFalse(catalog.schemas.contains("pg_catalog"))
        XCTAssertFalse(catalog.schemas.contains("information_schema"))

        let tables = catalog.tables(in: schema)
        XCTAssertEqual(Set(tables.map(\.name)), ["owners", "owner_names"])
        XCTAssertEqual(tables.first { $0.name == "owner_names" }?.kind, .view)

        let columns = catalog.columns(schema: schema, table: "owners")
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(columns.first { $0.name == "id" }?.dataType, "integer")

        let flat = try await driver.listCatalogColumns(database: "postgres")
        XCTAssertTrue(flat.contains { $0.schema == schema && $0.table == "owners" && $0.name == "name" })
    }

    // MARK: - Phase 2: scripts and cancellation

    func testRunsScriptSequentiallyAndReturnsLastResultSet() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let result = try await driver.run(
            """
            SELECT 1 AS first;
            SELECT 2 AS second;
            """,
            database: "postgres"
        )

        XCTAssertEqual(result.statementCount, 2)
        XCTAssertEqual(result.columns, ["second"])
        XCTAssertEqual(result.rows, [["2"]])
        XCTAssertEqual(result.message, "2 comandos executados")
    }

    func testRunsCommandsWithoutResultSet() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let schema = "herd_script_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock {
            _ = try? await driver.run("DROP SCHEMA IF EXISTS \(schema) CASCADE;", database: "postgres")
        }

        let result = try await driver.run(
            """
            CREATE SCHEMA \(schema);
            CREATE TABLE \(schema).items (id int);
            INSERT INTO \(schema).items VALUES (1), (2);
            """,
            database: "postgres"
        )

        XCTAssertEqual(result.statementCount, 3)
        XCTAssertTrue(result.isEmptyResultSet)
        XCTAssertEqual(result.message, "3 comandos executados")

        let counted = try await driver.run("SELECT count(*) AS total FROM \(schema).items;", database: "postgres")
        XCTAssertEqual(counted.rows, [["2"]])
    }

    func testScriptErrorNamesTheFailingCommand() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let error = await XCTAssertThrowsErrorAsync {
            _ = try await driver.run(
                "SELECT 1; SELECT * FROM herd_table_that_does_not_exist;",
                database: "postgres"
            )
        }
        let message = try XCTUnwrap(error?.localizedDescription)
        XCTAssertTrue(message.hasPrefix("Comando 2 de 2:"), message)
        XCTAssertTrue(message.contains("herd_table_that_does_not_exist"), message)
    }

    func testContinuesAfterLargeResultSet() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let result = try await driver.run(
            "SELECT generate_series(1, 25000) AS n; SELECT 'done' AS status;",
            database: "postgres"
        )

        XCTAssertEqual(result.statementCount, 2)
        XCTAssertEqual(result.columns, ["status"])
        XCTAssertEqual(result.rows, [["done"]])

        let after = try await driver.run("SELECT 1 AS ok;", database: "postgres")
        XCTAssertEqual(after.rows, [["1"]])
    }

    func testCancelKeepsTheConnectionUsable() async throws {
        guard ProcessInfo.processInfo.environment["HERD_TEST_PG"] == "1" else {
            throw XCTSkip("Set HERD_TEST_PG=1 to run against the local PostgreSQL server.")
        }

        let driver = try await makeDriver()
        addTeardownBlock { await driver.shutdown() }

        let start = Date()
        let task = Task {
            try await driver.run("SELECT pg_sleep(30);", database: "postgres")
        }

        try await Task.sleep(for: .milliseconds(700))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A execução deveria ter sido cancelada.")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Erro inesperado ao cancelar: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 10)

        let after = try await driver.run("SELECT 42 AS answer;", database: "postgres")
        XCTAssertEqual(after.rows, [["42"]])
    }

    private func makeDriver() async throws -> PostgresDriver {
        let config = ConnectionConfig(
            name: "local",
            host: "127.0.0.1",
            port: 5432,
            username: ProcessInfo.processInfo.environment["PGUSER"] ?? NSUserName(),
            database: "postgres"
        )
        return PostgresDriver(config: config, password: nil)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Error? {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
