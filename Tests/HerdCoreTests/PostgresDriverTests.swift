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

        let failure = await XCTAssertThrowsErrorAsync {
            _ = try await driver.run("SELECT * FROM \(schema).does_not_exist;", database: "postgres")
        }
        XCTAssertNotNil(failure)
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
